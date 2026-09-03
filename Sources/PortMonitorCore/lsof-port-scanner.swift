import Foundation

public protocol PortScanning: Sendable {
    func scan() async throws -> [ListeningPort]
}

public enum PortScanError: Error, LocalizedError, Equatable {
    case commandFailed(exitCode: Int32, message: String)
    case outputTooLarge

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(exitCode, message):
            if message.isEmpty {
                return "ポート一覧を取得できませんでした（終了コード: \(exitCode)）"
            }
            return "ポート一覧を取得できませんでした: \(message)"
        case .outputTooLarge:
            return "ポート一覧が大きすぎるため、安全のため読み取りを中止しました"
        }
    }
}

public struct LsofPortScanner: PortScanning {
    private static let maximumProcessCount = 4_096

    private let commandRunner: any CommandRunning
    private let identityReader: any ProcessIdentityReading
    private let parser: LsofOutputParser
    private let fileExists: @Sendable (String) -> Bool

    public init(
        commandRunner: any CommandRunning = FoundationCommandRunner(),
        identityReader: any ProcessIdentityReading = DarwinProcessIdentityReader(),
        parser: LsofOutputParser = LsofOutputParser(),
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.commandRunner = commandRunner
        self.identityReader = identityReader
        self.parser = parser
        self.fileExists = fileExists
    }

    public func scan() async throws -> [ListeningPort] {
        let candidatePorts = try await listeningPorts()
        guard !candidatePorts.isEmpty else {
            return []
        }

        let candidateProcessIDs = Set(candidatePorts.map(\.processID)).sorted()
        guard candidateProcessIDs.count <= Self.maximumProcessCount else {
            throw PortScanError.outputTooLarge
        }
        let identitiesBefore = identities(for: candidateProcessIDs)
        let confirmedPorts = try await listeningPorts(for: candidateProcessIDs)
        guard !confirmedPorts.isEmpty else {
            return []
        }

        let confirmedProcessIDs = Set(confirmedPorts.map(\.processID)).sorted()
        let directories = await workingDirectories(
            for: confirmedProcessIDs
        )
        let identitiesAfter = identities(for: confirmedProcessIDs)

        return confirmedPorts.map { port in
            let identityBefore = identitiesBefore[port.processID]
            let identityAfter = identitiesAfter[port.processID]
            let identity = identityBefore == identityAfter ? identityAfter : nil
            let directory = identity == nil ? nil : directories[port.processID]

            return ListeningPort(
                processID: port.processID,
                processName: port.processName,
                userID: identity?.ownerUserID ?? port.userID,
                userName: port.userName,
                port: port.port,
                addresses: port.addresses,
                workingDirectory: directory,
                isWorkingDirectoryMissing: directory.map { !fileExists($0) } ?? false,
                identity: identity
            )
        }
    }

    private func listeningPorts(for processIDs: [Int32]? = nil) async throws -> [ListeningPort] {
        var arguments = ["-nP"]
        if let processIDs {
            guard !processIDs.isEmpty else {
                return []
            }
            arguments.append(contentsOf: [
                "-a",
                "-p", processIDs.map(String.init).joined(separator: ",")
            ])
        }
        arguments.append(contentsOf: ["-iTCP", "-sTCP:LISTEN", "-F0pcuLfn"])

        let result = try await commandRunner.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: arguments
        )

        guard !result.stdoutWasTruncated, !result.stderrWasTruncated else {
            throw PortScanError.outputTooLarge
        }
        guard result.exitCode == 0 || result.exitCode == 1 else {
            let messageData = result.stderr.isEmpty ? result.stdout : result.stderr
            let message = String(decoding: messageData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw PortScanError.commandFailed(exitCode: result.exitCode, message: message)
        }
        return parser.parse(result.stdout)
    }

    private func identities(for processIDs: [Int32]) -> [Int32: ProcessIdentity] {
        Dictionary(uniqueKeysWithValues: processIDs.compactMap { processID in
            identityReader.identity(for: processID).map { (processID, $0) }
        })
    }

    private func workingDirectories(for processIDs: [Int32]) async -> [Int32: String] {
        guard !processIDs.isEmpty else {
            return [:]
        }

        do {
            let result = try await commandRunner.run(
                executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
                arguments: [
                    "-a",
                    "-p", processIDs.map(String.init).joined(separator: ","),
                    "-d", "cwd",
                    "-F0pfn"
                ]
            )
            guard !result.stdoutWasTruncated, !result.stderrWasTruncated else {
                return [:]
            }
            guard result.exitCode == 0 || result.exitCode == 1 else {
                return [:]
            }
            return parser.parseWorkingDirectories(result.stdout)
        } catch {
            return [:]
        }
    }
}
