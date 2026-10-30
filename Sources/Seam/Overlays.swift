import SwiftUI

struct OverlayHost: View {
    private let ws = Workspace.shared

    var body: some View {
        if let overlay = ws.overlay {
            ZStack(alignment: .top) {
                Color.black.opacity(0.35)
                    .onTapGesture { ws.overlay = nil }
                Group {
                    switch overlay {
                    case .search: SearchOverlay()
                    case .location: LocationOverlay()
                    case .shortcuts: ShortcutsOverlay()
                    case .preview: PreviewPane(item: ws.tab.currentItem, large: true).frame(width: 720, height: 540)
                    case .settings: SettingsOverlay()
                    }
                }
                .background(ws.theme.panel, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(ws.theme.dim.opacity(0.25)))
                .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
                .padding(.top, 90)
            }
            .transition(.opacity)
        }
    }
}

struct SearchOverlay: View {
    @Bindable var model = Workspace.shared.search
    private let ws = Workspace.shared
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(ws.theme.dim)
                TextField("Find files in \(model.root.folderTitle)…", text: $model.query)
                    .textFieldStyle(.plain).font(.system(size: 16))
                    .focused($focused)
                if model.indexing {
                    ProgressView().controlSize(.small)
                }
                Text(model.indexed.formatted()).font(.system(size: 11).monospacedDigit()).foregroundStyle(ws.theme.dim)
            }
            .padding(14)
            if !model.hits.isEmpty {
                Divider().opacity(0.3)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(model.hits.enumerated()), id: \.element.id) { i, hit in
                                row(hit, selected: i == model.selection)
                                    .onTapGesture { ws.overlay = nil; ws.tab.go(hit.url) }
                                    .id(i)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 380)
                    .onChange(of: model.selection) { _, s in proxy.scrollTo(s) }
                }
            } else if !model.query.isEmpty && !model.indexing {
                Divider().opacity(0.3)
                Text("No matches").font(.system(size: 12)).foregroundStyle(ws.theme.dim).padding(16)
            } else if model.query.isEmpty {
                Divider().opacity(0.3)
                Text("Type to search · space separates words · ↑↓ or ⌃J ⌃K to pick")
                    .font(.system(size: 11)).foregroundStyle(ws.theme.dim).padding(12)
            }
        }
        .frame(width: 640)
        .onAppear { focused = true }
    }

    private func row(_ hit: SearchHit, selected: Bool) -> some View {
        let name = hit.url.lastPathComponent
        let nameStart = hit.relative.count - name.count
        let parent = String(hit.relative.dropLast(name.count))
        return HStack(spacing: 8) {
            Image(systemName: hit.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(selected ? .white : ws.iconTint).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                highlighted(name, offset: nameStart, matched: hit.matched, selected: selected)
                    .font(.system(size: 13, weight: .medium))
                highlighted(parent.isEmpty ? "~" : parent, offset: 0, matched: parent.isEmpty ? [] : hit.matched, selected: selected)
                    .font(.system(size: 11)).opacity(0.65).lineLimit(1).truncationMode(.head)
            }
            Spacer()
        }
        .foregroundStyle(selected ? Color.white : ws.theme.fg)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(selected ? ws.theme.tint : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    /// Matched characters in bold; on the selected row they stay white, elsewhere they take the accent colour.
    private func highlighted(_ text: String, offset: Int, matched: Set<Int>, selected: Bool) -> Text {
        var out = Text("")
        for (i, ch) in text.enumerated() {
            let t = Text(String(ch))
            out = out + (matched.contains(offset + i) ? t.bold().foregroundColor(selected ? .white : ws.theme.tint) : t)
        }
        return out
    }
}

struct LocationOverlay: View {
    private let ws = Workspace.shared
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var ws = ws
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.right.circle").foregroundStyle(ws.theme.dim)
                    TextField("Path, ~/folder, or smb://server", text: $ws.locationText)
                        .textFieldStyle(.plain).font(.system(size: 16))
                        .focused($focused)
                }
                Text("Tab to complete · ↑↓ to pick · Return to go · ⌃P to pin · Esc to cancel")
                    .font(.system(size: 11)).foregroundStyle(ws.theme.dim)
            }
            .padding(14)
            if let message = ws.locationMessage {
                Divider().opacity(0.3)
                Text(message).font(.system(size: 12)).foregroundStyle(ws.theme.dim).padding(12)
            }
            if !ws.locationSuggestions.isEmpty {
                Divider().opacity(0.3)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(ws.locationSuggestions.enumerated()), id: \.offset) { i, s in
                                let selected = i == ws.locationSelection
                                HStack(spacing: 8) {
                                    Image(systemName: s.symbol).frame(width: 18)
                                        .foregroundStyle(selected ? .white : ws.iconTint)
                                    Text(s.label).font(.system(size: 13)).lineLimit(1)
                                    Spacer()
                                }
                                .foregroundStyle(selected ? Color.white : ws.theme.fg)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(selected ? ws.theme.tint : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                                .onTapGesture { ws.setLocation(s.text) }
                                .id(i)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 280)
                    .onChange(of: ws.locationSelection) { _, i in if i >= 0 { proxy.scrollTo(i) } }
                }
            }
        }
        .frame(width: 640)
        .onChange(of: ws.locationText) { ws.refreshLocationSuggestions() }
        .onAppear {
            focused = true
            DispatchQueue.main.async { (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil) }
        }
    }
}

struct ShortcutsOverlay: View {
    private let ws = Workspace.shared

    private let groups: [(String, [(String, String)])] = [
        ("Navigate", [
            ("h  j  k  l  /  arrows", "Move"), ("5j  3h  12k", "Repeat with a count"),
            ("l  →", "Open"), ("Backspace  -  h", "Parent folder"),
            ("gg  G  5G", "First / last / row 5"), ("⌃D  ⌃U", "Half page down / up"),
            ("⌃F  ⌃B", "Page down / up"), ("⌃O  Tab", "History back / forward"),
            ("gh  g/", "Home / root"), ("gt  gT", "Next / previous tab"),
            ("⌘F", "Fuzzy search"), ("⌘O  :", "Go to location"), ("Tab", "Complete path (in ⌘O)"),
            ("/", "Filter column"),
        ]),
        ("Files", [
            ("Space", "Toggle preview"), ("⇧Space", "Preview in a popup (j k move, Space closes)"), ("Return  r  F2", "Rename"), ("m", "Mark item"), ("⇧M", "Mark range"),
            ("y  ⌘C", "Copy"), ("⌘X", "Cut"), ("p  ⌘V", "Paste"), ("⌘⌫", "Move to Trash"), ("⇧⌘⌫", "Delete permanently"), ("⌘Z", "Undo last"),
            ("⌘N", "New file"), ("⇧⌘N", "New folder"), ("⇧⌘C", "Copy path"), ("⇧⌘R", "AirDrop selection"), ("t", "Open Terminal here"),
        ]),
        ("View", [
            ("⌘T  ⌘W", "New / close tab"), ("⇧⌘[  ⇧⌘]", "Previous / next tab"),
            ("⇧⌘.  or  .", "Show hidden"), ("⌘+  ⌘−", "Text size"), ("⌘,", "Settings"), ("F1  ?", "This list"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keyboard shortcuts").font(.system(size: 16, weight: .semibold))
            HStack(alignment: .top, spacing: 28) {
                ForEach(groups, id: \.0) { title, rows in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(ws.theme.dim)
                        ForEach(rows, id: \.0) { key, what in
                            HStack(spacing: 8) {
                                Text(key).font(.system(size: 11, design: .monospaced))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(ws.theme.bg, in: RoundedRectangle(cornerRadius: 4))
                                Text(what).font(.system(size: 12)).foregroundStyle(ws.theme.dim)
                            }
                        }
                    }
                }
            }
            Text("Esc to close").font(.system(size: 11)).foregroundStyle(ws.theme.dim)
        }
        .padding(22)
    }
}

struct SettingsOverlay: View {
    private let ws = Workspace.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Settings").font(.system(size: 16, weight: .semibold))
                Spacer()
                Text("Esc to close").font(.system(size: 11)).foregroundStyle(ws.theme.dim)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            Divider().opacity(0.3)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    group("General", [
                        toggle("Show hidden files", Binding(get: { ws.tab.showHidden }, set: { ws.setShowHidden($0) })),
                        toggle("Group folders first", Binding(get: { ws.tab.foldersFirst }, set: { ws.setFoldersFirst($0) })),
                        row("Sort by") {
                            menuPicker(Binding(get: { ws.tab.sortKey }, set: { ws.setSort(key: $0) }), SortKey.allCases, label: \.rawValue)
                        },
                        toggle("Ascending", Binding(get: { ws.tab.ascending }, set: { ws.setSort(ascending: $0) })),
                        toggle("Peek into folders", Binding(get: { ws.peekFolders }, set: { ws.peekFolders = $0 }),
                               hint: "Show a folder's contents in the next column as soon as it is selected."),
                    ])
                    group("Appearance", [
                        row("Theme") { menuPicker(Binding(get: { ws.theme }, set: { ws.setTheme($0) }), ws.themes, label: \.name) },
                        row(nil) {
                            HStack(spacing: 6) {
                                ForEach([ws.theme.bg, ws.theme.panel, ws.theme.fg, ws.theme.tint], id: \.self) { c in
                                    Circle().fill(c).frame(width: 18, height: 18)
                                        .overlay(Circle().stroke(ws.theme.dim.opacity(0.35), lineWidth: 1))
                                }
                                Spacer(minLength: 8)
                                button("Save Copy…") { ws.saveThemeCopy() }
                                button("Themes Folder") { NSWorkspace.shared.open(ConfigPaths.themes) }
                            }
                        },
                        row("Opacity") { slider(Binding(get: { ws.opacity }, set: { ws.opacity = $0 }), 0.2...1, step: 0.05) },
                        row("Text size") { slider(Binding(get: { ws.textScale }, set: { ws.textScale = $0 }), 0.7...1.8, step: 0.1) },
                        row("Density") {
                            segmented(Binding(get: { ws.airy }, set: { ws.airy = $0 }), off: "Compact", on: "Airy")
                        },
                        row("Icons") {
                            segmented(Binding(get: { ws.monoIcons }, set: { ws.monoIcons = $0 }), off: "Color", on: "Monochrome")
                        },
                    ])
                    group("Layout", [
                        toggle("Preview pane", Binding(get: { ws.showPreview }, set: { ws.showPreview = $0 })),
                        toggle("Sidebar", Binding(get: { ws.showSidebar }, set: { ws.showSidebar = $0 })),
                        toggle("Hide Pinned when empty", Binding(get: { ws.hidePinnedWhenEmpty }, set: { ws.hidePinnedWhenEmpty = $0 })),
                    ])
                    group("Files", [
                        row(nil) {
                            HStack(spacing: 8) {
                                Text("Everything above is stored in ~/.config/seam")
                                    .font(.system(size: 12)).foregroundStyle(ws.theme.dim).lineLimit(2)
                                Spacer(minLength: 8)
                                button("Settings File") { NSWorkspace.shared.activateFileViewerSelecting([ConfigPaths.settings]) }
                                button("Config Folder") { NSWorkspace.shared.open(ConfigPaths.directory) }
                            }
                        },
                    ])
                }
                .padding(22)
            }
        }
        .frame(width: 540)
        .frame(maxHeight: 640)
        .onAppear { ws.reloadThemes() }
    }

    // MARK: Building blocks

    private func group(_ title: String, _ rows: [AnyView]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14, weight: .semibold)).padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { i in
                    if i > 0 { Divider().opacity(0.3).padding(.horizontal, 14) }
                    rows[i].padding(.horizontal, 14).padding(.vertical, 10)
                }
            }
            .background(ws.theme.fg.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(ws.theme.dim.opacity(0.22)))
        }
    }

    private func row<C: View>(_ title: String?, @ViewBuilder _ control: () -> C) -> AnyView {
        AnyView(HStack {
            if let title { Text(title).font(.system(size: 13)); Spacer(minLength: 12) }
            control()
        })
    }

    private func toggle(_ title: String, _ isOn: Binding<Bool>, hint: String? = nil) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer(minLength: 12)
                Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden()
            }
            if let hint { Text(hint).font(.system(size: 11)).foregroundStyle(ws.theme.dim).padding(.trailing, 50) }
        })
    }

    private func menuPicker<T: Hashable>(_ selection: Binding<T>, _ options: [T], label: KeyPath<T, String>) -> some View {
        Picker("", selection: selection) {
            ForEach(options, id: \.self) { Text($0[keyPath: label]).tag($0) }
        }
        .labelsHidden().fixedSize()
    }

    private func segmented(_ isOn: Binding<Bool>, off: String, on: String) -> some View {
        Picker("", selection: isOn) {
            Text(off).tag(false)
            Text(on).tag(true)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
    }

    private func slider(_ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double) -> some View {
        HStack(spacing: 10) {
            Slider(value: value, in: range, step: step).frame(width: 190)
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .font(.system(size: 13).monospacedDigit()).foregroundStyle(ws.theme.dim).frame(width: 42, alignment: .trailing)
        }
    }

    private func button(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
    }
}
