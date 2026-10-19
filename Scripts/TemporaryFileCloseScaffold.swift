import Foundation

@MainActor final class FileState {
    enum ActiveFile: Equatable { case temporaryFile(URL), library(String) }
    enum ActiveGroup: Equatable { case temporary, other }
    var temporaryFiles: [URL]
    var currentActiveFile: ActiveFile?
    var currentActiveGroup: ActiveGroup? = .temporary
    var deletedConversations: Set<URL> = []
    var transitionCalls: [ActiveFile?] = []
    var transition: @MainActor (ActiveFile?) async -> Bool = { _ in false }
    static var current: FileState!
    init(_ files: [URL], active: ActiveFile?) { temporaryFiles = files; currentActiveFile = active; Self.current = self }
    func setActiveFile(_ file: ActiveFile?) { transitionCalls.append(file) }
    func requestActiveFileChange(_ file: ActiveFile?) async -> Bool {
        transitionCalls.append(file)
        guard await transition(file) else { return false }
        currentActiveFile = file
        return true
    }
}

@MainActor enum TemporaryFileActions {
    // INSERT CLOSE
    private static func deleteAIConversations(for files: [URL]) {
        FileState.current.deletedConversations.formUnion(files)
    }
}
