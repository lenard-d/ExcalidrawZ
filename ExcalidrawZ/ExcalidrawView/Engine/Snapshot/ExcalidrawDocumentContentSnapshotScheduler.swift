//
//  ExcalidrawDocumentContentSnapshotScheduler.swift
//  ExcalidrawZ
//
//  Tracks content-dirty revisions and schedules full canvas snapshot commits.
//

import Foundation

final class ExcalidrawDocumentContentSnapshotScheduler: @unchecked Sendable {
    struct CommitState: Sendable {
        let expectedFileID: String?
        let expectedRevision: Int?
    }

    private let lock = NSLock()
    private let onScheduledCommit: @Sendable (CommitState) async -> Void

    private var commitTask: Task<Void, Never>?
    private var isCommitInFlight = false
    private var latestStateRevision: Int?
    private var pendingRevision: Int?
    private var pendingFileID: String?
    private var hasPendingWithoutRevision = false
    private var lastCommitStartedAt: Date?
    private var completedContentRevision: Int?
    private var scheduledGeneration: UInt64 = 0

    private let initialDelayNanoseconds: UInt64 = 1_000_000_000
    private let throttleIntervalNanoseconds: UInt64 = 5_000_000_000

    init(onScheduledCommit: @escaping @Sendable (CommitState) async -> Void) {
        self.onScheduledCommit = onScheduledCommit
    }

    func reset() {
        lock.lock()
        commitTask?.cancel()
        commitTask = nil
        isCommitInFlight = false
        latestStateRevision = nil
        pendingRevision = nil
        pendingFileID = nil
        hasPendingWithoutRevision = false
        lastCommitStartedAt = nil
        completedContentRevision = nil
        scheduledGeneration &+= 1
        lock.unlock()
    }

    func recordLatestRevision(_ revision: Int?) {
        guard let revision else { return }
        lock.lock()
        latestStateRevision = max(latestStateRevision ?? revision, revision)
        lock.unlock()
    }

    func markClean(_ revision: Int?) {
        lock.lock()
        if let revision {
            if let latestStateRevision, revision < latestStateRevision {
                lock.unlock()
                return
            }
            latestStateRevision = revision
        }
        pendingRevision = nil
        pendingFileID = nil
        hasPendingWithoutRevision = false
        commitTask?.cancel()
        commitTask = nil
        completedContentRevision = nil
        scheduledGeneration &+= 1
        lock.unlock()
    }

    func recordPendingContentDirty(fileID: String?, revision: Int?) {
        let expectedFileID = fileID
        let expectedRevision = revision

        lock.lock()
        pendingFileID = expectedFileID
        if let expectedRevision {
            latestStateRevision = expectedRevision
            pendingRevision = expectedRevision
            hasPendingWithoutRevision = false
            if let completedContentRevision, expectedRevision > completedContentRevision {
                self.completedContentRevision = nil
                commitTask?.cancel()
                commitTask = nil
                scheduledGeneration &+= 1
            }
        } else if pendingRevision == nil {
            if let latestStateRevision {
                pendingRevision = latestStateRevision
            } else {
                hasPendingWithoutRevision = true
            }
        }

        scheduleCommitIfNeededLocked()
        lock.unlock()
    }

    /// Advances existing pending content after the web editor reports a quiet, finalized scene.
    /// An in-flight save keeps its real outcome; its completion schedules the remaining revision.
    func requestCompletedContentCommit(fileID: String, revision: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard pendingFileID == fileID,
              let pendingRevision, revision >= pendingRevision else { return }
        completedContentRevision = max(completedContentRevision ?? revision, revision)
        guard !isCommitInFlight else { return }
        commitTask?.cancel()
        commitTask = nil
        scheduleCommitIfNeededLocked()
    }

    func hasPendingDirtySnapshot() -> Bool {
        lock.lock()
        let hasPending = pendingRevision != nil || hasPendingWithoutRevision
        lock.unlock()
        return hasPending
    }

    func takeScheduledCommitState() -> CommitState? {
        lock.lock()
        defer { lock.unlock() }
        return takeScheduledCommitStateLocked()
    }

    private func takeScheduledCommitStateLocked() -> CommitState? {
        guard !isCommitInFlight else { return nil }
        let shouldCommit = pendingRevision != nil || hasPendingWithoutRevision
        guard shouldCommit else {
            commitTask = nil
            return nil
        }

        let state = CommitState(
            expectedFileID: pendingFileID,
            expectedRevision: pendingRevision
        )
        commitTask = nil
        isCommitInFlight = true
        lastCommitStartedAt = Date()
        completedContentRevision = nil
        scheduledGeneration &+= 1
        return state
    }

    func completeScheduledCommit() {
        lock.lock()
        isCommitInFlight = false
        let hasPendingChanges = pendingRevision != nil || hasPendingWithoutRevision
        if hasPendingChanges {
            scheduleCommitIfNeededLocked()
        }
        lock.unlock()
    }

    func takeFlushState() -> CommitState? {
        lock.lock()
        let shouldFlush = pendingRevision != nil || hasPendingWithoutRevision
        guard shouldFlush else {
            lock.unlock()
            return nil
        }

        let state = CommitState(
            expectedFileID: pendingFileID,
            expectedRevision: pendingRevision
        )
        commitTask?.cancel()
        commitTask = nil
        scheduledGeneration &+= 1
        lock.unlock()
        return state
    }

    /// Cancelling a lifecycle wait does not cancel or acknowledge the provider write.
    func waitForCommitToFinish() async -> Bool {
        while !Task.isCancelled {
            guard commitIsInFlight() else { return true }
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return false
            }
        }
        return false
    }

    func markCommitted(
        snapshotRevision: Int?,
        fallbackRevision: Int?
    ) {
        lock.lock()
        let committedRevision = snapshotRevision ?? fallbackRevision
        if let committedRevision,
           let latestStateRevision,
           committedRevision < latestStateRevision {
            lock.unlock()
            return
        }

        pendingRevision = nil
        pendingFileID = nil
        hasPendingWithoutRevision = false
        completedContentRevision = nil
        commitTask?.cancel()
        commitTask = nil
        scheduledGeneration &+= 1
        if let committedRevision {
            latestStateRevision = committedRevision
        }
        lock.unlock()
    }

    private func scheduleCommitIfNeededLocked() {
        guard !isCommitInFlight,
              commitTask == nil else {
            return
        }
        scheduledGeneration &+= 1
        commitTask = makeCommitTask(delay: commitDelayLocked(), generation: scheduledGeneration)
    }

    private func commitDelayLocked() -> UInt64 {
        if let completedContentRevision, let pendingRevision,
           completedContentRevision >= pendingRevision { return 0 }
        guard let lastCommitStartedAt else {
            return initialDelayNanoseconds
        }

        let elapsed = Date().timeIntervalSince(lastCommitStartedAt)
        let throttleInterval = TimeInterval(throttleIntervalNanoseconds) / 1_000_000_000
        let remaining = max(0, throttleInterval - elapsed)
        return UInt64(remaining * 1_000_000_000)
    }

    private func makeCommitTask(delay: UInt64, generation: UInt64) -> Task<Void, Never> {
        Task { [onScheduledCommit] in
            do {
                if delay > 0 {
                    try await Task.sleep(nanoseconds: delay)
                    try Task.checkCancellation()
                }
                let state = lock.withLock { () -> CommitState? in
                    guard generation == scheduledGeneration else { return nil }
                    return takeScheduledCommitStateLocked()
                }
                if let state { await onScheduledCommit(state) }
            } catch {
                return
            }
        }
    }

    private func commitIsInFlight() -> Bool {
        lock.lock()
        let isInFlight = isCommitInFlight
        lock.unlock()
        return isInFlight
    }
}
