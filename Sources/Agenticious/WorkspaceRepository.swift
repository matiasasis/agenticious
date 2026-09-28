import Combine
import Foundation

@MainActor
final class WorkspaceRepository: ObservableObject {
    @Published private(set) var path: String?
    @Published private(set) var root: String?
    @Published private(set) var isChecking = false
    private var requestID = UUID()
    private let lookup: (String) async -> String?

    init(lookup: @escaping (String) async -> String? = { path in
        await Task.detached(priority: .userInitiated) { Worktrees.repositoryRoot(of: path) }.value
    }) {
        self.lookup = lookup
    }

    func check(_ path: String?) async {
        let request = UUID()
        requestID = request
        self.path = path
        root = nil
        isChecking = path != nil
        guard let path else { return }

        let result = await lookup(path)
        guard !Task.isCancelled, requestID == request else { return }
        root = result
        isChecking = false
    }

    func isReady(for path: String?) -> Bool {
        path == nil || (self.path == path && !isChecking)
    }

    func isRepository(_ path: String?) -> Bool {
        isReady(for: path) && path != nil && root != nil
    }
}
