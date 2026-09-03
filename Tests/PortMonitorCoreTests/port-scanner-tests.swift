import XCTest
@testable import PortMonitorCore

final class PortScannerTests: XCTestCase {
    func testScansListenersAndEnrichesProcessMetadata() async throws {
        let listenerOutput = makeLsofData([
            "p42", "cnode", "u502", "Ldeveloper", "\nf10", "n127.0.0.1:3001",
            "\nf11", "n[::1]:3001"
        ])
        let cwdOutput = makeLsofData([
            "p42", "fcwd", "n/Users/developer/workspaces/example/web-app"
        ])
        let runner = ScriptedCommandRunner(results: [
            .init(stdout: listenerOutput, stderr: Data(), exitCode: 0),
            .init(stdout: listenerOutput, stderr: Data(), exitCode: 0),
            .init(stdout: cwdOutput, stderr: Data(), exitCode: 0)
        ])
        let identity = ProcessIdentity(processID: 42, ownerUserID: 502, startTimeMicroseconds: 123)
        let scanner = LsofPortScanner(
            commandRunner: runner,
            identityReader: StubScannerIdentityReader(identities: [42: identity]),
            fileExists: { _ in true }
        )

        let ports = try await scanner.scan()

        XCTAssertEqual(ports.count, 1)
        XCTAssertEqual(ports[0].identity, identity)
        XCTAssertEqual(ports[0].workingDirectory, "/Users/developer/workspaces/example/web-app")
        XCTAssertFalse(ports[0].isWorkingDirectoryMissing)
        XCTAssertEqual(runner.calls.first?.executable.path, "/usr/sbin/lsof")
        XCTAssertEqual(
            runner.calls.first?.arguments,
            ["-nP", "-iTCP", "-sTCP:LISTEN", "-F0pcuLfn"]
        )
        XCTAssertEqual(
            runner.calls.dropFirst().first?.arguments,
            ["-nP", "-a", "-p", "42", "-iTCP", "-sTCP:LISTEN", "-F0pcuLfn"]
        )
    }

    func testMarksDeletedWorkingDirectory() async throws {
        let runner = ScriptedCommandRunner(results: [
            .init(stdout: makeLsofData(["p42", "cnode", "u502", "\nf1", "n*:3001"]), stderr: Data(), exitCode: 0),
            .init(stdout: makeLsofData(["p42", "cnode", "u502", "\nf1", "n*:3001"]), stderr: Data(), exitCode: 0),
            .init(stdout: makeLsofData(["p42", "fcwd", "n/tmp/deleted-worktree"]), stderr: Data(), exitCode: 0)
        ])
        let identity = ProcessIdentity(processID: 42, ownerUserID: 502, startTimeMicroseconds: 123)
        let scanner = LsofPortScanner(
            commandRunner: runner,
            identityReader: StubScannerIdentityReader(identities: [42: identity]),
            fileExists: { _ in false }
        )

        let ports = try await scanner.scan()

        XCTAssertEqual(ports.count, 1)
        XCTAssertTrue(ports[0].isWorkingDirectoryMissing)
    }

    func testUsesRevalidatedListenerSnapshot() async throws {
        let initialOutput = makeLsofData([
            "p42", "cold-node", "u502", "Ldeveloper", "\nf10", "n127.0.0.1:3001"
        ])
        let confirmedOutput = makeLsofData([
            "p42", "cnode", "u502", "Ldeveloper", "\nf11", "n127.0.0.1:3002"
        ])
        let runner = ScriptedCommandRunner(results: [
            .init(stdout: initialOutput, stderr: Data(), exitCode: 0),
            .init(stdout: confirmedOutput, stderr: Data(), exitCode: 0),
            .init(stdout: Data(), stderr: Data(), exitCode: 1)
        ])
        let identity = ProcessIdentity(processID: 42, ownerUserID: 502, startTimeMicroseconds: 123)
        let scanner = LsofPortScanner(
            commandRunner: runner,
            identityReader: StubScannerIdentityReader(identities: [42: identity])
        )

        let ports = try await scanner.scan()

        XCTAssertEqual(ports.map(\.port), [3002])
        XCTAssertEqual(ports.first?.processName, "node")
        XCTAssertEqual(ports.first?.identity, identity)
    }

    func testDisablesStoppingWhenIdentityChangesDuringRevalidation() async throws {
        let listenerOutput = makeLsofData([
            "p42", "cnode", "u502", "Ldeveloper", "\nf10", "n127.0.0.1:3001"
        ])
        let runner = ScriptedCommandRunner(results: [
            .init(stdout: listenerOutput, stderr: Data(), exitCode: 0),
            .init(stdout: listenerOutput, stderr: Data(), exitCode: 0),
            .init(stdout: makeLsofData(["p42", "fcwd", "n/tmp/frontend"]), stderr: Data(), exitCode: 0)
        ])
        let original = ProcessIdentity(processID: 42, ownerUserID: 502, startTimeMicroseconds: 123)
        let replacement = ProcessIdentity(processID: 42, ownerUserID: 502, startTimeMicroseconds: 456)
        let scanner = LsofPortScanner(
            commandRunner: runner,
            identityReader: SequencedIdentityReader(identities: [original, replacement])
        )

        let ports = try await scanner.scan()

        XCTAssertEqual(ports.count, 1)
        XCTAssertNil(ports[0].identity)
        XCTAssertNil(ports[0].workingDirectory)
    }

    func testExitCodeOneWithNoOutputMeansNoListeners() async throws {
        let scanner = LsofPortScanner(
            commandRunner: ScriptedCommandRunner(results: [
                .init(stdout: Data(), stderr: Data(), exitCode: 1)
            ]),
            identityReader: StubScannerIdentityReader(identities: [:])
        )

        let ports = try await scanner.scan()

        XCTAssertTrue(ports.isEmpty)
    }

    func testKeepsPartialResultsWhenOneTargetProcessExitsDuringRevalidation() async throws {
        let initialOutput = makeLsofData([
            "p42", "cnode", "u502", "Ldeveloper", "\nf10", "n127.0.0.1:3001",
            "p43", "cnode", "u502", "Ldeveloper", "\nf11", "n127.0.0.1:3002"
        ])
        let remainingOutput = makeLsofData([
            "p42", "cnode", "u502", "Ldeveloper", "\nf10", "n127.0.0.1:3001"
        ])
        let identity = ProcessIdentity(processID: 42, ownerUserID: 502, startTimeMicroseconds: 123)
        let runner = ScriptedCommandRunner(results: [
            .init(stdout: initialOutput, stderr: Data(), exitCode: 0),
            .init(stdout: remainingOutput, stderr: Data(), exitCode: 1),
            .init(stdout: Data(), stderr: Data(), exitCode: 1)
        ])
        let scanner = LsofPortScanner(
            commandRunner: runner,
            identityReader: StubScannerIdentityReader(identities: [42: identity])
        )

        let ports = try await scanner.scan()

        XCTAssertEqual(ports.map(\.processID), [42])
        XCTAssertEqual(ports.map(\.port), [3001])
    }

    func testUnexpectedExitCodeThrowsUsefulError() async throws {
        let scanner = LsofPortScanner(
            commandRunner: ScriptedCommandRunner(results: [
                .init(stdout: Data(), stderr: Data("permission denied".utf8), exitCode: 2)
            ]),
            identityReader: StubScannerIdentityReader(identities: [:])
        )

        do {
            _ = try await scanner.scan()
            XCTFail("エラーになる必要があります")
        } catch let error as PortScanError {
            XCTAssertEqual(error, .commandFailed(exitCode: 2, message: "permission denied"))
        }
    }

    func testTruncatedOutputIsRejectedInsteadOfParsingPartialRecords() async throws {
        let scanner = LsofPortScanner(
            commandRunner: ScriptedCommandRunner(results: [
                .init(
                    stdout: makeLsofData(["p42", "cnode", "u502", "\nf1", "n*:3001"]),
                    stderr: Data(),
                    exitCode: 0,
                    stdoutWasTruncated: true
                )
            ]),
            identityReader: StubScannerIdentityReader(identities: [:])
        )

        do {
            _ = try await scanner.scan()
            XCTFail("切り詰めた出力は拒否する必要があります")
        } catch let error as PortScanError {
            XCTAssertEqual(error, .outputTooLarge)
        }
    }

    func testRejectsTooManyProcessesBeforeBuildingTargetedPIDArgument() async throws {
        var fields: [String] = []
        for index in 0...4_096 {
            fields.append("p\(index + 10)")
            fields.append("cnode")
            fields.append("u502")
            fields.append("f1")
            fields.append("n127.0.0.1:\(index + 1)")
        }
        let runner = ScriptedCommandRunner(results: [
            .init(stdout: makeLsofData(fields), stderr: Data(), exitCode: 0)
        ])
        let scanner = LsofPortScanner(
            commandRunner: runner,
            identityReader: StubScannerIdentityReader(identities: [:])
        )

        do {
            _ = try await scanner.scan()
            XCTFail("PID件数上限を超えた入力は拒否する必要があります")
        } catch let error as PortScanError {
            XCTAssertEqual(error, .outputTooLarge)
        }
        XCTAssertEqual(runner.calls.count, 1)
    }

    private func makeLsofData(_ fields: [String]) -> Data {
        Data((fields.joined(separator: "\0") + "\0\n").utf8)
    }
}

private final class ScriptedCommandRunner: CommandRunning, @unchecked Sendable {
    struct Call {
        let executable: URL
        let arguments: [String]
    }

    private let lock = NSLock()
    private var results: [CommandResult]
    private var recordedCalls: [Call] = []

    var calls: [Call] {
        lock.withLock { recordedCalls }
    }

    init(results: [CommandResult]) {
        self.results = results
    }

    func run(executable: URL, arguments: [String]) async throws -> CommandResult {
        try lock.withLock {
            recordedCalls.append(.init(executable: executable, arguments: arguments))
            guard !results.isEmpty else {
                throw PortScanError.commandFailed(exitCode: -1, message: "テスト応答がありません")
            }
            return results.removeFirst()
        }
    }
}

private final class StubScannerIdentityReader: ProcessIdentityReading, @unchecked Sendable {
    let identities: [Int32: ProcessIdentity]

    init(identities: [Int32: ProcessIdentity]) {
        self.identities = identities
    }

    func identity(for processID: Int32) -> ProcessIdentity? {
        identities[processID]
    }
}

private final class SequencedIdentityReader: ProcessIdentityReading, @unchecked Sendable {
    private let lock = NSLock()
    private var identities: [ProcessIdentity]

    init(identities: [ProcessIdentity]) {
        self.identities = identities
    }

    func identity(for processID: Int32) -> ProcessIdentity? {
        lock.withLock {
            guard !identities.isEmpty else {
                return nil
            }
            return identities.removeFirst()
        }
    }
}
