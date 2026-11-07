import SwiftUI
import BackpackProtocol

@MainActor
final class AdminArtworkStore: ObservableObject {
    @Published private(set) var jobs: [NativeArtworkJob] = []
    @Published private(set) var selected: NativeArtworkJob?
    @Published private(set) var source: NativeArtworkSource?
    @Published private(set) var sourceName = "Choose one explicit source"
    @Published private(set) var upload: NativeArtworkUpload?
    @Published private(set) var input: NativeArtworkUpload?
    @Published private(set) var result: NativeArtworkUpload?
    @Published private(set) var catalog: CommunityPage?
    @Published private(set) var busy = false
    @Published private(set) var failure: String?
    @Published private(set) var message: String?
    @Published private(set) var uncertainSubmission = false
    @Published private(set) var context = UUID()
    private var scope: AccountServiceScope?
    private var task: Task<Void, Never>?
    private var history: [UUID] = []
    var canUndoSelection: Bool { !history.isEmpty }
    func bind(_ community: CommunityController) {
        clear()
        do { scope = try AccountServiceScope(community, capability: .artwork, admin: true) }
        catch { failure = error.localizedDescription }
    }
    func clear() {
        task?.cancel(); task = nil; context = UUID(); scope = nil; busy = false
        jobs = []; selected = nil; catalog = nil; source = nil; upload = nil
        sourceName = "Choose one explicit source"; input = nil; result = nil
        history = []; failure = nil; message = nil; uncertainSubmission = false
    }
    private func accept(_ scope: AccountServiceScope, stamp: UUID) throws {
        try scope.check()
        guard self.scope === scope, context == stamp else { throw CancellationError() }
    }
    private func work(submitting: Bool = false, _ action: @escaping @MainActor (AccountServiceScope, UUID) async throws -> Void) {
        guard let scope, !busy else { failure = "Reload current admin capabilities and finish the active operation."; return }
        let stamp = context; busy = true; failure = nil; message = nil
        task = Task {
            do { try accept(scope, stamp: stamp); try await action(scope, stamp); try accept(scope, stamp: stamp) }
            catch {
                guard context == stamp, !Task.isCancelled else { return }
                input = nil; result = nil
                if submitting { uncertainSubmission = true }
                if scope.community.accountRevision != scope.revision || scope.community.origin != scope.origin ||
                    !scope.community.isAdmin || !scope.capability.enabled(scope.community.config) {
                    jobs = []; selected = nil; catalog = nil; source = nil; upload = nil; history = []
                } else if let denied = error as? CommunityFailure, [401,403,404,410].contains(denied.status) {
                    jobs = []; selected = nil; catalog = nil; source = nil; upload = nil; history = []
                }
                failure = error.localizedDescription + " Reload/reconcile explicitly; no automatic retry or stale rebase."
            }
            if context == stamp { busy = false }
        }
    }
    func reload() {
        work { scope, stamp in
            let list = try await scope.artworkJobs(); try self.accept(scope, stamp: stamp)
            self.jobs = list
            if let selected = self.selected {
                let current = try await scope.artworkJob(selected.id); try self.accept(scope, stamp: stamp)
                if current != selected { self.input = nil; self.result = nil }
                self.selected = current
            }
            self.message = "Current owned jobs reloaded. Retention and access remain server-enforced."
        }
    }
    func reconcileSubmission() {
        work { scope, stamp in
            let list = try await scope.artworkJobs(); try self.accept(scope, stamp: stamp)
            self.jobs = list; self.uncertainSubmission = false
            self.message = "Review the current owned jobs before deliberately starting another job. This is not an exactly-once receipt."
        }
    }
    func open(_ id: UUID, remember: Bool = true) {
        input = nil; result = nil
        work { scope, stamp in
            let value = try await scope.artworkJob(id); try self.accept(scope, stamp: stamp)
            if remember, let previous = self.selected?.id, previous != id {
                self.history.append(previous); self.history = Array(self.history.suffix(10))
            }
            self.selected = value
        }
    }
    func undoSelection() {
        guard !busy, let previous = history.popLast() else { return }
        open(previous, remember: false)
    }
    func search(_ query: String, page: Int) {
        work { scope, stamp in
            let value = try await scope.artworkCatalog(query, page: page); try self.accept(scope, stamp: stamp)
            self.catalog = value
        }
    }
    func chooseCommunity(_ item: CommunityItem) {
        guard !busy, catalog?.items.contains(where: { $0.id == item.id }) == true else { failure = "Choose a named item from the current authorized source page."; return }
        source = .community(item.id); sourceName = "Community: " + item.title; upload = nil
    }
    func chooseResult() {
        guard !busy, let selected, selected.status == .completed, selected.resultUrl != nil else { failure = "Select a current completed owned result first."; return }
        source = .result(selected.id); sourceName = "Owned result: " + selected.id.uuidString
        upload = nil
    }
    func chooseFile(_ outcome: Result<URL, Error>) {
        work { scope, stamp in
            let url = try outcome.get()
            let worker = Task.detached { try NativeArtworkUpload.prepare(url) }
            let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try self.accept(scope, stamp: stamp)
            self.upload = value; self.source = nil; self.sourceName = "Explicit local GIF input"
        }
    }
    func submit(_ settings: NativeArtworkSettings, consent: Bool) {
        guard consent, !uncertainSubmission, !jobs.contains(where: \.active) else {
            failure = "Explicit source-processing consent, no known active job and reconciled uncertain submissions are required."; return
        }
        let source = source, upload = upload
        work(submitting: true) { scope, stamp in
            let value = try await scope.createArtwork(source: source, upload: upload, settings: settings)
            try self.accept(scope, stamp: stamp)
            self.selected = value; self.input = nil; self.result = nil; self.upload = nil; self.source = nil
            self.sourceName = "Choose one explicit source"; self.uncertainSubmission = false
            self.jobs.removeAll { $0.id == value.id }; self.jobs.insert(value, at: 0); self.jobs = Array(self.jobs.prefix(20))
            self.message = "Owned preview job accepted; no original overwritten or publication performed."
        }
    }
    func loadMedia(input: Bool) {
        guard let selected else { failure = "Select a current owned job first."; return }
        work { scope, stamp in
            let value = try await scope.artworkMedia(selected, input: input); try self.accept(scope, stamp: stamp)
            guard self.selected == selected else { throw CancellationError() }
            if input { self.input = value } else { self.result = value }
        }
    }
    func export(input: Bool) async throws -> Data {
        guard !busy, let selected, let scope else { throw BackpackError.invalid("Select a current job and finish its active operation before exporting.") }
        let stamp = context; busy = true
        defer { if context == stamp { busy = false } }
        do {
            let value = try await scope.artworkMedia(selected, input: input)
            try accept(scope, stamp: stamp)
            guard self.selected == selected else { throw CancellationError() }
            return value.data
        } catch {
            if context == stamp {
                self.input = nil; result = nil
                failure = error.localizedDescription
            }
            throw error
        }
    }
    func remove(_ captured: NativeArtworkJob) {
        guard selected == captured else { failure = "The selected job changed; review its current state before cancelling/removing."; return }
        work { scope, stamp in
            try await scope.removeArtwork(captured); try self.accept(scope, stamp: stamp)
            self.jobs.removeAll { $0.id == captured.id }; self.selected = nil
            self.input = nil; self.result = nil; self.history.removeAll { $0 == captured.id }
            self.source = nil; self.upload = nil; self.sourceName = "Choose one explicit source"
            self.message = "Owned preview cancelled/removed; source artwork was not changed. A remote provider may retain assets under its own policy."
        }
    }
}
