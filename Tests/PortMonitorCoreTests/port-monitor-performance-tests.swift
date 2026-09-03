import XCTest
@testable import PortMonitorCore

final class PortMonitorPerformanceTests: XCTestCase {
    func testParsesFiveThousandListeners() throws {
        var fields: [String] = []
        fields.reserveCapacity(25_000)

        for index in 0..<5_000 {
            fields.append("\np\(index + 10)")
            fields.append("cnode")
            fields.append("u502")
            fields.append("f1")
            fields.append("n127.0.0.1:\(index + 1)")
        }
        let data = Data((fields.joined(separator: "\0") + "\0\n").utf8)

        let startedAt = ContinuousClock.now
        let parsedPorts = LsofOutputParser().parse(data)

        XCTAssertEqual(parsedPorts.count, 5_000)
        XCTAssertLessThan(
            startedAt.duration(to: .now),
            .seconds(2),
            "5,000件の解析に2秒以上かかっています"
        )
    }
}
