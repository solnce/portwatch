import Foundation

public protocol FreshPortScanning: PortScanning {
    func scanFresh() async throws -> [ListeningPort]
}

public actor CoalescingPortScanner: FreshPortScanning {
    private let scanner: any PortScanning
    private var inFlightTask: Task<[ListeningPort], Error>?
    private var scanGeneration = 0
    private var latestCompletedGeneration = 0
    private var latestCompletedResult: Result<[ListeningPort], Error>?
    private(set) var activeFreshRequestCount = 0

    public init(scanner: any PortScanning) {
        self.scanner = scanner
    }

    public func scan() async throws -> [ListeningPort] {
        if let inFlightTask {
            return try await waitForScan(
                inFlightTask,
                generation: scanGeneration
            )
        }

        return try await startNewScan()
    }

    public func scanFresh() async throws -> [ListeningPort] {
        activeFreshRequestCount += 1
        defer {
            activeFreshRequestCount -= 1
        }

        let minimumGeneration = scanGeneration + 1

        while true {
            if
                latestCompletedGeneration >= minimumGeneration,
                let latestCompletedResult
            {
                return try latestCompletedResult.get()
            }

            if let inFlightTask {
                let generation = scanGeneration
                if generation >= minimumGeneration {
                    return try await waitForScan(
                        inFlightTask,
                        generation: generation
                    )
                }

                _ = try? await waitForScan(
                    inFlightTask,
                    generation: generation
                )
                continue
            }

            return try await startNewScan()
        }
    }

    private func startNewScan() async throws -> [ListeningPort] {
        scanGeneration += 1
        let generation = scanGeneration
        let scanner = self.scanner
        let task = Task {
            try await scanner.scan()
        }
        inFlightTask = task

        return try await waitForScan(task, generation: generation)
    }

    private func waitForScan(
        _ task: Task<[ListeningPort], Error>,
        generation: Int
    ) async throws -> [ListeningPort] {
        do {
            let result = try await task.value
            recordCompletedScan(.success(result), generation: generation)
            clearInFlightTask(ifGenerationIs: generation)
            return result
        } catch {
            recordCompletedScan(.failure(error), generation: generation)
            clearInFlightTask(ifGenerationIs: generation)
            throw error
        }
    }

    private func recordCompletedScan(
        _ result: Result<[ListeningPort], Error>,
        generation: Int
    ) {
        guard generation >= latestCompletedGeneration else {
            return
        }
        latestCompletedGeneration = generation
        latestCompletedResult = result
    }

    private func clearInFlightTask(ifGenerationIs generation: Int) {
        guard scanGeneration == generation else {
            return
        }
        inFlightTask = nil
    }
}
