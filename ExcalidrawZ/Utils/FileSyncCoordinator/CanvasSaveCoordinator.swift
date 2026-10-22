import Foundation

enum CanvasSaveCoverage: Sendable {
    case fullScene
    case appState
}

/// Orders capture intent before asynchronous scene reads. The file coordinator owns bytes and writes.
final class CanvasSaveCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var rank: UInt64 = 0
    private var owner: CanvasMutationSession?
    private var durableRank: UInt64?
    private var durableFullContentRank: UInt64?
    // Metadata receipts never resolve an earlier full-scene obligation.
    private var pendingFullContentRank: UInt64?

    /// Full-content callers register intent before creating a Task or starting a scene read.
    func capture(owner: CanvasMutationSession, intent: CanvasSaveCoverage = .fullScene) -> CanvasSaveCapture {
        lock.withLock {
            rank &+= 1
            if self.owner != owner {
                durableRank = nil
                durableFullContentRank = nil
                pendingFullContentRank = nil
            }
            self.owner = owner
            if intent == .fullScene { pendingFullContentRank = rank }
            return CanvasSaveCapture(owner: owner, rank: rank, coordinator: self)
        }
    }

    var hasPendingSave: Bool {
        lock.withLock { owner != nil && (durableRank != rank || pendingFullContentRank != nil) }
    }

    var hasPendingFullContent: Bool { lock.withLock { pendingFullContentRank != nil } }

    func invalidate() {
        lock.withLock {
            rank &+= 1
            owner = nil
            durableRank = nil
            durableFullContentRank = nil
            pendingFullContentRank = nil
        }
    }

    fileprivate func withCurrent<Result>(_ capture: CanvasSaveCapture, _ body: () throws -> Result) throws -> Result {
        try lock.withLock {
            guard owner == capture.owner, rank == capture.rank else { throw CancellationError() }
            return try body()
        }
    }

    fileprivate func recordDurable(_ capture: CanvasSaveCapture, coverage: CanvasSaveCoverage) {
        lock.withLock {
            guard owner == capture.owner, rank == capture.rank else { return }
            durableRank = capture.rank
            if coverage == .fullScene {
                durableFullContentRank = capture.rank
                pendingFullContentRank = nil
            }
        }
    }

    fileprivate func acknowledge(_ capture: CanvasSaveCapture, coverage: CanvasSaveCoverage, _ body: () -> Void) -> Bool {
        lock.withLock {
            guard owner == capture.owner, rank == capture.rank, durableRank == capture.rank else { return false }
            guard coverage == .appState || durableFullContentRank == capture.rank else { return false }
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

    func performSave(coverage: CanvasSaveCoverage = .fullScene, _ write: () async throws -> Void) async throws {
        try withAdmission {}
        try await write()
        coordinator.recordDurable(self, coverage: coverage)
    }

    @discardableResult
    func acknowledgeDurable(coverage: CanvasSaveCoverage = .fullScene, _ acknowledge: () -> Void) -> Bool {
        coordinator.acknowledge(self, coverage: coverage, acknowledge)
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

/// Navigation keeps the outgoing owner until its capture/save and final checks finish.
enum CanvasSaveTransition {
    @MainActor
    static func prepare<Owner: Equatable>(
        owner: Owner,
        currentOwner: () -> Owner?,
        flush: () async -> Void,
        hasPendingSave: () -> Bool
    ) async -> Bool {
        guard !Task.isCancelled, currentOwner() == owner else { return false }
        await flush()
        return !Task.isCancelled && currentOwner() == owner && !hasPendingSave()
    }
}
