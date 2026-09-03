import Darwin
import XCTest
@testable import PortMonitorCore

final class ProcessStopperTests: XCTestCase {
    func testDarwinSignalSenderRejectsPIDOneWithoutCallingSystemFunction() throws {
        let signalFunction = RecordingSignalFunction()
        let sender = DarwinSignalSender { auditToken, signal in
            signalFunction.call(auditToken: auditToken, signal: signal)
        }

        XCTAssertThrowsError(
            try sender.send(
                signal: SIGTERM,
                to: 1,
                auditToken: makeAuditToken(processID: 1)
            )
        ) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EINVAL)
        }
        XCTAssertTrue(signalFunction.calls.isEmpty)
    }

    func testDarwinSignalSenderRejectsCurrentProcessWithoutCallingSystemFunction() throws {
        let currentProcessID = getpid()
        let signalFunction = RecordingSignalFunction()
        let sender = DarwinSignalSender { auditToken, signal in
            signalFunction.call(auditToken: auditToken, signal: signal)
        }

        XCTAssertThrowsError(
            try sender.send(
                signal: SIGTERM,
                to: currentProcessID,
                auditToken: makeAuditToken(processID: currentProcessID)
            )
        ) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EINVAL)
        }
        XCTAssertTrue(signalFunction.calls.isEmpty)
    }

    func testDarwinSignalSenderRejectsAuditTokenForDifferentPIDWithoutCallingSystemFunction() throws {
        let signalFunction = RecordingSignalFunction()
        let sender = DarwinSignalSender { auditToken, signal in
            signalFunction.call(auditToken: auditToken, signal: signal)
        }

        XCTAssertThrowsError(
            try sender.send(
                signal: SIGTERM,
                to: 42,
                auditToken: makeAuditToken(processID: 43)
            )
        ) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EINVAL)
        }
        XCTAssertTrue(signalFunction.calls.isEmpty)
    }

    func testDarwinSignalSenderRejectsNonTermSignalWithoutCallingSystemFunction() throws {
        let signalFunction = RecordingSignalFunction()
        let sender = DarwinSignalSender { auditToken, signal in
            signalFunction.call(auditToken: auditToken, signal: signal)
        }

        XCTAssertThrowsError(
            try sender.send(
                signal: SIGKILL,
                to: 42,
                auditToken: makeAuditToken()
            )
        ) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EINVAL)
        }
        XCTAssertTrue(signalFunction.calls.isEmpty)
    }

    func testDarwinSignalSenderMapsReturnedEPERMToPOSIXError() throws {
        let auditToken = makeAuditToken()
        let signalFunction = RecordingSignalFunction(result: EPERM)
        let sender = DarwinSignalSender { auditToken, signal in
            signalFunction.call(auditToken: auditToken, signal: signal)
        }

        XCTAssertThrowsError(
            try sender.send(signal: SIGTERM, to: 42, auditToken: auditToken)
        ) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EPERM)
        }
        XCTAssertEqual(
            signalFunction.calls,
            [.init(auditToken: auditToken, signal: SIGTERM)]
        )
    }

    func testSendsTermWithAuditTokenWhenIdentityAndOwnerStillMatch() throws {
        let auditToken = makeAuditToken()
        let identity = makeIdentity(auditToken: auditToken)
        let identityReader = StubIdentityReader(identity: identity)
        let signalSender = RecordingSignalSender()
        let stopper = SafeProcessStopper(
            identityReader: identityReader,
            signalSender: signalSender,
            userIdentityProvider: StubUserIdentityProvider(realUserID: 502, effectiveUserID: 502),
            currentProcessID: 99
        )

        let outcome = try stopper.stop(makePort(identity: identity))

        XCTAssertEqual(outcome, .signaled)
        XCTAssertEqual(
            signalSender.calls,
            [.init(processID: 42, signal: SIGTERM, auditToken: auditToken)]
        )
    }

    func testRejectsIdentityWithoutAuditToken() throws {
        let identity = makeIdentity(auditToken: nil)
        let signalSender = RecordingSignalSender()
        let stopper = makeStopper(identity: identity, signalSender: signalSender)

        XCTAssertThrowsError(try stopper.stop(makePort(identity: identity))) { error in
            XCTAssertEqual(error as? ProcessStopError, .identityUnavailable)
        }
        XCTAssertTrue(signalSender.calls.isEmpty)
    }

    func testRejectsAuditTokenWhosePIDDoesNotMatchTarget() throws {
        let selectedIdentity = makeIdentity(auditToken: makeAuditToken(processID: 43))
        let currentIdentity = makeIdentity(auditToken: makeAuditToken())
        let signalSender = RecordingSignalSender()
        let stopper = makeStopper(identity: currentIdentity, signalSender: signalSender)

        XCTAssertThrowsError(try stopper.stop(makePort(identity: selectedIdentity))) { error in
            XCTAssertEqual(error as? ProcessStopError, .staleProcess)
        }
        XCTAssertTrue(signalSender.calls.isEmpty)
    }

    func testDoesNotSignalWhenPIDWasReused() throws {
        let selectedIdentity = makeIdentity(
            startTimeMicroseconds: 1_000,
            auditToken: makeAuditToken(processIDVersion: 10)
        )
        let replacementIdentity = makeIdentity(
            startTimeMicroseconds: 2_000,
            auditToken: makeAuditToken(processIDVersion: 11)
        )
        let signalSender = RecordingSignalSender()
        let stopper = SafeProcessStopper(
            identityReader: StubIdentityReader(identity: replacementIdentity),
            signalSender: signalSender,
            userIdentityProvider: StubUserIdentityProvider(realUserID: 502, effectiveUserID: 502),
            currentProcessID: 99
        )

        XCTAssertThrowsError(try stopper.stop(makePort(identity: selectedIdentity))) { error in
            XCTAssertEqual(error as? ProcessStopError, .staleProcess)
        }
        XCTAssertTrue(signalSender.calls.isEmpty)
    }

    func testDoesNotSignalWhenAuditTokenChanged() throws {
        let selectedIdentity = makeIdentity(auditToken: makeAuditToken(processIDVersion: 10))
        let replacementIdentity = makeIdentity(auditToken: makeAuditToken(processIDVersion: 11))
        let signalSender = RecordingSignalSender()
        let stopper = makeStopper(identity: replacementIdentity, signalSender: signalSender)

        XCTAssertThrowsError(try stopper.stop(makePort(identity: selectedIdentity))) { error in
            XCTAssertEqual(error as? ProcessStopError, .staleProcess)
        }
        XCTAssertTrue(signalSender.calls.isEmpty)
    }

    func testRejectsForeignAndProtectedProcesses() throws {
        let foreignIdentity = makeIdentity(
            ownerUserID: 501,
            auditToken: makeAuditToken()
        )
        let signalSender = RecordingSignalSender()
        let stopper = SafeProcessStopper(
            identityReader: StubIdentityReader(identity: foreignIdentity),
            signalSender: signalSender,
            userIdentityProvider: StubUserIdentityProvider(realUserID: 502, effectiveUserID: 502),
            currentProcessID: 99
        )

        XCTAssertThrowsError(try stopper.stop(makePort(identity: foreignIdentity))) { error in
            XCTAssertEqual(error as? ProcessStopError, .permissionDenied)
        }
        XCTAssertThrowsError(try stopper.stop(makePort(processID: 1, identity: nil))) { error in
            XCTAssertEqual(error as? ProcessStopError, .protectedProcess)
        }
        XCTAssertThrowsError(try stopper.stop(makePort(processID: 99, identity: nil))) { error in
            XCTAssertEqual(error as? ProcessStopError, .protectedProcess)
        }
        XCTAssertTrue(signalSender.calls.isEmpty)
    }

    func testTreatsMissingProcessAndESRCHAsAlreadyExited() throws {
        let identity = makeIdentity(auditToken: makeAuditToken())
        let missingStopper = SafeProcessStopper(
            identityReader: StubIdentityReader(identity: nil),
            signalSender: RecordingSignalSender(),
            userIdentityProvider: StubUserIdentityProvider(realUserID: 502, effectiveUserID: 502),
            currentProcessID: 99
        )

        XCTAssertEqual(try missingStopper.stop(makePort(identity: identity)), .alreadyExited)

        let signalSender = RecordingSignalSender(error: POSIXError(.ESRCH))
        let vanishedStopper = SafeProcessStopper(
            identityReader: StubIdentityReader(identity: identity),
            signalSender: signalSender,
            userIdentityProvider: StubUserIdentityProvider(realUserID: 502, effectiveUserID: 502),
            currentProcessID: 99
        )

        XCTAssertEqual(try vanishedStopper.stop(makePort(identity: identity)), .alreadyExited)
    }

    func testMapsEPERMWithoutRetrying() throws {
        let identity = makeIdentity(auditToken: makeAuditToken())
        let signalSender = RecordingSignalSender(error: POSIXError(.EPERM))
        let stopper = SafeProcessStopper(
            identityReader: StubIdentityReader(identity: identity),
            signalSender: signalSender,
            userIdentityProvider: StubUserIdentityProvider(realUserID: 502, effectiveUserID: 502),
            currentProcessID: 99
        )

        XCTAssertThrowsError(try stopper.stop(makePort(identity: identity))) { error in
            XCTAssertEqual(error as? ProcessStopError, .permissionDenied)
        }
        XCTAssertEqual(signalSender.calls.count, 1)
    }

    func testRejectsRootUserContext() throws {
        let identity = makeIdentity(
            ownerUserID: 0,
            auditToken: makeAuditToken()
        )
        let signalSender = RecordingSignalSender()
        let stopper = SafeProcessStopper(
            identityReader: StubIdentityReader(identity: identity),
            signalSender: signalSender,
            userIdentityProvider: StubUserIdentityProvider(realUserID: 0, effectiveUserID: 0),
            currentProcessID: 99
        )

        XCTAssertThrowsError(try stopper.stop(makePort(identity: identity))) { error in
            XCTAssertEqual(error as? ProcessStopError, .unsafeUserContext)
        }
        XCTAssertTrue(signalSender.calls.isEmpty)
    }

    func testRejectsMismatchedRealAndEffectiveUserIDs() throws {
        let identity = makeIdentity(auditToken: makeAuditToken())
        let signalSender = RecordingSignalSender()
        let stopper = SafeProcessStopper(
            identityReader: StubIdentityReader(identity: identity),
            signalSender: signalSender,
            userIdentityProvider: StubUserIdentityProvider(realUserID: 501, effectiveUserID: 502),
            currentProcessID: 99
        )

        XCTAssertThrowsError(try stopper.stop(makePort(identity: identity))) { error in
            XCTAssertEqual(error as? ProcessStopError, .unsafeUserContext)
        }
        XCTAssertTrue(signalSender.calls.isEmpty)
    }

    func testRequestsSIGTERMOnly() throws {
        let auditToken = makeAuditToken()
        let identity = makeIdentity(auditToken: auditToken)
        let signalSender = RecordingSignalSender()
        let stopper = makeStopper(identity: identity, signalSender: signalSender)

        XCTAssertEqual(try stopper.stop(makePort(identity: identity)), .signaled)
        XCTAssertEqual(signalSender.calls.map(\.signal), [SIGTERM])
    }

    private func makeStopper(
        identity: ProcessIdentity?,
        signalSender: RecordingSignalSender
    ) -> SafeProcessStopper {
        SafeProcessStopper(
            identityReader: StubIdentityReader(identity: identity),
            signalSender: signalSender,
            userIdentityProvider: StubUserIdentityProvider(realUserID: 502, effectiveUserID: 502),
            currentProcessID: 99
        )
    }

    private func makeAuditToken(
        processID: Int32 = 42,
        processIDVersion: UInt32 = 10
    ) -> ProcessAuditToken {
        ProcessAuditToken(processID: processID, processIDVersion: processIDVersion)
    }

    private func makeIdentity(
        processID: Int32 = 42,
        ownerUserID: UInt32 = 502,
        startTimeMicroseconds: UInt64 = 1_000,
        auditToken: ProcessAuditToken?
    ) -> ProcessIdentity {
        ProcessIdentity(
            processID: processID,
            ownerUserID: ownerUserID,
            startTimeMicroseconds: startTimeMicroseconds,
            auditToken: auditToken
        )
    }

    private func makePort(
        processID: Int32 = 42,
        identity: ProcessIdentity?
    ) -> ListeningPort {
        ListeningPort(
            processID: processID,
            processName: "node",
            userID: identity?.ownerUserID,
            userName: "developer",
            port: 3001,
            addresses: ["127.0.0.1"],
            workingDirectory: "/tmp/frontend",
            isWorkingDirectoryMissing: false,
            identity: identity
        )
    }
}

private final class RecordingSignalFunction: @unchecked Sendable {
    struct Call: Equatable {
        let auditToken: ProcessAuditToken
        let signal: Int32
    }

    private let lock = NSLock()
    private let result: Int32
    private var recordedCalls: [Call] = []

    init(result: Int32 = 0) {
        self.result = result
    }

    var calls: [Call] {
        lock.withLock { recordedCalls }
    }

    func call(auditToken: ProcessAuditToken, signal: Int32) -> Int32 {
        lock.withLock {
            recordedCalls.append(.init(auditToken: auditToken, signal: signal))
        }
        return result
    }
}

private struct StubUserIdentityProvider: UserIdentityProviding {
    let realUserID: UInt32
    let effectiveUserID: UInt32
}

private final class StubIdentityReader: ProcessIdentityReading, @unchecked Sendable {
    let identity: ProcessIdentity?

    init(identity: ProcessIdentity?) {
        self.identity = identity
    }

    func identity(for processID: Int32) -> ProcessIdentity? {
        identity
    }
}

private final class RecordingSignalSender: SignalSending, @unchecked Sendable {
    struct Call: Equatable {
        let processID: Int32
        let signal: Int32
        let auditToken: ProcessAuditToken
    }

    private let lock = NSLock()
    private let error: Error?
    private var recordedCalls: [Call] = []

    var calls: [Call] {
        lock.withLock { recordedCalls }
    }

    init(error: Error? = nil) {
        self.error = error
    }

    func send(signal: Int32, to processID: Int32, auditToken: ProcessAuditToken) throws {
        lock.withLock {
            recordedCalls.append(
                .init(processID: processID, signal: signal, auditToken: auditToken)
            )
        }
        if let error {
            throw error
        }
    }
}
