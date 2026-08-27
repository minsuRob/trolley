import Foundation

/// How much of the vault is waiting on you.
///
/// One definition of what counts as 내 일감, read by every place that says a number or a
/// title for it. The options window has had a 「내 일감」 preset since before this file --
/// 담당=나 · 진행중·대기 · 제목만, applied by `applyMyWorkPreset` -- and a button that says
/// a count while that preset shows a list of a different length would make one of the two
/// a liar. So the three axes live here and every side reads them from the same place.
public enum WikiWorkload {
    /// 담당=나 · 진행중·대기, over the folders the index actually walks.
    ///
    /// 보류 is out for the same reason it is out of `WikiFilter.default`: it is the state
    /// for work that has been deliberately set down, and counting it would make the badge
    /// only ever grow. 완료 is out for the obvious one.
    ///
    /// `maxCount` and `detail` carry their initializer defaults and are not read --
    /// counting goes through `matches` rather than `apply`, so nothing is truncated.
    public static func myWorkFilter(handle: String) -> WikiFilter {
        WikiFilter(
            statuses: ["진행중", "대기"],
            assignees: [handle],
            folders: Set(WikiIndex.indexableFolders)
        )
    }

    /// The count over an already-walked snapshot. Pure, so a test never needs a vault.
    ///
    /// An empty handle counts nothing rather than everything: `WikiFilter` reads an empty
    /// set on an axis as "no constraint", so passing `[""]`-less filter through would
    /// answer with the whole open board instead of one person's share of it.
    public static func count(in pages: [WikiPage], handle: String) -> Int {
        guard !handle.isEmpty else { return 0 }
        let filter = myWorkFilter(handle: handle)
        return pages.filter(filter.matches).count
    }

    /// Up to `limit` of the pages `count` counts, in the vault's own order (`.board`,
    /// same as `INDEX.md`). Pure, so a test never needs a vault -- same reason `count` is.
    ///
    /// Goes through `apply` rather than `matches`, unlike `count`: a preview is exactly
    /// the place a cap belongs, where `count` bypasses one to avoid silently capping the
    /// number itself at `WikiFilter`'s default 40.
    public static func pages(in pages: [WikiPage], handle: String, limit: Int) -> [WikiPage] {
        guard !handle.isEmpty else { return [] }
        var filter = myWorkFilter(handle: handle)
        filter.maxCount = limit
        return filter.apply(to: pages).kept
    }

    /// The count for whoever `WikiSettings.me` names, or nil when there is nobody to
    /// count for -- no handle learned yet, or no readable vault.
    ///
    /// Nil and 0 are different answers and callers are expected to keep them apart: nil
    /// is "we do not know who you are", 0 is "we do, and nothing is on you".
    ///
    /// **Touches the disk. Never call this on the main thread.** The vault lives under
    /// `~/Desktop`, which macOS gates even for an unsandboxed app, and a walk that starts
    /// while the consent sheet is still unanswered blocks inside `open()` with no error
    /// and no log -- measured, and written up in `CLAUDE.md`.
    public static func myCount() -> Int? {
        let handle = WikiSettings.me
        guard !handle.isEmpty,
              WikiSettings.rootIsReadable,
              let root = WikiSettings.rootURL,
              let snapshot = try? WikiIndex.shared.snapshot(root: root)
        else { return nil }
        return count(in: snapshot.pages, handle: handle)
    }

    /// Up to `limit` of the pages `myCount` counts. Same disk-touching rule as `myCount`
    /// -- never call this on the main thread.
    public static func myPages(limit: Int) -> [WikiPage] {
        let handle = WikiSettings.me
        guard !handle.isEmpty,
              WikiSettings.rootIsReadable,
              let root = WikiSettings.rootURL,
              let snapshot = try? WikiIndex.shared.snapshot(root: root)
        else { return [] }
        return pages(in: snapshot.pages, handle: handle, limit: limit)
    }
}
