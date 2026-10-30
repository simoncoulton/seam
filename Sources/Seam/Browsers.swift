import SwiftUI

// MARK: - Miller columns

/// Holds the pending "scroll once the layout settles" work. Never publishes, so it can't trigger redraws.
final class ScrollSettle: ObservableObject {
    var work: DispatchWorkItem?
}

struct MillerView: View {
    let tab: BrowserState
    private let ws = Workspace.shared
    private let columnWidth: CGFloat = 250
    @StateObject private var settle = ScrollSettle()

    var body: some View {
        GeometryReader { geo in
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(tab.columns.enumerated()), id: \.element.id) { i, col in
                        HStack(spacing: 0) {
                            ColumnView(tab: tab, index: i, column: col)
                                .frame(width: columnWidth)
                            Rectangle().fill(ws.theme.dim.opacity(0.12)).frame(width: 1)
                        }
                        .id(col.id)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 28)), removal: .opacity))
                    }
                    if let peek = tab.peek {
                        PeekColumn(url: peek).frame(width: columnWidth).id("peek").opacity(0.55)
                            .transition(.opacity)
                    }
                    Color.clear.frame(width: 1).id("end")
                }
                .animation(.smooth(duration: 0.22), value: tab.columns.map(\.id))
                .animation(.smooth(duration: 0.18), value: tab.peek)
            }
            .onChange(of: tab.columns.count) { scrollToEnd(proxy) }
            .onChange(of: tab.focus) { scrollToEnd(proxy) }
            .onChange(of: geo.size.width) {
                // Track the edge while the width changes (dragging the preview divider)...
                scrollToEnd(proxy, animated: false)
                // ...and once more when it stops: the preview opens with an animation, so the first
                // scroll is computed against an in-between width and leaves the last column cut off.
                settle.work?.cancel()
                let work = DispatchWorkItem { scrollToEnd(proxy) }
                settle.work = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
            }
            .onAppear { scrollToEnd(proxy, animated: false) }
        }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let target = tab.columns.indices.contains(tab.focus + 1) ? tab.columns[tab.focus + 1].id : tab.columns.last?.id
        DispatchQueue.main.async {
            guard let target else { return }
            if animated { withAnimation(.smooth(duration: 0.25)) { proxy.scrollTo(target, anchor: .trailing) } }
            else { proxy.scrollTo(target, anchor: .trailing) }
        }
    }
}

struct ColumnView: View {
    let tab: BrowserState
    let index: Int
    let column: Column
    private let ws = Workspace.shared

    var body: some View {
        let focused = tab.focus == index
        let showsFilter = tab.filterBars.contains(column.id) || !column.filter.isEmpty
        VStack(spacing: 0) {
            ColumnHeader(name: column.dir.folderTitle, count: column.loading ? nil : column.shown.count, focused: focused)
            if showsFilter {
                ColumnFilter(tab: tab, index: index, column: column)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(column.shown) { item in
                            FileRow(tab: tab, item: item, columnIndex: index, selected: column.selected == item.url, columnFocused: focused)
                                .id(item.url)
                        }
                        if column.shown.isEmpty && !column.loading {
                            Text(column.filter.isEmpty ? "Empty" : "No matches")
                                .font(.system(size: 12)).foregroundStyle(ws.theme.dim).padding(.top, 20)
                        }
                    }
                    .padding(.vertical, 4).padding(.horizontal, 4)
                }
                .onChange(of: column.selected) { _, new in
                    guard let new, focused else { return }
                    proxy.scrollTo(new)
                }
                .onAppear { if let s = column.selected { proxy.scrollTo(s, anchor: .center) } }
            }
        }
        .animation(.smooth(duration: 0.18), value: showsFilter)
        .background(focused ? Color.clear : ws.theme.panel.opacity(0.35))
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            ws.transfer(urls, into: column.dir, move: !NSEvent.modifierFlags.contains(.option))
            return true
        }
        .contextMenu { ContextMenuItems(item: nil) }
    }
}

/// Folder name (and item count) shown above each column.
struct ColumnHeader: View {
    let name: String
    let count: Int?
    let focused: Bool
    private let ws = Workspace.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(name).font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if let count { Text("\(count)").font(.system(size: 10).monospacedDigit()).opacity(0.7) }
            }
            .foregroundStyle(focused ? ws.theme.fg : ws.theme.dim)
            .padding(.horizontal, 12).frame(height: 26)
            Rectangle().fill(ws.theme.dim.opacity(0.12)).frame(height: 1)
        }
    }
}

extension URL {
    /// Last path component, or the volume name for the root.
    var folderTitle: String { path == "/" ? "Macintosh HD" : lastPathComponent }
}

struct ColumnFilter: View {
    let tab: BrowserState
    let index: Int
    let column: Column
    private let ws = Workspace.shared
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10))
                TextField("Filter", text: Binding(
                    get: { column.filter },
                    set: { tab.setFilter($0, inColumn: index) }
                ))
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { tab.endFilter() }
                if !column.filter.isEmpty {
                    Button { tab.setFilter("", inColumn: index) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(ws.theme.dim)
            .padding(.horizontal, 8).frame(height: 26)
            .background(ws.theme.panel.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            SortBar(tab: tab, index: index, dir: column.dir)
        }
        .padding(.horizontal, 6).padding(.top, 6)
        .onAppear { if tab.filtering == column.id { DispatchQueue.main.async { focused = true } } }
        .onChange(of: tab.filtering) { _, id in focused = id == column.id }
        .onChange(of: focused) { _, on in
            if on { tab.filtering = column.id } else if tab.filtering == column.id { tab.filtering = nil }
        }
    }
}

/// Sort type as a row of small tabs (same treatment as the window tabs), direction as its own button on the right.
struct SortBar: View {
    let tab: BrowserState
    let index: Int
    let dir: URL
    private let ws = Workspace.shared

    var body: some View {
        let s = tab.sort(for: dir)
        let theme = ws.theme
        HStack(spacing: 2) {
            ForEach(SortKey.allCases, id: \.self) { (key: SortKey) in
                let active = key == s.key
                Text(key.short)
                    .font(.system(size: 10, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? theme.fg : theme.dim)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(active ? theme.panel : .clear, in: RoundedRectangle(cornerRadius: 5))
                    .hoverable(5)
                    .animation(.easeOut(duration: 0.15), value: active)
                    .contentShape(Rectangle())
                    .onTapGesture { tab.setSort(key: key, inColumn: index) }
            }
            Spacer(minLength: 0)
            Button { tab.setSort(ascending: !s.ascending, inColumn: index) } label: {
                Image(systemName: s.ascending ? "arrow.up" : "arrow.down")
                    .font(.system(size: 9, weight: .semibold)).padding(5)
            }
            .buttonStyle(.plain).foregroundStyle(theme.dim).hoverable(5)
            .help(s.ascending ? "Ascending: click for descending" : "Descending: click for ascending")
        }
    }
}

struct PeekColumn: View {
    let url: URL
    @StateObject private var box = Local<[FileItem]>([])
    private let ws = Workspace.shared

    var body: some View {
        VStack(spacing: 0) {
        ColumnHeader(name: url.folderTitle, count: box.value.count, focused: false)
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(box.value.prefix(300)) { item in
                    HStack(spacing: 8) {
                        FileIcon(item: item, size: 16)
                        Text(item.name).lineLimit(1)
                        Spacer()
                    }
                    .font(.system(size: ws.fontSize))
                    .frame(height: ws.rowHeight).padding(.horizontal, 8)
                }
            }
            .padding(4)
        }
        .task(id: url) {
            let dir = url
            let loaded = await Task.detached { DirectoryLoader.load(dir) }.value
            box.value = loaded
                .filter { ws.tab.showHidden || !$0.isHidden }
                .sorted { ($0.isBrowsable ? 0 : 1, $0.name.lowercased()) < ($1.isBrowsable ? 0 : 1, $1.name.lowercased()) }
        }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Row

/// Cloud-only files get a download arrow; click it to fetch the file, and it turns into a spinner meanwhile.
struct CloudBadge: View {
    let item: FileItem
    private let ws = Workspace.shared

    var body: some View {
        if ws.downloading.contains(item.url) {
            ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 18, height: 18)
        } else {
            Button { ws.download(item) } label: {
                Image(systemName: "icloud.and.arrow.down").font(.system(size: 12))
                    .foregroundStyle(ws.theme.tint).padding(3)
            }
            .buttonStyle(.plain).hoverable(5)
            .help("Not downloaded. Click to download.")
        }
    }
}

struct FileRow: View {
    let tab: BrowserState
    let item: FileItem
    let columnIndex: Int
    let selected: Bool
    let columnFocused: Bool
    private let ws = Workspace.shared
    @StateObject private var hover = Local(false)

    var body: some View {
        let theme = ws.theme
        let marked = tab.marks.contains(item.url)
        HStack(spacing: 8) {
            FileIcon(item: item, size: ws.fontSize + 3)
            if tab.renaming == item.url {
                RenameField(initial: item.name, selectsStem: !item.isDirectory || item.isPackage)
            } else {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(item.isHidden ? theme.dim : theme.fg)
            }
            Spacer(minLength: 4)
            if marked { Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.tint) }
            if item.isCloudOnly { CloudBadge(item: item) }
            if item.isBrowsable {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.dim.opacity(0.7))
            }
        }
        .font(.system(size: ws.fontSize))
        .padding(.horizontal, 8)
        .frame(height: ws.rowHeight)
        .background(rowFill(theme), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(theme.tint, lineWidth: 1.5)
                .opacity(selected && columnFocused ? 1 : 0)
        }
        .animation(.easeOut(duration: 0.12), value: hover.value)
        .animation(.easeOut(duration: 0.12), value: selected)
        .contentShape(Rectangle())
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                tab.toggleMark(item.url)
            } else {
                tab.select(item.url, inColumn: columnIndex)
            }
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            guard !NSEvent.modifierFlags.contains(.command) else { return }
            tab.select(item.url, inColumn: columnIndex); tab.openSelected() })
        .onHover { hover.value = $0; tab.hover(item, inColumn: columnIndex, entered: $0) }
        .draggable(item.url)
        .dropDestination(for: URL.self) { urls, _ in
            guard item.isBrowsable else { return false }
            ws.transfer(urls, into: item.url, move: !NSEvent.modifierFlags.contains(.option))
            return true
        }
        .contextMenu { ContextMenuItems(item: item) }
    }

    private func rowFill(_ theme: Theme) -> Color {
        if selected { return theme.sel }
        if tab.marks.contains(item.url) { return theme.sel.opacity(0.5) }
        return hover.value ? theme.dim.opacity(0.12) : .clear
    }
}

/// Sets the starting selection of a just-focused text field. AppKit selects everything when the field editor
/// takes over, and when that happens varies, so retry a few times, and stop once the text has been edited.
private struct InitialSelection: NSViewRepresentable {
    let text: String
    let length: Int

    func makeNSView(context: Context) -> NSView { Anchor(text: text, length: length) }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Anchor: NSView {
        let text: String
        let length: Int
        init(text: String, length: Int) {
            self.text = text
            self.length = length
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            guard window != nil else { return }
            for delay in [0, 0.03, 0.08, 0.2] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.apply() } }
        }

        private func apply() {
            guard let tv = window?.firstResponder as? NSTextView, tv.string == text else { return }
            let range = NSRange(location: 0, length: length)
            if tv.selectedRange() != range { tv.setSelectedRange(range) }
        }
    }
}

struct RenameField: View {
    @StateObject private var box: Local<String>
    @FocusState private var focused: Bool
    private let ws = Workspace.shared

    /// Length (UTF-16) of the part of the name that starts selected: everything but the extension.
    private let selectionLength: Int
    private let initial: String

    init(initial: String, selectsStem: Bool) {
        self.initial = initial
        _box = StateObject(wrappedValue: Local(initial))
        let name = initial as NSString
        let ext = name.pathExtension as NSString
        selectionLength = selectsStem && ext.length > 0 ? name.length - ext.length - 1 : name.length
    }

    var body: some View {
        TextField("", text: $box.value)
            .textFieldStyle(.plain)
            .focused($focused)
            .padding(.horizontal, 4)
            .background(ws.theme.bg, in: RoundedRectangle(cornerRadius: 4))
            .onSubmit { ws.commitRename(box.value) }
            .background(InitialSelection(text: initial, length: selectionLength))
            .onAppear { focused = true }
            .onChange(of: focused) { _, f in if !f, ws.tab.renaming != nil { ws.commitRename(box.value) } }
            .onDisappear {
                // A reload can rebuild the row under the field; don't leave rename mode (which swallows keys) stuck.
                if ws.tab.renaming != nil { ws.cancelRename() }
            }
    }
}

struct ContextMenuItems: View {
    let item: FileItem?
    private let ws = Workspace.shared

    /// Shortcuts are shown beside the entries. The key monitor handles the keys before the menu does.
    var body: some View {
        if let item {
            Button("Open") { ws.tab.openSelected() }.keyboardShortcut(.downArrow)
            if item.isCloudOnly { Button("Download Now") { ws.download(item) } }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Divider()
            Button("Rename") { ws.beginRename() }.keyboardShortcut(.return, modifiers: [])
            Button("Copy") { ws.copy(cut: false) }.keyboardShortcut("c")
            Button("Cut") { ws.copy(cut: true) }.keyboardShortcut("x")
            Button("Paste") { ws.paste() }.keyboardShortcut("v")
            Divider()
            Button("New File") { ws.newFile() }.keyboardShortcut("n")
            Button("New Folder") { ws.newFolder() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Compress") { ws.compress() }
            if ["zip", "tar", "gz", "tgz", "bz2", "xz"].contains(item.url.pathExtension.lowercased()) {
                Button("Extract") { ws.extract() }
            }
            if item.isBrowsable {
                Button(ws.pins.contains(item.url) ? "Unpin" : "Pin to Sidebar") { ws.togglePin(item.url) }
                Button("Add to Places") { ws.addPlace(item.url) }
            }
            Button("Copy Path") { ws.copyPath() }.keyboardShortcut("c", modifiers: [.command, .shift])
            Divider()
            Button("Move to Trash") { ws.trash() }.keyboardShortcut(.delete)
            Button("Delete Permanently…") { ws.deletePermanently() }.keyboardShortcut(.delete, modifiers: [.command, .shift])
        } else {
            Button("New File") { ws.newFile() }.keyboardShortcut("n")
            Button("New Folder") { ws.newFolder() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Paste") { ws.paste() }.keyboardShortcut("v")
            Button("Open Terminal Here") { ws.openTerminal() }
        }
    }
}
