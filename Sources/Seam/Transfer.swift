import Foundation

/// Shared between the copy thread and the UI: the thread writes, a MainActor poller reads.
final class TransferProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var finished: Int64 = 0
    private var current: Int64 = 0
    private var _total: Int64 = -1
    private var _item = 0
    private var _cancelled = false

    /// Bytes to copy, or -1 while the sizes are still being added up.
    var total: Int64 { lock.withLock { _total } }
    var done: Int64 { lock.withLock { finished + current } }
    var item: Int { lock.withLock { _item } }
    var cancelled: Bool { lock.withLock { _cancelled } }

    func cancel() { lock.withLock { _cancelled = true } }
    func setTotal(_ n: Int64) { lock.withLock { _total = n } }
    func setItem(_ n: Int) { lock.withLock { _item = n } }
    func setCurrent(_ n: Int64) { lock.withLock { current = n } }
    func finishFile(_ size: Int64) { lock.withLock { finished += size; current = 0 } }
}

struct TransferResult {
    var pairs: [(from: URL, to: URL)] = []
    var errors: [String] = []
    var cancelled = false
}

/// Copies files with progress and cancellation. Moves across volumes are a copy followed by removing the source.
enum Copier {
    private struct Cancelled: Error {}

    static func run(_ srcs: [URL], into dir: URL, move: Bool, progress: TransferProgress) -> TransferResult {
        var result = TransferResult()
        let fm = FileManager.default
        progress.setTotal(totalSize(srcs, progress))
        for (i, src) in srcs.enumerated() {
            if progress.cancelled { result.cancelled = true; break }
            progress.setItem(i + 1)
            var dest = dir.appendingPathComponent(src.lastPathComponent)
            if src.standardizedFileURL == dest.standardizedFileURL || fm.fileExists(atPath: dest.path) {
                dest = dest.uniqueSibling()
            }
            do {
                try copy(src, to: dest, progress)
                if move { try fm.removeItem(at: src) }
                result.pairs.append((src, dest))
            } catch is Cancelled {
                try? fm.removeItem(at: dest)
                result.cancelled = true
                break
            } catch {
                try? fm.removeItem(at: dest)
                result.errors.append(error.localizedDescription)
            }
        }
        return result
    }

    private static func totalSize(_ urls: [URL], _ progress: TransferProgress) -> Int64 {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        func size(_ u: URL) -> Int64? {
            guard let v = try? u.resourceValues(forKeys: keys), v.isRegularFile == true else { return nil }
            return Int64(v.fileSize ?? 0)
        }
        var total: Int64 = 0
        for u in urls {
            if let s = size(u) { total += s; continue }
            guard let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: Array(keys)) else { continue }
            for case let f as URL in e {
                if progress.cancelled { return total }
                total += size(f) ?? 0
            }
        }
        return total
    }

    private static func copy(_ src: URL, to dest: URL, _ progress: TransferProgress) throws {
        let v = try src.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        if v.isDirectory == true, v.isSymbolicLink != true {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
            for kid in try FileManager.default.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) {
                try copy(kid, to: dest.appendingPathComponent(kid.lastPathComponent), progress)
            }
            // Adding children changed the folder's times, so apply the original ones last.
            _ = copyfile(src.path, dest.path, nil, copyfile_flags_t(COPYFILE_STAT | COPYFILE_XATTR))
        } else {
            // Only regular files were counted in the total, so links add nothing.
            try copyFile(src, to: dest, size: v.isRegularFile == true ? Int64(v.fileSize ?? 0) : 0, progress)
        }
    }

    private static func copyFile(_ src: URL, to dest: URL, size: Int64, _ progress: TransferProgress) throws {
        if progress.cancelled { throw Cancelled() }
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        let callback: copyfile_callback_t = { what, stage, state, _, _, ctx in
            guard let ctx else { return Int32(COPYFILE_CONTINUE) }
            let p = Unmanaged<TransferProgress>.fromOpaque(ctx).takeUnretainedValue()
            if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS {
                var copied: off_t = 0
                copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
                p.setCurrent(Int64(copied))
            }
            return p.cancelled ? Int32(COPYFILE_QUIT) : Int32(COPYFILE_CONTINUE)
        }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(progress).toOpaque())
        let flags = copyfile_flags_t(COPYFILE_ACL | COPYFILE_STAT | COPYFILE_XATTR | COPYFILE_DATA | COPYFILE_NOFOLLOW | COPYFILE_EXCL | COPYFILE_CLONE)
        if copyfile(src.path, dest.path, state, flags) != 0 {
            let code = errno
            if progress.cancelled { throw Cancelled() }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                          userInfo: [NSLocalizedDescriptionKey: "\(src.lastPathComponent): \(String(cString: strerror(code)))"])
        }
        progress.finishFile(size)
    }
}
