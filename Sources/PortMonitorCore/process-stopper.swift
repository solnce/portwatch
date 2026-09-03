import Darwin
import Foundation

public protocol SignalSending: Sendable {
    func send(signal: Int32, to processID: Int32, auditToken: ProcessAuditToken) throws
}

public struct DarwinSignalSender: SignalSending {
    private let signalFunction: @Sendable (ProcessAuditToken, Int32) -> Int32

    public init() {
        signalFunction = { auditToken, signal in
            auditToken.withUnsafeMutableRawValue { rawToken in
                proc_signal_with_audittoken(rawToken, signal)
            }
        }
    }

    init(signalFunction: @escaping @Sendable (ProcessAuditToken, Int32) -> Int32) {
        self.signalFunction = signalFunction
    }

    public func send(signal: Int32, to processID: Int32, auditToken: ProcessAuditToken) throws {
        guard
            processID > 1,
            processID != getpid(),
            signal == SIGTERM,
            auditToken.processID == processID
        else {
            throw POSIXError(.EINVAL)
        }

        let result = signalFunction(auditToken, signal)
        guard result == 0 else {
            let code = POSIXErrorCode(rawValue: result) ?? .EIO
            throw POSIXError(code)
        }
    }
}

public protocol UserIdentityProviding: Sendable {
    var realUserID: UInt32 { get }
    var effectiveUserID: UInt32 { get }
}

public struct DarwinUserIdentityProvider: UserIdentityProviding {
    public init() {}

    public var realUserID: UInt32 {
        getuid()
    }

    public var effectiveUserID: UInt32 {
        geteuid()
    }
}

public enum StopOutcome: Equatable, Sendable {
    case signaled
    case alreadyExited
}

public enum ProcessStopError: Error, LocalizedError, Equatable, Sendable {
    case protectedProcess
    case identityUnavailable
    case staleProcess
    case permissionDenied
    case unsafeUserContext
    case signalFailed(String)

    public var errorDescription: String? {
        switch self {
        case .protectedProcess:
            return "保護対象のプロセスは停止できません"
        case .identityUnavailable:
            return "プロセスを安全に識別できないため停止しませんでした"
        case .staleProcess:
            return "プロセスが入れ替わったため停止しませんでした"
        case .permissionDenied:
            return "このプロセスを停止する権限がありません"
        case .unsafeUserContext:
            return "rootまたはユーザーIDが切り替わった状態では停止できません"
        case let .signalFailed(message):
            return "プロセスを停止できませんでした: \(message)"
        }
    }
}

public protocol ProcessStopping: Sendable {
    @discardableResult
    func stop(_ target: ListeningPort) throws -> StopOutcome
}

public struct SafeProcessStopper: ProcessStopping, Sendable {
    private let identityReader: any ProcessIdentityReading
    private let signalSender: any SignalSending
    private let userIdentityProvider: any UserIdentityProviding
    private let currentProcessID: Int32

    public init(
        identityReader: any ProcessIdentityReading = DarwinProcessIdentityReader(),
        signalSender: any SignalSending = DarwinSignalSender(),
        userIdentityProvider: any UserIdentityProviding = DarwinUserIdentityProvider(),
        currentProcessID: Int32 = getpid()
    ) {
        self.identityReader = identityReader
        self.signalSender = signalSender
        self.userIdentityProvider = userIdentityProvider
        self.currentProcessID = currentProcessID
    }

    @discardableResult
    public func stop(_ target: ListeningPort) throws -> StopOutcome {
        guard target.processID > 1, target.processID != currentProcessID else {
            throw ProcessStopError.protectedProcess
        }
        guard let expectedIdentity = target.identity else {
            throw ProcessStopError.identityUnavailable
        }
        guard let expectedAuditToken = expectedIdentity.auditToken else {
            throw ProcessStopError.identityUnavailable
        }
        guard
            expectedIdentity.processID == target.processID,
            expectedAuditToken.processID == target.processID
        else {
            throw ProcessStopError.staleProcess
        }
        let realUserID = userIdentityProvider.realUserID
        let effectiveUserID = userIdentityProvider.effectiveUserID
        guard effectiveUserID != 0, realUserID == effectiveUserID else {
            throw ProcessStopError.unsafeUserContext
        }
        guard expectedIdentity.ownerUserID == effectiveUserID else {
            throw ProcessStopError.permissionDenied
        }
        guard let currentIdentity = identityReader.identity(for: target.processID) else {
            return .alreadyExited
        }
        guard currentIdentity == expectedIdentity else {
            throw ProcessStopError.staleProcess
        }

        do {
            try signalSender.send(
                signal: SIGTERM,
                to: target.processID,
                auditToken: expectedAuditToken
            )
            return .signaled
        } catch let error as POSIXError where error.code == .ESRCH {
            return .alreadyExited
        } catch let error as POSIXError where error.code == .EPERM {
            throw ProcessStopError.permissionDenied
        } catch {
            throw ProcessStopError.signalFailed(error.localizedDescription)
        }
    }
}
