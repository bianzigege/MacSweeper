import Foundation

/// 一个文件被移到了废纸篓的哪里
public struct TrashMove: Codable, Sendable, Equatable {
    public let original: String
    public let inTrash: String
    public let bytes: Int64

    public init(original: String, inTrash: String, bytes: Int64) {
        self.original = original
        self.inTrash = inTrash
        self.bytes = bytes
    }
}

/// 一次清理（或卸载、重复文件清理）移走的所有文件
public struct TrashBatch: Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case clean, uninstall, duplicates
    }

    public let id: UUID
    public let date: Date
    public let kind: Kind
    /// 给人看的名字，比如“清理垃圾”“卸载 钉钉”
    public let title: String
    public let moves: [TrashMove]

    public init(id: UUID = UUID(), date: Date = Date(), kind: Kind, title: String, moves: [TrashMove]) {
        self.id = id
        self.date = date
        self.kind = kind
        self.title = title
        self.moves = moves
    }

    public var bytes: Int64 { moves.reduce(0) { $0 + $1.bytes } }

    /// 还能撤销：至少有一个文件还在废纸篓里
    public var isRestorable: Bool {
        moves.contains { FileManager.default.fileExists(atPath: $0.inTrash) }
    }

    // 旧版（0.7–0.11）的记录没有 id、kind、title，读的时候补上
    private enum Keys: String, CodingKey { case id, date, kind, title, moves }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decode(Date.self, forKey: .date)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .clean
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "清理垃圾"
        moves = try c.decode([TrashMove].self, forKey: .moves)
    }
}

public struct UndoReport: Sendable {
    public var restoredCount = 0
    public var restoredBytes: Int64 = 0
    /// 废纸篓已经清空，找不到了
    public var goneCount = 0
    /// 原位置已经有同名文件（比如 App 又重新生成了缓存），没有覆盖
    public var occupiedCount = 0
    public var failures: [(path: String, reason: String)] = []
}

/// 撤销历史：每次清理一条记录，可以逐条撤销。
/// 存在 ~/Library/Application Support/MacSweeper/trash-history.json，App 重开后也能撤销
public enum Undo {
    public static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MacSweeper/trash-history.json")
    /// 0.11 以前只记一次的旧文件，第一次读到时并进历史
    static let legacyFile = file.deletingLastPathComponent().appendingPathComponent("last-clean.json")
    /// 最多留多少条
    static let keep = 30

    private static let lock = NSLock()

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// 所有记录，最近的在前（包括已经撤销不了的，界面自己按 isRestorable 过滤）
    static func loadAll() -> [TrashBatch] {
        var all = (try? Data(contentsOf: file)).flatMap { try? decoder.decode([TrashBatch].self, from: $0) } ?? []
        if let data = try? Data(contentsOf: legacyFile), let old = try? decoder.decode(TrashBatch.self, from: data) {
            all.append(old)
            try? FileManager.default.removeItem(at: legacyFile)
            write(all)
        }
        return all.sorted { $0.date > $1.date }
    }

    private static func write(_ batches: [TrashBatch]) {
        guard let data = try? encoder.encode(batches) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    static func save(_ batch: TrashBatch) {
        lock.lock(); defer { lock.unlock() }
        var all = loadAll()
        all.insert(batch, at: 0)
        // 撤销不了的旧记录（废纸篓已清空）顺手清掉，只留最近 keep 条
        all = Array(all.filter(\.isRestorable).prefix(keep))
        if !all.contains(where: { $0.id == batch.id }) { all.insert(batch, at: 0) }
        write(all)
    }

    /// 还能撤销的记录，最近的在前
    public static func history() -> [TrashBatch] {
        lock.lock(); defer { lock.unlock() }
        return loadAll().filter(\.isRestorable)
    }

    /// 最近一次还能撤销的记录
    public static func lastBatch() -> TrashBatch? { history().first }

    /// 撤销某一条，完成后从历史里去掉
    public static func restore(id: UUID) -> UndoReport? {
        guard let batch = history().first(where: { $0.id == id }) else { return nil }
        // 卸载的 App 要放回“应用程序”文件夹，所以除了主目录，也允许放回 App 的位置
        let report = restore(batch.moves, allowed: { PathGuard.isAllowed($0) || PathGuard.isAllowedApp($0) })
        lock.lock()
        write(loadAll().filter { $0.id != id })
        lock.unlock()
        return report
    }

    /// 撤销最近一次
    public static func restoreLast() -> UndoReport? {
        guard let batch = lastBatch() else { return nil }
        return restore(id: batch.id)
    }

    /// 把文件从废纸篓放回原处。只放回允许的位置，原位置已有东西就不覆盖
    static func restore(_ moves: [TrashMove], allowed: (URL) -> Bool = PathGuard.isAllowed) -> UndoReport {
        let fm = FileManager.default
        var report = UndoReport()
        for move in moves {
            let from = URL(fileURLWithPath: move.inTrash)
            let to = URL(fileURLWithPath: move.original)
            guard from.path.contains("/.Trash/"), allowed(to) else {
                report.failures.append((move.original, L("不在允许范围内")))
                continue
            }
            guard fm.fileExists(atPath: from.path) || (try? fm.destinationOfSymbolicLink(atPath: from.path)) != nil else {
                report.goneCount += 1
                continue
            }
            if fm.fileExists(atPath: to.path) || (try? fm.destinationOfSymbolicLink(atPath: to.path)) != nil {
                report.occupiedCount += 1
                continue
            }
            do {
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: from, to: to)
                report.restoredCount += 1
                report.restoredBytes += move.bytes
                OperationLog.write("RESTORE \(move.bytes) \(to.path)")
            } catch {
                report.failures.append((move.original, error.localizedDescription))
            }
        }
        return report
    }
}
