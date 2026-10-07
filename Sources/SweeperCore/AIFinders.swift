import Foundation

// MARK: - 项目和项目依赖

/// 找主目录里的项目文件夹（AI 工具帮你做的网站、小程序、脚本等），
/// 算出每个项目最后一次改动的时间，以及里面能重新生成的依赖目录
enum ProjectFinder {
    struct Project {
        let url: URL
        let lastActive: Date
        let dependencies: [URL]
    }

    /// 有这些文件之一的文件夹就算一个项目
    static let markers: Set<String> = [
        "package.json", "pyproject.toml", "requirements.txt", "Cargo.toml", "go.mod", "Package.swift",
        "index.html", "CLAUDE.md", "AGENTS.md", ".git",
    ]
    /// 主目录第一层里不去找项目的文件夹
    static let skipTop: Set<String> = ["Library", "Applications", "Movies", "Music", "Pictures", "Public"]

    /// 删了能重新安装或重新生成的目录。dist、build 这类可能是你要交付的成果，不算
    static let alwaysDependency: Set<String> = [
        "node_modules", ".next", ".nuxt", ".turbo", ".parcel-cache", ".svelte-kit", ".vite", ".expo",
        "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", "DerivedData", ".gradle",
    ]
    /// 只有旁边有对应文件时才算依赖，比如 target 旁边要有 Cargo.toml
    static let dependencyIfSibling: [String: String] = [
        "target": "Cargo.toml", ".build": "Package.swift", "Pods": "Podfile",
    ]

    // 一次扫描里两条规则都要用，结果缓存两分钟，避免把主目录走两遍
    private static let lock = NSLock()
    private static var cached: (time: Date, projects: [Project])?

    static func all() -> [Project] {
        lock.lock(); defer { lock.unlock() }
        if let c = cached, Date().timeIntervalSince(c.time) < 120 { return c.projects }
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots: [URL] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        where !name.hasPrefix(".") && !skipTop.contains(name) {
            findRoots(home.appendingPathComponent(name), depth: 1, into: &roots)
        }
        let projects = roots.map(inspect)
        cached = (Date(), projects)
        return projects
    }

    static func dependencies(inactiveDays: Int) -> [Candidate] {
        let cutoff = Date().addingTimeInterval(-Double(inactiveDays) * 86_400)
        return all().filter { $0.lastActive < cutoff }.flatMap { p in
            p.dependencies.map { dep in
                let inner = String(dep.path.dropFirst(p.url.path.count + 1))
                return Candidate(url: dep, label: "\(p.url.lastPathComponent) › \(inner)", modified: p.lastActive)
            }
        }
    }

    static func staleProjects(inactiveDays: Int) -> [Candidate] {
        let cutoff = Date().addingTimeInterval(-Double(inactiveDays) * 86_400)
        return all().filter { $0.lastActive < cutoff }.map { Candidate(url: $0.url, modified: $0.lastActive) }
    }

    /// 往下找项目根目录，找到就不再往里找（项目里的子项目算同一个）
    private static func findRoots(_ dir: URL, depth: Int, into roots: inout [URL]) {
        guard depth <= 6, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        if !markers.isDisjoint(with: names) { roots.append(dir); return }
        for name in names where !name.hasPrefix(".") && !alwaysDependency.contains(name) {
            let url = dir.appendingPathComponent(name)
            if isPlainDirectory(url) { findRoots(url, depth: depth + 1, into: &roots) }
        }
    }

    /// App、照片图库这类“看起来是一个文件”的包，不进去，按一个整体看它的修改时间
    static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "photoslibrary", "xcarchive", "fcpbundle", "logicx", "rtfd", "pkg",
    ]

    /// 走一遍项目：记下依赖目录（不进去），其余文件里最新的修改时间就是项目最后活跃的时间。
    /// 用 fts 遍历，比逐个读文件信息快
    static func inspect(_ root: URL) -> Project {
        var deps: [URL] = []
        var newest: Int = 0   // 秒
        let fm = FileManager.default
        FTS.walk(root.path) { entry, path, level in
            let name = (path as NSString).lastPathComponent
            let mtime = Int(entry.pointee.fts_statp.pointee.st_mtimespec.tv_sec)
            switch Int32(entry.pointee.fts_info) {
            case FTS_D:
                guard level > 0 else { return .next }
                if name == ".git" { return .skip }
                let parent = (path as NSString).deletingLastPathComponent
                if alwaysDependency.contains(name)
                    || dependencyIfSibling[name].map({ fm.fileExists(atPath: parent + "/" + $0) }) == true
                    || ((name == ".venv" || name == "venv") && fm.fileExists(atPath: path + "/pyvenv.cfg")) {
                    deps.append(URL(fileURLWithPath: path))
                    return .skip
                }
                if packageExtensions.contains((name as NSString).pathExtension.lowercased()) {
                    newest = max(newest, mtime)
                    return .skip
                }
            case FTS_F, FTS_DEFAULT:
                if name != ".DS_Store" { newest = max(newest, mtime) }
            default:
                break
            }
            return .next
        }
        let lastActive = newest > 0 ? Date(timeIntervalSince1970: TimeInterval(newest)) : .distantPast
        return Project(url: root, lastActive: lastActive, dependencies: deps)
    }

    private static func isPlainDirectory(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
        return v?.isDirectory == true && v?.isSymbolicLink != true && v?.isPackage != true
    }
}

// MARK: - Codex 旧对话

enum CodexFinder {
    /// ~/.codex/sessions/年/月 里，整个月都早于 olderThanDays 天前的月份
    static func oldSessionMonths(olderThanDays days: Int) -> [Candidate] {
        let base = Scanner.expand("~/.codex/sessions")
        let fm = FileManager.default
        let cal = Calendar(identifier: .gregorian)
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var found: [Candidate] = []
        for year in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] {
            guard let y = Int(year) else { continue }
            let yearURL = base.appendingPathComponent(year)
            for month in (try? fm.contentsOfDirectory(atPath: yearURL.path)) ?? [] {
                guard let m = Int(month),
                      let start = cal.date(from: DateComponents(year: y, month: m, day: 1)),
                      let next = cal.date(byAdding: .month, value: 1, to: start),
                      next < cutoff
                else { continue }
                let url = yearURL.appendingPathComponent(month)
                let count = fm.enumerator(atPath: url.path)?.allObjects
                    .filter { ($0 as? String)?.hasSuffix(".jsonl") == true }.count ?? 0
                found.append(Candidate(url: url, label: L("%ld 年 %ld 月的对话（%ld 个）", y, m, count),
                                       modified: next.addingTimeInterval(-1)))
            }
        }
        return found
    }
}

// MARK: - 已卸载 AI 工具的残留

enum ToolTraceFinder {
    static func find(_ traces: [ToolTrace]) -> [Candidate] {
        let installed = AppInventory.scan().names
        let fm = FileManager.default
        var found: [Candidate] = []
        for trace in traces where !trace.appNames.contains(where: { installed.contains($0.lowercased()) }) {
            for path in trace.paths {
                let url = Scanner.expand(path)
                guard fm.fileExists(atPath: url.path) else { continue }
                // 里面装着命令行工具（bin 目录）的不动，比如 ~/.deskclaw 里装着 claude、codex 命令
                if containsCommandLineTools(url) { continue }
                found.append(Candidate(url: url, label: "\(trace.name) · \(url.lastPathComponent)"))
            }
        }
        return found
    }

    static func containsCommandLineTools(_ dir: URL) -> Bool {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [], errorHandler: { _, _ in true })
        else { return false }
        while let url = e.nextObject() as? URL {
            if e.level > 3 { e.skipDescendants(); continue }
            if url.lastPathComponent == "bin",
               let names = try? FileManager.default.contentsOfDirectory(atPath: url.path), !names.isEmpty {
                return true
            }
            if url.lastPathComponent == "node_modules" { e.skipDescendants() }
        }
        return false
    }
}

// MARK: - 旧版本

enum VersionFinder {
    /// 每个目录下按版本号命名的子文件夹（如 2.1.288、2.1.289），保留最新的，其余列出来。
    /// 正在被运行中的程序用到的版本也跳过
    static func olderVersions(in dirs: [String]) -> [Candidate] {
        let running = runningCommandLines()
        var found: [Candidate] = []
        for dir in dirs {
            let base = Scanner.expand(dir)
            let versions = ((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [])
                .filter { $0.first?.isNumber == true }
                .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
            for v in versions.dropLast() {
                let url = base.appendingPathComponent(v)
                if running.contains(where: { $0.contains(url.path + "/") }) { continue }
                found.append(Candidate(url: url, label: "\(base.lastPathComponent) \(v)"))
            }
        }
        return found
    }

    /// 所有正在运行的进程的完整命令行
    static func runningCommandLines() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "command"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}

// MARK: - 失效的命令链接

enum BrokenLinkFinder {
    /// 目录里的符号链接，指向的文件已经不存在（App 删了，命令还留着）
    static func find(in dirs: [String]) -> [Candidate] {
        let fm = FileManager.default
        var found: [Candidate] = []
        for dir in dirs {
            let base = Scanner.expand(dir)
            for name in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] {
                let url = base.appendingPathComponent(name)
                guard let target = try? fm.destinationOfSymbolicLink(atPath: url.path) else { continue }
                let resolved = target.hasPrefix("/") ? target
                    : (base.path as NSString).appendingPathComponent(target)
                if !fm.fileExists(atPath: resolved) {
                    found.append(Candidate(url: url, label: "\(name) → \(target)"))
                }
            }
        }
        return found
    }
}
