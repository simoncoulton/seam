import Darwin
import Foundation

struct DiskUsage: Equatable, Sendable {
    /// Bytes as Finder reports them.
    var logical: UInt64 = 0
    /// Bytes occupied on disk (block-rounded, so small files cost more than their length).
    var allocated: UInt64 = 0
    /// Files, symlinks and other non-folders.
    var files: UInt64 = 0
    var finished = false
}

/// Recursive size of files and folders, built the way dutui's scanner is:
/// - `getattrlistbulk` returns names, types and sizes for many entries per syscall, which is far
///   cheaper than a `stat` per file (the dominant cost of a naive walk on macOS).
/// - A handful of threads share one stack of directories. More than about 8 only fight over
///   filesystem locks, so the pool is clamped to 4...8.
/// - Hard links are counted once, scans stay on the starting volume, symlinks aren't followed,
///   and `cancel()` stops the walk within one directory.
final class SizeScan: @unchecked Sendable {
    private struct Job { let path: String; let dev: UInt32 }
    private struct Inode: Hashable { let dev: UInt32; let ino: UInt64 }
    private struct Linked { let key: Inode; let logical: UInt64; let allocated: UInt64 }

    private let cond = NSCondition()
    private var stack: [Job] = []
    private var active = 0
    private var total = DiskUsage()
    private var seen = Set<Inode>()
    private var cancelled = false

    private static let bufferSize = 256 * 1024

    func cancel() {
        cond.lock()
        cancelled = true
        cond.broadcast()
        cond.unlock()
    }

    /// Totals so far. Cheap enough to poll from a UI timer.
    func snapshot() -> DiskUsage {
        cond.lock()
        defer { cond.unlock() }
        return total
    }

    /// Walks `roots` and blocks until done or cancelled. Call off the main thread.
    @discardableResult
    func run(_ roots: [URL]) -> DiskUsage {
        cond.lock()
        for url in roots {
            var st = stat()
            // Follow a symlink given as the root itself; nothing below it is followed.
            guard stat(url.path, &st) == 0 else { continue }
            if (st.st_mode & S_IFMT) == S_IFDIR {
                stack.append(Job(path: url.realURL.path, dev: UInt32(truncatingIfNeeded: st.st_dev)))
            } else {
                addFile(Inode(dev: UInt32(truncatingIfNeeded: st.st_dev), ino: UInt64(st.st_ino)), nlink: UInt32(st.st_nlink),
                        logical: UInt64(max(st.st_size, 0)), allocated: UInt64(max(st.st_blocks, 0)) * 512)
            }
        }
        cond.unlock()

        let threads = min(8, max(4, ProcessInfo.processInfo.activeProcessorCount))
        DispatchQueue.concurrentPerform(iterations: threads) { _ in work() }

        cond.lock()
        defer { cond.unlock() }
        total.finished = !cancelled
        return total
    }

    /// Caller holds the lock.
    private func addFile(_ key: Inode, nlink: UInt32, logical: UInt64, allocated: UInt64) {
        if nlink > 1, !seen.insert(key).inserted { return }
        total.logical += logical
        total.allocated += allocated
        total.files += 1
    }

    private func work() {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 8)
        defer { buffer.deallocate() }
        while true {
            cond.lock()
            while stack.isEmpty {
                if active == 0 || cancelled {
                    cond.broadcast()
                    cond.unlock()
                    return
                }
                cond.wait()
            }
            if cancelled { cond.unlock(); return }
            let job = stack.removeLast()
            active += 1
            cond.unlock()

            var local = DiskUsage()
            var dirs: [Job] = []
            var linked: [Linked] = []
            list(job, buffer, &local, &dirs, &linked)

            cond.lock()
            total.logical += local.logical
            total.allocated += local.allocated
            total.files += local.files
            // Only hard-linked files take the shared set; everything else is summed without contention.
            for l in linked { addFile(l.key, nlink: 2, logical: l.logical, allocated: l.allocated) }
            stack.append(contentsOf: dirs)
            active -= 1
            cond.broadcast()
            cond.unlock()
        }
    }

    private func list(_ job: Job, _ buffer: UnsafeMutableRawPointer, _ local: inout DiskUsage,
                      _ dirs: inout [Job], _ linked: inout [Linked]) {
        let fd = open(job.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return } // unreadable: nothing to count
        defer { close(fd) }

        var al = attrlist()
        al.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        al.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_DEVID)
            | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_FILEID)
        al.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_TOTALSIZE) | attrgroup_t(ATTR_FILE_ALLOCSIZE)

        var sawEntries = false
        while true {
            let n = getattrlistbulk(fd, &al, buffer, Self.bufferSize, UInt64(FSOPT_PACK_INVAL_ATTRS))
            if n < 0 {
                // Not supported on this filesystem: use the portable path unless some entries were already read.
                if !sawEntries { listSlow(job, &local, &dirs, &linked) }
                return
            }
            if n == 0 { return }
            sawEntries = true
            var p = UnsafeRawPointer(buffer)
            for _ in 0..<n {
                // Packed layout with FSOPT_PACK_INVAL_ATTRS: length, returned set (5 x u32), name ref,
                // devid, objtype, fileid, linkcount, total size, allocated size.
                let length = Int(p.loadUnaligned(as: UInt32.self))
                let nameOffset = Int(p.loadUnaligned(fromByteOffset: 24, as: Int32.self))
                let dev = p.loadUnaligned(fromByteOffset: 32, as: UInt32.self)
                let type = p.loadUnaligned(fromByteOffset: 36, as: UInt32.self)
                if type == 2 { // VDIR
                    if dev == job.dev { // don't cross onto another volume
                        let name = String(cString: (p + 24 + nameOffset).assumingMemoryBound(to: CChar.self))
                        dirs.append(Job(path: job.path == "/" ? "/" + name : job.path + "/" + name, dev: job.dev))
                    }
                } else {
                    let ino = p.loadUnaligned(fromByteOffset: 40, as: UInt64.self)
                    let nlink = p.loadUnaligned(fromByteOffset: 48, as: UInt32.self)
                    let logical = UInt64(max(p.loadUnaligned(fromByteOffset: 52, as: Int64.self), 0))
                    let allocated = UInt64(max(p.loadUnaligned(fromByteOffset: 60, as: Int64.self), 0))
                    if nlink > 1 {
                        linked.append(Linked(key: Inode(dev: dev, ino: ino), logical: logical, allocated: allocated))
                    } else {
                        local.logical += logical
                        local.allocated += allocated
                        local.files += 1
                    }
                }
                p += length
            }
        }
    }

    /// `readdir` plus `fstatat` relative to the open directory, which avoids re-resolving the full path per entry.
    private func listSlow(_ job: Job, _ local: inout DiskUsage, _ dirs: inout [Job], _ linked: inout [Linked]) {
        guard let dir = opendir(job.path) else { return }
        defer { closedir(dir) }
        let fd = dirfd(dir)
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let dev = UInt32(truncatingIfNeeded: st.st_dev)
            if (st.st_mode & S_IFMT) == S_IFDIR {
                if dev == job.dev { dirs.append(Job(path: job.path == "/" ? "/" + name : job.path + "/" + name, dev: job.dev)) }
                continue
            }
            let logical = UInt64(max(st.st_size, 0)), allocated = UInt64(max(st.st_blocks, 0)) * 512
            if st.st_nlink > 1 {
                linked.append(Linked(key: Inode(dev: dev, ino: UInt64(st.st_ino)), logical: logical, allocated: allocated))
            } else {
                local.logical += logical
                local.allocated += allocated
                local.files += 1
            }
        }
    }
}

/// Finished results, so moving back over a folder doesn't walk it again. Cleared when anything changes on disk.
final class SizeCache: @unchecked Sendable {
    static let shared = SizeCache()
    private let lock = NSLock()
    private var store: [String: DiskUsage] = [:]

    func get(_ path: String) -> DiskUsage? {
        lock.lock(); defer { lock.unlock() }
        return store[path]
    }

    func put(_ path: String, _ usage: DiskUsage) {
        lock.lock(); defer { lock.unlock() }
        if store.count > 500 { store.removeAll() }
        store[path] = usage
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        store.removeAll()
    }
}

enum DiskSize {
    /// Measures `urls`, reporting partial totals about every 100 ms. Cancelling the calling task stops the
    /// walk and returns nil, so a task per selection cancels cleanly when the selection moves on.
    @MainActor
    static func measure(_ urls: [URL], progress: (DiskUsage) -> Void) async -> DiskUsage? {
        let key = urls.count == 1 ? urls[0].path : nil
        if let key, let hit = SizeCache.shared.get(key) { return hit }
        let scan = SizeScan()
        let worker = Task.detached(priority: .userInitiated) { scan.run(urls) }
        return await withTaskCancellationHandler {
            var polls = 0
            while true {
                // Poll fast at first so small folders feel instant, then settle at 10 Hz.
                try? await Task.sleep(for: .milliseconds(polls < 5 ? 15 : 100))
                polls += 1
                if Task.isCancelled { _ = await worker.value; return nil }
                let snap = scan.snapshot()
                if snap.finished {
                    if let key { SizeCache.shared.put(key, snap) }
                    return snap
                }
                progress(snap)
            }
        } onCancel: {
            scan.cancel()
        }
    }
}
