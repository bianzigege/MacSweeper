import Foundation

/// 计算文件和文件夹实际占用的磁盘空间（不跟随符号链接，和“显示简介”里的“磁盘上”一致）。
///
/// 用系统底层的 fts 遍历（du 命令用的就是它），比 FileManager 逐个读文件信息快一倍左右。
/// 一次扫描共用一个计算器，并记住每个算过的文件夹：之后再算它，或者算它的上级文件夹时，
/// 遇到算过的直接用记下的数，不再往里走（比如先算了“微信内置浏览器缓存”，再算“微信数据（全部）”）
final class SizeCalculator: @unchecked Sendable {
    private var cache: [String: Int64] = [:]
    private let lock = NSLock()

    func size(of url: URL) -> Int64 {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return 0 }
        switch st.st_mode & S_IFMT {
        case S_IFLNK: return 0
        case S_IFDIR: return directorySize(url.path)
        default: return Int64(st.st_blocks) * 512
        }
    }

    private func cached(_ path: String) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return cache[path]
    }

    private func directorySize(_ root: String) -> Int64 {
        if let known = cached(root) { return known }
        var total: Int64 = 0
        var linked = Set<UInt64>()   // 硬链接（同一个文件的几个名字）只算一次
        FTS.walk(root) { entry, path, level in
            switch Int32(entry.pointee.fts_info) {
            case FTS_D:
                // 子文件夹之前算过，直接加上，不再进去
                if level > 0, let known = cached(path) {
                    total += known
                    return .skip
                }
            case FTS_F, FTS_DEFAULT:
                let st = entry.pointee.fts_statp.pointee
                if st.st_nlink > 1 && !linked.insert(UInt64(st.st_ino)).inserted { break }
                total += Int64(st.st_blocks) * 512
            default:
                break
            }
            return .next
        }
        lock.lock(); cache[root] = total; lock.unlock()
        return total
    }
}

/// fts 的简单封装：不跟随符号链接，回调里可以决定跳过某个文件夹
enum FTS {
    enum Step { case next, skip }

    /// - xdev：不跨到别的磁盘（比如外接硬盘、挂载的网络盘）
    static func walk(_ root: String, xdev: Bool = false,
                     _ visit: (UnsafeMutablePointer<FTSENT>, String, Int) -> Step) {
        guard let rootPath = strdup(root) else { return }
        defer { free(rootPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [rootPath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | (xdev ? FTS_XDEV : 0), nil) else { return }
        defer { fts_close(fts) }
        while let entry = fts_read(fts) {
            let path = String(cString: entry.pointee.fts_path)
            if visit(entry, path, Int(entry.pointee.fts_level)) == .skip,
               Int32(entry.pointee.fts_info) == FTS_D {
                fts_set(fts, entry, FTS_SKIP)
            }
        }
    }
}
