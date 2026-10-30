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
            ("⇧⌘.  or  .", "Show hidden"), ("⌘+  ⌘−", "Text size"), ("F1  ?", "This list"),
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
