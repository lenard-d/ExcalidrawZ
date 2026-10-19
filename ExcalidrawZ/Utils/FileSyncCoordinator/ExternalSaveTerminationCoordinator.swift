import Foundation

struct ExternalSaveTerminationToken: Equatable {
    let fileID: String?
    let session: UUID
    let editRevision: UInt64?
    let loadGeneration: UInt64?

    init(fileID: String?, session: UUID, editRevision: UInt64?, loadGeneration: UInt64? = nil) {
        self.fileID = fileID
        self.session = session
        self.editRevision = editRevision
        self.loadGeneration = loadGeneration
    }

    func hasSameOwnerAndEdits(as other: Self) -> Bool {
        fileID == other.fileID && session == other.session && editRevision == other.editRevision
    }
}

@MainActor
protocol ExternalSaveTerminationParticipant: AnyObject {
    var terminationSaveToken: ExternalSaveTerminationToken { get }
    var hasPendingExternalSnapshot: Bool { get }
    func flushPendingCanvasSnapshotBeforeTermination() async -> Bool
}

/// Checks every live window and detects edits made while another window or backup is flushing.
@MainActor
final class ExternalSaveTerminationCoordinator {
    private struct Entry {
        weak var participant: (any ExternalSaveTerminationParticipant)?
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var validatedTokens: [ObjectIdentifier: ExternalSaveTerminationToken] = [:]

    func register(_ participant: any ExternalSaveTerminationParticipant) {
        entries[ObjectIdentifier(participant)] = Entry(participant: participant)
        validatedTokens = [:]
    }

    func flush() async -> Bool {
        validatedTokens = [:]
        entries = entries.filter { $0.value.participant != nil }
        let participants = entries.values.compactMap(\.participant)
        for participant in participants {
            guard !Task.isCancelled,
                  await participant.flushPendingCanvasSnapshotBeforeTermination() else { return false }
            validatedTokens[ObjectIdentifier(participant)] = participant.terminationSaveToken
        }
        return canConfirmTermination
    }

    var canConfirmTermination: Bool {
        guard !Task.isCancelled else { return false }
        return entries.allSatisfy { id, entry in
            guard let participant = entry.participant else { return true }
            return validatedTokens[id] == participant.terminationSaveToken && !participant.hasPendingExternalSnapshot
        }
    }
}
