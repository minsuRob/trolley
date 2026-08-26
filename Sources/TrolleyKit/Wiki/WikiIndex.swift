import Foundation

/// One wiki page, as far as this app is concerned: its frontmatter and its
/// filesystem identity. Deliberately no body -- see `WikiFrontmatter` for why.
public struct WikiPage: Equatable {
    /// Absolute, and the only thing that may ever be opened. A name typed by a
    /// model reaches a file by being looked up here, never by being joined to a path.
    public let path: String
    /// Relative to the wiki root, e.g. `context/tasks/위키맵 개선.md`.
    public let relativePath: String
    /// The first two components of `relativePath`, e.g. `context/tasks`. What the
    /// folder filter matches on.
    public let folder: String
    /// The filename without `.md`. This is the wiki's own identity key: its links
    /// are `[[basename]]` and it guarantees they are unique across the vault.
    public let basename: String

    public let type: String        // 유형
    public let status: String      // 상태
    public let category: String    // 분류
    public let priority: String    // 우선순위
    public let assignee: String    // 담당
    public let summary: String     // 요약
    public let areas: [String]     // 영역 -- scalar and list forms both land here
    public let created: String     // 생성일
    public let updated: String     // 갱신일

    /// Filesystem mtime. Validates the cache, and orders the `recent` sort.
    public let modified: Date

    public init(
        path: String, relativePath: String, folder: String, basename: String,
        type: String, status: String, category: String, priority: String,
        assignee: String, summary: String, areas: [String],
        created: String, updated: String, modified: Date
    ) {
        self.path = path
        self.relativePath = relativePath
        self.folder = folder
        self.basename = basename
        self.type = type
        self.status = status
        self.category = category
        self.priority = priority
        self.assignee = assignee
        self.summary = summary
        self.areas = areas
        self.created = created
        self.updated = updated
        self.modified = modified
    }

    /// Builds a page from an already-parsed frontmatter block. Returns nil when the
    /// block is empty, which is how a file with no frontmatter stays out of the index.
    public static func make(
        frontmatter: [String: WikiFrontmatter.Value],
        path: String, relativePath: String, modified: Date
    ) -> WikiPage? {
        guard !frontmatter.isEmpty else { return nil }
        let components = relativePath.split(separator: "/")
        let folder = components.dropLast().prefix(2).joined(separator: "/")
        let basename = (components.last.map(String.init) ?? path)
            .replacingOccurrences(of: ".md", with: "", options: [.anchored, .backwards])
        return WikiPage(
            path: path,
            relativePath: relativePath,
            folder: folder,
            basename: basename,
            type: WikiFrontmatter.scalar(frontmatter["유형"]),
            status: WikiFrontmatter.scalar(frontmatter["상태"]),
            category: WikiFrontmatter.scalar(frontmatter["분류"]),
            priority: WikiFrontmatter.scalar(frontmatter["우선순위"]),
            assignee: WikiFrontmatter.scalar(frontmatter["담당"]),
            summary: WikiFrontmatter.scalar(frontmatter["요약"]),
            areas: WikiFrontmatter.list(frontmatter["영역"]),
            created: WikiFrontmatter.scalar(frontmatter["생성일"]),
            updated: WikiFrontmatter.scalar(frontmatter["갱신일"]),
            modified: modified
        )
    }
}

/// The result of one walk: the pages, and enough about the walk itself to tell the
/// truth in the setup window. `scannedFiles` and `skipped` exist so a wiki that
/// half-loaded cannot look like a wiki that is half that size.
public struct WikiSnapshot: Equatable {
    public let root: String
    public let pages: [WikiPage]
    /// Every `.md` seen, including the ones with no frontmatter.
    public let scannedFiles: Int
    /// Relative paths that could not be read or decoded.
    public let skipped: [String]
    /// True when a limit stopped the walk early, so `pages` is a prefix of the truth.
    public let timedOut: Bool
    public let builtAt: Date

    public static let empty = WikiSnapshot(
        root: "", pages: [], scannedFiles: 0, skipped: [], timedOut: false, builtAt: .distantPast
    )

    public init(
        root: String, pages: [WikiPage], scannedFiles: Int,
        skipped: [String], timedOut: Bool, builtAt: Date
    ) {
        self.root = root
        self.pages = pages
        self.scannedFiles = scannedFiles
        self.skipped = skipped
        self.timedOut = timedOut
        self.builtAt = builtAt
    }
}

/// Walks a `markhub-llm-wiki` checkout and returns its pages. Read-only, by
/// construction: nothing in this file or anywhere else under `Wiki/` opens a file
/// for writing, and nothing it imports does either. The vault's `CLAUDE.md` makes
/// `context/sources` raw input and `INDEX.md`/`LOG.md` generated output; the
/// cheapest way to honour all of that is to have no write path to review.
///
/// The walk is bounded four independent ways -- which folders it enters, how deep,
/// how many files, and a wall clock. Any one of them alone would do in the normal
/// case; together they mean a pathological tree cannot hang the prompt box, which
/// calls into here on the main thread between a keystroke and a network request.
public final class WikiIndex {
    public static let shared = WikiIndex()

    public enum Failure: Error, Equatable {
        case noRoot
        case missing(String)
        /// Told apart from `missing` on purpose. The vault lives under `~/Desktop`,
        /// which macOS gates even for an unsandboxed app, and reporting a permission
        /// refusal as "not found" sends someone hunting for a folder that is right
        /// where they left it.
        case denied(String)
    }

    /// Only these are indexed. `members/**` and `_private/**` are excluded by the
    /// vault's own rules -- `_private` is not even offered as an option, because a
    /// rule that can be toggled is a rule that eventually gets toggled.
    public static let indexableFolders = ["context/tasks", "context/concepts"]
    /// Available to the folder filter but off by default: personal and derived areas.
    public static let optionalFolders = ["members", "logs"]
    /// Never entered, whatever the filter says.
    static let forbiddenDirectories: Set<String> = ["_private", ".git", "node_modules"]

    static let maxDepth = 6
    static let maxFiles = 2_000
    static let maxBytesPerFile = 8 * 1024
    static let deadline: TimeInterval = 0.15
    /// The setup window repaints every 1.5s. Without this gate that timer would walk
    /// the disk 40 times a minute for a wiki nobody is editing.
    static let revalidateInterval: TimeInterval = 2.0

    private let lock = NSLock()
    /// Keyed by absolute path. A `nil` page is remembered too -- memoising "this file
    /// has no frontmatter" is what makes `INDEX.md` cost one read for the life of the
    /// process instead of one per walk.
    private var cache: [String: (modified: Date, page: WikiPage?)] = [:]
    private var latest: WikiSnapshot?
    private var lastWalk: Date?
    private var warming = false

    public init() {}

    /// The cached snapshot if it is fresh enough, otherwise a new walk.
    ///
    /// The per-file cache is copied out, walked against, and copied back rather than
    /// mutated under the lock. The copy is 160 small entries; holding a lock across
    /// disk I/O -- which is what the obvious version does -- would let one slow walk
    /// block the prompt box on an unrelated thread.
    public func snapshot(root: URL, folders: [String] = indexableFolders, force: Bool = false) throws -> WikiSnapshot {
        if !force, let cached = cachedSnapshot(for: root) { return cached }

        lock.lock()
        var working = cache
        lock.unlock()

        let built: WikiSnapshot
        do {
            built = try Self.walk(root: root, folders: folders, cache: &working)
        } catch {
            // A root that has gone away must not leave a stale snapshot behind
            // reporting pages that can no longer be opened.
            lock.lock()
            latest = nil
            lastWalk = nil
            lock.unlock()
            throw error
        }

        lock.lock()
        cache = working
        latest = built
        lastWalk = Date()
        lock.unlock()
        return built
    }

    /// Builds in the background so the first question never pays for a cold walk.
    /// Called at launch and whenever the root changes.
    public func prewarm(root: URL, folders: [String] = indexableFolders) {
        lock.lock()
        if warming { lock.unlock(); return }
        warming = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            _ = try? self.snapshot(root: root, folders: folders, force: true)
            self.lock.lock()
            self.warming = false
            self.lock.unlock()
        }
    }

    /// Drops everything. Used when the root changes, so pages from the old checkout
    /// cannot survive into the new one's snapshot.
    public func invalidate() {
        lock.lock()
        cache.removeAll()
        latest = nil
        lastWalk = nil
        lock.unlock()
    }

    private func cachedSnapshot(for root: URL) -> WikiSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let latest, latest.root == root.path, let lastWalk,
              Date().timeIntervalSince(lastWalk) < Self.revalidateInterval
        else { return nil }
        return latest
    }

    // MARK: - The walk

    /// Pure apart from the filesystem: no settings are read here, so a test can walk
    /// a temporary tree without touching `UserDefaults`.
    static func walk(
        root: URL,
        folders: [String],
        cache: inout [String: (modified: Date, page: WikiPage?)],
        now: () -> Date = Date.init
    ) throws -> WikiSnapshot {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure.missing(root.path)
        }
        guard manager.isReadableFile(atPath: root.path) else {
            throw Failure.denied(root.path)
        }

        let started = now()
        var pages: [WikiPage] = []
        var skipped: [String] = []
        var scanned = 0
        var timedOut = false

        for folder in folders {
            let base = root.appendingPathComponent(folder)
            guard manager.fileExists(atPath: base.path) else { continue }
            // Resolved, because the enumerator hands back resolved paths and `/var` is
            // a symlink to `/private/var` on every Mac. Comparing an unresolved base
            // against a resolved entry finds no common prefix, and every page then
            // ends up with an empty `folder` -- which the folder filter silently
            // matches nothing against. Caught by a fixture living in the temp dir.
            let basePath = base.resolvingSymlinksInPath().path
            guard let walker = manager.enumerator(
                at: base,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            while let entry = walker.nextObject() as? URL {
                if scanned >= maxFiles || now().timeIntervalSince(started) > deadline {
                    timedOut = true
                    break
                }
                let values = try? entry.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
                )
                // Never `resolvingSymlinksInPath`: the vault has `.agents/skills`
                // pointing back into itself, and following links is how a walk of a
                // finite tree becomes infinite.
                if values?.isSymbolicLink == true {
                    walker.skipDescendants()
                    continue
                }
                if values?.isDirectory == true {
                    if forbiddenDirectories.contains(entry.lastPathComponent) || walker.level > maxDepth {
                        walker.skipDescendants()
                    }
                    continue
                }
                guard entry.pathExtension == "md" else { continue }
                scanned += 1

                // Built from the folder being walked rather than from the root, so it
                // is right regardless of how either path was spelled.
                let withinFolder = entry.path.hasPrefix(basePath + "/")
                    ? String(entry.path.dropFirst(basePath.count + 1))
                    : entry.lastPathComponent
                let relative = folder + "/" + withinFolder
                let modified = values?.contentModificationDate ?? .distantPast

                if let hit = cache[entry.path], hit.modified == modified {
                    if let page = hit.page { pages.append(page) }
                    continue
                }
                guard let text = head(of: entry, bytes: maxBytesPerFile) else {
                    skipped.append(relative)
                    continue
                }
                let page = WikiPage.make(
                    frontmatter: WikiFrontmatter.scan(text),
                    path: entry.path, relativePath: relative, modified: modified
                )
                cache[entry.path] = (modified, page)
                if let page { pages.append(page) }
            }
            if timedOut { break }
        }

        return WikiSnapshot(
            root: root.path, pages: pages, scannedFiles: scanned,
            skipped: skipped, timedOut: timedOut, builtAt: started
        )
    }

    /// The first `bytes` of a file, decoded as UTF-8.
    ///
    /// `FileHandle` rather than `String(contentsOf:)` because the largest page in the
    /// vault is 36KB and its frontmatter is under 400 bytes; reading the whole file to
    /// throw away 98% of it is exactly the cost this feature exists to avoid.
    ///
    /// A prefix read can land mid-character, so a strict decode is not enough on its
    /// own -- the lossy fallback is for the split byte, not for a corrupt file. Only a
    /// file that cannot be opened at all is skipped.
    static func head(of url: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes) else { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(decoding: data, as: UTF8.self)
    }
}
