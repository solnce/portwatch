import Combine
import Darwin
import Foundation
import PortMonitorCore

struct StopConfirmationSnapshot: Equatable, Sendable {
    let target: ListeningPort
    let heldPorts: [Int]
}

private enum ErrorOwner {
    case refresh
    case stop
}

private struct ScanCommitToken: Equatable, Sendable {
    let sequence: UInt64
}

@MainActor
final class PortMonitorStore: ObservableObject {
    @Published private(set) var ports: [ListeningPort] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var stoppingProcessIDs: Set<Int32> = []
    @Published private(set) var lastUpdatedAt: Date?
    @Published private(set) var pendingStop: StopConfirmationSnapshot?
    @Published var searchText = ""
    @Published var showsOnlyCurrentUser = true
    @Published private(set) var errorMessage: String?

    private let scanner: any FreshPortScanning
    private let stopper: any ProcessStopping
    private let currentUserID: UInt32
    private let currentProcessID: Int32
    private let allowsProcessStopping: Bool
    private var refreshTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var needsAnotherRefresh = false
    private var errorOwner: ErrorOwner?
    private var latestScanToken = ScanCommitToken(sequence: 0)
    private var pendingRefreshToken: ScanCommitToken?

    init(
        scanner: any FreshPortScanning,
        stopper: any ProcessStopping,
        currentUserID: UInt32 = geteuid(),
        currentProcessID: Int32 = getpid(),
        allowsProcessStopping: Bool = geteuid() != 0 && getuid() == geteuid()
    ) {
        self.scanner = scanner
        self.stopper = stopper
        self.currentUserID = currentUserID
        self.currentProcessID = currentProcessID
        self.allowsProcessStopping = allowsProcessStopping
    }

    deinit {
        monitorTask?.cancel()
        refreshTask?.cancel()
    }

    var visiblePorts: [ListeningPort] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return ports.filter { port in
            if showsOnlyCurrentUser, port.userID != currentUserID {
                return false
            }
            guard !query.isEmpty else {
                return true
            }

            let values = [
                String(port.port),
                String(port.processID),
                port.processName,
                port.userName ?? "",
                port.workingDirectory ?? "",
                port.addresses.joined(separator: " ")
            ]
            return values.contains { $0.lowercased().contains(query) }
        }
    }

    var ownedPortCount: Int {
        ports.filter { $0.userID == currentUserID }.count
    }

    func startMonitoring() {
        guard monitorTask == nil else {
            return
        }

        refresh()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch {
                    break
                }
                guard let self else {
                    break
                }
                if self.refreshTask == nil {
                    self.refresh()
                }
            }
        }
    }

    func refresh() {
        pendingRefreshToken = issueScanToken()
        guard refreshTask == nil else {
            needsAnotherRefresh = true
            return
        }

        refreshTask = Task { [weak self] in
            guard let self else {
                return
            }

            repeat {
                self.needsAnotherRefresh = false
                guard let scanToken = self.pendingRefreshToken else {
                    self.refreshTask = nil
                    return
                }
                self.pendingRefreshToken = nil
                self.isRefreshing = true

                do {
                    let scannedPorts = try await self.scanner.scan()
                    if self.commit(scannedPorts, using: scanToken) {
                        self.clearRefreshError()
                    }
                } catch {
                    if self.isLatestScan(scanToken) {
                        self.presentError(error.localizedDescription, owner: .refresh)
                    }
                }

                self.isRefreshing = false
            } while self.needsAnotherRefresh

            self.refreshTask = nil
        }
    }

    func canStop(_ port: ListeningPort) -> Bool {
        allowsProcessStopping
            && port.processID > 1
            && port.processID != currentProcessID
            && port.userID == currentUserID
            && port.identity?.auditToken != nil
    }

    func isStopping(_ port: ListeningPort) -> Bool {
        stoppingProcessIDs.contains(port.processID)
    }

    func requestStop(_ port: ListeningPort) {
        guard pendingStop == nil, canStop(port), !isStopping(port) else {
            return
        }
        let heldPorts = portsHeldBySameProcess(as: port)
        pendingStop = StopConfirmationSnapshot(
            target: port,
            heldPorts: heldPorts.isEmpty ? [port.port] : heldPorts
        )
    }

    func cancelPendingStop() {
        pendingStop = nil
    }

    func dismissError() {
        errorOwner = nil
        errorMessage = nil
    }

    func confirmPendingStop() {
        guard let selectedPort = pendingStop?.target else {
            return
        }

        pendingStop = nil
        dismissError()
        performStop(selectedPort)
    }

    private func performStop(_ selectedPort: ListeningPort) {
        guard canStop(selectedPort), !isStopping(selectedPort) else {
            return
        }

        let scanToken = issueScanToken()
        stoppingProcessIDs.insert(selectedPort.processID)
        Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                self.stoppingProcessIDs.remove(selectedPort.processID)
            }

            do {
                let latestPorts = try await self.scanner.scanFresh()
                guard let verifiedPort = latestPorts.first(where: {
                    $0.port == selectedPort.port
                        && $0.processID == selectedPort.processID
                        && $0.identity == selectedPort.identity
                }) else {
                    _ = self.commit(latestPorts, using: scanToken)
                    self.presentError(
                        "対象プロセスが終了または入れ替わったため、停止しませんでした",
                        owner: .stop
                    )
                    return
                }

                _ = try self.stopper.stop(verifiedPort)
                try? await Task.sleep(nanoseconds: 450_000_000)
                self.refresh()
            } catch {
                self.presentError(error.localizedDescription, owner: .stop)
            }
        }
    }

    func portsHeldBySameProcess(as selectedPort: ListeningPort) -> [Int] {
        ports
            .filter { $0.belongsToSameProcess(as: selectedPort) }
            .map(\.port)
            .sorted()
    }

    private func issueScanToken() -> ScanCommitToken {
        latestScanToken = ScanCommitToken(sequence: latestScanToken.sequence &+ 1)
        return latestScanToken
    }

    private func isLatestScan(_ token: ScanCommitToken) -> Bool {
        token == latestScanToken
    }

    @discardableResult
    private func commit(_ scannedPorts: [ListeningPort], using token: ScanCommitToken) -> Bool {
        guard isLatestScan(token) else {
            return false
        }
        ports = scannedPorts
        lastUpdatedAt = Date()
        return true
    }

    private func presentError(_ message: String, owner: ErrorOwner) {
        guard owner == .stop || errorOwner != .stop else {
            return
        }
        errorOwner = owner
        errorMessage = message
    }

    private func clearRefreshError() {
        guard errorOwner != .stop else {
            return
        }
        errorOwner = nil
        errorMessage = nil
    }
}
