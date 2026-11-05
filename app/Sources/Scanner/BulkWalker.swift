// SPDX-License-Identifier: GPL-3.0-only
// 扫描核心：用 getattrlistbulk 批量取目录条目的属性。
//
// 传统做法是 opendir + 每个文件一次 lstat，每文件两次 syscall。
// getattrlistbulk 一次 syscall 拿回一批条目的名字、类型、体积、inode、时间，
// 这是 Python 版 17 秒 → 目标 2 秒之间最大的一笔收益。
//
// 口径与 roomy-scan.py 一致：
//   · 实际占用（ATTR_FILE_ALLOCSIZE），不是逻辑大小
//   · 硬链接按 (dev, inode) 只计一次
//   · 不跟随符号链接，不跨卷
//   · 读不到的路径计数，不中断

import Foundation
import Darwin

// 直接用字面值，避开 Swift 导入 C 宏时 0x80000000 这类高位常量的符号类型问题
private let CMN_RETURNED_ATTRS: UInt32 = 0x8000_0000
private let CMN_NAME:           UInt32 = 0x0000_0001
private let CMN_DEVID:          UInt32 = 0x0000_0002
private let CMN_OBJTYPE:        UInt32 = 0x0000_0008
private let CMN_MODTIME:        UInt32 = 0x0000_0400
private let CMN_ACCTIME:        UInt32 = 0x0000_1000
private let CMN_FILEID:         UInt32 = 0x0200_0000
private let FILE_LINKCOUNT:     UInt32 = 0x0000_0001
private let FILE_DATALENGTH:    UInt32 = 0x0000_0002
private let FILE_ALLOCSIZE:     UInt32 = 0x0000_0004

private let VREG: UInt32 = 1
private let VDIR: UInt32 = 2
private let VLNK: UInt32 = 5

struct DirEntry {
    var name = ""
    var type: UInt32 = 0
    var dev: UInt64 = 0
    var fileID: UInt64 = 0
    var links: UInt32 = 1
    var logical: UInt64 = 0
    var alloc: UInt64 = 0
    var mtime: Int = 0
    var atime: Int = 0
    var isDir: Bool { type == VDIR }
    var isFile: Bool { type == VREG }
    var isLink: Bool { type == VLNK }
}

enum BulkError: Error { case denied, notFound, cancelled, identityChanged, other(Int32) }

/// 一次测量对一个目标是否完整。只对产生该大小的那次遍历有效：
/// complete = 整棵子树读完；incomplete = 读过但有失败/变化/取消；unknown = 本次没走到（跳过、跨卷、符号链接、目标消失）
enum MeasurementCompleteness: String, Sendable {
    case complete, incomplete, unknown
}

struct TargetMeasurement: Equatable, Sendable {
    let size: UInt64?
    let completeness: MeasurementCompleteness
}

/// 一次详细测量的结果：大小和完整性来自同一批遍历。batch 只用来表明"这是同一次测量"，
/// 不写进缓存、不序列化，也不作为删除授权。
struct MeasuredTargets: Sendable {
    let batch: UUID
    let measurements: [String: TargetMeasurement]
    var sizes: [String: UInt64] { measurements.compactMapValues(\.size) }
    func measurement(for path: String) -> TargetMeasurement? { measurements[path] }
}

/// 子树遍历的返回值：字节数 + 读失败/变化/取消的次数。issues > 0 的子树不能算完整。
private struct WalkSum {
    var bytes: UInt64 = 0
    var issues = 0
}

/// 一次遍历里记下的目标、目录和每个目标的完整性（完整性只在产生它的那次遍历里有意义）
private struct WalkOutput {
    var targets: [String: UInt64] = [:]
    var dirs: [String: UInt64] = [:]
    var completeness: [String: MeasurementCompleteness] = [:]
}

/// 目录属性缓冲。每个遍历线程一个，复用到底 ——
/// 之前每读一个目录分配一次 256KB，227k 个目录就是 227k 次 mmap/munmap，全是内核时间。
final class AttrBuffer {
    let size: Int
    let ptr: UnsafeMutableRawPointer
    init(size: Int = 128 * 1024) {
        self.size = size
        ptr = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
    }
    deinit { ptr.deallocate() }
}

/// Activity/classification callers retain all metadata. Byte-only walkers do not consume timestamps or
/// logical length: omitting those fields packs more entries into each bulk read without skipping entries.
enum BulkReadAttributes { case full, allocatedSize }

private func makeAttrList(_ attributes: BulkReadAttributes) -> attrlist {
    var al = attrlist()
    al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    al.commonattr = CMN_RETURNED_ATTRS | CMN_NAME | CMN_DEVID | CMN_OBJTYPE | CMN_FILEID
    al.fileattr = FILE_LINKCOUNT | FILE_ALLOCSIZE
    if attributes == .full {
        al.commonattr |= CMN_MODTIME | CMN_ACCTIME
        al.fileattr |= FILE_DATALENGTH
    }
    return al
}

/// 用已打开的目录 fd 读完全部条目。fd 由调用方关闭。
func readEntries(
    fd: Int32,
    into out: inout [DirEntry],
    buf: AttrBuffer,
    attributes: BulkReadAttributes = .full,
    includeFileNames: Bool = true,
    shouldContinue: () -> Bool = { true }
) throws {
    var al = makeAttrList(attributes)
    while true {
        guard shouldContinue() else { throw BulkError.cancelled }
        let n = getattrlistbulk(fd, &al, buf.ptr, buf.size, UInt64(FSOPT_NOFOLLOW))
        if n < 0 {
            if errno == EACCES || errno == EPERM { throw BulkError.denied }
            throw BulkError.other(errno)
        }
        if n == 0 { break }

        var p = buf.ptr
        for _ in 0..<Int(n) {
            let len = Int(p.load(as: UInt32.self))
            var q = p + 4
            let ret = q.load(as: attribute_set_t.self); q += MemoryLayout<attribute_set_t>.size
            var e = DirEntry()
            var name: UnsafePointer<CChar>?

            if ret.commonattr & CMN_NAME != 0 {
                let ref = q.load(as: attrreference_t.self)
                name = UnsafePointer((q + Int(ref.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
                q += MemoryLayout<attrreference_t>.size
            }
            if ret.commonattr & CMN_DEVID != 0   {
                e.dev = UInt64(UInt32(bitPattern: q.load(as: Int32.self))); q += 4
            }
            if ret.commonattr & CMN_OBJTYPE != 0 { e.type = q.load(as: UInt32.self); q += 4 }
            if ret.commonattr & CMN_MODTIME != 0 { e.mtime = Int(q.loadUnaligned(as: timespec.self).tv_sec); q += MemoryLayout<timespec>.size }
            if ret.commonattr & CMN_ACCTIME != 0 { e.atime = Int(q.loadUnaligned(as: timespec.self).tv_sec); q += MemoryLayout<timespec>.size }
            if ret.commonattr & CMN_FILEID != 0  { e.fileID = q.loadUnaligned(as: UInt64.self); q += 8 }
            if ret.fileattr & FILE_LINKCOUNT != 0 { e.links = q.load(as: UInt32.self); q += 4 }
            if ret.fileattr & FILE_DATALENGTH != 0 { e.logical = UInt64(max(0, q.loadUnaligned(as: Int64.self))); q += 8 }
            if ret.fileattr & FILE_ALLOCSIZE != 0 { e.alloc = UInt64(max(0, q.loadUnaligned(as: Int64.self))); q += 8 }

            if let name, name.pointee != 0 {
                // Byte walkers need names only to open subdirectories. All files still contribute their
                // identity/link/allocated-byte metadata; avoid a String allocation for every ordinary file.
                if includeFileNames || e.isDir { e.name = String(cString: name) }
                out.append(e)
            }
            p += len
        }
        guard shouldContinue() else { throw BulkError.cancelled }
    }
}

func openDir(_ path: String) throws -> Int32 {
    let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    if fd < 0 {
        switch errno {
        case EACCES, EPERM: throw BulkError.denied
        case ENOENT, ENOTDIR: throw BulkError.notFound
        default: throw BulkError.other(errno)
        }
    }
    return fd
}

/// 按路径一次读完一个目录（分组、找 node_modules 这类零散调用用它；热路径不走这里）
/// shouldContinue：浅层目录也要能取消 —— 只读根和第一层时不会进入 walk 递归，取消必须在这里生效
func readDir(_ path: String, shouldContinue: () -> Bool = { true }) throws -> [DirEntry] {
    let fd = try openDir(path); defer { close(fd) }
    var out: [DirEntry] = []
    out.reserveCapacity(64)
    try readEntries(fd: fd, into: &out, buf: AttrBuffer(size: 64 * 1024), shouldContinue: shouldContinue)
    return out
}

/// 遍历求实际占用。线程安全，可被并发调用。
final class BulkWalker {
    private let readAttributes: BulkReadAttributes
    init(readAttributes: BulkReadAttributes = .allocatedSize) { self.readAttributes = readAttributes }
    private struct LinkKey: Hashable { let dev: UInt64; let ino: UInt64 }
    private var seen = Set<LinkKey>()
    private let lock = NSLock()

    private var _denied = 0, _files = 0, _dirs = 0, _failed = 0, _cancelled = 0
    private let statLock = NSLock()
    var denied: Int { statLock.lock(); defer { statLock.unlock() }; return _denied }
    var files:  Int { statLock.lock(); defer { statLock.unlock() }; return _files }
    var dirs:   Int { statLock.lock(); defer { statLock.unlock() }; return _dirs }
    var failed: Int { statLock.lock(); defer { statLock.unlock() }; return _failed }
    var cancelled: Int { statLock.lock(); defer { statLock.unlock() }; return _cancelled }
    /// 有任何读失败、变化或取消：结果只能算残缺，不能当完整测量
    var incompleteReads: Bool {
        statLock.lock(); defer { statLock.unlock() }
        return _denied > 0 || _failed > 0 || _cancelled > 0
    }

    /// 硬链接去重：第一次见到返回 true
    private func firstSight(_ dev: UInt64, _ ino: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return seen.insert(LinkKey(dev: dev, ino: ino)).inserted
    }

    /// 单次遍历的局部统计，结束时一次性合并，避免每个目录都抢锁。linked：见到的多链接文件数（不合并，只给 measureTargets 判断子树能否复用）
    /// failed/cancelled：除权限以外的读失败和取消；它们和 denied 一样让这次测量不完整
    private struct Tally { var files = 0, dirs = 0, denied = 0, linked = 0, failed = 0, cancelled = 0 }
    private func merge(_ t: Tally) {
        statLock.lock()
        _files += t.files; _dirs += t.dirs; _denied += t.denied
        _failed += t.failed; _cancelled += t.cancelled
        statLock.unlock()
    }

    /// 返回 path 的实际占用字节数；不存在返回 nil。内部串行，由调用方决定并发。
    func size(of path: String, buf: AttrBuffer? = nil) -> UInt64? {
        sizeDetailed(of: path, buf: buf).size
    }

    /// 同 size(of:)，但把"这次遍历是否完整"一并带回来：只有 complete 才说明大小读全了。
    /// 符号链接不跟随（unknown）、读不了的目录不给大小（incomplete）、不存在的是 unknown。
    /// 取消在入口就作废这次测量：哪怕目标只是一个单文件，取消之后读到的也不是完整结果。
    func sizeDetailed(of path: String, buf: AttrBuffer? = nil,
                      shouldContinue: () -> Bool = { true }) -> TargetMeasurement {
        guard shouldContinue() else {
            merge(Tally(cancelled: 1))
            return TargetMeasurement(size: nil, completeness: .incomplete)
        }
        var st = stat()
        let statResult = lstat(path, &st)
        let statErrno = errno      // 立刻取走：下面的 merge 会加锁，errno 可能已经被改掉
        guard statResult == 0 else {
            switch statErrno {
            case ENOENT, ENOTDIR:      // 本来就不存在：不知道大小，但也没读错
                return TargetMeasurement(size: nil, completeness: .unknown)
            case EACCES, EPERM:
                merge(Tally(denied: 1))
                return TargetMeasurement(size: nil, completeness: .incomplete)
            default:
                merge(Tally(failed: 1))
                return TargetMeasurement(size: nil, completeness: .incomplete)
            }
        }
        let mode = st.st_mode & S_IFMT
        if mode == S_IFLNK { return TargetMeasurement(size: 0, completeness: .unknown) }
        if mode == S_IFREG {
            var t = Tally(); t.files = 1; merge(t)
            let dev = UInt64(UInt32(bitPattern: st.st_dev))
            if st.st_nlink > 1 && !firstSight(dev, st.st_ino) {
                return TargetMeasurement(size: 0, completeness: .complete)
            }
            return TargetMeasurement(size: UInt64(st.st_blocks) * 512, completeness: .complete)
        }
        guard mode == S_IFDIR else { return TargetMeasurement(size: 0, completeness: .unknown) }

        let fd: Int32
        do { fd = try openDir(path) }
        catch BulkError.denied {
            merge(Tally(denied: 1))
            return TargetMeasurement(size: nil, completeness: .incomplete)
        }
        catch BulkError.notFound { return TargetMeasurement(size: nil, completeness: .unknown) }
        catch {
            merge(Tally(failed: 1))
            return TargetMeasurement(size: nil, completeness: .incomplete)
        }
        defer { close(fd) }

        let b = buf ?? AttrBuffer()
        var tally = Tally()
        var entries: [DirEntry] = []; entries.reserveCapacity(128)
        let rootDev = UInt64(UInt32(bitPattern: st.st_dev))
        let sum = walk(fd: fd, rootDev: rootDev, buf: b, entries: &entries, tally: &tally,
                       shouldContinue: shouldContinue)
        merge(tally)
        return TargetMeasurement(size: sum.bytes, completeness: sum.issues == 0 ? .complete : .incomplete)
    }

    /// 同 size(of:)，额外把 path 及其 maxDepth 层以内每个目录的总占用交给 record（一次遍历）
    func size(of path: String, maxDepth: Int, skip: Set<String> = [], buf: AttrBuffer? = nil,
              record: (String, UInt64) -> Void) -> UInt64? {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return size(of: path, buf: buf) }
        let fd: Int32
        do { fd = try openDir(path) } catch { return 0 }
        defer { close(fd) }
        let b = buf ?? AttrBuffer()
        var tally = Tally()
        var entries: [DirEntry] = []; entries.reserveCapacity(128)
        let sum = walk(fd: fd, rootDev: UInt64(UInt32(bitPattern: st.st_dev)), buf: b, entries: &entries,
                       tally: &tally, path: path, depth: 0, maxDepth: maxDepth, skip: skip, record: record,
                       shouldContinue: { true })
        merge(tally)
        return sum.bytes
    }

    private func walk(fd: Int32, rootDev: UInt64, buf: AttrBuffer, entries: inout [DirEntry], tally: inout Tally,
                      path: String, depth: Int, maxDepth: Int, skip: Set<String>,
                      record: (String, UInt64) -> Void, shouldContinue: () -> Bool) -> WalkSum {
        entries.removeAll(keepingCapacity: true)
        do { try readEntries(fd: fd, into: &entries, buf: buf, attributes: readAttributes,
                             includeFileNames: readAttributes == .full, shouldContinue: shouldContinue) }
        catch BulkError.denied { tally.denied += 1; return WalkSum(issues: 1) }
        catch BulkError.cancelled { tally.cancelled += 1; return WalkSum(issues: 1) }
        catch { tally.failed += 1; return WalkSum(issues: 1) }
        tally.dirs += 1

        var sum = WalkSum()
        var subdirs: [String] = []
        for e in entries {
            if e.isLink || e.dev != rootDev { continue }
            if e.isFile {
                tally.files += 1
                if e.links > 1 { tally.linked += 1; if !firstSight(e.dev, e.fileID) { continue } }
                sum.bytes &+= e.alloc
            } else if e.isDir {
                subdirs.append(e.name)
            }
        }
        for name in subdirs where !skip.contains(path + "/" + name) {
            let cfd = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if cfd < 0 {
                if errno == EACCES || errno == EPERM { tally.denied += 1 } else { tally.failed += 1 }
                sum.issues += 1
                continue
            }
            if depth < maxDepth {
                let child = walk(fd: cfd, rootDev: rootDev, buf: buf, entries: &entries, tally: &tally,
                                 path: path + "/" + name, depth: depth + 1, maxDepth: maxDepth, skip: skip,
                                 record: record, shouldContinue: shouldContinue)
                sum.bytes &+= child.bytes
                sum.issues += child.issues
            } else {
                let child = walk(fd: cfd, rootDev: rootDev, buf: buf, entries: &entries, tally: &tally,
                                 shouldContinue: shouldContinue)
                sum.bytes &+= child.bytes
                sum.issues += child.issues
            }
            close(cfd)
        }
        record(path, sum.bytes)
        return sum
    }

    /// 一次遍历：记下每个目标的子树大小，以及 dirDepth 层以内、不小于 dirThreshold 的目录大小。
    /// 根目录按第一层拆开并发；整次共用硬链接去重表，所以一个目标在别处还有硬链接时，那部分不算它的（删它也腾不出来）。
    /// 遍历没覆盖到的目标（在 skip 里、跨卷、在 roots 之外、本身是文件）最后逐个补齐。
    /// reuse：清单统计时已经完整走过的子树，走到这里直接取用、不再读一遍（结果和读一遍相同，见 MeasuredSubtrees）
    /// shouldContinue：给取消用。检查点放在每读一批条目和每个子目录之前，所以取消能传进递归本身，
    /// 不只是最外层的一次 readEntries；取消到的结果只能算残缺，不能当完整测量。
    /// includeAllRootChildren：增长对比用。为 true 时一级子目录全部进 dirs，不受 dirThreshold 截断；
    /// 更深层目录仍按阈值。否则一个一级目录跨过 200 MB 时，会被增长对比误当成新增/移除。
    func measure(roots: [String], targets: [String], dirDepth: Int, dirThreshold: UInt64,
                 skip: Set<String>, reuse: MeasuredSubtrees? = nil,
                 shouldContinue: @escaping () -> Bool = { true },
                 includeAllRootChildren: Bool = false) -> SizeIndex {
        let trie = PathTrie()
        targets.forEach(trie.insert)
        reuse?.plant(in: trie, targets: targets, skip: skip, dirThreshold: dirThreshold)
        final class Box: @unchecked Sendable { let lock = NSLock(); var index = SizeIndex() }
        let box = Box()
        // 按第二层拆任务：第一层里有个特别大的（~/Library 100 GB）时也能并发。
        // 第一层目录的大小 = 它自己的文件 + 各子任务的大小，最后加总。
        struct Task { let path: String; let parent: Int }
        var firsts: [(path: String, own: UInt64, dev: UInt64, root: Int)] = []
        // 和 roots 等长：取消提前跳出时不能按下标 append，否则后面按 roots 枚举会越界。
        // 没走到的根留 nil，不造 0（rootTotals 里干脆不出现 = 大小未知）
        var rootFiles = [UInt64?](repeating: nil, count: roots.count)
        var unreadable: [String] = []
        var tasks: [Task] = []
        var completedRoots = Set<Int>()
        rootsLoop: for (r, root) in roots.enumerated() {
            // 取消后不再开新的根：剩下的根不进 roots，页面按"没统计到"处理
            guard shouldContinue() else { merge(Tally(cancelled: 1)); break }
            // du -x：根所在的挂载点以外的第一层目录（比如 /private/var/vm）不算
            var rootStat = stat()
            let rootDev: UInt64? = lstat(root, &rootStat) == 0 ? UInt64(UInt32(bitPattern: rootStat.st_dev)) : nil
            var filesHere: UInt64 = 0
            let rootEntries: [DirEntry]
            do { rootEntries = try readDir(root, shouldContinue: shouldContinue) }
            catch BulkError.cancelled { merge(Tally(cancelled: 1)); break }
            catch {
                // 根不存在：什么也没有；存在但读不了：大小未知，记下来，不能当 0
                if rootDev != nil { unreadable.append(root) }
                continue
            }
            for e in rootEntries {
                guard shouldContinue() else { merge(Tally(cancelled: 1)); break rootsLoop }
                if e.isFile {
                    if rootDev != nil, e.dev == rootDev! {
                        if e.links > 1 && !firstSight(e.dev, e.fileID) { continue }
                        filesHere &+= e.alloc
                    }
                    continue
                }
                guard e.isDir, !e.isLink else { continue }
                let first = root + "/" + e.name
                // 目录项自带的 dev 在挂载点上可能是被盖住的那一层，所以用 lstat 的结果判断
                var firstStat = stat()
                if let rootDev, lstat(first, &firstStat) == 0, UInt64(UInt32(bitPattern: firstStat.st_dev)) != rootDev { continue }
                guard !skip.contains(first) else { continue }
                if let reused = trie.node(for: first)?.reused,
                   let local = MeasuredSubtrees.merge(reused, depth: 1, dirDepth: dirDepth, dirThreshold: dirThreshold) {
                    box.index.dirs.merge(local) { a, _ in a }
                    firsts.append((first, reused.total, e.dev, r))
                    continue
                }
                let kids: [DirEntry]
                do { kids = try readDir(first, shouldContinue: shouldContinue) }
                catch BulkError.cancelled { merge(Tally(cancelled: 1)); break rootsLoop }
                catch { unreadable.append(first); continue }
                var own: UInt64 = 0
                for k in kids where !k.isLink && k.dev == e.dev {
                    guard shouldContinue() else { merge(Tally(cancelled: 1)); break rootsLoop }
                    if k.isFile {
                        if k.links > 1 && !firstSight(k.dev, k.fileID) { continue }
                        own &+= k.alloc
                    } else if k.isDir, !skip.contains(first + "/" + k.name) {
                        tasks.append(Task(path: first + "/" + k.name, parent: firsts.count))
                    }
                }
                firsts.append((first, own, e.dev, r))
            }
            rootFiles[r] = rootDev == nil ? nil : filesHere
            completedRoots.insert(r)
        }
        // 并发任务里的读失败只记任务路径：足够让整份根快照作废，又不会为 6 层以下每个坏路径存字符串。
        final class Gaps: @unchecked Sendable {
            private let lock = NSLock()
            private var paths = Set<String>()
            func add(_ path: String) { lock.lock(); paths.insert(path); lock.unlock() }
            func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return Array(paths) }
        }
        let gaps = Gaps()
        final class Totals: @unchecked Sendable { let lock = NSLock(); var byFirst: [UInt64] = [] }
        let totals = Totals()
        totals.byFirst = firsts.map(\.own)
        DispatchQueue.concurrentPerform(iterations: tasks.count) { i in
            guard shouldContinue() else { merge(Tally(cancelled: 1)); return }
            let task = tasks[i]
            if let node = trie.node(for: task.path), let reused = node.reused,
               let local = MeasuredSubtrees.merge(reused, depth: 2, dirDepth: dirDepth, dirThreshold: dirThreshold) {
                box.lock.lock()
                box.index.dirs.merge(local) { a, _ in a }
                if node.marked { box.index.targets[task.path] = reused.total }
                box.lock.unlock()
                totals.lock.lock(); totals.byFirst[task.parent] &+= reused.total; totals.lock.unlock()
                return
            }
            var st = stat()
            guard lstat(task.path, &st) == 0, UInt64(UInt32(bitPattern: st.st_dev)) == firsts[task.parent].dev,
                  let fd = try? openDir(task.path) else {
                gaps.add(task.path)
                return
            }
            defer { close(fd) }
            var local = WalkOutput(), tally = Tally()
            var entries: [DirEntry] = []
            let sum = measureWalk(fd: fd, rootDev: UInt64(UInt32(bitPattern: st.st_dev)), buf: AttrBuffer(), entries: &entries,
                                  tally: &tally, path: task.path, depth: 2, node: trie.node(for: task.path), dirDepth: dirDepth,
                                  dirThreshold: dirThreshold, skip: skip, shouldContinue: shouldContinue, into: &local)
            merge(tally)
            // 任一后代读坏/变化/取消：所属任务路径记成缺口，根不能当完整快照。
            if sum.issues > 0 { gaps.add(task.path) }
            box.lock.lock()
            box.index.targets.merge(local.targets) { a, _ in a }
            box.index.dirs.merge(local.dirs) { a, _ in a }
            box.lock.unlock()
            totals.lock.lock(); totals.byFirst[task.parent] &+= sum.bytes; totals.lock.unlock()
        }
        unreadable.append(contentsOf: gaps.snapshot())
        var rootTotals: [String: UInt64] = [:]
        for (r, root) in roots.enumerated() { if let files = rootFiles[r] { rootTotals[root] = files } }
        for (i, first) in firsts.enumerated() {
            // 取消时没走完的根不参与加总：宁可留成"未知"，也不把半截数当根的总占用
            guard completedRoots.contains(first.root) else { continue }
            let total = totals.byFirst[i]
            rootTotals[roots[first.root], default: 0] &+= total
            if trie.node(for: first.path)?.marked == true { box.index.targets[first.path] = total }
            // 增长对比保留全部一级目录；其余调用仍按阈值截断，深层目录也仍按阈值。
            if dirDepth >= 1 && (includeAllRootChildren || total >= dirThreshold) {
                box.index.dirs[first.path] = total
            }
        }
        // 取消过就把统计标成不完整：哪怕回调后来又返回 true，也不能把半截遍历称成完整
        if !shouldContinue() { merge(Tally(cancelled: 1)) }
        var index = box.index
        index.roots = rootTotals
        index.unreadable = Array(Set(unreadable)).sorted()
        for t in targets where index.targets[t] == nil {
            guard shouldContinue() else { merge(Tally(cancelled: 1)); break }
            if let s = sizeDetailed(of: t, shouldContinue: shouldContinue).size { index.targets[t] = s }
        }
        return index
    }

    /// 只统计目标：最外层的目标各遍历一次，嵌套在里面的目标在同一次子树遍历里记下。
    /// 组间并发、组内串行（同 parallelSizes：线程太多会在 APFS 内核锁上打架）。不存在的目标不出现在结果里。
    /// record：顺便把每个最外层目标的子树记下来，留给之后的完整遍历取用
    func measureTargets(_ targets: [String], threads: Int = 6, record: MeasuredSubtrees? = nil) -> [String: UInt64] {
        measureTargetsDetailed(targets, threads: threads, record: record).sizes
    }

    /// 同 measureTargets，但每个目标额外带回"产生这个大小的同一次遍历是否完整"。
    /// 完整性只对目标自己的子树负责：根、嵌套目标、fallback 各自独立；跨卷/跳过/没走到的目标
    /// 不会继承父目标的 complete，而是用自己的那次遍历作证。
    /// shouldContinue：给取消用；取消到的子树一律 incomplete，不会因为已经读到一部分就报 complete。
    func measureTargetsDetailed(_ targets: [String], threads: Int = 6, record: MeasuredSubtrees? = nil,
                                shouldContinue: @escaping () -> Bool = { true }) -> MeasuredTargets {
        let trie = PathTrie()
        targets.forEach(trie.insert)
        func nested(_ path: String) -> Bool {
            var n = trie.root
            let parts = path.split(separator: "/")
            for c in parts.dropLast() {
                guard let next = n.children[String(c)] else { return false }
                if next.marked { return true }
                n = next
            }
            return false
        }
        let tops = Array(Set(targets.filter { !nested($0) })).sorted()
        // 目标大小差别很大（一个 node_modules 能抵几百个小目录）：谁空了谁取下一个，不按固定步长分
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var measurements: [String: TargetMeasurement] = [:]
            var next = 0
        }
        let box = Box()
        let workers = max(1, min(threads, tops.count))
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            let buf = AttrBuffer()
            var tally = Tally()
            var entries: [DirEntry] = []
            while true {
                box.lock.lock(); let i = box.next; box.next += 1; box.lock.unlock()
                guard i < tops.count else { break }
                let path = tops[i]
                var st = stat()
                let statResult = lstat(path, &st)
                let statErrno = errno      // 立刻取走：discard 与 box 的锁都可能改动 errno
                guard statResult == 0 else {
                    let denied = statErrno == EACCES || statErrno == EPERM
                    let missing = statErrno == ENOENT || statErrno == ENOTDIR
                    if denied { tally.denied += 1 } else if !missing { tally.failed += 1 }
                    record?.discard(path)
                    box.lock.lock()
                    box.measurements[path] = TargetMeasurement(size: nil,
                        completeness: missing ? .unknown : .incomplete)
                    box.lock.unlock()
                    continue
                }
                guard (st.st_mode & S_IFMT) == S_IFDIR else {
                    let measured = sizeDetailed(of: path, buf: buf, shouldContinue: shouldContinue)
                    box.lock.lock(); box.measurements[path] = measured; box.lock.unlock()
                    continue
                }
                let fd: Int32
                do { fd = try openDir(path) }
                catch BulkError.denied {
                    tally.denied += 1
                    record?.discard(path)
                    box.lock.lock(); box.measurements[path] = TargetMeasurement(size: nil, completeness: .incomplete); box.lock.unlock()
                    continue
                }
                catch BulkError.notFound {
                    record?.discard(path)
                    box.lock.lock(); box.measurements[path] = TargetMeasurement(size: nil, completeness: .unknown); box.lock.unlock()
                    continue
                }
                catch {
                    tally.failed += 1
                    record?.discard(path)
                    box.lock.lock(); box.measurements[path] = TargetMeasurement(size: nil, completeness: .incomplete); box.lock.unlock()
                    continue
                }
                let dev = UInt64(UInt32(bitPattern: st.st_dev))
                var output = WalkOutput()
                let linked = tally.linked
                let sum = measureWalk(fd: fd, rootDev: dev, buf: buf, entries: &entries, tally: &tally, path: path, depth: 0,
                                      node: trie.node(for: path), dirDepth: record?.depth ?? -1,
                                      dirThreshold: record?.threshold ?? .max, skip: [],
                                      shouldContinue: shouldContinue, into: &output)
                close(fd)
                if let record {
                    // 读坏或出现硬链接的子树不记：下次宁可重读，也不把旧结果当完整证据
                    if sum.issues == 0 && tally.linked == linked {
                        record.add(path, total: sum.bytes, dirs: output.dirs)
                    } else {
                        record.discard(path)
                    }
                }
                output.targets[path] = sum.bytes
                output.completeness[path] = sum.issues == 0 ? .complete : .incomplete
                box.lock.lock()
                for (target, size) in output.targets {
                    box.measurements[target] = TargetMeasurement(size: size,
                        completeness: output.completeness[target] ?? .unknown)
                }
                box.lock.unlock()
            }
            merge(tally)
        }
        // 嵌套目标遍历没走到的（本身是文件、在符号链接后面、大小写和磁盘上不同、跨卷）逐个补齐；
        // 补齐用自己的遍历作证，不借用父目标的 complete
        var measurements = box.measurements
        for t in targets where measurements[t] == nil {
            measurements[t] = sizeDetailed(of: t, shouldContinue: shouldContinue)
        }
        return MeasuredTargets(batch: UUID(), measurements: measurements)
    }

    private func measureWalk(fd: Int32, rootDev: UInt64, buf: AttrBuffer, entries: inout [DirEntry], tally: inout Tally,
                             path: String?, depth: Int, node: PathTrie.Node?, dirDepth: Int, dirThreshold: UInt64,
                             skip: Set<String>, shouldContinue: () -> Bool, into output: inout WalkOutput) -> WalkSum {
        entries.removeAll(keepingCapacity: true)
        do { try readEntries(fd: fd, into: &entries, buf: buf, attributes: readAttributes,
                             includeFileNames: readAttributes == .full, shouldContinue: shouldContinue) }
        catch BulkError.denied { tally.denied += 1; return WalkSum(issues: 1) }
        catch BulkError.cancelled { tally.cancelled += 1; return WalkSum(issues: 1) }
        catch { tally.failed += 1; return WalkSum(issues: 1) }
        tally.dirs += 1
        var sum = WalkSum()
        var subdirs: [String] = []
        for e in entries {
            if e.isLink || e.dev != rootDev { continue }
            if e.isFile {
                tally.files += 1
                if e.links > 1 { tally.linked += 1; if !firstSight(e.dev, e.fileID) { continue } }
                sum.bytes &+= e.alloc
            } else if e.isDir {
                subdirs.append(e.name)
            }
        }
        for name in subdirs {
            let childNode = node?.children[name]
            // 路径只在需要记录时才拼：还在 dirDepth 以内，或者正沿着某个目标往下走
            let childPath: String? = (depth + 1 <= dirDepth || childNode != nil) ? path.map { $0 + "/" + name } : nil
            if let cp = childPath, skip.contains(cp) { continue }
            if let cp = childPath, let node = childNode, let reused = node.reused,
               let local = MeasuredSubtrees.merge(reused, depth: depth + 1, dirDepth: dirDepth, dirThreshold: dirThreshold) {
                output.dirs.merge(local) { a, _ in a }
                if node.marked {
                    output.targets[cp] = reused.total
                    output.completeness[cp] = .complete   // 只收没有读错、没有硬链接的子树
                }
                sum.bytes &+= reused.total
                continue
            }
            let cfd = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if cfd < 0 {
                if errno == EACCES || errno == EPERM { tally.denied += 1 } else { tally.failed += 1 }
                sum.issues += 1
                continue
            }
            if childPath == nil {
                let child = walk(fd: cfd, rootDev: rootDev, buf: buf, entries: &entries, tally: &tally,
                                 shouldContinue: shouldContinue)
                sum.bytes &+= child.bytes
                sum.issues += child.issues
            } else {
                let child = measureWalk(fd: cfd, rootDev: rootDev, buf: buf, entries: &entries, tally: &tally, path: childPath,
                                        depth: depth + 1, node: childNode, dirDepth: dirDepth, dirThreshold: dirThreshold,
                                        skip: skip, shouldContinue: shouldContinue, into: &output)
                sum.bytes &+= child.bytes
                sum.issues += child.issues
            }
            close(cfd)
        }
        if let path {
            if node?.marked == true {
                output.targets[path] = sum.bytes
                output.completeness[path] = sum.issues == 0 ? .complete : .incomplete
            }
            if depth <= dirDepth && sum.bytes >= dirThreshold { output.dirs[path] = sum.bytes }
        }
        return sum
    }

    /// 递归用 openat(parentfd, name)：不重复解析整条路径，深目录树上这是大头
    private func walk(fd: Int32, rootDev: UInt64, buf: AttrBuffer,
                      entries: inout [DirEntry], tally: inout Tally,
                      shouldContinue: () -> Bool) -> WalkSum {
        entries.removeAll(keepingCapacity: true)
        do { try readEntries(fd: fd, into: &entries, buf: buf, attributes: readAttributes,
                             includeFileNames: readAttributes == .full, shouldContinue: shouldContinue) }
        catch BulkError.denied { tally.denied += 1; return WalkSum(issues: 1) }
        catch BulkError.cancelled { tally.cancelled += 1; return WalkSum(issues: 1) }
        catch { tally.failed += 1; return WalkSum(issues: 1) }
        tally.dirs += 1

        var sum = WalkSum()
        var subdirs: [String] = []
        for e in entries {
            if e.isLink || e.dev != rootDev { continue }          // 不跟链接、不跨卷
            if e.isFile {
                tally.files += 1
                if e.links > 1 { tally.linked += 1; if !firstSight(e.dev, e.fileID) { continue } }
                sum.bytes &+= e.alloc
            } else if e.isDir {
                subdirs.append(e.name)
            }
        }
        for name in subdirs {
            let cfd = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if cfd < 0 {
                if errno == EACCES || errno == EPERM { tally.denied += 1 } else { tally.failed += 1 }
                sum.issues += 1
                continue
            }
            let child = walk(fd: cfd, rootDev: rootDev, buf: buf, entries: &entries, tally: &tally,
                             shouldContinue: shouldContinue)
            sum.bytes &+= child.bytes
            sum.issues += child.issues
            close(cfd)
        }
        return sum
    }
}

/// 只列直接子目录/文件名（给规则分组用），失败返回空
func children(of path: String, limit: Int = 400) -> [String] {
    guard let es = try? readDir(path) else { return [] }
    return es.filter { !$0.name.hasPrefix(".DS") }
             .map { path + "/" + $0.name }
             .sorted()
             .prefix(limit).map { $0 }
}

/// (距今天数 atime, 距今天数 mtime)
/// 几层以内最新的修改时间离现在几天。目录 mtime 只在直接子项增删时才变，
/// 只看最外层会把每天都在写的缓存（Go 模块、Gradle）误判成"几个月没动"。
func newestActivityDays(_ path: String, maxDepth: Int = 3, budget: Int = 2000) -> Int? {
    var st = stat()
    guard lstat(path, &st) == 0 else { return nil }
    var newest = Int(st.st_mtimespec.tv_sec)
    var remaining = budget
    func rec(_ dir: String, _ depth: Int) {
        guard depth < maxDepth, remaining > 0, let es = try? readDir(dir) else { return }
        for e in es where !e.isLink {
            remaining -= 1
            if remaining <= 0 { return }
            newest = max(newest, e.mtime)
            if e.isDir { rec(dir + "/" + e.name, depth + 1) }
        }
    }
    if (st.st_mode & S_IFMT) == S_IFDIR { rec(path, 0) }
    return Int(Date().timeIntervalSince1970 - Double(newest)) / 86_400
}

func statDays(_ path: String) -> (Int?, Int?) {
    var st = stat()
    guard stat(path, &st) == 0 else { return (nil, nil) }
    let now = Date().timeIntervalSince1970
    let a = Int((now - Double(st.st_atimespec.tv_sec)) / 86400)
    let m = Int((now - Double(st.st_mtimespec.tv_sec)) / 86400)
    return (a, m)
}

func pathExists(_ p: String) -> Bool {
    var st = stat(); return lstat(p, &st) == 0
}
func isDirectory(_ p: String) -> Bool {
    var st = stat(); return stat(p, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
}

final class PathTrie {
    final class Node {
        var children: [String: Node] = [:]; var marked = false
        /// 已经量过的子树：走到这里直接取用（MeasuredSubtrees.plant 种进来）
        var reused: MeasuredSubtrees.Entry?
    }
    let root = Node()
    func insert(_ path: String) {
        var n = root
        for c in path.split(separator: "/") { let k = String(c); if n.children[k] == nil { n.children[k] = Node() }; n = n.children[k]! }
        n.marked = true
    }
    func node(for path: String) -> Node? {
        var n = root
        for c in path.split(separator: "/") { guard let next = n.children[String(c)] else { return nil }; n = next }
        return n
    }
}

/// 清单统计时完整走过的子树：总大小，以及里面 depth 层以内、不小于 threshold 的目录。
/// 随后的完整遍历（按文件夹看）走到这些目录直接取用，不必把清单刚读过的几十万个目录再读一遍。
/// 只收没有多链接文件的子树：硬链接按 inode 只算一次、算在先见到的地方，有它的子树在两次遍历里可能算出不同大小；
/// 没有它的子树在哪次遍历里算都一样，所以取用后的结果和重新读一遍相同（期间磁盘没变的话）。
/// 一次扫描一份，用完即弃：隔得越久越可能过时
final class MeasuredSubtrees: @unchecked Sendable {
    struct Entry {
        let total: UInt64
        /// 子树里够大的目录（含子树根自己）和它相对子树根的层数；记到第 recorded 层、不小于 threshold
        let dirs: [(path: String, depth: Int, bytes: UInt64)]
        let recorded: Int, threshold: UInt64
    }
    let depth: Int, threshold: UInt64
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    /// 默认按"按文件夹看"的口径记：遍历记到第 6 层，子树最浅在第 1 层，所以子树里记 5 层；门槛 200 MB
    init(depth: Int = 5, threshold: UInt64 = 200_000_000) { self.depth = depth; self.threshold = threshold }

    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    func add(_ path: String, total: UInt64, dirs: [String: UInt64]) {
        let base = path.split(separator: "/").count
        let list = dirs.map { (path: $0.key, depth: $0.key.split(separator: "/").count - base, bytes: $0.value) }
        lock.lock(); defer { lock.unlock() }
        if entries[path] == nil { entries[path] = Entry(total: total, dirs: list, recorded: depth, threshold: threshold) }
    }

    /// 后一次测量读坏了同一棵子树：旧记录不再可信，丢掉，宁可下次重读也不拿旧结果充完整。
    /// 一起失效所有重叠的祖先和子树：晚一次读到子项失败，说明早先那次"完整"走过的父目录已经不能算完整；
    /// 反过来，父目录读坏时它里面记过的子树也不能再单独拿出来当完整证据。
    func discard(_ path: String) {
        let inside = path + "/"
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { key, _ in
            !(key == path || key.hasPrefix(inside) || path.hasPrefix(key + "/"))
        }
    }

    /// 把能取用的子树种进遍历的路径树。不能取用的：里面有要跳过的目录，或里面另有要单独记大小的目标；
    /// 遍历要的门槛比记下的低也不能取用。要的层数比记下的深的，到 merge 时按子树所在层判断
    func plant(in trie: PathTrie, targets: [String], skip: Set<String>, dirThreshold: UInt64) {
        guard dirThreshold >= threshold else { return }
        lock.lock(); let all = entries; lock.unlock()
        let blockers = Array(skip) + targets
        for (path, entry) in all {
            let inside = path + "/"
            guard !skip.contains(path), !blockers.contains(where: { $0.hasPrefix(inside) }) else { continue }
            let wasTarget = trie.node(for: path)?.marked == true
            trie.insert(path)                       // insert 会标成目标：只为了让遍历沿路拼出路径，标记恢复原样
            let node = trie.node(for: path)!
            node.marked = wasTarget
            node.reused = entry
        }
    }

    /// 子树根在遍历的第 depth 层（从遍历根算），取出遍历要记的那些目录；记下的层数不够遍历要的深度时返回 nil（照常读一遍）
    static func merge(_ entry: Entry, depth: Int, dirDepth: Int, dirThreshold: UInt64) -> [String: UInt64]? {
        guard dirDepth - depth <= entry.recorded, dirThreshold >= entry.threshold else { return nil }
        var out: [String: UInt64] = [:]
        for d in entry.dirs where depth + d.depth <= dirDepth && d.bytes >= dirThreshold { out[d.path] = d.bytes }
        return out
    }
}

struct SizeIndex {
    var targets: [String: UInt64] = [:]
    var dirs: [String: UInt64] = [:]
    /// 每个遍历根的总占用（根里的文件 + 同一挂载点内、没被跳过的第一层目录），`du -x` 口径
    var roots: [String: UInt64] = [:]
    /// 读不了的根、根里读不了的第一层目录，以及深层读坏时所属的并行任务路径：
    /// 它们的大小没算进来（根不会出现在 roots 里，绝不当成 0）。只记任务路径，不逐个记更深路径。
    var unreadable: [String] = []
    /// 产生 targets 的那次详细遍历（MeasuredTargets.batch）。缺省 nil = 没有同批证据：
    /// 谁都不能拿别处的 proof 往这份 index 上贴，只能走独立复核。
    /// 只活在内存里，不序列化、不写缓存，也不作为删除授权。
    var measurementBatch: UUID? = nil
}

extension SizeIndex {
    /// 从一次详细测量建索引：targets 与 batch 同源，sized 只有 batch 对得上才复用那次遍历的结论
    static func from(_ measurement: MeasuredTargets) -> SizeIndex {
        var index = SizeIndex()
        index.targets = measurement.sizes
        index.measurementBatch = measurement.batch
        return index
    }
    /// 这份 index 的 targets 是否就出自这次测量（nil 一律不信）
    func trusts(_ measurement: MeasuredTargets) -> Bool {
        measurementBatch.map { $0 == measurement.batch } ?? false
    }
}
