import Darwin
import XCTest
@testable import PortMonitorCore

final class CommandRunnerTests: XCTestCase {
    func testReadsLargeStdoutAndStderrWithoutDeadlockOrReordering() async throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw XCTSkip("/usr/bin/python3 がありません")
        }
        let repeatCount = 2_048
        let ascendingPattern = Data((0...255).map(UInt8.init))
        let descendingPattern = Data((0...255).reversed().map(UInt8.init))
        var expectedOutput = Data()
        var expectedError = Data()
        for _ in 0..<repeatCount {
            expectedOutput.append(ascendingPattern)
            expectedError.append(descendingPattern)
        }
        let script = """
        import sys
        sys.stdout.buffer.write(bytes(range(256)) * \(repeatCount))
        sys.stderr.buffer.write(bytes(reversed(range(256))) * \(repeatCount))
        """
        let runner = FoundationCommandRunner(timeout: 3, maximumOutputBytes: 2 * 1_024 * 1_024)

        let result = try await runner.run(executable: python, arguments: ["-c", script])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, expectedOutput)
        XCTAssertEqual(result.stderr, expectedError)
        XCTAssertFalse(result.stdoutWasTruncated)
        XCTAssertFalse(result.stderrWasTruncated)
    }

    func testReportsTruncatedOutputWhileStillDrainingChildProcess() async throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw XCTSkip("/usr/bin/python3 がありません")
        }
        let runner = FoundationCommandRunner(timeout: 3, maximumOutputBytes: 1_024)

        let result = try await runner.run(
            executable: python,
            arguments: ["-c", "import sys; sys.stdout.buffer.write(b'X' * 131072)"]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.count, 1_024)
        XCTAssertTrue(result.stdoutWasTruncated)
    }

    func testReturnsShellStyleExitCodeWhenChildTerminatesBySignal() async throws {
        let runner = FoundationCommandRunner(timeout: 3)

        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "kill -HUP $$"]
        )

        XCTAssertEqual(result.exitCode, 128 + SIGHUP)
    }

    func testPreservesNormalNonzeroExitCode() async throws {
        let runner = FoundationCommandRunner(timeout: 3)

        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 23"]
        )

        XCTAssertEqual(result.exitCode, 23)
    }

    func testDoesNotWaitForeverWhenDescendantKeepsOutputPipesOpen() async throws {
        let shell = URL(fileURLWithPath: "/bin/sh")
        let exitMarker = FileManager.default.temporaryDirectory
            .appendingPathComponent("port-watch-pipe-holder-\(UUID().uuidString).marker")
        defer {
            try? FileManager.default.removeItem(at: exitMarker)
        }
        let script = """
        marker=$1
        (
            trap '/usr/bin/touch "$marker"; exit 0' PIPE
            while true; do
                printf x
                sleep 0.01
            done
        ) &
        exit 0
        """
        let runner = FoundationCommandRunner(timeout: 5)
        let startedAt = ContinuousClock.now

        do {
            _ = try await runner.run(
                executable: shell,
                arguments: ["-c", script, "port-watch-pipe-holder", exitMarker.path]
            )
            XCTFail("継承された出力パイプを有限時間で閉じる必要があります")
        } catch let error as CommandRunError {
            guard case let .outputReadFailed(stream, message) = error else {
                return XCTFail("想定外のエラーです: \(error)")
            }
            XCTAssertEqual(stream, "標準出力/標準エラー")
            XCTAssertTrue(message.contains("出力パイプ"))
        }

        XCTAssertLessThan(startedAt.duration(to: .now), .seconds(7))
        for _ in 0..<1_000 {
            if FileManager.default.fileExists(atPath: exitMarker.path) {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: exitMarker.path))
    }

    func testTerminatesCommandAfterTimeout() async throws {
        let runner = FoundationCommandRunner(timeout: 0.05)
        let startedAt = ContinuousClock.now

        do {
            _ = try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"]
            )
            XCTFail("タイムアウトする必要があります")
        } catch let error as CommandRunError {
            XCTAssertEqual(error, .timedOut(executable: "/bin/sleep"))
        }

        XCTAssertLessThan(startedAt.duration(to: .now), .seconds(2))
    }

    func testForceTerminatesChildThatIgnoresTermAndInterrupt() async throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw XCTSkip("/usr/bin/python3 がありません")
        }
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("port-watch-timeout-\(UUID().uuidString).marker")
        defer {
            try? FileManager.default.removeItem(at: marker)
        }
        let script = """
        import signal, sys, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        time.sleep(1.2)
        open(sys.argv[1], 'w').write('still-running')
        """
        let runner = FoundationCommandRunner(timeout: 0.2)

        do {
            _ = try await runner.run(
                executable: python,
                arguments: ["-c", script, marker.path]
            )
            XCTFail("タイムアウトする必要があります")
        } catch let error as CommandRunError {
            XCTAssertEqual(error, .timedOut(executable: python.path))
        }

        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "signalを無視する子プロセスがtimeout後も残っています"
        )
    }
}
