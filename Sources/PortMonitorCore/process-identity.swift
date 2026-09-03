import Darwin
import Foundation

public struct ProcessAuditToken: Hashable, Sendable {
    private let words: SIMD8<UInt32>

    init(rawValue: audit_token_t) {
        words = SIMD8(
            rawValue.val.0,
            rawValue.val.1,
            rawValue.val.2,
            rawValue.val.3,
            rawValue.val.4,
            rawValue.val.5,
            rawValue.val.6,
            rawValue.val.7
        )
    }

    init(processID: Int32, processIDVersion: UInt32) {
        var words = SIMD8<UInt32>(repeating: 0)
        words[5] = UInt32(bitPattern: processID)
        words[7] = processIDVersion
        self.words = words
    }

    var processID: Int32 {
        Int32(bitPattern: words[5])
    }

    var processIDVersion: UInt32 {
        words[7]
    }

    func withUnsafeMutableRawValue<Result>(
        _ body: (UnsafeMutablePointer<audit_token_t>) throws -> Result
    ) rethrows -> Result {
        var rawValue = audit_token_t()
        rawValue.val = (
            words[0],
            words[1],
            words[2],
            words[3],
            words[4],
            words[5],
            words[6],
            words[7]
        )
        return try withUnsafeMutablePointer(to: &rawValue, body)
    }
}

public struct ProcessIdentity: Hashable, Sendable {
    public let processID: Int32
    public let ownerUserID: UInt32
    public let startTimeMicroseconds: UInt64
    public let auditToken: ProcessAuditToken?

    public init(
        processID: Int32,
        ownerUserID: UInt32,
        startTimeMicroseconds: UInt64,
        auditToken: ProcessAuditToken? = nil
    ) {
        self.processID = processID
        self.ownerUserID = ownerUserID
        self.startTimeMicroseconds = startTimeMicroseconds
        self.auditToken = auditToken
    }
}

public protocol ProcessIdentityReading: Sendable {
    func identity(for processID: Int32) -> ProcessIdentity?
}

public struct DarwinProcessIdentityReader: ProcessIdentityReading {
    public init() {}

    public func identity(for processID: Int32) -> ProcessIdentity? {
        guard
            processID > 0,
            let initialSnapshot = bsdIdentity(for: processID),
            let auditToken = auditToken(for: processID),
            auditToken.processID == processID,
            let verifiedSnapshot = bsdIdentity(for: processID),
            initialSnapshot == verifiedSnapshot
        else {
            return nil
        }

        return ProcessIdentity(
            processID: processID,
            ownerUserID: verifiedSnapshot.ownerUserID,
            startTimeMicroseconds: verifiedSnapshot.startTimeMicroseconds,
            auditToken: auditToken
        )
    }

    private func bsdIdentity(for processID: Int32) -> BSDIdentitySnapshot? {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(
            processID,
            PROC_PIDTBSDINFO,
            0,
            &info,
            expectedSize
        )

        guard
            result == expectedSize,
            info.pbi_pid == UInt32(bitPattern: processID)
        else {
            return nil
        }

        guard
            let seconds = UInt64(exactly: info.pbi_start_tvsec),
            let microseconds = UInt64(exactly: info.pbi_start_tvusec),
            microseconds < 1_000_000
        else {
            return nil
        }
        let (scaledSeconds, overflowed) = seconds.multipliedReportingOverflow(by: 1_000_000)
        guard !overflowed else {
            return nil
        }
        let (startTime, additionOverflowed) = scaledSeconds.addingReportingOverflow(microseconds)
        guard !additionOverflowed else {
            return nil
        }

        return BSDIdentitySnapshot(
            ownerUserID: info.pbi_uid,
            startTimeMicroseconds: startTime
        )
    }

    private func auditToken(for processID: Int32) -> ProcessAuditToken? {
        var taskPort: mach_port_name_t = 0
        guard task_name_for_pid(mach_task_self_, processID, &taskPort) == KERN_SUCCESS else {
            return nil
        }
        defer {
            _ = mach_port_deallocate(mach_task_self_, taskPort)
        }

        var rawToken = audit_token_t()
        let expectedCount = mach_msg_type_number_t(
            MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size
        )
        var actualCount = expectedCount
        let result = withUnsafeMutablePointer(to: &rawToken) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(expectedCount)) { info in
                task_info(taskPort, task_flavor_t(TASK_AUDIT_TOKEN), info, &actualCount)
            }
        }

        guard result == KERN_SUCCESS, actualCount == expectedCount else {
            return nil
        }
        return ProcessAuditToken(rawValue: rawToken)
    }
}

private struct BSDIdentitySnapshot: Equatable {
    let ownerUserID: UInt32
    let startTimeMicroseconds: UInt64
}
