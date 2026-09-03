import Foundation

public struct ListeningPort: Identifiable, Hashable, Sendable {
    public let processID: Int32
    public let processName: String
    public let userID: UInt32?
    public let userName: String?
    public let port: Int
    public let addresses: [String]
    public let workingDirectory: String?
    public let isWorkingDirectoryMissing: Bool
    public let identity: ProcessIdentity?

    public var id: String {
        let startedAt = identity?.startTimeMicroseconds ?? 0
        return "\(processID):\(port):\(startedAt)"
    }

    public init(
        processID: Int32,
        processName: String,
        userID: UInt32?,
        userName: String?,
        port: Int,
        addresses: [String],
        workingDirectory: String? = nil,
        isWorkingDirectoryMissing: Bool = false,
        identity: ProcessIdentity? = nil
    ) {
        self.processID = processID
        self.processName = processName
        self.userID = userID
        self.userName = userName
        self.port = port
        self.addresses = addresses
        self.workingDirectory = workingDirectory
        self.isWorkingDirectoryMissing = isWorkingDirectoryMissing
        self.identity = identity
    }

    public func belongsToSameProcess(as other: ListeningPort) -> Bool {
        guard processID == other.processID else {
            return false
        }

        switch (identity, other.identity) {
        case let (.some(lhs), .some(rhs)):
            return lhs == rhs
        case (.none, .none):
            return true
        default:
            return false
        }
    }
}
