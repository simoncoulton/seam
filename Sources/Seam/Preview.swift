import AVFoundation
import ImageIO
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

enum Thumbnails {
    static func image(for url: URL, size: CGSize) async -> NSImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let req = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .all)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) else { return nil }
        return rep.nsImage
    }
}

struct PreviewPane: View {
    let item: FileItem?
    var large = false
    private let ws = Workspace.shared

    var body: some View {
        Group {
            if let item {
                PreviewContent(item: item, large: large).id(item.url)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.viewfinder").font(.system(size: 30))
                    Text("Select a file to preview").font(.system(size: 12))
                }
                .foregroundStyle(ws.theme.dim)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ws.theme.panel.opacity(large ? 1 : 0.4))
    }
}

private struct PreviewContent: View {
    let item: FileItem
    let large: Bool
    private let ws = Workspace.shared
    @StateObject private var imageBox = Local<NSImage?>(nil)
    @StateObject private var textBox = Local<String?>(nil)
    @StateObject private var metaBox = Local<[(String, String)]>([])
    private var image: NSImage? { imageBox.value }
    private var text: String? { textBox.value }
    private var meta: [(String, String)] { metaBox.value }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Spacer().frame(height: 30)
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: large ? 340 : 280)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                } else if text == nil {
                    FileIcon(item: item, size: 96)
                        .frame(maxWidth: .infinity)
                }
                Text(item.name).font(.system(size: 14, weight: .semibold)).textSelection(.enabled)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(meta.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.0).foregroundStyle(ws.theme.dim).frame(width: 90, alignment: .leading)
                            Text(row.1).textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .font(.system(size: 12))
                if item.isCloudOnly {
                    Button { ws.download(item) } label: {
                        Label(ws.downloading.contains(item.url) ? "Downloading…" : "Download", systemImage: "icloud.and.arrow.down")
                    }
                    .disabled(ws.downloading.contains(item.url))
                }
                if let text {
                    Divider().opacity(0.3)
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
        .task(id: item.isCloudOnly) { await load() }
    }

    private func load() async {
        let url = item.url
        var rows: [(String, String)] = [("Kind", item.kind)]
        if item.isBrowsable {
            let count = (try? FileManager.default.contentsOfDirectory(atPath: url.path).count) ?? 0
            rows.append(("Contains", "\(count) item\(count == 1 ? "" : "s")"))
        } else {
            rows.append(("Size", Format.size(item.size)))
        }
        if let d = item.modified { rows.append(("Modified", Format.date.string(from: d))) }
        if item.isCloudOnly { rows.append(("Status", "Not downloaded")) }
        metaBox.value = rows
        // Reading a placeholder would download it, so previews never touch one.
        guard !item.isBrowsable, !item.isCloudOnly else { return }

        let type = UTType(filenameExtension: url.pathExtension)
        if let g = await Thumbnails.image(for: url, size: CGSize(width: 560, height: 560)) { imageBox.value = g }

        if type?.conforms(to: .image) == true || type?.identifier.contains("raw") == true {
            metaBox.value += Self.imageMeta(url)
        } else if type?.conforms(to: .audiovisualContent) == true {
            if let dur = try? await AVURLAsset(url: url).load(.duration), dur.seconds.isFinite {
                let s = Int(dur.seconds)
                metaBox.value.append(("Duration", String(format: "%d:%02d", s / 60, s % 60)))
            }
        } else if type?.conforms(to: .pdf) != true {
            // Text reader: capped at 1 MiB, so big files never stall the pane.
            let content = await Task.detached { () -> String? in
                guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
                defer { try? h.close() }
                guard let data = try? h.read(upToCount: 1 << 20), !data.contains(0) else { return nil }
                return String(data: data, encoding: .utf8).map { String($0.prefix(20_000)) }
            }.value
            if let content, !content.isEmpty { textBox.value = content; imageBox.value = nil }
        }
    }

    private static func imageMeta(_ url: URL) -> [(String, String)] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return [] }
        var rows: [(String, String)] = []
        if let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int {
            rows.append(("Dimensions", "\(w) × \(h)"))
        }
        if let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            let make = tiff[kCGImagePropertyTIFFMake] as? String ?? ""
            let model = tiff[kCGImagePropertyTIFFModel] as? String ?? ""
            if !(make + model).isEmpty { rows.append(("Camera", "\(make) \(model)".trimmingCharacters(in: .whitespaces))) }
        }
        if let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let lens = exif[kCGImagePropertyExifLensModel] as? String { rows.append(("Lens", lens)) }
            if let f = exif[kCGImagePropertyExifFNumber] as? Double { rows.append(("Aperture", "ƒ/\(f)")) }
            if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
                rows.append(("Shutter", t < 1 ? "1/\(Int((1 / t).rounded())) s" : "\(t) s"))
            }
            if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { rows.append(("ISO", "\(iso)")) }
        }
        return rows
    }
}
