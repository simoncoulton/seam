import AppKit

struct LocationSuggestion: Hashable {
    /// Full replacement for the location field.
    let text: String
    let label: String
    let symbol: String
}

/// `smb://[user@]server[/share[/path]]`, split at the first slash after the server.
struct SMBAddress {
    let server: String
    /// Everything after the slash that follows the server; nil while no slash has been typed.
    let afterServer: String?

    init?(_ text: String) {
        guard text.lowercased().hasPrefix("smb://") else { return nil }
        let rest = String(text.dropFirst(6))
        if let slash = rest.firstIndex(of: "/") {
            server = String(rest[..<slash])
            afterServer = String(rest[rest.index(after: slash)...])
        } else {
            server = rest
            afterServer = nil
        }
        guard !server.isEmpty else { return nil }
    }

    var host: String { server.split(separator: "@").last.map(String.init) ?? server }

    /// True when no share has been named, e.g. `smb://hub` or `smb://hub/`.
    var isServerOnly: Bool { (afterServer ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty }

    var url: URL? {
        var c = URLComponents()
        c.scheme = "smb"
        let parts = server.split(separator: "@", maxSplits: 1).map(String.init)
        if parts.count == 2 { c.user = parts[0]; c.host = parts[1] } else { c.host = server }
        c.path = "/" + (afterServer ?? "")
        return c.url
    }
}

extension Workspace {
    // MARK: Opening the bar

    func showLocation(prefill: String) {
        locationText = prefill
        locationSelection = -1
        locationSuggestions = []
        locationMessage = nil
        shareCache = [:]
        shareErrors = [:]
        overlay = .location
    }

    // MARK: Suggestions

    /// Rebuilds the list under the location field: folders for paths, shares for `smb://server/`.
    func refreshLocationSuggestions() {
        locationSelection = -1
        locationMessage = nil
        let t = locationText
        if t.contains("://") {
            guard let smb = SMBAddress(t), let after = smb.afterServer, !after.contains("/") else {
                locationSuggestions = []
                return
            }
            guard let shares = shareCache[smb.server] else {
                locationSuggestions = []
                fetchShares(for: smb)
                return
            }
            locationSuggestions = shares
                .filter { after.isEmpty || $0.lowercased().hasPrefix(after.lowercased()) }
                .map { LocationSuggestion(text: "smb://\(smb.server)/\($0)", label: $0, symbol: "externaldrive.connected.to.line.below") }
            if shares.isEmpty {
                locationMessage = shareErrors[smb.server].map { "Can't list shares: \($0). Press Return to sign in through macOS." }
                    ?? "No shares found on \(smb.host)"
            }
            return
        }
        locationSuggestions = pathSuggestions(t)
    }

    private func pathSuggestions(_ t: String) -> [LocationSuggestion] {
        guard !t.isEmpty else { return [] }
        if t == "~" { return [LocationSuggestion(text: "~/", label: "~", symbol: "house")] }
        let dirPart = t.lastIndex(of: "/").map { String(t[...$0]) } ?? ""
        let typed = String(t.dropFirst(dirPart.count))
        let base: URL
        if dirPart.isEmpty { base = tab.currentDir }
        else if dirPart.hasPrefix("/") || dirPart.hasPrefix("~") { base = URL(fileURLWithPath: (dirPart as NSString).expandingTildeInPath) }
        else { base = tab.currentDir.appendingPathComponent(dirPart) }
        let opts: FileManager.DirectoryEnumerationOptions = typed.hasPrefix(".") ? [] : [.skipsHiddenFiles]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: opts) else { return [] }
        return urls
            .filter { $0.lastPathComponent.lowercased().hasPrefix(typed.lowercased()) }
            .filter { DirectoryLoader.item(for: $0).isDirectory }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .prefix(60)
            .map { LocationSuggestion(text: dirPart + $0 + "/", label: $0, symbol: "folder") }
    }

    // MARK: Completion (Tab) and selection

    /// Shell-style Tab: complete a unique match, otherwise the longest common prefix.
    func completeLocation() {
        if locationSuggestions.indices.contains(locationSelection) {
            setLocation(locationSuggestions[locationSelection].text)
            return
        }
        let t = locationText
        if t.contains("://") {
            guard let smb = SMBAddress(t) else { return }
            guard let after = smb.afterServer else { setLocation(t + "/"); return }
            applyCompletion(prefix: "smb://\(smb.server)/", typed: after)
            return
        }
        if t == "~" { setLocation("~/"); return }
        let dirPart = t.lastIndex(of: "/").map { String(t[...$0]) } ?? ""
        applyCompletion(prefix: dirPart, typed: String(t.dropFirst(dirPart.count)))
    }

    private func applyCompletion(prefix: String, typed: String) {
        let s = locationSuggestions
        guard let first = s.first else { return }
        if s.count == 1 { setLocation(first.text.hasSuffix("/") ? first.text : first.text + "/"); return }
        let common = s.dropFirst().reduce(first.label) { $0.commonPrefix(with: $1.label, options: .caseInsensitive) }
        if common.count > typed.count { setLocation(prefix + common) }
    }

    func moveLocationSelection(_ d: Int) {
        let n = locationSuggestions.count
        guard n > 0 else { return }
        if locationSelection < 0 { locationSelection = d > 0 ? 0 : n - 1 }
        else { locationSelection = min(max(locationSelection + d, 0), n - 1) }
    }

    func submitLocation() {
        var text = locationText
        if locationSuggestions.indices.contains(locationSelection) { text = locationSuggestions[locationSelection].text }
        openLocation(text)
    }

    /// Sets the field text and parks the caret at the end, like a shell after completion.
    func setLocation(_ text: String) {
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView {
            tv.string = text
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        locationText = text
        refreshLocationSuggestions()
    }

    // MARK: SMB servers and shares

    /// Return on `smb://server` with no share: list the shares if the server allows it, otherwise let
    /// macOS handle the login and share choice.
    func connectServer(_ smb: SMBAddress) {
        locationMessage = "Looking for shares on \(smb.host)…"
        Task {
            let listing: (shares: [String], error: String?)
            if let cached = shareCache[smb.server], !cached.isEmpty { listing = (cached, nil) }
            else { listing = await Self.listShares(server: smb.server) }
            if !listing.shares.isEmpty {
                shareCache[smb.server] = listing.shares
                if overlay == .location { setLocation("smb://\(smb.server)/") }
                return
            }
            shareErrors[smb.server] = listing.error
            locationMessage = nil
            overlay = nil
            if let url = smb.url { mount(url, hint: listing.error) }
        }
    }

    func fetchShares(for smb: SMBAddress) {
        guard !sharesLoading.contains(smb.server) else { return }
        sharesLoading.insert(smb.server)
        locationMessage = "Looking for shares on \(smb.host)…"
        Task {
            let listing = await Self.listShares(server: smb.server)
            sharesLoading.remove(smb.server)
            shareCache[smb.server] = listing.shares
            shareErrors[smb.server] = listing.error
            if overlay == .location { refreshLocationSuggestions() }
        }
    }

    /// Asks `smbutil` for the shares without prompting. Servers that need a login return an error.
    nonisolated static func listShares(server: String) async -> (shares: [String], error: String?) {
        await Task.detached { () -> (shares: [String], error: String?) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/smbutil")
            p.arguments = ["view", "-N", "//\(server)"]
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            do { try p.run() } catch { return ([], error.localizedDescription) }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: killer)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            killer.cancel()
            if p.terminationReason == .uncaughtSignal { return ([], "timed out") }
            if p.terminationStatus != 0 {
                var msg = String(decoding: errData.isEmpty ? data : errData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if msg.hasPrefix("smbutil:") { msg = String(msg.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
                return ([], msg.isEmpty ? "exit \(p.terminationStatus)" : msg)
            }
            return (parseShares(String(decoding: data, as: UTF8.self)), nil)
        }.value
    }

    /// Parses `smbutil view` output, keeping disk shares and dropping admin shares like `IPC$`.
    nonisolated static func parseShares(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        guard let header = lines.first(where: { $0.hasPrefix("Share") && $0.contains("Type") }),
              let typeRange = header.range(of: "Type") else { return [] }
        let col = header.distance(from: header.startIndex, to: typeRange.lowerBound)
        var shares: [String] = []
        for line in lines.drop(while: { !$0.hasPrefix("---") }).dropFirst() {
            if line.contains("shares listed") { break }
            guard line.count > col else { continue }
            let name = String(line.prefix(col)).trimmingCharacters(in: .whitespaces)
            let type = line.dropFirst(col).split(separator: " ").first.map(String.init) ?? ""
            if name.isEmpty || name.hasSuffix("$") || type != "Disk" { continue }
            shares.append(name)
        }
        return shares
    }
}
