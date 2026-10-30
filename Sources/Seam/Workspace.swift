import AppKit
import NetFS
import Observation
import SwiftUI

enum Overlay { case search, location, shortcuts, preview }

struct SidebarPlace: Identifiable, Hashable, Codable {
    var name: String
    let symbol: String
    let url: URL
    var id: URL { url }
}

/// App-wide state: tabs, theme, overlays, clipboard, undo.
@MainActor @Observable
final class Workspace {
    static let shared = Workspace()

    var tabs: [BrowserState] = []
    var activeTab = 0
    var overlay: Overlay? { didSet { if oldValue == .search, overlay != .search { search.stop() } } }
    var locationText = ""
    var toastText: String?
    var volumes: [SidebarPlace] = []
    /// Dropbox, OneDrive (including shared libraries), Google Drive and iCloud Drive, as Finder lists them.
    var cloud: [SidebarPlace] = []
    /// Cloud placeholders currently being downloaded.
    var downloading: Set<URL> = []
    private var cloudWatch: DispatchSourceFileSystemObject?
    var search = SearchModel()
    var places: [SidebarPlace] = []
    var renamingPlace: URL?
    var locationSuggestions: [LocationSuggestion] = []
    var locationSelection = -1
    var locationMessage: String?
    var shareCache: [String: [String]] = [:]
    var shareErrors: [String: String] = [:]
    var sharesLoading: Set<String> = []
    /// Vim-style input waiting for its motion, e.g. "5" or "g" or "12g", shown in the status bar.
    var pendingKeys = ""
    @ObservationIgnored private var pendingCount: Int?
    @ObservationIgnored private var pendingG = false
    @ObservationIgnored private var pendingToken = 0

    var themes: [Theme] = Themes.presets
    var theme: Theme = Themes.presets[0]
    var pins: [URL] = []
    var showPreview = true { didSet { defaults.set(showPreview, forKey: "showPreview") } }
    var showSidebar = true
    var previewWidth: CGFloat = 300 { didSet { defaults.set(Double(previewWidth), forKey: "previewWidth") } }
    var hidePinnedWhenEmpty = false { didSet { defaults.set(hidePinnedWhenEmpty, forKey: "hidePinnedWhenEmpty") } }
    var monoIcons = false { didSet { defaults.set(monoIcons, forKey: "monoIcons") } }
    /// Window tint opacity; below 1 the window turns translucent with a blur behind it.
    var opacity = 1.0 { didSet { defaults.set(opacity, forKey: "opacity") } }
    var textScale = 1.0 { didSet { defaults.set(textScale, forKey: "textScale") } }
    var airy = false { didSet { defaults.set(airy, forKey: "airy") } }

    private var clipboard: (urls: [URL], cut: Bool)?
    private var undoStack: [(label: String, run: () -> Void)] = []
    private var toastTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    private var monitor: Any?

    var tab: BrowserState { tabs[activeTab] }
    var rowHeight: CGFloat { (airy ? 30 : 23) * textScale }
    var fontSize: CGFloat { 13 * textScale }
    var iconTint: Color { theme.tint }

    init() {
        themes = Themes.presets + Themes.loadCustom()
        if let name = defaults.string(forKey: "theme"), let t = themes.first(where: { $0.name == name }) { theme = t }
        pins = (defaults.stringArray(forKey: "pins") ?? []).map {
            $0.contains("://") ? (URL(string: $0) ?? URL(fileURLWithPath: $0)) : URL(fileURLWithPath: $0)
        }
        loadPlaces()
        if defaults.object(forKey: "showPreview") != nil { showPreview = defaults.bool(forKey: "showPreview") }
        let scale = defaults.double(forKey: "textScale")
        if scale > 0 { textScale = scale }
        airy = defaults.bool(forKey: "airy")
        monoIcons = defaults.bool(forKey: "monoIcons")
        let savedWidth = defaults.double(forKey: "previewWidth")
        if savedWidth > 0 { previewWidth = min(max(CGFloat(savedWidth), 220), 560) }
        hidePinnedWhenEmpty = defaults.bool(forKey: "hidePinnedWhenEmpty")
        if defaults.object(forKey: "opacity") != nil { opacity = defaults.double(forKey: "opacity") }
        tabs = [BrowserState(start: FileManager.default.homeDirectoryForCurrentUser)]
        refreshVolumes()
        refreshCloud()
        watchCloudStorage()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Workspace.shared.refreshVolumes() }
            }
        }
    }

    // MARK: Sidebar

    static func defaultPlaces() -> [SidebarPlace] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        func p(_ n: String, _ s: String, _ rel: String) -> SidebarPlace {
            SidebarPlace(name: n, symbol: s, url: rel.isEmpty ? home : home.appendingPathComponent(rel))
        }
        return [
            p("Home", "house", ""), p("Desktop", "menubar.dock.rectangle", "Desktop"),
            p("Documents", "doc", "Documents"), p("Downloads", "arrow.down.circle", "Downloads"),
            p("Pictures", "photo", "Pictures"), p("Movies", "film", "Movies"),
            p("Music", "music.note", "Music"),
            SidebarPlace(name: "Applications", symbol: "square.grid.2x2", url: URL(fileURLWithPath: "/Applications")),
            p("Trash", "trash", ".Trash"),
        ]
    }

    private func loadPlaces() {
        if let data = defaults.data(forKey: "places"), let saved = try? JSONDecoder().decode([SidebarPlace].self, from: data) {
            places = saved
        } else {
            places = Self.defaultPlaces()
        }
    }

    private func savePlaces() {
        if let data = try? JSONEncoder().encode(places) { defaults.set(data, forKey: "places") }
    }

    func addPlace(_ url: URL) {
        guard !places.contains(where: { $0.url == url }) else { toast("\(url.lastPathComponent) is already in Places"); return }
        let name = url.lastPathComponent.isEmpty ? "Macintosh HD" : url.lastPathComponent
        withAnimation(.smooth(duration: 0.2)) { places.append(SidebarPlace(name: name, symbol: "folder", url: url)) }
        savePlaces()
    }

    func removePlace(_ url: URL) {
        withAnimation(.smooth(duration: 0.2)) { places.removeAll { $0.url == url } }
        savePlaces()
    }

    func renamePlace(_ url: URL, to name: String) {
        guard renamingPlace == url else { return }
        renamingPlace = nil
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let i = places.firstIndex(where: { $0.url == url }) else { return }
        places[i].name = trimmed
        savePlaces()
    }

    func resetPlaces() {
        withAnimation(.smooth(duration: 0.2)) { places = Self.defaultPlaces() }
        savePlaces()
    }

    func movePlace(_ url: URL, by offset: Int) {
        guard let i = places.firstIndex(where: { $0.url == url }) else { return }
        let j = min(max(i + offset, 0), places.count - 1)
        guard i != j else { return }
        withAnimation(.smooth(duration: 0.2)) { places.insert(places.remove(at: i), at: j) }
        savePlaces()
    }

    func movePin(_ url: URL, by offset: Int) {
        guard let i = pins.firstIndex(of: url) else { return }
        let j = min(max(i + offset, 0), pins.count - 1)
        guard i != j else { return }
        withAnimation(.smooth(duration: 0.2)) { pins.insert(pins.remove(at: i), at: j) }
        savePins()
    }

    /// Handles a sidebar row dropped on another row of the same section: it takes the target's slot.
    /// Row being dragged for reordering; set when the drag starts so the drop doesn't depend on the pasteboard.
    var draggingRow: (section: String, url: URL)?
    /// Row the drag is hovering over; the sidebar draws an insertion bar on it.
    var dropTarget: URL?

    /// True when dropping on `url` would put the dragged row below it (it came from above).
    func dragComesFromAbove(_ url: URL) -> Bool {
        guard let drag = draggingRow else { return false }
        let urls = drag.section == "places" ? places.map(\.url) : pins
        guard let a = urls.firstIndex(of: drag.url), let b = urls.firstIndex(of: url) else { return false }
        return a < b
    }

    /// Moves the dragged row to where `target` is.
    func reorderDragging(onto target: URL, section: String) {
        guard let drag = draggingRow, drag.section == section, drag.url != target else { return }
        withAnimation(.smooth(duration: 0.2)) {
            if section == "places" {
                guard let from = places.firstIndex(where: { $0.url == drag.url }),
                      let to = places.firstIndex(where: { $0.url == target }) else { return }
                places.insert(places.remove(at: from), at: to)
            } else {
                guard let from = pins.firstIndex(of: drag.url), let to = pins.firstIndex(of: target) else { return }
                pins.insert(pins.remove(at: from), at: to)
            }
        }
        section == "places" ? savePlaces() : savePins()
    }

    /// Cloud providers mount as File Provider folders in ~/Library/CloudStorage, one per account or library.
    func refreshCloud() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let storage = home.appendingPathComponent("Library/CloudStorage")
        let urls = (try? FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var places = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { SidebarPlace(name: Self.cloudName($0.lastPathComponent), symbol: "cloud", url: $0) }
        let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if FileManager.default.fileExists(atPath: icloud.path) {
            places.insert(SidebarPlace(name: "iCloud Drive", symbol: "icloud", url: icloud), at: 0)
        }
        if places != cloud { cloud = places }
    }

    /// `OneDrive-SharedLibraries-Acme` becomes "OneDrive – Shared Libraries – Acme"; `GoogleDrive-me@x.com` likewise.
    nonisolated static func cloudName(_ folder: String) -> String {
        folder.split(separator: "-", omittingEmptySubsequences: true).enumerated().map { i, part in
            var s = String(part)
            if s == "SharedLibraries" { s = "Shared Libraries" }
            if i == 0, s == "GoogleDrive" { s = "Google Drive" }
            return s
        }.joined(separator: " – ")
    }

    /// Accounts appear and disappear as providers sign in and out.
    private func watchCloudStorage() {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage").path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { Workspace.shared.refreshCloud() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        cloudWatch = source
    }

    func refreshVolumes() {
        let keys: [URLResourceKey] = [.volumeNameKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        volumes = urls.map { u in
            let name = (try? u.resourceValues(forKeys: Set(keys)).volumeName) ?? u.lastPathComponent
            return SidebarPlace(name: name ?? u.lastPathComponent, symbol: u.path == "/" ? "internaldrive" : "externaldrive", url: u)
        }
    }

    func eject(_ place: SidebarPlace) {
        guard place.url.path != "/" else { return }
        do { try NSWorkspace.shared.unmountAndEjectDevice(at: place.url) }
        catch { toast("Couldn't eject \(place.name): \(error.localizedDescription)") }
    }

    func togglePin(_ url: URL) {
        if let i = pins.firstIndex(of: url) { pins.remove(at: i) } else { pins.append(url) }
        savePins()
    }

    /// Adds a pin without toggling it off, so drag and drop onto the sidebar is idempotent.
    func pin(_ url: URL) {
        guard !pins.contains(url) else { return }
        pins.append(url)
        savePins()
    }

    func isPinned(_ url: URL) -> Bool { pins.contains(url) }

    private func savePins() {
        defaults.set(pins.map { $0.isFileURL ? $0.path : $0.absoluteString }, forKey: "pins")
    }

    func pinAddress(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: t), let scheme = url.scheme, scheme.count > 1 {
            pin(url)
            toast("Pinned \(t)")
        } else if FileManager.default.fileExists(atPath: (t as NSString).expandingTildeInPath) {
            pin(URL(fileURLWithPath: (t as NSString).expandingTildeInPath))
            toast("Pinned \(t)")
        } else {
            toast("Nothing to pin at \(t)")
        }
    }

    func openPin(_ url: URL) {
        if !url.isFileURL { mount(url); return }
        if FileManager.default.fileExists(atPath: url.path) { tab.go(url) }
        else { toast("\(url.lastPathComponent) isn't available. Is the drive connected?") }
    }

    // MARK: Network shares and AirDrop

    /// Mounts a network share into /Volumes through NetFS (no Finder window), then browses it.
    /// A URL with no share name makes macOS show its own login and share picker.
    func mount(_ url: URL, hint: String? = nil) {
        toast("Connecting to \(url.host ?? url.absoluteString)…")
        Task {
            let (status, mountPaths) = await Task.detached { () -> (Int32, [String]) in
                let options = NSMutableDictionary()
                options[kNAUIOptionKey as String] = kNAUIOptionAllowUI as String
                var mounts: Unmanaged<CFArray>?
                let status = NetFSMountURLSync(url as CFURL, nil, nil, nil, options, nil, &mounts)
                return (status, (mounts?.takeRetainedValue() as? [String]) ?? [])
            }.value
            // 17 (EEXIST): already mounted, so just go there.
            let fallback = "/Volumes/\(url.lastPathComponent)"
            let existing = !url.lastPathComponent.isEmpty && FileManager.default.fileExists(atPath: fallback)
            let path = mountPaths.first ?? (existing ? fallback : nil)
            refreshVolumes()
            if let path, status == 0 || status == 17 {
                toastText = nil
                tab.go(URL(fileURLWithPath: path))
                if mountPaths.count > 1 { toast("Mounted \(mountPaths.count) shares. The others are under Devices.") }
            } else if status == -128 {
                toastText = nil
            } else if status == -5998 {
                toast("No shares are available to that account")
            } else {
                let detail = hint.map { " (\($0))" } ?? ""
                toast("Couldn't connect to \(url.host ?? url.absoluteString), error \(status)\(detail)")
            }
        }
    }

    func airdrop(_ urls: [URL]) {
        guard !urls.isEmpty else { toast("Select files, then send with AirDrop"); return }
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            toast("AirDrop isn't available. Check Wi-Fi and Bluetooth.")
            return
        }
        service.perform(withItems: urls)
    }

    // MARK: Tabs, theme

    func newTab(at url: URL? = nil) {
        tabs.append(BrowserState(start: url ?? tab.currentDir))
        activeTab = tabs.count - 1
    }

    func closeTab(_ i: Int) {
        guard tabs.count > 1 else { NSApp.keyWindow?.close(); return }
        tabs.remove(at: i)
        activeTab = min(activeTab, tabs.count - 1)
    }

    func cycleTab(_ d: Int) { activeTab = ((activeTab + d) % tabs.count + tabs.count) % tabs.count }

    func setTheme(_ t: Theme) {
        theme = t
        defaults.set(t.name, forKey: "theme")
    }

    func saveThemeCopy() {
        var t = theme
        t = Theme(name: t.name + " Custom", isDark: t.isDark, background: t.background, surface: t.surface,
                  text: t.text, subtext: t.subtext, accent: t.accent, selection: t.selection)
        do {
            let url = try Themes.save(t)
            themes = Themes.presets + Themes.loadCustom()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            toast("Saved \(url.lastPathComponent). Edit the colors, then relaunch to load changes.")
        } catch { toast("Couldn't save theme: \(error.localizedDescription)") }
    }

    func toast(_ text: String) {
        toastText = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { toastText = nil }
        }
    }

    // MARK: Location

    func openLocation(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { overlay = nil; return }
        if let smb = SMBAddress(t) {
            if smb.isServerOnly { connectServer(smb); return }
            overlay = nil
            if let url = smb.url { mount(url) }
            return
        }
        overlay = nil
        if let url = URL(string: t), let scheme = url.scheme, scheme.count > 1 {
            switch scheme.lowercased() {
            case "afp", "nfs", "ftp": mount(url)
            case "http", "https": NSWorkspace.shared.open(url)
            case "sftp", "ssh": toast("macOS can't mount SFTP natively yet. Mount it with sshfs, then open it from /Volumes.")
            default: toast("Unsupported address: \(t)")
            }
            return
        }
        let path = (t as NSString).expandingTildeInPath
        let resolved = path.hasPrefix("/") ? path : tab.currentDir.appendingPathComponent(path).path
        if FileManager.default.fileExists(atPath: resolved) { tab.go(URL(fileURLWithPath: resolved)) }
        else { toast("No such path: \(t)") }
    }

    // MARK: File operations

    private func pushUndo(_ label: String, _ run: @escaping () -> Void) {
        undoStack.append((label, run))
        if undoStack.count > 20 { undoStack.removeFirst() }
    }

    func undo() {
        guard let last = undoStack.popLast() else { toast("Nothing to undo"); return }
        last.run()
        toast("Undid \(last.label)")
        tab.reloadAll()
    }

    func copy(cut: Bool) {
        let urls = tab.targets()
        guard !urls.isEmpty else { return }
        clipboard = (urls, cut)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
        toast(cut ? "Cut \(urls.count) item(s)" : "Copied \(urls.count) item(s)")
    }

    func paste() {
        let dir = tab.currentDir
        let source: (urls: [URL], cut: Bool)
        if let c = clipboard { source = c }
        else if let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            source = (urls, false)
        } else { return }
        transfer(source.urls, into: dir, move: source.cut)
        if source.cut { clipboard = nil }
    }

    func transfer(_ urls: [URL], into dir: URL, move: Bool) {
        let fm = FileManager.default
        var pairs: [(from: URL, to: URL)] = []
        for src in urls {
            var dest = dir.appendingPathComponent(src.lastPathComponent)
            if src.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL, move { continue }
            if src.standardizedFileURL == dest.standardizedFileURL || fm.fileExists(atPath: dest.path) {
                dest = dest.uniqueSibling()
            }
            do {
                if move { try fm.moveItem(at: src, to: dest) } else { try fm.copyItem(at: src, to: dest) }
                pairs.append((src, dest))
            } catch { toast(error.localizedDescription) }
        }
        guard !pairs.isEmpty else { return }
        if move {
            pushUndo("move") { for p in pairs { try? fm.moveItem(at: p.to, to: p.from) } }
        } else {
            pushUndo("copy") { for p in pairs { try? fm.trashItem(at: p.to, resultingItemURL: nil) } }
        }
        tab.marks = []
        tab.reloadAll()
    }

    func trash() {
        let urls = tab.targets()
        guard !urls.isEmpty else { return }
        var moved: [(from: URL, trashed: URL)] = []
        for u in urls {
            var result: NSURL?
            do {
                try FileManager.default.trashItem(at: u, resultingItemURL: &result)
                if let r = result as URL? { moved.append((u, r)) }
            } catch { toast(error.localizedDescription) }
        }
        guard !moved.isEmpty else { return }
        pushUndo("trash") { for m in moved { try? FileManager.default.moveItem(at: m.trashed, to: m.from) } }
        tab.marks = []
        tab.reloadAll()
    }

    /// Removes the targets for good, after asking. Not undoable.
    func deletePermanently() {
        let urls = tab.targets()
        guard !urls.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = urls.count == 1 ? "Delete “\(urls[0].lastPathComponent)” permanently?" : "Delete \(urls.count) items permanently?"
        alert.informativeText = "This skips the Trash and can't be undone."
        let delete = alert.addButton(withTitle: "Delete")
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var failed = 0
        for u in urls {
            do { try FileManager.default.removeItem(at: u) } catch { failed += 1; toast(error.localizedDescription) }
        }
        if failed < urls.count { toast("Deleted \(urls.count - failed) item\(urls.count - failed == 1 ? "" : "s")") }
        tab.marks = []
        tab.reloadAll()
    }

    /// Pulls a cloud placeholder down by reading it: the provider fetches the contents before the read returns.
    func download(_ item: FileItem) {
        let url = item.url
        guard item.isCloudOnly, !downloading.contains(url) else { return }
        downloading.insert(url)
        Task {
            let ok = await Task.detached { () -> Bool in
                guard let h = try? FileHandle(forReadingFrom: url) else { return false }
                defer { try? h.close() }
                while let chunk = try? h.read(upToCount: 4 << 20), !chunk.isEmpty {}
                return true
            }.value
            downloading.remove(url)
            if ok { tab.reloadAll() } else { toast("Couldn't download \(item.name)") }
        }
    }

    func beginRename() {
        guard let item = tab.currentItem else { return }
        tab.renaming = item.url
    }

    /// Drops the rename field and its text editor, so keys reach `handle(_:)` again.
    func cancelRename() {
        tab.renaming = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    func commitRename(_ newName: String) {
        guard let url = tab.renaming else { return }
        cancelRename()
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != url.lastPathComponent, !name.contains("/") else { return }
        let dest = url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: url.hasDirectoryPath)
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            pushUndo("rename") { try? FileManager.default.moveItem(at: dest, to: url) }
            // Point the selection (and the folder column beside it) at the new path before reloading. Otherwise the
            // reload sees a missing selection, jumps to the first row, and the child column is torn down and rebuilt.
            let col = tab.focus
            if tab.columns.indices.contains(col), tab.columns[col].selected == url {
                tab.columns[col].selected = dest
                if tab.columns.indices.contains(col + 1), tab.columns[col + 1].dir == url {
                    tab.columns[col + 1].dir = dest
                    tab.reload(col + 1)
                }
            }
            tab.reload(col) { [tab] in
                guard tab.columns.indices.contains(col),
                      let item = tab.columns[col].shown.first(where: { $0.name == name }) else { return }
                tab.select(item.url, inColumn: col)
            }
        } catch { toast(error.localizedDescription) }
    }

    func newFile() {
        let url = tab.currentDir.appendingPathComponent("untitled").uniqueSibling(suffix: " ")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { toast("Couldn't create a file here"); return }
        pushUndo("new file") { try? FileManager.default.removeItem(at: url) }
        revealAndRename(url)
    }

    /// Reloads the focused column, selects the new item and starts renaming it. The row is matched by name
    /// because the loader's URL for it can differ from ours (trailing slash on folders, `/private` prefix).
    private func revealAndRename(_ url: URL) {
        let name = url.lastPathComponent
        tab.reload(tab.focus) { [tab] in
            let col = tab.focus
            guard let item = tab.columns[col].shown.first(where: { $0.name == name }) else { return }
            tab.select(item.url, inColumn: col)
            tab.renaming = item.url
        }
    }

    func newFolder() {
        let dir = tab.currentDir
        let url = dir.appendingPathComponent("untitled folder").uniqueSibling(suffix: " ")
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            pushUndo("new folder") { try? FileManager.default.removeItem(at: url) }
            revealAndRename(url)
        } catch { toast(error.localizedDescription) }
    }

    func compress() {
        let urls = tab.targets()
        guard let first = urls.first else { return }
        let dir = tab.currentDir
        let out = urls.count == 1
            ? dir.appendingPathComponent(first.lastPathComponent + ".zip")
            : dir.appendingPathComponent("Archive.zip")
        let dest = FileManager.default.fileExists(atPath: out.path) ? out.uniqueSibling() : out
        let names = urls.map(\.lastPathComponent)
        run("/usr/bin/zip", ["-r", "-q", dest.path] + names, cwd: dir, done: "Created \(dest.lastPathComponent)")
    }

    func extract() {
        guard let item = tab.currentItem else { return }
        let dir = tab.currentDir
        let ext = item.url.pathExtension.lowercased()
        let stem = item.url.deletingPathExtension().lastPathComponent
        let target = dir.appendingPathComponent(stem)
        let dest = FileManager.default.fileExists(atPath: target.path) ? target.uniqueSibling(suffix: " ") : target
        switch ext {
        case "zip": run("/usr/bin/ditto", ["-x", "-k", item.url.path, dest.path], cwd: dir, done: "Extracted \(stem)")
        case "tar", "gz", "tgz", "bz2", "xz":
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            run("/usr/bin/tar", ["-xf", item.url.path, "-C", dest.path], cwd: dir, done: "Extracted \(stem)")
        default: toast("Not an archive Seam can extract")
        }
    }

    private func run(_ exe: String, _ args: [String], cwd: URL, done: String) {
        Task {
            let ok = await Task.detached { () -> Bool in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                p.currentDirectoryURL = cwd
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
            }.value
            toast(ok ? done : "Operation failed")
            tab.reloadAll()
        }
    }

    func copyPath() {
        let paths = tab.targets().map(\.path).joined(separator: "\n")
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths, forType: .string)
        toast("Copied path")
    }

    func revealInFinder() {
        let urls = tab.targets()
        if urls.isEmpty { NSWorkspace.shared.open(tab.currentDir) }
        else { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func openTerminal() {
        let cfg = NSWorkspace.OpenConfiguration()
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([tab.currentDir], withApplicationAt: app, configuration: cfg)
    }

    // MARK: Keyboard

    func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { Workspace.shared.handle(event) ? nil : event }
        }
    }

    private var isEditingText: Bool { NSApp.keyWindow?.firstResponder is NSTextView }

    /// Letters are matched by physical key position so h/j/k/l keep working on non-Latin layouts.
    private static let letterByKeyCode: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b",
        12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 31: "o", 32: "u", 34: "i", 35: "p",
        37: "l", 38: "j", 40: "k", 45: "n", 46: "m",
    ]

    private func handle(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        let cmd = mods.contains(.command), ctrl = mods.contains(.control)
        let shift = mods.contains(.shift), opt = mods.contains(.option)
        let code = e.keyCode
        let letter = Self.letterByKeyCode[code] ?? ""
        let chars = e.charactersIgnoringModifiers ?? ""

        // Overlays own the keyboard.
        if let o = overlay {
            if code == 53 || (o == .shortcuts && (code == 122 || chars == "?")) { overlay = nil; return true }
            if o == .preview {
                if code == 49 || letter == "q" { overlay = nil; return true }
                if code == 125 || letter == "j" { tab.move(1); return true }
                if code == 126 || letter == "k" { tab.move(-1); return true }
                return true
            }
            if o == .search {
                if code == 125 || (ctrl && (letter == "n" || letter == "j")) { search.move(1); return true }
                if code == 126 || (ctrl && (letter == "p" || letter == "k")) { search.move(-1); return true }
                if code == 36 { if let hit = search.selectedHit { overlay = nil; tab.go(hit.url) }; return true }
            }
            if o == .location {
                if code == 36 { submitLocation(); return true }
                if code == 48 { completeLocation(); return true }
                if code == 125 || code == 126 { moveLocationSelection(code == 125 ? 1 : -1); return true }
            }
            if o == .location, ctrl, letter == "p" {
                pinAddress(locationSuggestions.indices.contains(locationSelection) ? locationSuggestions[locationSelection].text : locationText)
                return true
            }
            return false
        }

        if renamingPlace != nil { if code == 53 { renamingPlace = nil; return true }; return false }
        if tab.renaming != nil { if code == 53 { cancelRename(); return true }; return false }
        if tab.filtering != nil {
            if code == 53 { tab.clearFilter(); return true }
            if code == 36 { tab.endFilter(); return true }
            return false
        }
        if isEditingText {
            if code == 53 { NSApp.keyWindow?.makeFirstResponder(nil); return true }
            return false
        }

        if cmd && !shift && letter == "f" { openSearch(); return true }
        if cmd && !shift && letter == "o" { openLocation(); return true }
        if code == 122 || (chars == "?" && !cmd) { overlay = .shortcuts; return true }

        if cmd {
            switch (letter, code) {
            case ("c", _) where !shift: copy(cut: false)
            case ("x", _): copy(cut: true)
            case ("v", _): paste()
            case ("z", _): undo()
            case ("t", _): newTab()
            case ("w", _): closeTab(activeTab)
            case ("n", _) where shift: newFolder()
            case ("n", _): newFile()
            case ("c", _) where shift: copyPath()
            case ("r", _) where !shift: tab.reloadAll()
            case (_, 51) where shift: deletePermanently()
            case (_, 51): trash()
            case (_, 33): if shift { cycleTab(-1) } else { tab.back() }
            case (_, 30): if shift { cycleTab(1) } else { tab.forward() }
            case (_, 126): tab.goUp()
            case (_, 125): tab.openSelected()
            case (_, 47) where shift: tab.showHidden.toggle()
            case ("r", _) where shift: airdrop(tab.targets())
            case (_, 24): textScale = min(textScale + 0.1, 1.8)
            case (_, 27): textScale = max(textScale - 0.1, 0.7)
            default: return false
            }
            return true
        }

        // Vim prefixes: a count (5j, 12G) and the `g` chord (gg, gh, gt, gT).
        if !cmd, !ctrl, !opt {
            if !shift, chars.count == 1, let d = chars.first, d.isASCII, d.isNumber, d != "0" || pendingCount != nil {
                pendingCount = min((pendingCount ?? 0) * 10 + (d.wholeNumberValue ?? 0), 9999)
                showPending()
                return true
            }
            if pendingG {
                pendingG = false
                let n = pendingCount
                pendingCount = nil
                showPending()
                switch (letter, shift, code) {
                case ("g", false, _): if let n { tab.jump(toIndex: n - 1) } else { tab.jump(toLast: false) }
                case ("h", false, _): tab.go(FileManager.default.homeDirectoryForCurrentUser)
                case ("t", false, _): cycleTab(n ?? 1)
                case ("t", true, _): cycleTab(-(n ?? 1))
                case (_, false, 44): tab.go(URL(fileURLWithPath: "/"))
                default: break
                }
                return true
            }
            if letter == "g", !shift { pendingG = true; showPending(); return true }
        }
        let count = pendingCount ?? 1, counted = pendingCount != nil
        if counted { pendingCount = nil; showPending() }

        if ctrl && code == 48 { cycleTab(shift ? -1 : 1); return true }
        if ctrl, !cmd, !opt {
            switch letter {
            case "d": tab.move(max(1, pageRows / 2) * count)
            case "u": tab.move(-max(1, pageRows / 2) * count)
            case "f": tab.move(pageRows * count)
            case "b": tab.move(-pageRows * count)
            case "o": for _ in 0..<count { tab.back() }
            default: return false
            }
            return true
        }
        if ctrl || opt { return false }

        switch (letter, code) {
        case ("h", _), (_, 123): for _ in 0..<count { tab.navigate(.left) }
        case ("l", _), (_, 124): for _ in 0..<count { tab.navigate(.right) }
        case ("j", _), (_, 125): tab.move(count)
        case ("k", _), (_, 126): tab.move(-count)
        case (_, 36): beginRename()
        case (_, 51): tab.goUp()
        case (_, 27) where !shift: tab.goUp()
        case ("g", _): if counted { tab.jump(toIndex: count - 1) } else { tab.jump(toLast: true) }
        case (_, 48): tab.forward()
        case (_, 41) where shift: openLocation()
        case (_, 49) where shift: overlay = .preview
        case (_, 49): showPreview.toggle()
        case (_, 120), ("r", _): beginRename()
        case ("m", _) where shift: tab.markRange()
        case ("m", _): tab.toggleMark()
        case ("y", _): copy(cut: false)
        case ("p", _): paste()
        case ("t", _): openTerminal()
        case (_, 44) where !shift: tab.beginFilter()
        case (_, 47): tab.showHidden.toggle()
        case (_, 53):
            if tab.hasFilter { tab.clearFilter() } else { tab.marks = [] }
        default: return false
        }
        return true
    }

    /// Rows that fit in a column, for Ctrl-D/U/F/B.
    private var pageRows: Int {
        let height = NSApp.keyWindow?.contentView?.bounds.height ?? 700
        return max(4, Int((height - 190) / rowHeight))
    }

    private func showPending() {
        pendingKeys = (pendingCount.map(String.init) ?? "") + (pendingG ? "g" : "")
        pendingToken += 1
        guard !pendingKeys.isEmpty else { return }
        let token = pendingToken
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if token == pendingToken { pendingCount = nil; pendingG = false; pendingKeys = "" }
        }
    }

    func openSearch() {
        search.start(root: tab.currentDir, showHidden: tab.showHidden)
        overlay = .search
    }

    func openLocation() { showLocation(prefill: tab.currentDir.path) }
}
