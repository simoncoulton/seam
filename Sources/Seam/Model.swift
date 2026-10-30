import AppKit
import Combine
import UniformTypeIdentifiers

struct FileItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isHidden: Bool
    let size: Int64
    let modified: Date?
    let kind: String
    /// A cloud placeholder (Dropbox, OneDrive, iCloud): listed here, but the contents aren't on this Mac yet.
    var isCloudOnly = false

    var id: URL { url }
    /// Folders that open a new Miller column (bundles like .app open as files).
    var isBrowsable: Bool { isDirectory && !isPackage }
}

enum DirectoryLoader {
    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey,
        .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey,
    ]

    static func load(_ dir: URL) -> [FileItem] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: []
        ) else { return [] }
        return urls.map(item(for:))
    }

    static func item(for url: URL) -> FileItem {
        let v = try? url.resourceValues(forKeys: Set(keys))
        var isDir = v?.isDirectory ?? false
        if v?.isSymbolicLink == true {
            let target = url.resolvingSymlinksInPath()
            isDir = (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        }
        // The "dataless" file flag marks File Provider placeholders. lstat doesn't download anything.
        var st = stat()
        let cloudOnly = !isDir && lstat(url.path, &st) == 0 && (st.st_flags & 0x4000_0000) != 0 // SF_DATALESS
        return FileItem(
            url: url,
            name: url.lastPathComponent,
            isDirectory: isDir,
            isPackage: v?.isPackage ?? false,
            isHidden: (v?.isHidden ?? false) || url.lastPathComponent.hasPrefix("."),
            size: Int64(v?.fileSize ?? 0),
            modified: v?.contentModificationDate,
            kind: v?.localizedTypeDescription ?? (isDir ? "Folder" : "Document"),
            isCloudOnly: cloudOnly
        )
    }
}

/// Stand-in for `@State`, which needs the SwiftUIMacros plugin that only full Xcode ships.
final class Local<T>: ObservableObject {
    @Published var value: T
    init(_ value: T) { self.value = value }
}

enum SortKey: String, CaseIterable, Identifiable {
    case name = "Name", modified = "Date Modified", size = "Size", kind = "Kind"
    var id: String { rawValue }
    var short: String {
        switch self {
        case .name: "Name"
        case .modified: "Date"
        case .size: "Size"
        case .kind: "Kind"
        }
    }
}

enum Icons {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for item: FileItem) -> NSImage {
        let ext = item.url.pathExtension.lowercased()
        let key: String
        if item.isBrowsable { key = "dir" }
        else if item.isPackage || ext.isEmpty { key = item.url.path }
        else { key = "." + ext }
        if let hit = cache.object(forKey: key as NSString) { return hit }
        let image: NSImage
        if key == "dir" { image = NSWorkspace.shared.icon(for: .folder) }
        else if key.hasPrefix(".") { image = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data) }
        else { image = NSWorkspace.shared.icon(forFile: item.url.path) }
        cache.setObject(image, forKey: key as NSString)
        return image
    }
}

enum Format {
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

extension URL {
    /// `name copy.ext`, `name copy 2.ext`, ... until nothing exists at the destination.
    func uniqueSibling(suffix: String = " copy") -> URL {
        let dir = deletingLastPathComponent()
        let ext = pathExtension
        let stem = deletingPathExtension().lastPathComponent
        var n = 0
        while true {
            let label = n == 0 ? suffix : "\(suffix) \(n + 1)"
            let name = ext.isEmpty ? "\(stem)\(label)" : "\(stem)\(label).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}

extension URL {
    /// Canonical path as `realpath` reports it. Foundation's own resolving/standardizing methods strip
    /// `/private`, which is the opposite of what directory listings return.
    var realURL: URL {
        guard let resolved = realpath(path, nil) else { return self }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }
}
