import Darwin
import Foundation

public struct CommandResult: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32
    public let stdoutWasTruncated: Bool
    public let stderrWasTruncated: Bool

    public init(
        stdout: Data,
        stderr: Data,
        exitCode: Int32,
        stdoutWasTruncated: Bool = false,
        stderrWasTruncated: Bool = false
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.stdoutWasTruncated = stdoutWasTruncated
        self.stderrWasTruncated = stderrWasTruncated
    }
}

public protocol CommandRunning: Sendable {
    func run(executable: URL, arguments: [String]) async throws -> CommandResult
}

public enum CommandRunError: Error, LocalizedError, Equatable {
    case timedOut(executable: String)
    case outputReadFailed(stream: String, message: String)

    public var errorDescription: String? {
        switch self {
        case let .timedOut(executable):
            return "\(executable) の実行がタイムアウトしました"
        case let .outputReadFailed(stream, message):
            return "\(stream) の読み取りに失敗しました: \(message)"
        }
    }
}

public struct FoundationCommandRunner: CommandRunning {
    private let timeout: TimeInterval
    private let maximumOutputBytes: Int

    public init(timeout: TimeInterval = 3, maximumOutputBytes: Int = 8 * 1_024 * 1_024) {
        self.timeout = timeout.isFinite ? max(0, timeout) : 3
        self.maximumOutputBytes = maximumOutputBytes
    }

    public func run(executable: URL, arguments: [String]) async throws -> CommandResult {
        let invocation = BlockingCommandInvocation(
            executable: executable,
            arguments: arguments,
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes
        )
        return try await Task.detached(priority: .utility) {
            try invocation.run()
        }.value
    }
}

private struct BlockingCommandInvocation: Sendable {
    let executable: URL
    let arguments: [String]
    let timeout: TimeInterval
    let maximumOutputBytes: Int

    func run() throws -> CommandResult {
        let command = try SpawnedCommand.launch(
            executable: executable,
            arguments: arguments
        )
        defer {
            command.child.terminateAndReapIfNeeded()
        }

        let outputCollector = DataCollector(maximumBytes: maximumOutputBytes)
        let errorCollector = DataCollector(maximumBytes: maximumOutputBytes)
        let outputReader = PipeReader(
            fileHandle: command.standardOutput,
            collector: outputCollector
        )
        let errorReader = PipeReader(
            fileHandle: command.standardError,
            collector: errorCollector
        )
        let readers = DispatchGroup()
        outputReader.start(in: readers)
        errorReader.start(in: readers)
        defer {
            if readers.wait(timeout: .now()) == .timedOut {
                outputReader.close()
                errorReader.close()
            }
        }

        guard let waitStatus = try command.child.waitForExit(for: timeout) else {
            defer {
                finishReadersAfterTimeout(
                    readers,
                    outputReader: outputReader,
                    errorReader: errorReader
                )
            }
            try terminateAfterTimeout(command.child)
            throw CommandRunError.timedOut(executable: executable.path)
        }

        try finishReadersAfterExit(
            readers,
            outputReader: outputReader,
            errorReader: errorReader
        )

        return CommandResult(
            stdout: outputCollector.data,
            stderr: errorCollector.data,
            exitCode: exitCode(fromWaitStatus: waitStatus),
            stdoutWasTruncated: outputCollector.wasTruncated,
            stderrWasTruncated: errorCollector.wasTruncated
        )
    }

    private func terminateAfterTimeout(_ child: SpawnedChild) throws {
        try child.send(signal: SIGTERM)
        if try child.waitForExit(for: 0.5) == nil {
            try child.send(signal: SIGKILL)
            if try child.waitForExit(for: 0.5) == nil {
                child.transferReapingToBackground()
            }
        }
    }

    private func finishReadersAfterExit(
        _ readers: DispatchGroup,
        outputReader: PipeReader,
        errorReader: PipeReader
    ) throws {
        guard readers.wait(timeout: .now() + 1) == .success else {
            outputReader.close()
            errorReader.close()
            _ = readers.wait(timeout: .now() + 0.25)
            throw CommandRunError.outputReadFailed(
                stream: "標準出力/標準エラー",
                message: "子プロセス終了後も出力パイプが閉じられませんでした"
            )
        }
        try throwReaderErrorIfNeeded(outputReader, errorReader: errorReader)
    }

    private func finishReadersAfterTimeout(
        _ readers: DispatchGroup,
        outputReader: PipeReader,
        errorReader: PipeReader
    ) {
        if readers.wait(timeout: .now() + 1) == .timedOut {
            outputReader.close()
            errorReader.close()
            _ = readers.wait(timeout: .now() + 0.25)
        }
    }

    private func throwReaderErrorIfNeeded(
        _ outputReader: PipeReader,
        errorReader: PipeReader
    ) throws {
        if let message = outputReader.errorDescription {
            throw CommandRunError.outputReadFailed(stream: "標準出力", message: message)
        }
        if let message = errorReader.errorDescription {
            throw CommandRunError.outputReadFailed(stream: "標準エラー", message: message)
        }
    }

    private func exitCode(fromWaitStatus waitStatus: Int32) -> Int32 {
        let terminationStatus = waitStatus & 0x7f
        if terminationStatus == 0 {
            return (waitStatus >> 8) & 0xff
        }
        return 128 + terminationStatus
    }
}

private struct SpawnedCommand {
    let child: SpawnedChild
    let standardOutput: FileHandle
    let standardError: FileHandle

    static func launch(executable: URL, arguments: [String]) throws -> SpawnedCommand {
        let outputPipe = try DescriptorPipe.make()
        let errorPipe = try DescriptorPipe.make()
        var fileActions: posix_spawn_file_actions_t?
        try requirePOSIXSuccess(posix_spawn_file_actions_init(&fileActions))
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
        }

        try configureFileActions(
            &fileActions,
            outputPipe: outputPipe,
            errorPipe: errorPipe
        )

        var attributes: posix_spawnattr_t?
        try requirePOSIXSuccess(posix_spawnattr_init(&attributes))
        defer {
            posix_spawnattr_destroy(&attributes)
        }
        try configureAttributes(&attributes)

        let executablePath = executable.path
        var processID = pid_t(0)
        let spawnResult = try withCStringArray([executablePath] + arguments) { argumentPointer in
            executablePath.withCString { executablePointer in
                posix_spawn(
                    &processID,
                    executablePointer,
                    &fileActions,
                    &attributes,
                    argumentPointer,
                    environ
                )
            }
        }
        try requirePOSIXSuccess(spawnResult)

        outputPipe.writeEnd.close()
        errorPipe.writeEnd.close()
        return SpawnedCommand(
            child: SpawnedChild(processID: processID),
            standardOutput: FileHandle(
                fileDescriptor: outputPipe.readEnd.take(),
                closeOnDealloc: true
            ),
            standardError: FileHandle(
                fileDescriptor: errorPipe.readEnd.take(),
                closeOnDealloc: true
            )
        )
    }

    private static func configureFileActions(
        _ fileActions: inout posix_spawn_file_actions_t?,
        outputPipe: DescriptorPipe,
        errorPipe: DescriptorPipe
    ) throws {
        try requirePOSIXSuccess(
            posix_spawn_file_actions_adddup2(
                &fileActions,
                outputPipe.writeEnd.rawValue,
                STDOUT_FILENO
            )
        )
        try requirePOSIXSuccess(
            posix_spawn_file_actions_adddup2(
                &fileActions,
                errorPipe.writeEnd.rawValue,
                STDERR_FILENO
            )
        )

        for descriptor in [
            outputPipe.readEnd.rawValue,
            outputPipe.writeEnd.rawValue,
            errorPipe.readEnd.rawValue,
            errorPipe.writeEnd.rawValue
        ] {
            try requirePOSIXSuccess(
                posix_spawn_file_actions_addclose(&fileActions, descriptor)
            )
        }
    }

    private static func configureAttributes(
        _ attributes: inout posix_spawnattr_t?
    ) throws {
        var signalMask = sigset_t()
        guard sigemptyset(&signalMask) == 0 else {
            throw makePOSIXError(errno)
        }
        try requirePOSIXSuccess(
            posix_spawnattr_setsigmask(&attributes, &signalMask)
        )

        var defaultSignals = sigset_t()
        guard sigemptyset(&defaultSignals) == 0 else {
            throw makePOSIXError(errno)
        }
        for signal in [SIGHUP, SIGINT, SIGQUIT, SIGPIPE, SIGTERM] {
            guard sigaddset(&defaultSignals, signal) == 0 else {
                throw makePOSIXError(errno)
            }
        }
        try requirePOSIXSuccess(
            posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        )

        let flags = Int16(
            POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETSIGDEF
                | POSIX_SPAWN_SETSIGMASK
        )
        try requirePOSIXSuccess(posix_spawnattr_setflags(&attributes, flags))
    }
}

private final class SpawnedChild {
    let processID: pid_t
    private var isReaped = false
    private var reapingWasTransferred = false
    private var storedWaitStatus: Int32?

    init(processID: pid_t) {
        self.processID = processID
    }

    func waitForExit(for interval: TimeInterval) throws -> Int32? {
        let deadline = DispatchTime.now() + max(0, interval)
        while true {
            if let waitStatus = try pollForExit() {
                return waitStatus
            }

            let now = DispatchTime.now().uptimeNanoseconds
            let deadlineNanoseconds = deadline.uptimeNanoseconds
            guard now < deadlineNanoseconds else {
                return nil
            }
            let remainingMicroseconds = (deadlineNanoseconds - now) / 1_000
            usleep(useconds_t(min(10_000, max(1, remainingMicroseconds))))
        }
    }

    func send(signal: Int32) throws {
        guard ownsReapingResponsibility else {
            return
        }
        guard
            processID > 1,
            processID != getpid(),
            signal == SIGTERM || signal == SIGKILL
        else {
            throw POSIXError(.EINVAL)
        }

        guard Darwin.kill(processID, signal) == 0 else {
            let code = errno
            if code == ESRCH {
                return
            }
            throw makePOSIXError(code)
        }
    }

    func terminateAndReapIfNeeded() {
        guard ownsReapingResponsibility else {
            return
        }
        try? send(signal: SIGKILL)
        do {
            if try waitForExit(for: 0.25) == nil {
                transferReapingToBackground()
            }
        } catch {
            transferReapingToBackground()
        }
    }

    func transferReapingToBackground() {
        guard ownsReapingResponsibility else {
            return
        }
        reapingWasTransferred = true
        BackgroundChildReaper.reap(processID: processID)
    }

    private func pollForExit() throws -> Int32? {
        if let storedWaitStatus {
            return storedWaitStatus
        }
        guard ownsReapingResponsibility else {
            throw POSIXError(.ECHILD)
        }

        var waitStatus = Int32(0)
        while true {
            let result = Darwin.waitpid(processID, &waitStatus, WNOHANG)
            if result == processID {
                markReaped(waitStatus: waitStatus)
                return waitStatus
            }
            if result == 0 {
                return nil
            }
            if result == -1, errno == EINTR {
                continue
            }
            if result == -1, errno == ECHILD {
                isReaped = true
            }
            throw makePOSIXError(errno)
        }
    }

    private func markReaped(waitStatus: Int32) {
        storedWaitStatus = waitStatus
        isReaped = true
    }

    private var ownsReapingResponsibility: Bool {
        !isReaped && !reapingWasTransferred
    }
}

private enum BackgroundChildReaper {
    private static let queue = DispatchQueue(
        label: "com.local.port-watch.child-reaper",
        qos: .utility,
        attributes: .concurrent
    )

    static func reap(processID: pid_t) {
        queue.async {
            var waitStatus = Int32(0)
            while true {
                let result = Darwin.waitpid(processID, &waitStatus, 0)
                if result == processID {
                    return
                }
                if result == -1, errno == EINTR {
                    continue
                }
                return
            }
        }
    }
}

private struct DescriptorPipe {
    let readEnd: OwnedFileDescriptor
    let writeEnd: OwnedFileDescriptor

    static func make() throws -> DescriptorPipe {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&descriptors) == 0 else {
            throw makePOSIXError(errno)
        }

        let pipe = DescriptorPipe(
            readEnd: OwnedFileDescriptor(descriptors[0]),
            writeEnd: OwnedFileDescriptor(descriptors[1])
        )
        try pipe.readEnd.prepareForSpawnPipe()
        try pipe.writeEnd.prepareForSpawnPipe()
        return pipe
    }
}

private final class OwnedFileDescriptor {
    private var descriptor: Int32?

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close()
    }

    var rawValue: Int32 {
        guard let descriptor else {
            preconditionFailure("ファイルディスクリプタの所有権は移動済みです")
        }
        return descriptor
    }

    func take() -> Int32 {
        let descriptor = rawValue
        self.descriptor = nil
        return descriptor
    }

    func close() {
        guard let descriptor else {
            return
        }
        self.descriptor = nil
        _ = Darwin.close(descriptor)
    }

    func prepareForSpawnPipe() throws {
        let currentDescriptor = rawValue
        if currentDescriptor <= STDERR_FILENO {
            let duplicate = Darwin.fcntl(
                currentDescriptor,
                F_DUPFD_CLOEXEC,
                STDERR_FILENO + 1
            )
            guard duplicate != -1 else {
                throw makePOSIXError(errno)
            }
            descriptor = duplicate
            _ = Darwin.close(currentDescriptor)
            return
        }

        guard Darwin.fcntl(currentDescriptor, F_SETFD, FD_CLOEXEC) != -1 else {
            throw makePOSIXError(errno)
        }
    }
}

private func withCStringArray<Result>(
    _ strings: [String],
    body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
) throws -> Result {
    var pointers: [UnsafeMutablePointer<CChar>?] = []
    pointers.reserveCapacity(strings.count + 1)
    defer {
        for case let pointer? in pointers {
            Darwin.free(pointer)
        }
    }

    for string in strings {
        guard !string.utf8.contains(0) else {
            throw POSIXError(.EINVAL)
        }
        guard let pointer = Darwin.strdup(string) else {
            throw POSIXError(.ENOMEM)
        }
        pointers.append(pointer)
    }
    pointers.append(nil)

    return try pointers.withUnsafeMutableBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress else {
            throw POSIXError(.EINVAL)
        }
        return try body(baseAddress)
    }
}

private func requirePOSIXSuccess(_ result: Int32) throws {
    guard result == 0 else {
        throw makePOSIXError(result)
    }
}

private func makePOSIXError(_ code: Int32) -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
}

private final class DataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var storage = Data()
    private var didTruncate = false

    init(maximumBytes: Int) {
        self.maximumBytes = max(0, maximumBytes)
    }

    var data: Data {
        lock.withLock { storage }
    }

    var wasTruncated: Bool {
        lock.withLock { didTruncate }
    }

    func append(_ data: Data) {
        guard !data.isEmpty else {
            return
        }
        lock.withLock {
            let remainingBytes = maximumBytes - storage.count
            guard remainingBytes > 0 else {
                didTruncate = true
                return
            }

            if data.count <= remainingBytes {
                storage.append(data)
            } else {
                storage.append(data.prefix(remainingBytes))
                didTruncate = true
            }
        }
    }
}

private final class PipeReader: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let collector: DataCollector
    private let lock = NSLock()
    private var storedErrorDescription: String?

    init(fileHandle: FileHandle, collector: DataCollector) {
        self.fileHandle = fileHandle
        self.collector = collector
    }

    var errorDescription: String? {
        lock.withLock { storedErrorDescription }
    }

    func start(in group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer {
                group.leave()
            }

            while true {
                do {
                    guard
                        let chunk = try fileHandle.read(upToCount: 64 * 1_024),
                        !chunk.isEmpty
                    else {
                        return
                    }
                    collector.append(chunk)
                } catch {
                    lock.withLock {
                        if storedErrorDescription == nil {
                            storedErrorDescription = error.localizedDescription
                        }
                    }
                    return
                }
            }
        }
    }

    func close() {
        try? fileHandle.close()
    }
}
