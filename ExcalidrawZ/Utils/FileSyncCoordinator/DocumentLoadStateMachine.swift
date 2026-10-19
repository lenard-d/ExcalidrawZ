import Foundation

struct DocumentLoadStateMachine {
    struct Request: Equatable, Sendable {
        let id: String
        let generation: UInt64
        let fileID: String
    }

    private(set) var confirmedFileID: String?
    private(set) var currentRequest: Request?
    private(set) var generation: UInt64 = 0

    mutating func begin(fileID: String, force: Bool, expectedGeneration: UInt64? = nil) -> Request? {
        if let expectedGeneration, (generation != expectedGeneration || currentRequest != nil) {
            return nil
        }
        if !force {
            if currentRequest?.fileID == fileID {
                return nil
            }
            if currentRequest == nil, confirmedFileID == fileID {
                return nil
            }
        }

        generation &+= 1
        let request = Request(
            id: "native-\(generation)-\(UUID().uuidString)",
            generation: generation,
            fileID: fileID
        )
        currentRequest = request
        return request
    }

    func isCurrent(_ request: Request) -> Bool {
        currentRequest == request
    }

    func isConfirmed(_ request: Request) -> Bool {
        generation == request.generation && currentRequest == nil && confirmedFileID == request.fileID
    }

    mutating func confirm(_ request: Request) -> Bool {
        guard isCurrent(request) else { return false }
        confirmedFileID = request.fileID
        currentRequest = nil
        return true
    }

    mutating func fail(_ request: Request) -> Bool {
        guard isCurrent(request) else { return false }
        currentRequest = nil
        return true
    }

    mutating func reset() {
        generation &+= 1
        confirmedFileID = nil
        currentRequest = nil
    }
}
