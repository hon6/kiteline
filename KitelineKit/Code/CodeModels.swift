import Foundation

/// 代码 IDE 的数据：仓库概览、提交图、提交详情、对比、可编辑的文件（接口见 Sources/MobileServer.swift 的 /api/repo、/api/fs）

struct RepoChange: Decodable, Hashable, Identifiable {
    var path: String
    var status: String
    var oldPath: String?
    var add: Int
    var del: Int
    var binary: Bool
    var id: String { status + ":" + path }
    var name: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        path = c.text("path") ?? ""
        status = c.text("status") ?? "M"
        oldPath = c.text("oldPath").flatMap { $0.isEmpty ? nil : $0 }
        add = c.int("add")
        del = c.int("del")
        binary = c.one("binary") ?? false
    }
}

struct RepoBranch: Decodable, Hashable, Identifiable {
    var name: String
    var hash: String
    var upstream: String?
    var ahead: Int
    var behind: Int
    var gone: Bool
    var ts: Double?
    var subject: String
    var current: Bool
    /// 在哪个工作树里检出着（当前目录或别的工作树）
    var worktree: String?
    var id: String { name }

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        name = c.text("name") ?? ""
        hash = c.text("hash") ?? ""
        upstream = c.text("upstream")
        ahead = c.int("ahead"); behind = c.int("behind")
        gone = c.one("gone") ?? false
        ts = c.one("ts")
        subject = c.text("subject") ?? ""
        current = c.one("current") ?? false
        worktree = c.text("worktree").flatMap { $0.isEmpty ? nil : $0 }
    }
}

struct RepoRemoteBranch: Decodable, Hashable, Identifiable {
    var name: String
    var remote: String
    var branch: String
    var hash: String
    var ts: Double?
    var subject: String
    var id: String { name }

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        name = c.text("name") ?? ""
        remote = c.text("remote") ?? ""
        branch = c.text("branch") ?? name
        hash = c.text("hash") ?? ""
        ts = c.one("ts")
        subject = c.text("subject") ?? ""
    }
}

struct RepoTag: Decodable, Hashable, Identifiable {
    var name: String
    var hash: String
    var ts: Double?
    var subject: String
    var id: String { name }

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        name = c.text("name") ?? ""
        hash = c.text("hash") ?? ""
        ts = c.one("ts")
        subject = c.text("subject") ?? ""
    }
}

struct RepoStash: Decodable, Hashable, Identifiable {
    var ref: String
    var hash: String
    var ts: Double?
    var title: String
    var id: String { ref }

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        ref = c.text("ref") ?? "stash@{0}"
        hash = c.text("hash") ?? ""
        ts = c.one("ts")
        title = c.text("title") ?? ""
    }
}

struct RepoWorktree: Decodable, Hashable, Identifiable {
    var path: String
    var head: String
    var branch: String?
    var detached: Bool
    var locked: Bool
    var prunable: Bool
    var main: Bool
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        path = c.text("path") ?? ""
        head = c.text("head") ?? ""
        branch = c.text("branch")
        detached = c.one("detached") ?? false
        locked = c.one("locked") ?? false
        prunable = c.one("prunable") ?? false
        main = c.one("main") ?? false
    }
}

/// 这台电脑上一个正在跑的会话在仓库的哪个工作树、哪个分支
struct RepoSessionLink: Decodable, Hashable {
    var sessionId: String
    var worktree: String
    var branch: String?
    var detached: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        sessionId = c.text("sessionId") ?? ""
        worktree = c.text("worktree") ?? ""
        branch = c.text("branch")
        detached = c.text("detached")
    }
}

struct RepoRemote: Decodable, Hashable {
    var name: String
    var url: String
}

struct RepoOverview: Decodable {
    var repo: String?
    var reason: String?
    var name: String
    var branch: String?
    var oid: String?
    var upstream: String?
    var ahead: Int
    var behind: Int
    var staged: [RepoChange]
    var unstaged: [RepoChange]
    var untracked: [RepoChange]
    var untrackedCount: Int
    var conflicts: [RepoChange]
    /// 进行到一半的操作：merge / rebase / cherry-pick / revert
    var state: String?
    var mergeMessage: String?
    var remotes: [RepoRemote]
    var branches: [RepoBranch]
    var remoteBranches: [RepoRemoteBranch]
    var tags: [RepoTag]
    var stashes: [RepoStash]
    var worktrees: [RepoWorktree]
    var sessions: [RepoSessionLink]
    var identityMissing: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        repo = c.text("repo")
        reason = c.text("reason")
        name = c.text("name") ?? (repo.map { ($0 as NSString).lastPathComponent } ?? "")
        branch = c.text("branch")
        oid = c.text("oid")
        upstream = c.text("upstream")
        ahead = c.int("ahead"); behind = c.int("behind")
        staged = c.list("staged"); unstaged = c.list("unstaged"); untracked = c.list("untracked")
        untrackedCount = c.int("untrackedCount")
        conflicts = c.list("conflicts")
        state = c.text("state")
        mergeMessage = c.text("mergeMessage")
        remotes = c.list("remotes"); branches = c.list("branches"); remoteBranches = c.list("remoteBranches")
        tags = c.list("tags"); stashes = c.list("stashes"); worktrees = c.list("worktrees"); sessions = c.list("sessions")
        let identity: [String: String] = c.one("identity") ?? [:]
        identityMissing = repo != nil && ((identity["name"] ?? "").isEmpty || (identity["email"] ?? "").isEmpty)
    }

    /// 工作区里还没暂存的（改过的 + 新文件）
    var changes: [RepoChange] { unstaged + untracked }
    var changeCount: Int { staged.count + unstaged.count + untrackedCount + conflicts.count }
    var currentBranch: RepoBranch? { branches.first(where: \.current) }
}

/// 提交图里一行要画的东西：圆点在第几列、什么颜色；线段 [x1, y1, x2, y2, 颜色]（y：0 上沿 / 1 圆点 / 2 下沿）
struct GraphRow: Decodable, Hashable {
    var col: Int
    var color: Int
    var segs: [[Int]]

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        col = c.int("col"); color = c.int("color")
        segs = c.list("segs")
    }
}

struct RefLabel: Decodable, Hashable {
    /// branch / remote / tag / head
    var type: String
    var name: String
    var current: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        type = c.text("type") ?? "branch"
        name = c.text("name") ?? ""
        current = c.one("current") ?? false
    }
}

struct CommitRow: Decodable, Hashable, Identifiable {
    var hash: String
    var short: String
    var parents: [String]
    var author: String
    var email: String
    var ts: Double?
    var refs: [RefLabel]
    var subject: String
    var graph: GraphRow?
    var id: String { hash }

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        hash = c.text("hash") ?? ""
        short = c.text("short") ?? String(hash.prefix(8))
        parents = c.list("parents")
        author = c.text("author") ?? ""
        email = c.text("email") ?? ""
        ts = c.one("ts")
        refs = c.list("refs")
        subject = c.text("subject") ?? ""
        graph = c.one("graph")
    }
}

struct LogPage: Decodable {
    var commits: [CommitRow]
    var width: Int
    var more: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        commits = c.list("commits")
        width = c.int("width")
        more = c.one("more") ?? false
    }
}

struct CommitInfo: Decodable {
    var hash: String
    var parents: [String]
    var author: String
    var email: String
    var ts: Double?
    var committer: String
    var committedAt: Double?
    var refs: [RefLabel]
    var message: String
    var files: [RepoChange]
    var branches: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        hash = c.text("hash") ?? ""
        parents = c.list("parents")
        author = c.text("author") ?? ""
        email = c.text("email") ?? ""
        ts = c.one("ts")
        committer = c.text("committer") ?? ""
        committedAt = c.one("committedAt")
        refs = c.list("refs")
        message = c.text("fullMessage") ?? ""
        files = c.list("files")
        branches = c.list("branches")
    }

    var subject: String { message.components(separatedBy: "\n").first ?? "" }
}

struct DiffPayload: Decodable {
    var diff: String
    var path: String
    var mode: String
    var hunks: [String]
    var binary: Bool
    var original: String?
    var modified: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        diff = c.text("diff") ?? ""
        path = c.text("path") ?? ""
        mode = c.text("mode") ?? "unstaged"
        hunks = c.list("hunks")
        binary = c.one("binary") ?? false
        original = c.text("original")
        modified = c.text("modified")
    }
}

/// 打开来编辑的文件（/api/file?edit=1）
struct EditableFile: Decodable {
    var path: String
    var name: String
    var size: Int
    var mtime: Double?
    var text: String?
    var sha: String?
    var eol: String?
    var lossy: Bool
    var truncated: Bool
    var secret: Bool
    var image: Bool
    var binary: Bool
    var tooLarge: Bool
    var lines: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        path = c.text("path") ?? ""
        name = c.text("name") ?? (path as NSString).lastPathComponent
        size = c.int("size")
        mtime = c.one("mtime")
        text = c.text("text")
        sha = c.text("sha")
        eol = c.text("eol")
        lossy = c.one("lossy") ?? false
        truncated = c.one("truncated") ?? false
        secret = c.one("secret") ?? false
        image = c.one("image") ?? false
        binary = c.one("binary") ?? false
        tooLarge = c.one("tooLarge") ?? false
        lines = c.int("lines")
    }

    /// 能不能在这里改：完整读到了、按 UTF-8 无损
    var editable: Bool { text != nil && !truncated && !lossy }
}

/// 目录里的一项（/api/files）
struct CodeEntry: Decodable, Hashable {
    var name: String
    var type: String
    var size: Int
    var mtime: Double?
    var git: String?
    var link: Bool
    var isDir: Bool { type == "dir" }

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        name = c.text("name") ?? ""
        type = c.text("type") ?? "file"
        size = c.int("size")
        mtime = c.one("mtime")
        git = c.text("git")
        link = c.one("link") ?? false
    }
}

struct CodeListing: Decodable {
    var path: String
    var root: String
    var entries: [CodeEntry]
    var truncated: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        path = c.text("path") ?? ""
        root = c.text("root") ?? ""
        entries = c.list("entries")
        truncated = c.one("truncated") ?? false
    }
}

/// Git 报错：一句能看懂的话 + git 的原话（冲突的文件、钩子的输出）
struct GitError: LocalizedError {
    var message: String
    var detail: String?
    var errorDescription: String? { message }
}

/// /api/repo、/api/fs 的调用
@MainActor
enum CodeAPI {
    /// 慢的操作（要连远端、要跑提交钩子）：先拿任务号，再一秒问一次结果。手机那边的请求等不了几分钟
    static let slowOps: Set<String> = ["push", "pull", "fetch", "remote_branch_delete", "commit", "merge", "rebase", "cherry_pick",
                                       "revert", "continue", "skip", "worktree_add"]

    static func overview(_ model: AppModel, key: String) async throws -> RepoOverview {
        try await model.api.get(RepoOverview.self, "/api/repo", ["key": key, "op": "overview"])
    }

    static func log(_ model: AppModel, key: String, skip: Int = 0, limit: Int = 200, path: String? = nil, query: String? = nil, ref: String? = nil) async throws -> LogPage {
        var q = ["key": key, "op": "log", "skip": "\(skip)", "limit": "\(limit)"]
        if let path { q["path"] = path }
        if let query, !query.isEmpty { q["q"] = query }
        if let ref { q["ref"] = ref }
        return try await model.api.get(LogPage.self, "/api/repo", q)
    }

    static func commit(_ model: AppModel, key: String, hash: String) async throws -> CommitInfo {
        try await model.api.get(CommitInfo.self, "/api/repo", ["key": key, "op": "commit_info", "commit": hash])
    }

    /// mode：unstaged / staged / untracked / commit
    static func diff(_ model: AppModel, key: String, path: String, mode: String, commit: String? = nil, oldPath: String? = nil) async throws -> DiffPayload {
        var q = ["key": key, "op": "diff", "path": path, "mode": mode]
        if let commit { q["commit"] = commit }
        if let oldPath { q["oldPath"] = oldPath }
        return try await model.api.get(DiffPayload.self, "/api/repo", q)
    }

    /// 会改仓库的操作；Git 报错抛 GitError
    @discardableResult
    static func run(_ model: AppModel, key: String, _ op: String, _ body: [String: Any] = [:]) async throws -> [String: Any] {
        var payload = body
        payload["op"] = op
        if slowOps.contains(op) {
            payload["job"] = true
            let started = try await model.api.post("/api/repo", ["key": key], body: payload)
            guard let job = started["job"] as? String else { return try check(started) }
            let deadline = Date().addingTimeInterval(330)
            while Date() < deadline {
                try await Task.sleep(for: .milliseconds(700))
                let state = try await model.api.get("/api/repo", ["key": key, "op": "job", "job": job])
                guard state["done"] as? Bool == true else { continue }
                if state["failed"] as? Bool == true {
                    throw GitError(message: state["error"] as? String ?? L("操作失败"), detail: state["detail"] as? String)
                }
                return state["result"] as? [String: Any] ?? [:]
            }
            throw GitError(message: L("操作超时：电脑上的 Git 仍在运行，请稍后刷新查看"), detail: nil)
        }
        return try check(try await model.api.post("/api/repo", ["key": key], body: payload))
    }

    private static func check(_ reply: [String: Any]) throws -> [String: Any] {
        if reply["failed"] as? Bool == true {
            throw GitError(message: reply["error"] as? String ?? L("操作失败"), detail: reply["detail"] as? String)
        }
        return reply
    }

    @discardableResult
    static func fs(_ model: AppModel, key: String, _ op: String, _ body: [String: Any] = [:]) async throws -> [String: Any] {
        var payload = body
        payload["op"] = op
        return try await model.api.post("/api/fs", ["key": key], body: payload)
    }

    static func list(_ model: AppModel, key: String, path: String) async throws -> CodeListing {
        try await model.api.get(CodeListing.self, "/api/files", ["key": key, "path": path])
    }

    static func open(_ model: AppModel, key: String, path: String, reveal: Bool = false) async throws -> EditableFile {
        var q = ["key": key, "path": path, "edit": "1"]
        if reveal { q["reveal"] = "1" }
        return try await model.api.get(EditableFile.self, "/api/file", q)
    }
}

/// 改动状态的字母 → 界面上的字和颜色（同 VS Code：M 改 / A 增 / D 删 / R 名 / U 冲突 / ? 新）
enum ChangeMark {
    static func label(_ status: String) -> String {
        switch status {
        case "M", "T": "M"
        case "A": "A"
        case "D": "D"
        case "R": "R"
        case "C": "C"
        case "U": "!"
        case "?", "??": "U"
        default: status
        }
    }

    static func describe(_ status: String) -> String {
        switch status {
        case "M", "T": L("已修改")
        case "A": L("已添加")
        case "D": L("已删除")
        case "R": L("已重命名")
        case "C": L("已复制")
        case "U": L("冲突")
        case "?", "??": L("未跟踪")
        default: status
        }
    }
}
