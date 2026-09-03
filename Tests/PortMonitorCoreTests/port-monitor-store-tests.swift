import XCTest
@testable import LocalPortMonitorApp
@testable import PortMonitorCore

final class PortMonitorStoreTests: XCTestCase {
    @MainActor
    func testRefreshLoadsPortsAndFiltersToCurrentUser() async throws {
        let ownPort = makePort(processID: 10, userID: 502, port: 3001)
        let foreignPort = makePort(processID: 20, userID: 501, port: 8080)
        let scanner = ScriptedStoreScanner(responses: [[ownPort, foreignPort]])
        let store = PortMonitorStore(
            scanner: scanner,
            stopper: RecordingProcessStopper(),
            currentUserID: 502,
            currentProcessID: 99,
            allowsProcessStopping: true
        )

        store.refresh()
        await waitUntil { store.lastUpdatedAt != nil }

        XCTAssertEqual(store.ports, [ownPort, foreignPort])
        XCTAssertEqual(store.visiblePorts, [ownPort])
        XCTAssertEqual(store.ownedPortCount, 1)

        store.showsOnlyCurrentUser = false
        XCTAssertEqual(store.visiblePorts, [ownPort, foreignPort])
    }

    @MainActor
    func testRepeatedRefreshRequestsStayBounded() async throws {
        let scanner = SlowCountingScanner()
        let store = PortMonitorStore(
            scanner: scanner,
            stopper: RecordingProcessStopper(),
            currentUserID: 502,
            currentProcessID: 99,
            allowsProcessStopping: true
        )

        store.refresh()
        await Task.yield()
        for _ in 0..<100 {
            store.refresh()
        }

        await waitUntil { store.lastUpdatedAt != nil && !store.isRefreshing }
        try await Task.sleep(nanoseconds: 100_000_000)

        let callCount = await scanner.callCount
        XCTAssertLessThanOrEqual(callCount, 2)
    }

    @MainActor
    func testRequestStopShowsConfirmationWithoutSendingSignal() {
        let port = makePort(processID: 42, userID: 502, port: 3001)
        let stopper = RecordingProcessStopper()
        let store = PortMonitorStore(
            scanner: ScriptedStoreScanner(responses: [[port]]),
            stopper: stopper,
            currentUserID: 502,
            currentProcessID: 99,
            allowsProcessStopping: true
        )

        store.requestStop(port)

        XCTAssertEqual(store.pendingStop?.target, port)
        XCTAssertEqual(store.pendingStop?.heldPorts, [3001])
        XCTAssertEqual(stopper.callCount, 0)
    }

    @MainActor
    func testCancelPendingStopDismissesConfirmationWithoutSendingSignal() {
        let port = makePort(processID: 42, userID: 502, port: 3001)
        let stopper = RecordingProcessStopper()
        let store = PortMonitorStore(
            scanner: ScriptedStoreScanner(responses: [[port]]),
            stopper: stopper,
            currentUserID: 502,
            currentProcessID: 99,
            allowsProcessStopping: true
        )
        store.requestStop(port)

        store.cancelPendingStop()

        XCTAssertNil(store.pendingStop)
        XCTAssertEqual(stopper.callCount, 0)
    }

    @MainActor
    func testConfirmPendingStopDismissesConfirmationAndSendsSignal() async throws {
        let port = makePort(processID: 42, userID: 502, port: 3001)
        let stopper = RecordingProcessStopper()
        let store = PortMonitorStore(
            scanner: ScriptedStoreScanner(responses: [[port]]),
            stopper: stopper,
            currentUserID: 502,
            currentProcessID: 99,
            allowsProcessStopping: true
        )
        store.requestStop(port)

        store.confirmPendingStop()

        XCTAssertNil(store.pendingStop)
        await waitUntil { stopper.callCount == 1 }
        XCTAssertEqual(stopper.callCount, 1)
    }

    @MainActor
    func testRepeatedConfirmRequestsSendOneSignalSequence() async throws {
        let port = makePort(processID: 42, userID: 502, port: 3001)
        let scanner = ScriptedStoreScanner(responses: [[port], []])
        let stopper = RecordingProcessStopper()
        let store = PortMonitorStore(
            scanner: scanner,
            stopper: stopper,
            currentUserID: 502,
            currentProcessID: 99,
            allowsProcessStopping: true
        )
        store.requestStop(port)

        for _ in 0..<100 {
            store.confirmPendingStop()
        }
        await waitUntil { stopper.callCount == 1 }

        XCTAssertEqual(stopper.callCount, 1)
        XCTAssertNil(store.pendingStop)
        XCTAssertTrue(store.isStopping(port))
    }

    @MainActor
    func testRequestStopRejectsUnstoppablePort() {
        let port = makePort(processID: 42, userID: 501, port: 3001)
        let stopper = RecordingProcessStopper()
        let store = PortMonitorStore(
            scanner: ScriptedStoreScanner(responses: [[port]]),
            stopper: stopper,
            currentUserID: 502,
            currentProcessID: 99,
            allowsProcessStopping: true
        )

        store.requestStop(port)

        XCTAssertNil(store.pendingStop)
        XCTAssertEqual(stopper.callCount, 0)
    }

    @MainActor
    func testRefreshKeepsPendingStopSnapshot() async throws {
        let port = makePort(processID: 42, userID: 502, port: 3001)
        let siblingPort = makePort(processID: 42, userID: 502, port: 3002)
        let replacementPort = makePort(processID: 84, userID: 502, port: 3002)
        let store = PortMonitorStore(
            scanner: ScriptedStoreScanner(responses: [[port, siblingPort], [replacementPort]]),
            stopper: RecordingProcessStopper(),
            currentUserID: 502,
            currentProcessID: 99,
            allowsProcessStopping: true
        )

        store.refresh()
        await waitUntil { store.ports == [port, siblingPort] && !store.isRefreshing }
        store.requestStop(port)
        XCTAssertEqual(store.pendingStop?.target, port)
        XCTAssertEqual(store.pendingStop?.heldPorts, [3001, 3002])

        store.refresh()
        await waitUntil { store.ports == [replacementPort] && !store.isRefreshing }

        XCTAssertEqual(store.pendingStop?.target, port)
        XCTAssertEqual(store.pendingStop?.heldPorts, [3001, 3002])
        XCTAssertEqual(store.ports, [replacementPort])
    }

    @MainActor
    func testConfirmDoesNotStopProcessThatDisappearedBeforeFreshScan() async throws {
        let port = makePort(processID: 42, userID: 502, port: 3001)
        let stopper = RecordingProcessStopper()
        let store = PortMonitorStore(
            scanner: ScriptedStoreScanner(responses: [[]]),
            stopper: stopper,
            currentUserID: 502,
            currentProcessID: 99,
            allowsProcessStopping: true
        )
        store.requestStop(port)

        store.confirmPendingStop()
        await waitUntil { !store.isStopping(port) }

        XCTAssertNil(store.pendingStop)
        XCTAssertEqual(stopper.callCount, 0)
        XCTAssertEqual(store.ports, [])
        XCTAssertEqual(
            store.errorMessage,
            "対象プロセスが終了または入れ替わったため、停止しませんでした"
        )
    }

    @MainActor
    func testStopWaitsForOngoingRefreshThenUsesFreshSnapshot() async throws {
        let port = makePort(processID: 42, userID: 502, port: 3001)
        let underlyingScanner = GatedStoreScanner(firstResponse: [port], laterResponse: [])
        let scanner = CoalescingPortScanner(scanner: underlyingScanner)
        let stopper = RecordingProcessStopper()
        let store = PortMonitorStore(
            scanner: scanner,
            stopper: stopper,
            currentUserID: 502,
            currentProcessID: 99,
            allowsProcessStopping: true
        )

        store.refresh()
        for _ in 0..<1_000 {
            if await underlyingScanner.callCount == 1 {
                break
            }
            await Task.yield()
        }

        store.requestStop(port)
        store.confirmPendingStop()
        XCTAssertTrue(store.isStopping(port))
        XCTAssertTrue(store.isRefreshing)
        for _ in 0..<20 {
            await Task.yield()
        }
        let callsBeforeRelease = await underlyingScanner.callCount
        XCTAssertEqual(callsBeforeRelease, 1)

        await underlyingScanner.releaseFirstScan()
        await waitUntilAsync { await underlyingScanner.callCount >= 2 }
        await waitUntil { !store.isStopping(port) && !store.isRefreshing }

        XCTAssertEqual(stopper.callCount, 0)
        let finalCallCount = await underlyingScanner.callCount
        XCTAssertEqual(finalCallCount, 2)
        XCTAssertEqual(
            store.errorMessage,
            "対象プロセスが終了または入れ替わったため、停止しませんでした"
        )
    }

    @MainActor
    func testOlderRefreshCompletionDoesNotClearStopError() async throws {
        let port = makePort(processID: 42, userID: 502, port: 3001)
        let scanner = GatedRefreshStoreScanner(
            refreshResponse: [port],
            freshResponse: []
        )
        let stopper = RecordingProcessStopper()
        let store = PortMonitorStore(
            scanner: scanner,
            stopper: stopper,
            currentUserID: 502,
            currentProcessID: 99,
            allowsProcessStopping: true
        )

        store.refresh()
        await waitUntilAsync { await scanner.refreshCallCount == 1 }
        XCTAssertTrue(store.isRefreshing)

        store.requestStop(port)
        store.confirmPendingStop()
        XCTAssertTrue(store.isStopping(port))
        await waitUntilAsync { await scanner.freshCallCount == 1 }
        await waitUntil {
            !store.isStopping(port)
                && store.errorMessage == "対象プロセスが終了または入れ替わったため、停止しませんでした"
        }
        XCTAssertTrue(store.isRefreshing)
        XCTAssertEqual(store.ports, [])
        let lastUpdatedAfterStop = try XCTUnwrap(store.lastUpdatedAt)

        await scanner.releaseRefresh()
        await waitUntil { !store.isRefreshing }

        XCTAssertEqual(stopper.callCount, 0)
        XCTAssertEqual(store.ports, [])
        XCTAssertEqual(store.lastUpdatedAt, lastUpdatedAfterStop)
        XCTAssertEqual(
            store.errorMessage,
            "対象プロセスが終了または入れ替わったため、停止しませんでした"
        )
    }

    @MainActor
    func testNewerRefreshDoesNotSuppressPendingStopError() async throws {
        let port = makePort(processID: 42, userID: 502, port: 3001)
        let replacementPort = makePort(processID: 84, userID: 502, port: 3002)
        let scanner = GatedFreshStoreScanner(
            refreshResponse: [replacementPort],
            freshResponse: []
        )
        let stopper = RecordingProcessStopper()
        let store = PortMonitorStore(
            scanner: scanner,
            stopper: stopper,
            currentUserID: 502,
            currentProcessID: 99,
            allowsProcessStopping: true
        )

        store.requestStop(port)
        store.confirmPendingStop()
        XCTAssertTrue(store.isStopping(port))
        await waitUntilAsync { await scanner.freshCallCount == 1 }

        store.refresh()
        await waitUntil { store.ports == [replacementPort] && !store.isRefreshing }
        let lastUpdatedAfterRefresh = try XCTUnwrap(store.lastUpdatedAt)

        await scanner.releaseFreshScan()
        await waitUntil {
            !store.isStopping(port)
                && store.errorMessage == "対象プロセスが終了または入れ替わったため、停止しませんでした"
        }

        XCTAssertEqual(stopper.callCount, 0)
        XCTAssertEqual(store.ports, [replacementPort])
        XCTAssertEqual(store.lastUpdatedAt, lastUpdatedAfterRefresh)
        XCTAssertEqual(
            store.errorMessage,
            "対象プロセスが終了または入れ替わったため、停止しませんでした"
        )
    }

    @MainActor
    func testSuccessfulRefreshAfterStopErrorUpdatesPortsWithoutClearingError() async throws {
        let port = makePort(processID: 42, userID: 502, port: 3001)
        let replacementPort = makePort(processID: 84, userID: 502, port: 3002)
        let scanner = ScriptedStoreScanner(responses: [[], [replacementPort]])
        let stopper = RecordingProcessStopper()
        let store = PortMonitorStore(
            scanner: scanner,
            stopper: stopper,
            currentUserID: 502,
            currentProcessID: 99,
            allowsProcessStopping: true
        )

        store.requestStop(port)
        store.confirmPendingStop()
        await waitUntil {
            !store.isStopping(port)
                && store.errorMessage == "対象プロセスが終了または入れ替わったため、停止しませんでした"
        }
        XCTAssertEqual(store.ports, [])

        store.refresh()
        await waitUntil { store.ports == [replacementPort] && !store.isRefreshing }

        XCTAssertEqual(stopper.callCount, 0)
        XCTAssertEqual(store.ports, [replacementPort])
        XCTAssertEqual(
            store.errorMessage,
            "対象プロセスが終了または入れ替わったため、停止しませんでした"
        )
    }

    @MainActor
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<300 {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("期待した状態に遷移しませんでした")
    }

    @MainActor
    private func waitUntilAsync(
        _ condition: @escaping @Sendable () async -> Bool
    ) async {
        for _ in 0..<300 {
            if await condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("非同期処理が期待した状態に遷移しませんでした")
    }

    private func makePort(processID: Int32, userID: UInt32, port: Int) -> ListeningPort {
        let identity = ProcessIdentity(
            processID: processID,
            ownerUserID: userID,
            startTimeMicroseconds: UInt64(processID) * 1_000,
            auditToken: ProcessAuditToken(
                processID: processID,
                processIDVersion: UInt32(bitPattern: processID)
            )
        )
        return ListeningPort(
            processID: processID,
            processName: "node",
            userID: userID,
            userName: "developer",
            port: port,
            addresses: ["127.0.0.1"],
            workingDirectory: "/tmp/frontend",
            isWorkingDirectoryMissing: false,
            identity: identity
        )
    }
}

private actor ScriptedStoreScanner: FreshPortScanning {
    private var responses: [[ListeningPort]]

    init(responses: [[ListeningPort]]) {
        self.responses = responses
    }

    func scan() async throws -> [ListeningPort] {
        guard responses.count > 1 else {
            return responses.first ?? []
        }
        return responses.removeFirst()
    }

    func scanFresh() async throws -> [ListeningPort] {
        try await scan()
    }
}

private actor SlowCountingScanner: FreshPortScanning {
    private(set) var callCount = 0

    func scan() async throws -> [ListeningPort] {
        callCount += 1
        try await Task.sleep(nanoseconds: 40_000_000)
        return []
    }

    func scanFresh() async throws -> [ListeningPort] {
        try await scan()
    }
}

private actor GatedStoreScanner: PortScanning {
    private(set) var callCount = 0
    private var isFirstScanReleased = false
    private let firstResponse: [ListeningPort]
    private let laterResponse: [ListeningPort]

    init(firstResponse: [ListeningPort], laterResponse: [ListeningPort]) {
        self.firstResponse = firstResponse
        self.laterResponse = laterResponse
    }

    func scan() async throws -> [ListeningPort] {
        callCount += 1
        let currentCall = callCount
        if currentCall == 1 {
            while !isFirstScanReleased {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            return firstResponse
        }
        return laterResponse
    }

    func releaseFirstScan() {
        isFirstScanReleased = true
    }
}

private actor GatedRefreshStoreScanner: FreshPortScanning {
    private(set) var refreshCallCount = 0
    private(set) var freshCallCount = 0
    private var isRefreshReleased = false
    private let refreshResponse: [ListeningPort]
    private let freshResponse: [ListeningPort]

    init(refreshResponse: [ListeningPort], freshResponse: [ListeningPort]) {
        self.refreshResponse = refreshResponse
        self.freshResponse = freshResponse
    }

    func scan() async throws -> [ListeningPort] {
        refreshCallCount += 1
        while !isRefreshReleased {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        return refreshResponse
    }

    func scanFresh() async throws -> [ListeningPort] {
        freshCallCount += 1
        return freshResponse
    }

    func releaseRefresh() {
        isRefreshReleased = true
    }
}

private actor GatedFreshStoreScanner: FreshPortScanning {
    private(set) var freshCallCount = 0
    private var isFreshScanReleased = false
    private let refreshResponse: [ListeningPort]
    private let freshResponse: [ListeningPort]

    init(refreshResponse: [ListeningPort], freshResponse: [ListeningPort]) {
        self.refreshResponse = refreshResponse
        self.freshResponse = freshResponse
    }

    func scan() async throws -> [ListeningPort] {
        refreshResponse
    }

    func scanFresh() async throws -> [ListeningPort] {
        freshCallCount += 1
        while !isFreshScanReleased {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        return freshResponse
    }

    func releaseFreshScan() {
        isFreshScanReleased = true
    }
}

private final class RecordingProcessStopper: ProcessStopping, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCallCount = 0

    var callCount: Int {
        lock.withLock { recordedCallCount }
    }

    func stop(_ target: ListeningPort) throws -> StopOutcome {
        lock.withLock {
            recordedCallCount += 1
        }
        return .signaled
    }
}
