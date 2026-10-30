import SwiftUI

struct Theme: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let isDark: Bool
    let background: String
    let surface: String
    let text: String
    let subtext: String
    let accent: String
    let selection: String

    var bg: Color { Color(hex: background) }
    var panel: Color { Color(hex: surface) }
    var fg: Color { Color(hex: text) }
    var dim: Color { Color(hex: subtext) }
    var tint: Color { Color(hex: accent) }
    var sel: Color { Color(hex: selection) }

    var yaml: YAML {
        .map([
            ("name", .string(name)), ("dark", .bool(isDark)),
            ("background", .string(background)), ("surface", .string(surface)),
            ("text", .string(text)), ("subtext", .string(subtext)),
            ("accent", .string(accent)), ("selection", .string(selection)),
        ])
    }

    /// Only `name`, `background`, `text` and `accent` are required; the rest fall back to sensible colors.
    init?(yaml: YAML) {
        guard let name = yaml["name"]?.string, let bg = yaml["background"]?.string,
              let fg = yaml["text"]?.string, let accent = yaml["accent"]?.string else { return nil }
        self.init(
            name: name,
            isDark: yaml["dark"]?.bool ?? true,
            background: bg,
            surface: yaml["surface"]?.string ?? bg,
            text: fg,
            subtext: yaml["subtext"]?.string ?? fg,
            accent: accent,
            selection: yaml["selection"]?.string ?? accent
        )
    }

    init(name: String, isDark: Bool, background: String, surface: String, text: String, subtext: String, accent: String, selection: String) {
        self.name = name
        self.isDark = isDark
        self.background = background
        self.surface = surface
        self.text = text
        self.subtext = subtext
        self.accent = accent
        self.selection = selection
    }

    static let fileHeader = "Seam theme. Colors are hex (#rrggbb). Seam reads every .yml file in this folder;\nreopen Settings or relaunch after editing."
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}

enum Themes {
    static let presets: [Theme] = [
        Theme(name: "Seam Dark", isDark: true, background: "#16181d", surface: "#1d2027", text: "#e6e8ee", subtext: "#8b91a1", accent: "#5b9cf5", selection: "#2c4a7a"),
        Theme(name: "Seam Light", isDark: false, background: "#f6f7f9", surface: "#ebedf1", text: "#1d2128", subtext: "#6b7280", accent: "#2f6fe0", selection: "#cfe0fb"),
        Theme(name: "Nord", isDark: true, background: "#2e3440", surface: "#3b4252", text: "#eceff4", subtext: "#a3acbd", accent: "#88c0d0", selection: "#434c5e"),
        Theme(name: "Dracula", isDark: true, background: "#282a36", surface: "#303342", text: "#f8f8f2", subtext: "#8c93b8", accent: "#bd93f9", selection: "#44475a"),
        Theme(name: "Gruvbox Dark", isDark: true, background: "#282828", surface: "#32302f", text: "#ebdbb2", subtext: "#a89984", accent: "#fabd2f", selection: "#504945"),
        Theme(name: "Gruvbox Light", isDark: false, background: "#fbf1c7", surface: "#f2e5bc", text: "#3c3836", subtext: "#7c6f64", accent: "#b57614", selection: "#ebdbb2"),
        Theme(name: "Solarized Dark", isDark: true, background: "#002b36", surface: "#073642", text: "#eee8d5", subtext: "#839496", accent: "#268bd2", selection: "#0d4452"),
        Theme(name: "Solarized Light", isDark: false, background: "#fdf6e3", surface: "#eee8d5", text: "#586e75", subtext: "#93a1a1", accent: "#268bd2", selection: "#e3dcc2"),
        Theme(name: "Tokyo Night", isDark: true, background: "#1a1b26", surface: "#1f2335", text: "#c0caf5", subtext: "#7982a9", accent: "#7aa2f7", selection: "#2e3c64"),
        Theme(name: "Catppuccin Mocha", isDark: true, background: "#1e1e2e", surface: "#262637", text: "#cdd6f4", subtext: "#9399b2", accent: "#cba6f7", selection: "#403c5a"),
        Theme(name: "Catppuccin Frappé", isDark: true, background: "#303446", surface: "#292c3c", text: "#c6d0f5", subtext: "#a5adce", accent: "#ca9ee6", selection: "#51576d"),
        Theme(name: "Catppuccin Latte", isDark: false, background: "#eff1f5", surface: "#e6e9ef", text: "#4c4f69", subtext: "#7c7f93", accent: "#8839ef", selection: "#d9d3f3"),
        Theme(name: "Rosé Pine", isDark: true, background: "#191724", surface: "#1f1d2e", text: "#e0def4", subtext: "#908caa", accent: "#ebbcba", selection: "#403d52"),
        Theme(name: "One Dark", isDark: true, background: "#282c34", surface: "#2c313a", text: "#abb2bf", subtext: "#7f848e", accent: "#61afef", selection: "#3e4451"),
        Theme(name: "Everforest", isDark: true, background: "#2d353b", surface: "#343f44", text: "#d3c6aa", subtext: "#859289", accent: "#a7c080", selection: "#475258"),
        Theme(name: "Kanagawa", isDark: true, background: "#1f1f28", surface: "#2a2a37", text: "#dcd7ba", subtext: "#727169", accent: "#7e9cd8", selection: "#363646"),
        Theme(name: "Monokai", isDark: true, background: "#272822", surface: "#2f302a", text: "#f8f8f2", subtext: "#908f85", accent: "#a6e22e", selection: "#49483e"),
    ]

    static var directory: URL { ConfigPaths.themes }

    static func fileName(for theme: Theme) -> String {
        theme.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".yml"
    }

    /// Writes the built-in themes (and any old TOML ones) into the themes folder the first time it is needed, so
    /// there is a file to copy and edit for every theme.
    static func seedIfNeeded() {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        for t in presets + Legacy.themes() { _ = try? save(t) }
    }

    /// Themes from the folder, with the built-ins filling in any that have no file (so the list is never empty).
    static func all() -> [Theme] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let custom = urls.filter { ["yml", "yaml"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .compactMap { YAML.parse($0) }
            .compactMap(Theme.init(yaml:))
        let byName = Dictionary(custom.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let builtIn = presets.map { byName[$0.name] ?? $0 }
        let extra = custom.filter { c in !presets.contains { $0.name == c.name } }
        return builtIn + extra
    }

    @discardableResult
    static func save(_ theme: Theme) throws -> URL {
        let url = directory.appendingPathComponent(fileName(for: theme))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try theme.yaml.render(header: Theme.fileHeader).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
