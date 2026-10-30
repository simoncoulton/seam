import SwiftUI

struct RootView: View {
    private let ws = Workspace.shared

    var body: some View {
        let theme = ws.theme
        let tab = ws.tab
        ZStack {
            HStack(spacing: 0) {
                if ws.showSidebar {
                    SidebarView()
                        .frame(width: 210)
                    Rectangle().fill(theme.dim.opacity(0.15)).frame(width: 1)
                }
                VStack(spacing: 0) {
                    TabBar()
                    PathBar(tab: tab)
                    Group {
                        MillerView(tab: tab)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    StatusBar(tab: tab)
                }
                if ws.showPreview {
                    PreviewResizeHandle()
                    PreviewPane(item: tab.currentItem)
                        .frame(width: ws.previewWidth)
                }
            }
            OverlayHost()
            if let toast = ws.toastText {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 12))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(theme.panel, in: Capsule())
                        .overlay(Capsule().stroke(theme.dim.opacity(0.25)))
                        .padding(.bottom, 40)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .foregroundStyle(theme.fg)
        .background { WindowBackdrop() }
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .animation(.easeOut(duration: 0.15), value: ws.toastText)
        .animation(.easeOut(duration: 0.12), value: ws.showPreview)
        .ignoresSafeArea()
    }
}

// MARK: - Tabs

struct TabBar: View {
    private let ws = Workspace.shared

    var body: some View {
        let theme = ws.theme
        HStack(spacing: 4) {
            if !ws.showSidebar { Spacer().frame(width: 70) }
            ForEach(Array(ws.tabs.enumerated()), id: \.element.id) { i, t in
                TabItem(tab: t, index: i)
            }
            Button { ws.newTab() } label: { Image(systemName: "plus").font(.system(size: 11, weight: .medium)).padding(6) }
                .buttonStyle(.plain).foregroundStyle(theme.dim).hoverable()
            Spacer()
            Button { ws.showPreview.toggle() } label: {
                Image(systemName: "sidebar.right").padding(6).foregroundStyle(ws.showPreview ? theme.tint : theme.dim)
            }
            .buttonStyle(.plain).hoverable()
            OptionsMenu().padding(4).hoverable()
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }
}

struct TabItem: View {
    let tab: BrowserState
    let index: Int
    private let ws = Workspace.shared

    var body: some View {
        let theme = ws.theme
        let active = index == ws.activeTab
        HStack(spacing: 6) {
            Image(systemName: "folder.fill").font(.system(size: 11)).foregroundStyle(ws.iconTint)
            Text(tab.title).lineLimit(1).font(.system(size: 12, weight: active ? .semibold : .regular))
            Spacer(minLength: 4)
            if ws.tabs.count > 1 {
                Button { ws.closeTab(index) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).padding(4)
                }
                .buttonStyle(.plain).foregroundStyle(theme.dim).hoverable(4)
            }
        }
        .padding(.leading, 10).padding(.trailing, 5).padding(.vertical, 7)
        .frame(minWidth: 120, maxWidth: 200)
        .background(active ? theme.panel : .clear, in: RoundedRectangle(cornerRadius: 7))
        .hoverable(7)
        .animation(.easeOut(duration: 0.15), value: active)
        .contentShape(Rectangle())
        .onTapGesture { ws.activeTab = index }
    }
}

struct OptionsMenu: View {
    private let ws = Workspace.shared

    var body: some View {
        Menu {
            Picker("Sort by", selection: Binding(get: { ws.tab.sortKey }, set: { ws.tab.setDefaultSort(key: $0) })) {
                ForEach(SortKey.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Ascending", isOn: Binding(get: { ws.tab.ascending }, set: { ws.tab.setDefaultSort(ascending: $0) }))
            Toggle("Group folders first", isOn: Binding(get: { ws.tab.foldersFirst }, set: { ws.tab.foldersFirst = $0; ws.tab.refreshAll() }))
            Toggle("Show hidden files", isOn: Binding(get: { ws.tab.showHidden }, set: { ws.tab.showHidden = $0 }))
            Divider()
            Toggle("Theme-colored icons", isOn: Binding(get: { ws.monoIcons }, set: { ws.monoIcons = $0 }))
            Toggle("Airy density", isOn: Binding(get: { ws.airy }, set: { ws.airy = $0 }))
            Toggle("Peek into folders", isOn: Binding(get: { ws.peekFolders }, set: { ws.peekFolders = $0 }))
            Toggle("Sidebar", isOn: Binding(get: { ws.showSidebar }, set: { ws.showSidebar = $0 }))
            Toggle("Hide Pinned when empty", isOn: Binding(get: { ws.hidePinnedWhenEmpty }, set: { ws.hidePinnedWhenEmpty = $0 }))
            Divider()
            Menu("Window opacity") {
                ForEach([1.0, 0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2], id: \.self) { v in
                    Button((abs(v - ws.opacity) < 0.01 ? "✓ " : "") + (v == 1 ? "Opaque" : "\(Int(v * 100))%")) { ws.opacity = v }
                }
            }
            Menu("Theme") {
                ForEach(ws.themes) { t in
                    Button(t.name + (t == ws.theme ? " ✓" : "")) { ws.setTheme(t) }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .foregroundStyle(ws.theme.dim)
    }
}

// MARK: - Path bar and status

struct PathBar: View {
    let tab: BrowserState
    private let ws = Workspace.shared

    var body: some View {
        let pinned = ws.isPinned(tab.currentDir)
        HStack(spacing: 4) {
            Button { tab.back() } label: { Image(systemName: "chevron.left").padding(5) }
                .buttonStyle(.plain).disabled(!tab.canGoBack).hoverable()
            Button { tab.forward() } label: { Image(systemName: "chevron.right").padding(5) }
                .buttonStyle(.plain).disabled(!tab.canGoForward).hoverable()
            Crumbs(tab: tab).frame(maxWidth: .infinity, alignment: .leading)
            Button { ws.togglePin(tab.currentDir) } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .foregroundStyle(pinned ? ws.theme.tint : ws.theme.dim).padding(5)
            }
            .buttonStyle(.plain).hoverable().help(pinned ? "Unpin this folder" : "Pin this folder")
        }
        .font(.system(size: 12))
        .foregroundStyle(ws.theme.dim)
        .padding(.horizontal, 8).frame(height: 30)
    }
}

struct Crumbs: View {
    let tab: BrowserState
    private let ws = Workspace.shared

    var body: some View {
        let comps = tab.currentDir.pathComponents
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(comps.enumerated()), id: \.offset) { i, c in
                        if i > 0 { Image(systemName: "chevron.right").font(.system(size: 8)).opacity(0.5) }
                        Text(c == "/" ? "Macintosh HD" : c)
                            .foregroundStyle(i == comps.count - 1 ? ws.theme.fg : ws.theme.dim)
                            .padding(.horizontal, 4).padding(.vertical, 2)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                let url = comps[0...i].dropFirst().reduce(URL(fileURLWithPath: "/")) { $0.appendingPathComponent($1) }
                                tab.go(url)
                            }
                            .id(i)
                    }
                }
            }
            .onChange(of: comps.count) { proxy.scrollTo(comps.count - 1, anchor: .trailing) }
        }
    }
}

struct StatusBar: View {
    let tab: BrowserState
    private let ws = Workspace.shared
    @StateObject private var size = Local<DiskUsage?>(nil)

    /// What the footer measures: the marked items, otherwise the selected one.
    private var targets: [URL] {
        if !tab.marks.isEmpty { return tab.marks.sorted { $0.path < $1.path } }
        return tab.currentItem.map { [$0.url] } ?? []
    }

    /// A plain file's size comes from the listing; anything else is walked.
    private var isPlainFile: Bool { tab.marks.isEmpty && tab.currentItem.map { !$0.isDirectory } == true }

    var body: some View {
        let count = tab.shown.count
        let targets = self.targets
        HStack {
            Text("\(count) item\(count == 1 ? "" : "s")")
            if !tab.marks.isEmpty { Text("· \(tab.marks.count) marked").foregroundStyle(ws.theme.tint) }
            Spacer()
            if !ws.pendingKeys.isEmpty {
                Text(ws.pendingKeys).font(.system(size: 11, design: .monospaced)).foregroundStyle(ws.theme.tint)
            }
            if let usage = size.value {
                Text(label(usage))
                    .monospacedDigit()
                    .foregroundStyle(usage.finished ? ws.theme.fg : ws.theme.dim)
                    .help(usage.allocated > 0 ? "On disk: \(Format.size(Int64(usage.allocated)))" : "")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(ws.theme.dim)
        .padding(.horizontal, 12).frame(height: 24)
        // One task per selection: moving on cancels the walk that was running.
        .task(id: targets) { await measure(targets) }
    }

    private func label(_ u: DiskUsage) -> String {
        let bytes = Format.size(Int64(u.logical))
        if isPlainFile { return bytes }
        let files = "\(u.files.formatted()) file\(u.files == 1 ? "" : "s")"
        return u.finished ? "\(bytes) · \(files)" : "Calculating… \(bytes) · \(files)"
    }

    @MainActor
    private func measure(_ targets: [URL]) async {
        size.value = nil
        guard !targets.isEmpty else { return }
        if isPlainFile, let item = tab.currentItem {
            size.value = DiskUsage(logical: UInt64(max(item.size, 0)), allocated: 0, files: 1, finished: true)
            return
        }
        // Hold off while the selection is still moving, so holding j or k stays instant.
        if targets.count > 1 || SizeCache.shared.get(targets[0].path) == nil {
            try? await Task.sleep(for: .milliseconds(120))
            if Task.isCancelled { return }
        }
        if let result = await DiskSize.measure(targets, progress: { size.value = $0 }) { size.value = result }
    }
}

// MARK: - Sidebar

// MARK: - Window backdrop

/// Solid theme background, or a tinted blur of whatever is behind the window when opacity < 1.
struct WindowBackdrop: View {
    private let ws = Workspace.shared

    var body: some View {
        let translucent = ws.opacity < 1
        ZStack {
            if translucent { BlurView() }
            ws.theme.bg.opacity(ws.opacity)
        }
        .background(WindowConfigurator(translucent: translucent))
    }
}

struct BlurView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .behindWindow
        v.state = .active
        v.material = .underWindowBackground
        return v
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct WindowConfigurator: NSViewRepresentable {
    let translucent: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            view.window?.isOpaque = !translucent
            view.window?.backgroundColor = translucent ? .clear : .windowBackgroundColor
        }
    }
}

// MARK: - Preview resizing

/// Draggable divider on the preview's left edge.
struct PreviewResizeHandle: View {
    private let ws = Workspace.shared
    @StateObject private var startWidth = Local<CGFloat?>(nil)
    @StateObject private var hovering = Local(false)

    var body: some View {
        let active = hovering.value || startWidth.value != nil
        Rectangle()
            .fill(ws.theme.dim.opacity(active ? 0.55 : 0.15))
            .frame(width: 1)
            // The grab area overlaps the neighbouring panes instead of taking layout space, so the
            // columns and the preview sit flush against the divider.
            .overlay {
                Rectangle().fill(ws.theme.dim.opacity(active ? 0.55 : 0)).frame(width: 3)
                    .contentShape(Rectangle().inset(by: -3))
            }
            .frame(width: 1)
            .animation(.easeOut(duration: 0.12), value: active)
            .contentShape(Rectangle().inset(by: -4))
            // push/pop gets undone whenever a neighbouring view updates its cursor, so claim it on every move.
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    NSCursor.resizeLeftRight.set()
                    if !hovering.value { hovering.value = true }
                case .ended:
                    if startWidth.value == nil { NSCursor.arrow.set() }
                    hovering.value = false
                }
            }
            .gesture(
                // Global coordinates: the handle moves as the width changes, so local ones would feed back.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        if startWidth.value == nil { startWidth.value = ws.previewWidth }
                        NSCursor.resizeLeftRight.set()
                        ws.previewWidth = min(max((startWidth.value ?? 300) - drag.translation.width, 220), 560)
                    }
                    .onEnded { _ in startWidth.value = nil; hovering.value = false }
            )
    }
}
