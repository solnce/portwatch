import XCTest
@testable import PortMonitorCore

final class RealLsofSmokeTests: XCTestCase {
    func testRealScannerReturnsValidUniqueRecords() async throws {
        let ports = try await LsofPortScanner().scan()
        let identifiers = Set(ports.map(\.id))

        XCTAssertEqual(identifiers.count, ports.count)
        XCTAssertTrue(ports.allSatisfy { (1...65_535).contains($0.port) })
        XCTAssertTrue(ports.allSatisfy { $0.processID > 0 })
    }
}
