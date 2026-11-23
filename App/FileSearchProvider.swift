import AppKit
import MenuFoldCore

/// Files and documents from the local Spotlight index, for the panel's "Документи" section.
///
/// One `NSMetadataQuery` per search, over the user's home folder only, matched on `kMDItemFSName`
/// with the typed text as a wildcard and sorted freshest first. Nothing leaves the Mac: Spotlight is
/// the system index, the query runs in this process, and no shell command, network service or
/// third-party index is involved. Every hit goes through `FileSearch.isCandidate` (the same rules the
/// grid applies to apps: no hidden names, bundles, caches or build output), so a broad query cannot
/// leak those into the panel.
///
/// `FileSearching` is a `nonisolated async` requirement while `NSMetadataQuery` needs a run loop and
/// the main thread: the query is built and run inside `Task { @MainActor in … }`, and `searchFiles`
/// only awaits it. A query that does not answer within `timeout` (Spotlight off, still indexing)
/// comes back empty instead of keeping the section waiting.
final class SpotlightFileSearchProvider: FileSearching {
    /// How long one query may take before it answers with nothing.
    private let timeout: Duration
    /// Answers already given, so typing a query back and forth costs nothing (20 queries).
    private let cache = FileQueryCache(capacity: 20)

    init(timeout: Duration = .milliseconds(1500)) {
        self.timeout = timeout
    }

    func searchFiles(matching term: String, limit: Int) async -> [FileItem] {
        let text = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, limit > 0, !Task.isCancelled else { return [] }
        // The model asks for what it can show; the ceiling keeps a wrong caller from asking for the
        // whole disk.
        let bounded = min(limit, FileSearch.maxLimit)
        let key = Self.cacheKey(text: text, limit: bounded)
        if let cached = await cache.value(for: key) { return cached }
        let items = await Task { @MainActor [timeout] in
            await SpotlightFileQuery(text: text, limit: bounded, timeout: timeout).run()
        }.value
        // Only a real answer is worth keeping: an empty one may just mean "still indexing", and a
        // cached empty answer would hide the files of a later, successful query.
        if !items.isEmpty { await cache.store(items, for: key) }
        return items
    }

    private static func cacheKey(text: String, limit: Int) -> String {
        "\(limit)|\(text)"
    }
}

// MARK: - One query

/// One Spotlight query, from `start()` to the first answer or the timeout. Everything here is
/// main-actor bound: `NSMetadataQuery` delivers its notifications on the run loop, and reading its
/// results from another thread is not supported.
@MainActor
private final class SpotlightFileQuery {
    private let text: String
    private let limit: Int
    private let timeout: Duration
    private let query = NSMetadataQuery()
    private var observer: NSObjectProtocol?
    private var watchdog: Task<Void, Never>?
    private var continuation: CheckedContinuation<[FileItem], Never>?
    /// The gather notification and the timeout can both arrive; the continuation resumes once.
    private var didFinish = false

    init(text: String, limit: Int, timeout: Duration) {
        self.text = text
        self.limit = limit
        self.timeout = timeout
    }

    func run() async -> [FileItem] {
        // Read before the tasks: the watchdog needs only the duration, not the run object.
        let timeout = self.timeout
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            // The home folder only: documents live there, and the app grid already covers the system
            // locations. `FileSearch` still filters ~/Library and the Trash out of the hits.
            query.searchScopes = [FileManager.default.homeDirectoryForCurrentUser]
            query.predicate = NSPredicate(format: "%K LIKE[c] %@", NSMetadataItemFSNameKey,
                                          "*" + Self.escaped(text) + "*")
            query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
            observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.finishWithGatheredItems() }
            }
            watchdog = Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, !Task.isCancelled else { return }
                self.finish(with: [])
            }
            query.start()
        }
    }

    /// Hands over once and stops the query: a late notification or a timeout after the answer must
    /// not touch the continuation again.
    private func finish(with items: [FileItem]) {
        guard !didFinish else { return }
        didFinish = true
        stop()
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: items)
    }

    private func finishWithGatheredItems() {
        finish(with: items(from: query))
    }

    private func stop() {
        query.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        watchdog?.cancel()
        watchdog = nil
    }

    /// Reads the hits the query gathered, freshest first as it sorted them, each one filtered with
    /// `FileSearch.isCandidate`, at most `limit`.
    private func items(from query: NSMetadataQuery) -> [FileItem] {
        // A few more hits than the panel shows are read, since the filter drops some of them (app
        // bundles, caches, build output); reading more of the result set blocks the run loop.
        let fetchLimit = min(max(limit * 4, 24), 120)
        var items: [FileItem] = []
        items.reserveCapacity(limit)
        for hit in query.results.prefix(fetchLimit) {
            guard let hit = hit as? NSMetadataItem,
                  let path = hit.value(forAttribute: NSMetadataItemPathKey) as? String, !path.isEmpty
            else { continue }
            let item = FileItem(
                url: URL(fileURLWithPath: path),
                modified: hit.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date,
                size: (hit.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value
            )
            guard FileSearch.isCandidate(item) else { continue }
            items.append(item)
            if items.count == limit { break }
        }
        return items
    }

    /// `text` with the wildcards of a `LIKE` predicate escaped: a file called "a*b" must match
    /// itself rather than everything, and a backslash stays a backslash.
    static func escaped(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count)
        for character in text {
            if character == "*" || character == "?" || character == "\\" { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }
}

// MARK: - Cache

/// The last few answers, oldest dropped first. An actor because `searchFiles` is `nonisolated`: the
/// panel may ask from any task, while the rows it gets back are plain values.
private actor FileQueryCache {
    private let capacity: Int
    private var keys: [String] = []
    private var answers: [String: [FileItem]] = [:]

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    func value(for key: String) -> [FileItem]? {
        answers[key]
    }

    func store(_ items: [FileItem], for key: String) {
        if answers.updateValue(items, forKey: key) == nil { keys.append(key) }
        while keys.count > capacity {
            answers.removeValue(forKey: keys.removeFirst())
        }
    }
}
