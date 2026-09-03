import Darwin
import XCTest
@testable import PortMonitorCore

final class ProcessIdentityTests: XCTestCase {
    func testReadsAuditTokenForCurrentProcess() throws {
        let processID = getpid()

        let identity = try XCTUnwrap(DarwinProcessIdentityReader().identity(for: processID))
        let auditToken = try XCTUnwrap(identity.auditToken)

        XCTAssertEqual(identity.processID, processID)
        XCTAssertEqual(identity.ownerUserID, geteuid())
        XCTAssertEqual(auditToken.processID, processID)
    }

    func testRejectsInvalidProcessIDWithoutAuditTokenLookup() {
        XCTAssertNil(DarwinProcessIdentityReader().identity(for: 0))
        XCTAssertNil(DarwinProcessIdentityReader().identity(for: -1))
    }

    func testAuditTokenRoundTripsAllIdentityWords() {
        let token = ProcessAuditToken(processID: 42, processIDVersion: 7)

        token.withUnsafeMutableRawValue { rawToken in
            XCTAssertEqual(Int32(bitPattern: rawToken.pointee.val.5), 42)
            XCTAssertEqual(rawToken.pointee.val.7, 7)
        }
    }
}
