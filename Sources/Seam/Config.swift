import AppKit
import Foundation

/// Where Seam keeps its configuration: `~/.config/seam/` (`SEAM_CONFIG_DIR` overrides it, for tests).
///
///     settings.yml    preferences, written whenever one changes
///     sidebar.yml     pinned folders and the Places list
///     themes/*.yml    one theme per file
enum ConfigPaths {
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["SEAM_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/seam", isDirectory: true)
    }

    static var settings: URL { directory.appendingPathComponent("settings.yml") }
    static var sidebar: URL { directory.appendingPathComponent("sidebar.yml") }
    static var themes: URL { directory.appendingPathComponent("themes", isDirectory: true) }

    @discardableResult
    static func write(_ text: String, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            NSLog("Seam: couldn't write \(url.path): \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - Settings

struct Settings {
    var theme = "Seam Dark"
    var opacity = 1.0
    var textScale = 1.0
    var airy = false
    var monoIcons = false
    var showHidden = true
    var foldersFirst = true
    var sortKey = SortKey.name
    var sortAscending = true
    var peekFolders = false
    var showPreview = true
    var previewWidth = 300.0
    var showSidebar = true
    var hidePinnedWhenEmpty = false

    init() {}

    /// Reads known keys and ignores everything else, so a hand-edited or older file still loads.
    init(yaml: YAML?) {
        guard let y = yaml else { return }
        if let v = y["theme"]?.string { theme = v }
        if let v = y["opacity"]?.double { opacity = min(max(v, 0.2), 1) }
        if let v = y["text_scale"]?.double { textScale = min(max(v, 0.7), 1.8) }
        if let v = y["airy"]?.bool { airy = v }
        if let v = y["theme_colored_icons"]?.bool { monoIcons = v }
        if let v = y["show_hidden"]?.bool { showHidden = v }
        if let v = y["folders_first"]?.bool { foldersFirst = v }
        if let v = y["sort_by"]?.string, let k = SortKey.allCases.first(where: { $0.configName == v.lowercased() }) { sortKey = k }
        if let v = y["sort_ascending"]?.bool { sortAscending = v }
        if let v = y["peek_folders"]?.bool { peekFolders = v }
        if let v = y["show_preview"]?.bool { showPreview = v }
        if let v = y["preview_width"]?.double { previewWidth = min(max(v, 220), 560) }
        if let v = y["show_sidebar"]?.bool { showSidebar = v }
        if let v = y["hide_pinned_when_empty"]?.bool { hidePinnedWhenEmpty = v }
    }

    var yaml: YAML {
        .map([
            ("theme", .string(theme)),
            ("opacity", .double((opacity * 100).rounded() / 100)),
            ("text_scale", .double((textScale * 100).rounded() / 100)),
            ("airy", .bool(airy)),
            ("theme_colored_icons", .bool(monoIcons)),
            ("show_hidden", .bool(showHidden)),
            ("folders_first", .bool(foldersFirst)),
            ("sort_by", .string(sortKey.configName)),
            ("sort_ascending", .bool(sortAscending)),
            ("peek_folders", .bool(peekFolders)),
            ("show_preview", .bool(showPreview)),
            ("preview_width", .int(Int(previewWidth))),
            ("show_sidebar", .bool(showSidebar)),
            ("hide_pinned_when_empty", .bool(hidePinnedWhenEmpty)),
        ])
    }

    static let header = """
    Seam settings. The settings dialog (⌘,) writes this file whenever something changes.
    Edit it by hand while Seam is closed; comments are not kept when Seam saves.

    sort_by: name | modified | size | kind
    opacity: 0.2 to 1.0 (below 1.0 the window is translucent)
    text_scale: 0.7 to 1.8
    """
}

extension SortKey {
    var configName: String {
        switch self {
        case .name: "name"
        case .modified: "modified"
        case .size: "size"
        case .kind: "kind"
        }
    }
}

/// Holds the live settings and writes `settings.yml` shortly after each change.
@MainActor
enum SettingsStore {
    static var current: Settings = load()
    private static var pending: DispatchWorkItem?

    static func update(_ change: (inout Settings) -> Void) {
        change(&current)
        pending?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { flush() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Writes immediately; also called when the app quits so a pending change isn't lost.
    static func flush() {
        guard pending != nil else { return }
        pending?.cancel()
        pending = nil
        ConfigPaths.write(current.yaml.render(header: Settings.header), to: ConfigPaths.settings)
    }

    private static func load() -> Settings {
        if let text = try? String(contentsOf: ConfigPaths.settings, encoding: .utf8) {
            if let yaml = YAML.parse(text) { return Settings(yaml: yaml) }
            // Unreadable by us: keep the file as it was and start from defaults rather than overwrite it silently.
            try? FileManager.default.copyItem(at: ConfigPaths.settings, to: ConfigPaths.settings.appendingPathExtension("bak"))
            NSLog("Seam: couldn't parse settings.yml; kept a copy as settings.yml.bak")
            return Settings()
        }
        let migrated = Legacy.settings()
        ConfigPaths.write(migrated.yaml.render(header: Settings.header), to: ConfigPaths.settings)
        return migrated
    }
}

// MARK: - Sidebar (pins and places)

@MainActor
enum SidebarStore {
    static func url(from text: String) -> URL {
        text.contains("://") ? (URL(string: text) ?? URL(fileURLWithPath: text)) : URL(fileURLWithPath: text)
    }

    static func text(for url: URL) -> String { url.isFileURL ? url.path : url.absoluteString }

    /// `places` is nil when the file has none, so the caller can fall back to its defaults.
    static func load() -> (pins: [URL], places: [SidebarPlace]?) {
        guard let text = try? String(contentsOf: ConfigPaths.sidebar, encoding: .utf8) else {
            let legacy = Legacy.sidebar()
            if !legacy.pins.isEmpty || legacy.places != nil { save(pins: legacy.pins, places: legacy.places) }
            return legacy
        }
        guard let yaml = YAML.parse(text) else { return ([], nil) }
        let pins = (yaml["pins"]?.items ?? []).compactMap { $0.string }.map(url(from:))
        let places = yaml["places"].map { list in
            list.items.compactMap { item -> SidebarPlace? in
                guard let name = item["name"]?.string, let path = item["path"]?.string else { return nil }
                return SidebarPlace(name: name, symbol: item["symbol"]?.string ?? "folder", url: url(from: path))
            }
        }
        return (pins, places)
    }

    static func save(pins: [URL], places: [SidebarPlace]?) {
        var pairs: [(key: String, value: YAML)] = [("pins", .list(pins.map { .string(text(for: $0)) }))]
        if let places {
            pairs.append(("places", .list(places.map {
                .map([("name", .string($0.name)), ("symbol", .string($0.symbol)), ("path", .string(text(for: $0.url)))])
            })))
        }
        ConfigPaths.write(YAML.map(pairs).render(header: "Seam sidebar: pinned folders and the Places list.\nWritten by Seam when you pin, reorder or rename; edit while Seam is closed."),
                          to: ConfigPaths.sidebar)
    }
}

// MARK: - One-time import of the old storage

/// Earlier versions kept preferences in the `dev.seam.macos` UserDefaults domain and themes as TOML under
/// `~/Library/Application Support/Seam/themes`. The first launch with no `~/.config/seam` copies them across.
/// The old data is only read, never changed or removed.
@MainActor
enum Legacy {
    private static var defaults: UserDefaults { .standard }

    static func settings() -> Settings {
        var s = Settings()
        let d = defaults
        if let v = d.string(forKey: "theme") { s.theme = v }
        if d.object(forKey: "opacity") != nil { s.opacity = min(max(d.double(forKey: "opacity"), 0.2), 1) }
        if d.double(forKey: "textScale") > 0 { s.textScale = min(max(d.double(forKey: "textScale"), 0.7), 1.8) }
        s.airy = d.bool(forKey: "airy")
        s.monoIcons = d.bool(forKey: "monoIcons")
        if d.object(forKey: "showHidden") != nil { s.showHidden = d.bool(forKey: "showHidden") }
        s.peekFolders = d.bool(forKey: "peekFolders")
        if d.object(forKey: "showPreview") != nil { s.showPreview = d.bool(forKey: "showPreview") }
        if d.double(forKey: "previewWidth") > 0 { s.previewWidth = min(max(d.double(forKey: "previewWidth"), 220), 560) }
        s.hidePinnedWhenEmpty = d.bool(forKey: "hidePinnedWhenEmpty")
        return s
    }

    static func sidebar() -> (pins: [URL], places: [SidebarPlace]?) {
        let pins = (defaults.stringArray(forKey: "pins") ?? []).map(SidebarStore.url(from:))
        var places: [SidebarPlace]?
        if let data = defaults.data(forKey: "places") { places = try? JSONDecoder().decode([SidebarPlace].self, from: data) }
        return (pins, places)
    }

    nonisolated static var themeDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Seam/themes", isDirectory: true)
    }

    /// The flat `key = value` TOML subset the old theme files used.
    nonisolated static func parseTOMLTheme(_ source: String) -> Theme? {
        var kv: [String: String] = [:]
        for raw in source.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("[") { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            kv[parts[0]] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        guard let name = kv["name"], let bg = kv["background"], let fg = kv["text"], let accent = kv["accent"] else { return nil }
        return Theme(name: name, isDark: kv["dark"] != "false", background: bg, surface: kv["surface"] ?? bg, text: fg,
                     subtext: kv["subtext"] ?? fg, accent: accent, selection: kv["selection"] ?? accent)
    }

    nonisolated static func themes() -> [Theme] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: themeDirectory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "toml" }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .compactMap(parseTOMLTheme)
    }
}
