import Foundation

public struct LsofOutputParser: Sendable {
    public init() {}

    public func parse(_ data: Data) -> [ListeningPort] {
        var context = ProcessContext()
        var listeners: [ListenerKey: ListenerAccumulator] = [:]

        for field in fields(in: data) {
            guard let type = field.first else {
                continue
            }
            let value = String(field.dropFirst())

            switch type {
            case "p":
                context = ProcessContext(processID: parseProcessID(value))
            case "c":
                context.processName = limited(value)
            case "u":
                context.userID = UInt32(value)
            case "L":
                context.userName = limited(value)
            case "n":
                guard
                    let processID = context.processID,
                    let endpoint = parseEndpoint(value)
                else {
                    continue
                }

                let key = ListenerKey(processID: processID, port: endpoint.port)
                var accumulator = listeners[key] ?? ListenerAccumulator(
                    processID: processID,
                    processName: context.processName,
                    userID: context.userID,
                    userName: context.userName,
                    port: endpoint.port
                )
                accumulator.add(address: endpoint.address)
                listeners[key] = accumulator
            default:
                continue
            }
        }

        return listeners.values
            .map(\.listeningPort)
            .sorted {
                if $0.port != $1.port {
                    return $0.port < $1.port
                }
                if $0.processName != $1.processName {
                    return $0.processName.localizedStandardCompare($1.processName) == .orderedAscending
                }
                return $0.processID < $1.processID
            }
    }

    public func parseWorkingDirectories(_ data: Data) -> [Int32: String] {
        var currentProcessID: Int32?
        var currentDescriptor: String?
        var directories: [Int32: String] = [:]

        for field in fields(in: data) {
            guard let type = field.first else {
                continue
            }
            let value = String(field.dropFirst())

            switch type {
            case "p":
                currentProcessID = parseProcessID(value)
                currentDescriptor = nil
            case "f":
                currentDescriptor = value
            case "n":
                guard
                    currentDescriptor == "cwd",
                    let processID = currentProcessID,
                    !value.isEmpty
                else {
                    continue
                }
                directories[processID] = limited(value, maximumLength: 4_096)
            default:
                continue
            }
        }

        return directories
    }

    private func fields(in data: Data) -> [Substring] {
        String(decoding: data, as: UTF8.self)
            .split(separator: "\0", omittingEmptySubsequences: true)
            .compactMap { rawField in
                let field = rawField.drop(while: { $0 == "\n" || $0 == "\r" })
                return field.isEmpty ? nil : field
            }
    }

    private func parseProcessID(_ value: String) -> Int32? {
        guard let processID = Int32(value), processID > 0 else {
            return nil
        }
        return processID
    }

    private func parseEndpoint(_ value: String) -> (address: String, port: Int)? {
        guard let separatorIndex = value.lastIndex(of: ":") else {
            return nil
        }

        let portText = value[value.index(after: separatorIndex)...]
        guard
            !portText.isEmpty,
            portText.allSatisfy(\.isNumber),
            let port = Int(portText),
            (1...65_535).contains(port)
        else {
            return nil
        }

        let address = String(value[..<separatorIndex])
        guard !address.isEmpty else {
            return nil
        }
        return (address, port)
    }

    private func limited(_ value: String, maximumLength: Int = 512) -> String {
        guard value.count > maximumLength else {
            return value
        }
        return String(value.prefix(maximumLength))
    }
}

private struct ProcessContext {
    var processID: Int32?
    var processName = "Unknown"
    var userID: UInt32?
    var userName: String?

    init(processID: Int32? = nil) {
        self.processID = processID
    }
}

private struct ListenerKey: Hashable {
    let processID: Int32
    let port: Int
}

private struct ListenerAccumulator {
    let processID: Int32
    let processName: String
    let userID: UInt32?
    let userName: String?
    let port: Int
    private(set) var addresses: [String] = []

    mutating func add(address: String) {
        guard !addresses.contains(address) else {
            return
        }
        addresses.append(address)
    }

    var listeningPort: ListeningPort {
        ListeningPort(
            processID: processID,
            processName: processName,
            userID: userID,
            userName: userName,
            port: port,
            addresses: addresses
        )
    }
}
