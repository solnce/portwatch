import XCTest
@testable import PortMonitorCore

final class CoalescingPortScannerTests: XCTestCase {
    func testOneHundredConcurrentRequestsShareOneUnderlyingScan() async throws {
        let underlyingScanner = GatedScanner()
        let scanner = CoalescingPortScanner(scanner: underlyingScanner)
        let tasks = (0..<100).map { _ in
            Task {
                try await scanner.scan()
            }
        }

        await waitUntilCalled(underlyingScanner)
        let callsBeforeRelease = await underlyingScanner.callCount
        XCTAssertEqual(callsBeforeRelease, 1)

        await underlyingScanner.release()
        for task in tasks {
            let ports = try await task.value
            XCTAssertTrue(ports.isEmpty)
        }

        let finalCallCount = await underlyingScanner.callCount
        XCTAssertEqual(finalCallCount, 1)
    }

    func testFreshScanWaitsForCurrentScanThenStartsNewGeneration() async throws {
        let underlyingScanner = SequencedGatedScanner()
        let scanner = CoalescingPortScanner(scanner: underlyingScanner)
        let regularTask = Task {
            try await scanner.scan()
        }

        await waitUntilCallCount(1, scanner: underlyingScanner)
        let freshTask = Task {
            try await scanner.scanFresh()
        }
        for _ in 0..<20 {
            await Task.yield()
        }

        let callsWhileFirstScanRuns = await underlyingScanner.callCount
        XCTAssertEqual(callsWhileFirstScanRuns, 1)

        await underlyingScanner.releaseFirstScan()
        let regularResult = try await regularTask.value
        let freshResult = try await freshTask.value

        XCTAssertEqual(regularResult.map(\.port), [3001])
        XCTAssertTrue(freshResult.isEmpty)
        let finalCallCount = await underlyingScanner.callCount
        XCTAssertEqual(finalCallCount, 2)
    }

    func testOneHundredFreshRequestsShareOneScanAfterCurrentScanFinishes() async throws {
        let underlyingScanner = SequencedGatedScanner()
        let scanner = CoalescingPortScanner(scanner: underlyingScanner)
        let regularTask = Task {
            try await scanner.scan()
        }

        await waitUntilCallCount(1, scanner: underlyingScanner)
        let freshTasks = (0..<100).map { _ in
            Task {
                try await scanner.scanFresh()
            }
        }

        await waitUntilFreshRequestCount(100, scanner: scanner)
        let callsBeforeRelease = await underlyingScanner.callCount
        XCTAssertEqual(callsBeforeRelease, 1)

        await underlyingScanner.releaseFirstScan()
        _ = try await regularTask.value
        for task in freshTasks {
            let ports = try await task.value
            XCTAssertTrue(ports.isEmpty)
        }

        let finalCallCount = await underlyingScanner.callCount
        XCTAssertEqual(finalCallCount, 2)
    }

    private func waitUntilFreshRequestCount(
        _ expectedCount: Int,
        scanner: CoalescingPortScanner
    ) async {
        for _ in 0..<10_000 {
            if await scanner.activeFreshRequestCount == expectedCount {
                return
            }
            await Task.yield()
        }
        XCTFail("fresh scan要求が期待数に達しませんでした")
    }

    private func waitUntilCalled(_ scanner: GatedScanner) async {
        for _ in 0..<1_000 {
            if await scanner.callCount > 0 {
                return
            }
            await Task.yield()
        }
        XCTFail("スキャンが開始されませんでした")
    }

    private func waitUntilCallCount(
        _ expectedCount: Int,
        scanner: SequencedGatedScanner
    ) async {
        for _ in 0..<1_000 {
            if await scanner.callCount >= expectedCount {
                return
            }
            await Task.yield()
        }
        XCTFail("期待した回数のスキャンが開始されませんでした")
    }
}

private actor GatedScanner: PortScanning {
    private(set) var callCount = 0
    private var isReleased = false

    func scan() async throws -> [ListeningPort] {
        callCount += 1
        while !isReleased {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        return []
    }

    func release() {
        isReleased = true
    }
}

private actor SequencedGatedScanner: PortScanning {
    private(set) var callCount = 0
    private var canFinishFirstScan = false

    func scan() async throws -> [ListeningPort] {
        callCount += 1
        let currentCall = callCount

        if currentCall == 1 {
            while !canFinishFirstScan {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            return [makePort()]
        }
        return []
    }

    func releaseFirstScan() {
        canFinishFirstScan = true
    }

    private func makePort() -> ListeningPort {
        ListeningPort(
            processID: 42,
            processName: "node",
            userID: 502,
            userName: "developer",
            port: 3001,
            addresses: ["127.0.0.1"]
        )
    }
}
