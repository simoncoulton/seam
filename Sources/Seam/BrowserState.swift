import AppKit
import Observation

struct Column: Identifiable {
    let id = UUID()
    var dir: URL
    var items: [FileItem] = []
    var shown: [FileItem] = []
    var selected: URL?
    var filter = ""
    var loading = true
}

enum Direction { case left, right, up, down }

/// One tab: a stack of Miller columns plus the view settings that go with it.
@MainActor @Observable
final class BrowserState: Identifiable {
    let id = UUID()
    var columns: [Column] = []
    var focus = 0
    var sortKey: SortKey = .name
    var ascending = true
    var showHidden = UserDefaults.standard.object(forKey: "showHidden") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showHidden, forKey: "showHidden")
            refreshAll()
        }
    }
    var foldersFirst = true
    var marks: Set<URL> = []
    /// The row last marked by hand; Shift+M marks everything between it and the current row.
    var markAnchor: URL?
    var renaming: URL?
    var filtering: UUID?
    /// Columns whose filter bar is open (opened with `/`, closed with Esc).
    var filterBars: Set<UUID> = []
    /// Per-folder sort chosen from a column's filter bar; folders without one use `sortKey`.
    var sortOverrides: [URL: (key: SortKey, ascending: Bool)] = [:]
    var peek: URL?

    private(set) var history: [URL] = []
    private var historyIndex = -1
    private var watchers: [UUID: DirWatcher] = [:]
    private var peekTask: Task<Void, Never>?
    /// Mirrors `Workspace.peekFolders`, read from defaults so tabs created before the setting loads agree with it.
    private var peeksChildren: Bool { UserDefaults.standard.bool(forKey: "peekFolders") }

    init(start: URL) { go(start) }

    // MARK: Derived

    var currentDir: URL { columns.indices.contains(focus) ? columns[focus].dir : URL(fileURLWithPath: "/") }
    var shown: [FileItem] { columns.indices.contains(focus) ? columns[focus].shown : [] }
    var currentItem: FileItem? {
        guard columns.indices.contains(focus), let sel = columns[focus].selected else { return nil }
        return columns[focus].shown.first { $0.url == sel }
    }
    var title: String { currentDir.lastPathComponent.isEmpty ? "/" : currentDir.lastPathComponent }
    var hasFilter: Bool {
        columns.indices.contains(focus) && (!columns[focus].filter.isEmpty || filterBars.contains(columns[focus].id))
    }
    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex < history.count - 1 }

    func targets() -> [URL] {
        if !marks.isEmpty { return Array(marks) }
        return currentItem.map { [$0.url] } ?? []
    }

    // MARK: Loading

    func go(_ url: URL, select target: URL? = nil, record: Bool = true) {
        // Use the real path: listings report /private/var for /var, which would never match a selection
        // built from the path we were given.
        var dir = url.realURL
        var pick = target
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) else { return }
        if !isDir.boolValue { pick = dir; dir = dir.deletingLastPathComponent() }

        var chain: [URL] = []
        var cur = dir
        while true {
            chain.insert(cur, at: 0)
            if cur.path == "/" { break }
            cur = cur.deletingLastPathComponent()
        }
        columns = chain.enumerated().map { i, d in
            Column(dir: d, selected: i + 1 < chain.count ? chain[i + 1] : pick)
        }
        focus = columns.count - 1
        marks = []
        renaming = nil
        peek = nil
        filtering = nil
        filterBars = []
        if record {
            if historyIndex < history.count - 1 { history.removeSubrange((historyIndex + 1)...) }
            if history.last != dir { history.append(dir) }
            historyIndex = history.count - 1
        }
        columns.indices.forEach { reload($0) }
        syncWatchers()
    }

    func back() {
        guard canGoBack else { return }
        historyIndex -= 1
        go(history[historyIndex], record: false)
    }

    func forward() {
        guard canGoForward else { return }
        historyIndex += 1
        go(history[historyIndex], record: false)
    }

    func reload(_ index: Int, then: (() -> Void)? = nil) {
        guard columns.indices.contains(index) else { return }
        let dir = columns[index].dir
        let id = columns[index].id
        Task.detached(priority: .userInitiated) { [weak self] in
            let items = DirectoryLoader.load(dir)
            await MainActor.run {
                guard let self, let i = self.columns.firstIndex(where: { $0.id == id }) else { return }
                let firstLoad = self.columns[i].loading
                self.columns[i].items = items
                self.columns[i].loading = false
                self.applyView(i)
                self.afterLoad(i, firstLoad: firstLoad)
                then?()
            }
        }
    }

    func reloadAll() {
        SizeCache.shared.clear()
        columns.indices.forEach { reload($0) }
    }

    private func afterLoad(_ i: Int, firstLoad: Bool) {
        guard i == focus else { return }
        let shown = columns[i].shown
        if let sel = columns[i].selected, shown.contains(where: { $0.url == sel }) {
            // Rebuilt chains and reloads: make sure the column after the selection exists.
            if firstLoad, columns.count == i + 1, shown.first(where: { $0.url == sel })?.isBrowsable == true {
                select(sel, inColumn: i)
            }
        } else if let first = shown.first {
            select(first.url, inColumn: i)
        } else {
            columns[i].selected = nil
        }
    }

    func applyView(_ i: Int) {
        guard columns.indices.contains(i) else { return }
        var list = columns[i].items
        if !showHidden { list = list.filter { !$0.isHidden } }
        if !columns[i].filter.isEmpty {
            let f = columns[i].filter
            list = list.filter { $0.name.localizedCaseInsensitiveContains(f) }
        }
        let (key, asc) = sort(for: columns[i].dir)
        list.sort { a, b in
            if foldersFirst, a.isBrowsable != b.isBrowsable { return a.isBrowsable }
            let result: ComparisonResult
            switch key {
            case .name: result = a.name.localizedStandardCompare(b.name)
            case .modified: result = (a.modified ?? .distantPast).compare(b.modified ?? .distantPast)
            case .size: result = a.size < b.size ? .orderedAscending : (a.size > b.size ? .orderedDescending : .orderedSame)
            case .kind:
                let k = a.kind.localizedStandardCompare(b.kind)
                result = k == .orderedSame ? a.name.localizedStandardCompare(b.name) : k
            }
            return asc ? result == .orderedAscending : result == .orderedDescending
        }
        columns[i].shown = list
    }

    func refreshAll() { columns.indices.forEach { applyView($0) } }

    // MARK: Selection and movement

    func select(_ url: URL, inColumn i: Int) {
        guard columns.indices.contains(i) else { return }
        columns[i].selected = url
        focus = i
        peek = nil
        let item = columns[i].shown.first { $0.url == url }
        let wantsColumn = item?.isBrowsable == true && peeksChildren
        if columns.count > i + 1 {
            if wantsColumn, columns[i + 1].dir == url {
                if columns.count > i + 2 { columns.removeSubrange((i + 2)...) }
                syncWatchers()
                return
            }
            columns.removeSubrange((i + 1)...)
        }
        if wantsColumn {
            columns.append(Column(dir: url))
            reload(columns.count - 1)
        }
        syncWatchers()
    }

    /// Opens or closes the column beside the focused one after the peek setting changes.
    func syncChildColumn() {
        guard columns.indices.contains(focus) else { return }
        if let sel = columns[focus].selected { select(sel, inColumn: focus) }
        else if columns.count > focus + 1 { columns.removeSubrange((focus + 1)...); syncWatchers() }
    }

    func move(_ delta: Int) {
        let list = shown
        guard !list.isEmpty else { return }
        let cur = columns[focus].selected.flatMap { s in list.firstIndex { $0.url == s } }
        let start = cur ?? (delta > 0 ? -1 : list.count)
        let next = min(max(start + delta, 0), list.count - 1)
        select(list[next].url, inColumn: focus)
    }

    func jump(toIndex i: Int) {
        let list = shown
        guard !list.isEmpty else { return }
        select(list[min(max(i, 0), list.count - 1)].url, inColumn: focus)
    }

    func jump(toLast: Bool) {
        guard let item = toLast ? shown.last : shown.first else { return }
        select(item.url, inColumn: focus)
    }

    func navigate(_ d: Direction) {
        switch d {
        case .up: move(-1)
        case .down: move(1)
        case .left: stepLeft()
        case .right: stepRight()
        }
    }

    private func stepRight() {
        guard let item = currentItem, item.isBrowsable else { return }
        // Moving left closes the column to the right, so reopen it when going back in.
        if columns.count <= focus + 1 {
            columns.append(Column(dir: item.url))
            reload(columns.count - 1)
            syncWatchers()
        }
        focus += 1
        if columns[focus].selected == nil, let first = columns[focus].shown.first {
            select(first.url, inColumn: focus)
        }
    }

    /// Moving back closes the trailing column. With peeking on, the column for the newly focused column's
    /// selected folder stays, as it does when moving up and down.
    private func stepLeft() {
        guard focus > 0 else { return }
        focus -= 1
        let keep = focus + (peeksChildren ? 2 : 1)
        if columns.count > keep { columns.removeSubrange(keep...) }
        peek = nil
        syncWatchers()
    }

    func goUp() { stepLeft() }

    func openSelected() {
        guard let item = currentItem else { return }
        if item.isBrowsable { stepRight() } else { NSWorkspace.shared.open(item.url) }
    }

    func toggleMark() {
        guard let item = currentItem else { return }
        toggleMark(item.url)
        move(1)
    }

    func toggleMark(_ url: URL) {
        if marks.contains(url) { marks.remove(url) } else { marks.insert(url); markAnchor = url }
    }

    /// Marks every row from the anchor (or the nearest marked row above or below) to the current one.
    func markRange() {
        let list = shown
        guard let cur = columns[focus].selected.flatMap({ s in list.firstIndex { $0.url == s } }) else { return }
        var from = markAnchor.flatMap { a in list.firstIndex { $0.url == a } }
        if from == nil {
            let marked = list.indices.filter { marks.contains(list[$0].url) }
            from = marked.min { abs($0 - cur) < abs($1 - cur) }
        }
        for i in min(from ?? cur, cur)...max(from ?? cur, cur) { marks.insert(list[i].url) }
        markAnchor = list[cur].url
    }

    // MARK: Filter

    func beginFilter() {
        guard columns.indices.contains(focus) else { return }
        filterBars.insert(columns[focus].id)
        filtering = columns[focus].id
    }

    /// Leaves the field; an empty filter bar closes, one with text stays as an active filter.
    func endFilter() {
        if let id = filtering, let c = columns.first(where: { $0.id == id }), c.filter.isEmpty { filterBars.remove(id) }
        filtering = nil
    }

    func sort(for dir: URL) -> (key: SortKey, ascending: Bool) {
        sortOverrides[dir] ?? (sortKey, ascending)
    }

    func setSort(key: SortKey? = nil, ascending: Bool? = nil, inColumn i: Int) {
        guard columns.indices.contains(i) else { return }
        let cur = sort(for: columns[i].dir)
        sortOverrides[columns[i].dir] = (key ?? cur.key, ascending ?? cur.ascending)
        applyView(i)
    }

    /// Sets the tab-wide default and drops per-folder overrides so the change shows everywhere.
    func setDefaultSort(key: SortKey? = nil, ascending newAscending: Bool? = nil) {
        if let key { sortKey = key }
        if let newAscending { ascending = newAscending }
        sortOverrides = [:]
        refreshAll()
    }

    func setFilter(_ text: String, inColumn i: Int) {
        guard columns.indices.contains(i) else { return }
        columns[i].filter = text
        applyView(i)
        if let first = columns[i].shown.first, !columns[i].shown.contains(where: { $0.url == columns[i].selected }) {
            select(first.url, inColumn: i)
        }
    }

    /// Clears the filter of the column being edited, or of the focused column.
    func clearFilter() {
        let i = columns.firstIndex { $0.id == filtering } ?? focus
        if columns.indices.contains(i) { filterBars.remove(columns[i].id) }
        filtering = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
        setFilter("", inColumn: i)
    }

        // MARK: Peek (hover a folder to see inside without navigating)

    func hover(_ item: FileItem, inColumn i: Int, entered: Bool) {
        peekTask?.cancel()
        guard i == columns.count - 1 else { return }
        guard entered, item.isBrowsable, columns[i].selected != item.url else {
            if !entered, peek == item.url { peek = nil }
            return
        }
        peekTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.peek = item.url
        }
    }

    // MARK: Watchers

    private func syncWatchers() {
        let live = Set(columns.map(\.id))
        for id in watchers.keys where !live.contains(id) { watchers[id] = nil }
        for col in columns where watchers[col.id] == nil {
            let id = col.id
            watchers[id] = DirWatcher(url: col.dir) { [weak self] in
                SizeCache.shared.clear()
                guard let self, let i = self.columns.firstIndex(where: { $0.id == id }) else { return }
                self.reload(i)
            }
        }
    }
}

/// Reloads a column when something is added, removed, or renamed in its folder.
final class DirWatcher {
    private let source: DispatchSourceFileSystemObject?

    init(url: URL, onChange: @escaping @MainActor () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { source = nil; return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        s.setEventHandler { MainActor.assumeIsolated { onChange() } }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    deinit { source?.cancel() }
}
