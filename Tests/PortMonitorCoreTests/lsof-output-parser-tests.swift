import XCTest
@testable import PortMonitorCore

final class LsofOutputParserTests: XCTestCase {
    func testParsesIPv4IPv6AndWildcardListeners() throws {
        let data = makeLsofData([
            "p42", "cnode", "u502", "Ldeveloper", "\nf10", "n127.0.0.1:3001",
            "\nf11", "n[::1]:3001", "\nf12", "n*:4173"
        ])

        let ports = LsofOutputParser().parse(data)

        XCTAssertEqual(ports.count, 2)
        XCTAssertEqual(ports[0].processID, 42)
        XCTAssertEqual(ports[0].processName, "node")
        XCTAssertEqual(ports[0].userID, 502)
        XCTAssertEqual(ports[0].userName, "developer")
        XCTAssertEqual(ports[0].port, 3001)
        XCTAssertEqual(ports[0].addresses, ["127.0.0.1", "[::1]"])
        XCTAssertEqual(ports[1].port, 4173)
        XCTAssertEqual(ports[1].addresses, ["*"])
    }

    func testKeepsDifferentProcessesOnTheSamePortSeparate() throws {
        let data = makeLsofData([
            "p10", "cfirst", "u502", "\nf3", "n127.0.0.1:8080",
            "\np20", "csecond", "u502", "\nf4", "n127.0.0.1:8080"
        ])

        let ports = LsofOutputParser().parse(data)

        XCTAssertEqual(ports.map(\.processID), [10, 20])
        XCTAssertEqual(ports.map(\.port), [8080, 8080])
    }

    func testRejectsMalformedPIDsAndOutOfRangePortsWithoutLosingValidRecords() throws {
        let data = makeLsofData([
            "pnope", "cbroken", "\nf1", "n*:3000",
            "\np2", "cvalid", "u502", "\nf2", "n*:0",
            "\nf3", "n*:65536", "\nf4", "n*:65535"
        ])

        let ports = LsofOutputParser().parse(data)

        XCTAssertEqual(ports.count, 1)
        XCTAssertEqual(ports[0].processID, 2)
        XCTAssertEqual(ports[0].port, 65535)
    }

    func testIgnoresDuplicateFileRecordsAndUnknownFields() throws {
        let data = makeLsofData([
            "p77", "cnode", "u502", "Zunknown", "\nf7", "n*:3000",
            "\nf8", "n*:3000", "\nf9", "n127.0.0.1:3000"
        ])

        let ports = LsofOutputParser().parse(data)

        XCTAssertEqual(ports.count, 1)
        XCTAssertEqual(ports[0].addresses, ["*", "127.0.0.1"])
    }

    func testParsesWorkingDirectoriesWithSpacesAndJapaneseCharacters() throws {
        let data = makeLsofData([
            "p10", "fcwd", "n/Users/developer/作業 folder/frontend",
            "\np20", "fcwd", "n/tmp/other"
        ])

        let directories = LsofOutputParser().parseWorkingDirectories(data)

        XCTAssertEqual(directories[10], "/Users/developer/作業 folder/frontend")
        XCTAssertEqual(directories[20], "/tmp/other")
    }

    private func makeLsofData(_ fields: [String]) -> Data {
        Data((fields.joined(separator: "\0") + "\0\n").utf8)
    }
}
