import Foundation

struct CanvasMutationSession: Hashable, Sendable {
    let fileID: String
    let saveSession: UUID
    let loadGeneration: UInt64
}

/// Tracks JavaScript work before its first suspension and retains dirty state until a real save.
final class OwnedCanvasMutationCoordinator: @unchecked Sendable {
    struct Revision: Equatable, Sendable {
        let session: CanvasMutationSession
        let value: UInt64
    }

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var activeOperations = 0
    private var pending: [CanvasMutationSession: Revision] = [:]

    var hasPendingSave: Bool { lock.withLock { !pending.isEmpty } }

    func pendingRevision(for session: CanvasMutationSession) -> Revision? {
        lock.withLock { pending[session] }
    }

    func recordMutation(in session: CanvasMutationSession) {
        lock.withLock {
            generation &+= 1
            pending[session] = Revision(session: session, value: generation)
        }
    }

    @MainActor
    func perform(
        in session: CanvasMutationSession,
        operation: @escaping @MainActor () async throws -> Void
    ) async throws {
        lock.withLock {
            generation &+= 1
            pending[session] = Revision(session: session, value: generation)
            activeOperations += 1
        }
        // The caller's cancellation must not acknowledge or interrupt an in-flight bridge call.
        let task = Task { @MainActor in
            defer { self.lock.withLock { self.activeOperations -= 1 } }
            try await operation()
        }
        try await task.value
        try Task.checkCancellation()
    }

    func waitUntilIdle() async -> Bool {
        while lock.withLock({ activeOperations > 0 }) {
            do { try await Task.sleep(for: .milliseconds(10)) }
            catch { return false }
        }
        return !Task.isCancelled
    }

    func acknowledge(_ revision: Revision) {
        lock.withLock {
            guard activeOperations == 0, pending[revision.session] == revision else { return }
            pending[revision.session] = nil
        }
    }
}
