import Darwin
import Foundation
import Observation

struct SearchHit: Identifiable {
    let url: URL
    let relative: String
    let isDirectory: Bool
    let score: Int
    /// Character offsets into `relative` that matched the query, for highlighting.
    let matched: Set<Int>
    var id: URL { url }
}

/// A few thousand paths packed into one byte arena, so a query is a linear scan over contiguous memory
/// with no per-path allocation. Chunks are immutable once published.
private final class Chunk: @unchecked Sendable {
    let raw: [UInt8]
    /// Entry i occupies raw[starts[i] ..< starts[i + 1]].
    let starts: [Int32]
    /// Offset of the file name within the entry.
    let nameOff: [UInt16]
    /// bit 0: directory, bit 1: the path passes through a dot-name.
    let flags: [UInt8]
    var count: Int { nameOff.count }

    init(raw: [UInt8], starts: [Int32], nameOff: [UInt16], flags: [UInt8]) {
        self.raw = raw; self.starts = starts; self.nameOff = nameOff; self.flags = flags
    }
}

private struct ChunkBuilder {
    var raw: [UInt8] = []
    var starts: [Int32] = [0]
    var nameOff: [UInt16] = []
    var flags: [UInt8] = []
    var count: Int { nameOff.count }

    mutating func add(parent: [UInt8], name: UnsafePointer<CChar>, isDir: Bool, hidden: Bool) {
        let len = strlen(name)
        if !parent.isEmpty { raw.append(contentsOf: parent); raw.append(UInt8(ascii: "/")) }
        nameOff.append(UInt16(truncatingIfNeeded: parent.isEmpty ? 0 : parent.count + 1))
        name.withMemoryRebound(to: UInt8.self, capacity: len) { raw.append(contentsOf: UnsafeBufferPointer(start: $0, count: len)) }
        starts.append(Int32(raw.count))
        flags.append((isDir ? 1 : 0) | (hidden ? 2 : 0))
    }

    mutating func take() -> Chunk {
        defer { self = ChunkBuilder() }
        return Chunk(raw: raw, starts: starts, nameOff: nameOff, flags: flags)
    }
}

/// Every path under one root, walked once with `getattrlistbulk` on a handful of threads (the same
/// scanner shape as the footer size), then kept in memory so searches don't touch the disk.
final class FileIndex: @unchecked Sendable {
    let root: URL
    let showHidden: Bool
    private let lock = NSLock()
    private var chunkList: [Chunk] = []
    private var done = false
    private(set) var builtAt = Date()

    init(root: URL, showHidden: Bool) {
        self.root = root
        self.showHidden = showHidden
    }

    fileprivate var chunks: [Chunk] { lock.lock(); defer { lock.unlock() }; return chunkList }
    var count: Int { lock.lock(); defer { lock.unlock() }; return chunkList.reduce(0) { $0 + $1.count } }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return done }

    fileprivate func publish(_ chunk: Chunk) {
        lock.lock(); chunkList.append(chunk); lock.unlock()
    }

    fileprivate func finish() {
        lock.lock(); done = true; builtAt = Date(); lock.unlock()
    }

    func cancel() { walker.cancel() }

    private lazy var walker = IndexWalker(index: self)

    /// Blocks until the walk is done. Call off the main thread.
    func build() {
        walker.run()
        finish()
    }
}

private final class IndexWalker: @unchecked Sendable {
    private struct Job { let path: String; let rel: [UInt8]; let dev: UInt32; let hidden: Bool }

    private unowned let index: FileIndex
    private let cond = NSCondition()
    private var stack: [Job] = []
    private var active = 0
    private var cancelled = false

    private static let bufferSize = 256 * 1024
    /// Not worth walking into: huge, machine-generated, and never what someone is looking for by name.
    private static let skipDirs: Set<String> = [
        ".git", "node_modules", ".build", ".Trash", ".cache", ".npm", ".cargo", ".rustup", ".gradle", "DerivedData",
        "__pycache__", ".venv", "venv", ".next", "Pods", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100",
        ".TemporaryItems", ".pnpm-store", ".yarn", "target",
    ]
    private static let skipSuffixes = [".app", ".framework", ".photoslibrary", ".musiclibrary", ".bundle", ".xcassets", ".lproj"]

    init(index: FileIndex) { self.index = index }

    func cancel() {
        cond.lock(); cancelled = true; cond.broadcast(); cond.unlock()
    }

    func run() {
        var st = stat()
        guard stat(index.root.path, &st) == 0 else { return }
        stack = [Job(path: index.root.path, rel: [], dev: UInt32(truncatingIfNeeded: st.st_dev), hidden: false)]
        let threads = min(8, max(4, ProcessInfo.processInfo.activeProcessorCount))
        DispatchQueue.concurrentPerform(iterations: threads) { _ in work() }
    }

    private func work() {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 8)
        defer { buffer.deallocate() }
        var builder = ChunkBuilder()
        defer { if builder.count > 0 { index.publish(builder.take()) } }
        while true {
            cond.lock()
            while stack.isEmpty {
                if active == 0 || cancelled { cond.broadcast(); cond.unlock(); return }
                cond.wait()
            }
            if cancelled { cond.unlock(); return }
            let job = stack.removeLast()
            active += 1
            cond.unlock()

            var dirs: [Job] = []
            list(job, buffer, &builder, &dirs)
            if builder.count >= 1500 { index.publish(builder.take()) }

            cond.lock()
            stack.append(contentsOf: dirs)
            active -= 1
            cond.broadcast()
            cond.unlock()
        }
    }

    private func list(_ job: Job, _ buffer: UnsafeMutableRawPointer, _ builder: inout ChunkBuilder, _ dirs: inout [Job]) {
        let fd = open(job.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { close(fd) }

        var al = attrlist()
        al.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        al.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_DEVID)
            | attrgroup_t(ATTR_CMN_OBJTYPE)

        while true {
            let n = getattrlistbulk(fd, &al, buffer, Self.bufferSize, UInt64(FSOPT_PACK_INVAL_ATTRS))
            if n <= 0 { return }
            var p = UnsafeRawPointer(buffer)
            for _ in 0..<n {
                // Packed layout: length, returned set (5 x u32), name ref, devid, objtype.
                let length = Int(p.loadUnaligned(as: UInt32.self))
                let nameOffset = Int(p.loadUnaligned(fromByteOffset: 24, as: Int32.self))
                let dev = p.loadUnaligned(fromByteOffset: 32, as: UInt32.self)
                let type = p.loadUnaligned(fromByteOffset: 36, as: UInt32.self)
                let namePtr = (p + 24 + nameOffset).assumingMemoryBound(to: CChar.self)
                p += length

                let dot = namePtr.pointee == 46 // "."
                if dot && !index.showHidden { continue }
                let isDir = type == 2
                let hidden = job.hidden || dot
                builder.add(parent: job.rel, name: namePtr, isDir: isDir, hidden: hidden)
                guard isDir, dev == job.dev else { continue } // stay on this volume; symlinks aren't directories here

                let name = String(cString: namePtr)
                if Self.skipDirs.contains(name) { continue }
                if job.rel.isEmpty, name == "Library", index.root.path == NSHomeDirectory() { continue }
                if Self.skipSuffixes.contains(where: { name.hasSuffix($0) }) { continue }
                var rel = job.rel
                if !rel.isEmpty { rel.append(UInt8(ascii: "/")) }
                rel.append(contentsOf: Array(name.utf8))
                dirs.append(Job(path: job.path == "/" ? "/" + name : job.path + "/" + name, rel: rel, dev: job.dev, hidden: hidden))
            }
        }
    }
}

/// fzf-style matching: space-separated terms must all match as subsequences of the path; matches that land
/// in the file name, at word starts, or in a row score higher; short, shallow, non-hidden paths win ties.
private enum Matcher {
    @inline(__always)
    static func fold(_ c: UInt8) -> UInt8 { (c >= 65 && c <= 90) ? c | 0x20 : c }

    @inline(__always)
    static func isSeparator(_ c: UInt8) -> Bool { c == 47 || c == 46 || c == 95 || c == 45 || c == 32 }

    /// Score of `q` against `t[from..<to]`, or nil. `exactCase` compares bytes untouched (smart-case).
    static func score(_ q: UnsafeBufferPointer<UInt8>, exactCase: Bool, _ t: UnsafePointer<UInt8>,
                      from: Int, to: Int, nameStart: Int) -> Int? {
        let m = q.count
        // Forward: first place the whole query fits.
        var qi = 0, end = -1, i = from
        while i < to {
            let c = exactCase ? t[i] : fold(t[i])
            if c == q[qi] { qi += 1; if qi == m { end = i; break } }
            i += 1
        }
        if end < 0 { return nil }
        // Backward: pull the start in so the window is as tight as it can be.
        var start = end, qj = m - 1
        var j = end
        while j >= from {
            let c = exactCase ? t[j] : fold(t[j])
            if c == q[qj] { if qj == 0 { start = j; break }; qj -= 1 }
            j -= 1
        }
        // Score the window.
        var total = 0, prev = -2
        qi = 0
        i = start
        while i <= end && qi < m {
            let c = exactCase ? t[i] : fold(t[i])
            if c == q[qi] {
                var s = 16
                if i == prev + 1 { s += 8 }
                if i == from || isSeparator(t[i - 1]) || (t[i - 1] >= 97 && t[i - 1] <= 122 && t[i] >= 65 && t[i] <= 90) { s += 10 }
                if i == nameStart { s += 8 }
                if i >= nameStart { s += 4 }
                total += s
                prev = i
                qi += 1
            }
            i += 1
        }
        let span = end - start + 1
        total -= min(span - m, 30)
        if span == m { total += 6; if start >= nameStart { total += 20; if start == nameStart { total += 20 } } }
        return total
    }
}

struct SearchQuery: Sendable {
    let terms: [[UInt8]]
    let exactCase: [Bool]
    let words: [String]

    init?(_ text: String) {
        let parts = text.split(separator: " ").map(String.init)
        guard !parts.isEmpty else { return nil }
        words = parts
        // Smart case: a term with a capital letter matches case-sensitively.
        exactCase = parts.map { $0.contains { $0.isUppercase } }
        terms = zip(parts, exactCase).map { Array(($1 ? $0 : $0.lowercased()).utf8) }
    }
}

/// Recursive fuzzy search under the folder you're in. Nothing is indexed until search opens: the walk starts
/// then, streams results as it goes, and is cancelled and freed when search closes.
@MainActor @Observable
final class SearchModel {
    var query = "" { didSet { run() } }
    var hits: [SearchHit] = []
    var selection = 0
    var indexing = false
    var indexed = 0
    private(set) var root = URL(fileURLWithPath: "/")

    private var index: FileIndex?
    private var queryTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var lastCount = -1

    var selectedHit: SearchHit? { hits.indices.contains(selection) ? hits[selection] : nil }

    func start(root: URL, showHidden: Bool) {
        stop()
        self.root = root
        let fresh = FileIndex(root: root.realURL, showHidden: showHidden)
        index = fresh
        indexing = true
        Task.detached(priority: .userInitiated) { fresh.build() }
        pollTask = Task { [weak self] in
            // Keep results and the counter fresh while the walk fills the index.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.index === fresh else { return }
                let done = fresh.finished
                self.indexed = fresh.count
                if self.indexed != self.lastCount { self.lastCount = self.indexed; self.run() }
                if done { self.indexing = false; return }
            }
        }
        query = ""
    }

    /// Search closed: stop walking and drop the index.
    func stop() {
        pollTask?.cancel()
        queryTask?.cancel()
        index?.cancel()
        index = nil
        hits = []
        indexed = 0
        indexing = false
        lastCount = -1
        selection = 0
    }

    func move(_ d: Int) {
        guard !hits.isEmpty else { return }
        selection = min(max(selection + d, 0), hits.count - 1)
    }

    // MARK: Querying

    private func run() {
        queryTask?.cancel()
        guard let q = SearchQuery(query), let index else {
            hits = []; selection = 0; return
        }
        let chunks = index.chunks
        let root = index.root
        let prefix: [UInt8] = []
        queryTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> [SearchHit] in
                Self.search(q, chunks: chunks, root: root, prefix: prefix)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.hits = result
            self.selection = min(self.selection, max(result.count - 1, 0))
        }
    }

    private struct Candidate { let score: Int; let chunk: Int; let entry: Int }

    nonisolated private static func search(_ q: SearchQuery, chunks: [Chunk], root: URL, prefix: [UInt8]) -> [SearchHit] {
        let limit = 60
        let slots = UnsafeMutablePointer<[Candidate]>.allocate(capacity: chunks.count)
        slots.initialize(repeating: [], count: chunks.count)
        defer { slots.deinitialize(count: chunks.count); slots.deallocate() }
        let cancelled = ManagedFlag()
        let skip = prefix.isEmpty ? 0 : prefix.count + 1

        DispatchQueue.concurrentPerform(iterations: chunks.count) { ci in
            if Task.isCancelled { cancelled.set(); return }
            let chunk = chunks[ci]
            var best: [Candidate] = []
            chunk.raw.withUnsafeBufferPointer { raw in
                guard let base = raw.baseAddress else { return }
                for e in 0..<chunk.count {
                    let from = Int(chunk.starts[e]), to = Int(chunk.starts[e + 1])
                    var begin = from
                    if skip > 0 {
                        // Only entries inside the folder, matched on the part below it.
                        guard to - from > skip, memcmp(base + from, prefix, prefix.count) == 0, base[from + prefix.count] == 47 else { continue }
                        begin = from + skip
                    }
                    let nameStart = from + Int(chunk.nameOff[e])
                    var total = 0
                    var ok = true
                    for (k, term) in q.terms.enumerated() {
                        let s = term.withUnsafeBufferPointer {
                            Matcher.score($0, exactCase: q.exactCase[k], base, from: begin, to: to, nameStart: max(nameStart, begin))
                        }
                        guard let s else { ok = false; break }
                        total += s
                    }
                    guard ok else { continue }
                    total -= (to - begin) / 8
                    if chunk.flags[e] & 2 != 0 { total -= 25 }
                    best.append(Candidate(score: total, chunk: ci, entry: e))
                    if best.count > limit * 4 {
                        best.sort { $0.score > $1.score }
                        best.removeSubrange(limit...)
                    }
                }
            }
            best.sort { $0.score > $1.score }
            slots[ci] = Array(best.prefix(limit))
        }
        if cancelled.isSet { return [] }

        var all: [Candidate] = []
        for i in 0..<chunks.count { all.append(contentsOf: slots[i]) }
        all.sort { $0.score > $1.score }
        return all.prefix(limit).map { c in
            let chunk = chunks[c.chunk]
            let from = Int(chunk.starts[c.entry]), to = Int(chunk.starts[c.entry + 1])
            let rel = String(decoding: chunk.raw[from..<to], as: UTF8.self)
            return SearchHit(url: root.appendingPathComponent(rel), relative: rel, isDirectory: chunk.flags[c.entry] & 1 != 0,
                             score: c.score, matched: highlight(q, in: rel, skipping: skipChars(prefix)))
        }
    }

    nonisolated private static func skipChars(_ prefix: [UInt8]) -> Int {
        prefix.isEmpty ? 0 : String(decoding: prefix, as: UTF8.self).count + 1
    }

    /// Characters of `text` that the query matched, picking the tightest window per term like the scorer does.
    nonisolated private static func highlight(_ q: SearchQuery, in text: String, skipping: Int) -> Set<Int> {
        let chars = Array(text)
        var out = Set<Int>()
        for (k, word) in q.words.enumerated() {
            let w = Array(q.exactCase[k] ? word : word.lowercased())
            func same(_ a: Character, _ b: Character) -> Bool { q.exactCase[k] ? a == b : Character(a.lowercased()) == b }
            var qi = 0, end = -1
            var i = skipping
            while i < chars.count {
                if same(chars[i], w[qi]) { qi += 1; if qi == w.count { end = i; break } }
                i += 1
            }
            guard end >= 0 else { continue }
            var qj = w.count - 1, j = end
            var found: [Int] = []
            while j >= skipping {
                if same(chars[j], w[qj]) { found.append(j); if qj == 0 { break }; qj -= 1 }
                j -= 1
            }
            out.formUnion(found)
        }
        return out
    }
}

private final class ManagedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
