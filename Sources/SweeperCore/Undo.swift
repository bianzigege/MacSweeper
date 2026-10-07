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

/// 一次清理移走的所有文件
public struct TrashBatch: Codable, Sendable {
    public let date: Date
    public let moves: [TrashMove]

    public var bytes: Int64 { moves.reduce(0) { $0 + $1.bytes } }
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

/// 撤销上次清理：把上一次移到废纸篓的文件放回原处。
/// 记录存在 ~/Library/Application Support/MacSweeper/last-clean.json，App 重开后也能撤销
public enum Undo {
    public static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MacSweeper/last-clean.json")

    static func save(_ batch: TrashBatch) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(batch) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// 上一次清理的记录；没有、或者废纸篓里已经一个都找不到了，返回 nil
    public static func lastBatch() -> TrashBatch? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let batch = try? decoder.decode(TrashBatch.self, from: data) else { return nil }
        return batch.moves.contains { FileManager.default.fileExists(atPath: $0.inTrash) } ? batch : nil
    }

    /// 撤销上一次清理，完成后清掉记录
    public static func restoreLast() -> UndoReport? {
        guard let batch = lastBatch() else { return nil }
        let report = restore(batch.moves)
        try? FileManager.default.removeItem(at: file)   // 只删撤销记录这个小文件
        return report
    }

    /// 把文件从废纸篓放回原处。只放回主目录里允许的位置，原位置已有东西就不覆盖
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
