import SwiftUI
import UniformTypeIdentifiers

/// Pinned folders and Places are editable and drag-reorderable; Devices and the fixed rows are not.
struct SidebarView: View {
    private let ws = Workspace.shared

    var body: some View {
        let theme = ws.theme
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Spacer().frame(height: 38)
                if !(ws.hidePinnedWhenEmpty && ws.pins.isEmpty) {
                header("Pinned").dropDestination(for: URL.self) { urls, _ in pinFolders(urls) }
                ForEach(ws.pins, id: \.self) { url in
                    row(SidebarPlace(name: pinName(url), symbol: url.isFileURL ? "pin" : "network", url: url),
                        section: "pins", action: { ws.openPin(url) })
                        .contextMenu {
                            Button("Move Up") { ws.movePin(url, by: -1) }
                            Button("Move Down") { ws.movePin(url, by: 1) }
                            Divider()
                            Button("Unpin") { ws.togglePin(url) }
                        }
                }
                if ws.pins.isEmpty {
                    Text("Drop folders here to pin")
                        .font(.system(size: 11)).foregroundStyle(theme.dim)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .dropDestination(for: URL.self) { urls, _ in pinFolders(urls) }
                }
                }

                placesHeader
                ForEach(ws.places) { p in
                    row(p, section: "places", action: { ws.openPin(p.url) })
                        .contextMenu {
                            Button("Rename") { ws.renamingPlace = p.url }
                            Button("Move Up") { ws.movePlace(p.url, by: -1) }
                            Button("Move Down") { ws.movePlace(p.url, by: 1) }
                            Divider()
                            Button("Remove from Places") { ws.removePlace(p.url) }
                        }
                }
                row(SidebarPlace(name: "AirDrop", symbol: "dot.radiowaves.left.and.right", url: URL(fileURLWithPath: "/")),
                    action: { ws.airdrop(ws.tab.targets()) }, drop: { ws.airdrop($0) }, showsActive: false)
                row(SidebarPlace(name: "Network", symbol: "network", url: URL(fileURLWithPath: "/Volumes")),
                    action: { ws.showLocation(prefill: "smb://") }, showsActive: false)

                if !ws.cloud.isEmpty {
                    header("Cloud")
                    ForEach(ws.cloud) { row($0) }
                }

                header("Devices")
                ForEach(ws.volumes) { v in
                    row(v).contextMenu {
                        if v.url.path != "/" { Button("Eject") { ws.eject(v) } }
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .background(theme.panel.opacity(0.6))
    }

    private var placesHeader: some View {
        HStack(spacing: 0) {
            header("Places")
            Button { ws.addPlace(ws.tab.currentDir) } label: {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).padding(5)
            }
            .buttonStyle(.plain).foregroundStyle(ws.theme.dim).hoverable(4)
            .help("Add the current folder to Places")
            .padding(.top, 10)
        }
        .contextMenu {
            Button("Add Current Folder") { ws.addPlace(ws.tab.currentDir) }
            Button("Reset Places to Defaults") { ws.resetPlaces() }
        }
    }

    private func pinFolders(_ urls: [URL]) -> Bool {
        let dirs = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        dirs.forEach(ws.pin)
        if dirs.isEmpty { ws.toast("Only folders can be pinned") }
        return !dirs.isEmpty
    }

    private func pinName(_ url: URL) -> String {
        if url.isFileURL { return url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent }
        let share = url.lastPathComponent
        return share.isEmpty ? (url.host ?? url.absoluteString) : "\(share) on \(url.host ?? "")"
    }

    private func header(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.system(size: 10, weight: .semibold)).tracking(0.6)
            .foregroundStyle(ws.theme.dim)
            .padding(.leading, 8).padding(.top, 14).padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    /// `section` ("pins" or "places") makes the row draggable for reordering.
    @ViewBuilder
    private func row(_ p: SidebarPlace, section: String? = nil, action: (() -> Void)? = nil,
                     drop: (([URL]) -> Void)? = nil, showsActive: Bool = true) -> some View {
        let active = showsActive && ws.tab.currentDir == p.url
        let content = HStack(spacing: 8) {
            Image(systemName: p.symbol).frame(width: 16).foregroundStyle(ws.iconTint)
            if section == "places", ws.renamingPlace == p.url {
                PlaceNameField(url: p.url, initial: p.name)
            } else {
                Text(p.name).lineLimit(1)
            }
            Spacer()
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(active ? ws.theme.sel : .clear, in: RoundedRectangle(cornerRadius: 6))
        .animation(.easeOut(duration: 0.15), value: active)
        .hoverable()
        .contentShape(Rectangle())
        .onTapGesture { if let action { action() } else { ws.tab.go(p.url) } }
        .onDrop(of: [.url, .plainText], delegate: SidebarDropDelegate(section: section, target: p.url) { urls in
            if let drop { drop(urls); return }
            guard p.url.isFileURL else { return }
            ws.transfer(urls, into: p.url, move: !NSEvent.modifierFlags.contains(.option))
        })
        if let section {
            content
                .opacity(ws.draggingRow?.url == p.url ? 0.35 : 1)
                .overlay(alignment: ws.dragComesFromAbove(p.url) ? .bottom : .top) {
                    if ws.dropTarget == p.url, ws.draggingRow?.url != p.url {
                        Capsule().fill(ws.theme.tint).frame(height: 2).padding(.horizontal, 4).offset(y: ws.dragComesFromAbove(p.url) ? 1 : -1)
                    }
                }
                .onDrag {
                    ws.draggingRow = (section, p.url)
                    // Plain words, so the pasteboard doesn't parse this as a URL and offer it to file drops.
                    return NSItemProvider(object: "Seam sidebar row" as NSString)
                } preview: {
                    Text(p.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(ws.theme.panel, in: Capsule())
                        .foregroundStyle(ws.theme.fg)
                }
        } else {
            content
        }
    }
}

struct PlaceNameField: View {
    let url: URL
    @StateObject private var box: Local<String>
    @FocusState private var focused: Bool
    private let ws = Workspace.shared

    init(url: URL, initial: String) {
        self.url = url
        _box = StateObject(wrappedValue: Local(initial))
    }

    var body: some View {
        TextField("", text: $box.value)
            .textFieldStyle(.plain)
            .focused($focused)
            .onSubmit { ws.renamePlace(url, to: box.value) }
            .onChange(of: focused) { _, on in if !on { ws.renamePlace(url, to: box.value) } }
            .onAppear {
                focused = true
                DispatchQueue.main.async { (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil) }
            }
    }
}

/// Collects URLs from item-provider callbacks that arrive on arbitrary threads.
private final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [URL] = []

    func add(_ url: URL?) {
        guard let url else { return }
        lock.lock(); items.append(url); lock.unlock()
    }

    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return items }
}

/// One drop target for both jobs: files dropped onto a row, and sidebar rows dragged to reorder.
struct SidebarDropDelegate: DropDelegate {
    let section: String?
    let target: URL
    let onFiles: ([URL]) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.url, .plainText]) }

    func dropEntered(info: DropInfo) {
        let ws = Workspace.shared
        if let section, ws.draggingRow?.section == section { ws.dropTarget = target }
    }

    func dropExited(info: DropInfo) {
        let ws = Workspace.shared
        if ws.dropTarget == target { ws.dropTarget = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        let ws = Workspace.shared
        if let section, ws.draggingRow?.section == section {
            ws.reorderDragging(onto: target, section: section)
            ws.draggingRow = nil
            ws.dropTarget = nil
            return true
        }
        let fileProviders = info.itemProviders(for: [.url])
        if !fileProviders.isEmpty {
            let box = URLBox()
            let group = DispatchGroup()
            for provider in fileProviders {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    box.add(url)
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                let urls = box.urls
                MainActor.assumeIsolated { onFiles(urls) }
            }
            return true
        }
        return false
    }
}
