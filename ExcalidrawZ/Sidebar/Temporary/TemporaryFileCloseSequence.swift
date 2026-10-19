import Foundation

/// Keeps each close's destination choice and effects in one ordered turn.
@MainActor
final class TemporaryFileCloseSequence {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var isBusy = false
    private var waiters: [Waiter] = []

    var isIdle: Bool { !isBusy }

    func perform(_ operation: @MainActor () async -> Bool) async -> Bool {
        guard await acquire() else { return false }
        defer { release() }
        guard !Task.isCancelled else { return false }
        return await operation()
    }

    private func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        if !isBusy {
            isBusy = true
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    private func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }
}
