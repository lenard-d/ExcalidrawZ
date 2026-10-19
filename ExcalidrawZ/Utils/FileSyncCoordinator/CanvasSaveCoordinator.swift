import Foundation

/// Orders capture intent before asynchronous scene reads. The file coordinator owns bytes and writes.
final class CanvasSaveCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var rank: UInt64 = 0
    private var owner: CanvasMutationSession?
    private var durableRank: UInt64?

    func capture(owner: CanvasMutationSession) -> CanvasSaveCapture {
        lock.withLock {
            rank &+= 1
            self.owner = owner
            return CanvasSaveCapture(owner: owner, rank: rank, coordinator: self)
        }
    }

    var hasPendingSave: Bool { lock.withLock { owner != nil && durableRank != rank } }

    func invalidate() {
        lock.withLock {
            rank &+= 1
            owner = nil
            durableRank = nil
        }
    }

    fileprivate func withCurrent<Result>(_ capture: CanvasSaveCapture, _ body: () throws -> Result) throws -> Result {
        try lock.withLock {
            guard owner == capture.owner, rank == capture.rank else { throw CancellationError() }
            return try body()
        }
    }

    fileprivate func recordDurable(_ capture: CanvasSaveCapture) {
        lock.withLock {
            guard owner == capture.owner, rank == capture.rank else { return }
            durableRank = capture.rank
        }
    }

    fileprivate func acknowledge(_ capture: CanvasSaveCapture, _ body: () -> Void) -> Bool {
        lock.withLock {
            guard owner == capture.owner, rank == capture.rank, durableRank == capture.rank else { return false }
            body()
            return true
        }
    }
}

struct CanvasSaveCapture: Sendable {
    let owner: CanvasMutationSession
    fileprivate let rank: UInt64
    fileprivate let coordinator: CanvasSaveCoordinator

    var isCurrent: Bool { (try? withAdmission {}) != nil }

    /// Admission and pending-byte replacement use the same short lock. No await occurs inside it.
    func withAdmission<Result>(_ body: () throws -> Result) throws -> Result {
        try coordinator.withCurrent(self, body)
    }

    func performSave(_ write: () async throws -> Void) async throws {
        try withAdmission {}
        try await write()
        coordinator.recordDurable(self)
    }

    @discardableResult
    func acknowledgeDurable(_ acknowledge: () -> Void) -> Bool {
        coordinator.acknowledge(self, acknowledge)
    }
}

/// Recovery export reads the live scene and never substitutes cached native content on failure.
enum CanvasRecoverySnapshot {
    @MainActor
    static func capture<Owner: Equatable, Snapshot>(
        owner: Owner,
        currentOwner: () -> Owner?,
        waitUntilIdle: () async -> Bool,
        read: () async throws -> Snapshot
    ) async throws -> Snapshot {
        guard await waitUntilIdle(), !Task.isCancelled, currentOwner() == owner else {
            throw CancellationError()
        }
        let snapshot = try await read()
        guard !Task.isCancelled, currentOwner() == owner else { throw CancellationError() }
        return snapshot
    }
}
