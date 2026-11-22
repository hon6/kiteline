import AppKit
import SwiftUI
import KitelineKit
import UniformTypeIdentifiers

/// 别的 App 经系统共享菜单发给 Kiteline 的东西（微信「转发到其他应用 → 选择电脑中的应用 → Kiteline」、访达「共享」……）。
/// 共享扩展（ShareExtension/）把文件拷进 ShareInbox/<编号>/、清单写进 ShareInbox/<编号>.json，再用 kiteline://share?id=<编号> 唤起这里；
/// 这里弹「发送到会话」面板：发给一个已有会话，或者带着内容去「新任务」选项目、Agent 新建会话（同 iPhone「用其他应用打开」）
struct SharedPayload: Identifiable {
    struct File: Identifiable {
        let id = UUID()
        let url: URL
        let name: String
        let size: Int
        var isImage: Bool { UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true }
    }

    let id: String
    var text: String
    var files: [File]
    /// 收件目录（发完、取消后删掉）
    let dir: URL

    /// 电脑那头一个文件最多收 25 MB；一次请求的总量也有上限（转成 base64 后要在本机服务的 48 MB 以内），同 iPhone
    static let maxFile = 25 * 1024 * 1024
    static let maxTotal = 28 * 1024 * 1024
}

enum ShareInbox {
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/TARS/ShareInbox", isDirectory: true)
    }

    /// 扩展写得进去的前提是目录在（它的沙盒例外只覆盖这个目录）；顺手清掉一天前没处理的。
    /// 系统对新装的第三方共享扩展常常默认不开（共享菜单里看不到）：第一次启动时替它打开一次，以后用户在系统设置里关掉的不再动
    static func prepare() {
        let defaults = UserDefaults.standard
        if !AppConfig.isolated, !defaults.bool(forKey: "kitelineShareEnabled") {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
                task.arguments = ["-e", "use", "-i", "com.mrhong.tars.share"]
                try? task.run()
                task.waitUntilExit()
                // 成功了才记下（刚装好时系统可能还没登记扩展，下次启动再试）
                if task.terminationStatus == 0 { UserDefaults.standard.set(true, forKey: "kitelineShareEnabled") }
                Log.write("共享扩展：已在系统共享菜单中启用（pluginkit 退出码 \(task.terminationStatus)）")
            }
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let old = Date().addingTimeInterval(-86400)
        for url in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < old {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// kiteline://share?id=<编号>：读出扩展放进来的东西
    static func parse(_ url: URL) -> SharedPayload? {
        guard url.scheme?.lowercased() == "kiteline", url.host?.lowercased() == "share",
              let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value,
              UUID(uuidString: id) != nil else { return nil }
        let dir = root.appendingPathComponent(id, isDirectory: true)
        guard let data = try? Data(contentsOf: root.appendingPathComponent(id + ".json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let files = ((manifest["files"] as? [String]) ?? []).compactMap { name -> SharedPayload.File? in
            let url = dir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return SharedPayload.File(url: url, name: name, size: size)
        }
        return SharedPayload(id: id, text: manifest["text"] as? String ?? "", files: files, dir: dir)
    }

    /// 发完、取消：收件目录和清单都删掉
    static func discard(_ payload: SharedPayload) {
        try? FileManager.default.removeItem(at: payload.dir)
        try? FileManager.default.removeItem(at: root.appendingPathComponent(payload.id + ".json"))
    }

    /// 读出来分成图和文件：图照对话里发图那样压缩（最多 6 张，多的和解不开的当文件发）
    static func load(_ files: [SharedPayload.File]) -> (images: [TarsTaskImage], files: [(name: String, data: Data)]) {
        var images: [TarsTaskImage] = []
        var others: [(name: String, data: Data)] = []
        for file in files {
            guard let data = try? Data(contentsOf: file.url) else { continue }
            if file.isImage, images.count < TarsTaskInput.maxImages {
                let base = (file.name as NSString).deletingPathExtension
                if let image = TarsTaskImage.make(data, name: (base.isEmpty ? "image" : base) + ".jpg") {
                    images.append(image); continue
                }
            }
            others.append((file.name, data))
        }
        return (images, others)
    }
}

/// 「发送到会话」面板（Mac）：收到的内容 + 补充说明 + 发到哪儿（已有会话 / 新建会话）
struct ShareSheet: View {
    @ObservedObject var model = KitelineModel.shared
    @State private var payload: SharedPayload?
    @State private var text = ""
    @State private var target = "session"
    @State private var picked: String?
    @State private var query = ""
    @State private var sending = false
    @State private var message: String?

    private var files: [SharedPayload.File] { payload?.files ?? [] }
    private var total: Int { files.reduce(0) { $0 + $1.size } }
    private var tooLarge: Bool { files.contains { $0.size > SharedPayload.maxFile && !$0.isImage } || total > SharedPayload.maxTotal }
    private var hasContent: Bool { !files.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// 能发的会话：能回复的、不是群和代码标签；搜索按标题、项目、电脑
    private var sessions: [SessionItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return model.sessions.filter { $0.canReply && !$0.readOnly }
            .filter { q.isEmpty || "\($0.title) \($0.folder) \($0.cwd) \($0.sourceName)".lowercased().contains(q) }
            .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
    }

    private var canSend: Bool {
        !sending && hasContent && !tooLarge && (target == "project" || picked != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("把从其他应用共享来的内容发给一个会话，或新建会话（可选择项目和 Agent）。")
                .font(.app(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .panelDragBackground()
            if !files.isEmpty { fileList }
            VStack(alignment: .leading, spacing: 4) {
                Text("内容").font(.app(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(.app(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 72)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("补充说明（可选），例如：核对这份报价单的金额").font(.app(size: 13)).foregroundStyle(.tertiary)
                                .padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                        }
                    }
            }
            HStack(spacing: 10) {
                LookSegmented(selection: $target, options: [("session", L("已有会话")), ("project", L("新建会话"))])
                    .labelsHidden().frame(width: 220)
                Spacer()
                if target == "session" {
                    TextField("搜索会话", text: $query).textFieldStyle(.roundedBorder).frame(width: 200)
                }
            }
            // 两种去处切换时面板高度不变（不跳）
            Group { if target == "session" { sessionList } else { newSessionNote } }
                .frame(minHeight: 230, idealHeight: 260, maxHeight: .infinity, alignment: .top)
            HStack {
                if let message {
                    Label(message, systemImage: "exclamationmark.triangle").font(.app(size: 11.5)).foregroundStyle(.orange).lineLimit(2)
                } else if tooLarge {
                    Text(total > SharedPayload.maxTotal ? "文件总大小超过 28 MB，请分批发送。" : "有文件超过 25 MB，无法发送。")
                        .font(.app(size: 11.5)).foregroundStyle(.orange)
                } else if !files.isEmpty {
                    Text("文件将传到会话所在的电脑，Agent 会收到文件路径并自行读取。").font(.app(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { cancel() }.keyboardShortcut(.cancelAction).tarsButton()
                Button(target == "project" ? L("下一步") : (sending ? L("正在发送…") : L("发送"))) { send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .tarsButton(prominent: true)
                    .disabled(!canSend)
            }
        }
        .padding(DialogMetric.pad)
        .frame(minWidth: 520, idealWidth: 600, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(L("发送到会话"))
        .onAppear(perform: take)
        // 面板开着又共享来一批：换成新的（旧的那批没发，丢掉）
        .onChange(of: model.sharedPayload?.id) { _, id in if id != nil { take() } }
    }

    // MARK: 文件

    private var fileList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(files) { file in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path)).resizable().frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(file.name).font(.app(size: 12)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 180, alignment: .leading)
                            Text(file.size > SharedPayload.maxFile && !file.isImage ? L("超过 25 MB，无法发送")
                                 : ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                                .font(.app(size: 10.5))
                                .foregroundStyle(file.size > SharedPayload.maxFile && !file.isImage ? Color.orange : Color.secondary)
                        }
                        Button { remove(file) } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("移除")
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
                }
            }
        }
    }

    // MARK: 已有会话

    private var sessionList: some View {
        List(selection: $picked) {
            ForEach(sessions) { item in
                HStack(spacing: 10) {
                    SessionAvatar(key: item.id, title: item.title, activity: item.activity, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.app(size: 13, weight: .semibold)).lineLimit(1)
                        Text("\(item.sourceName) · \(item.folder) · \(item.status)").font(.app(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    if let at = item.updatedAt {
                        Text(Format.short(at)).font(.app(size: 10.5)).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 2)
                .tag(item.id)
            }
            if sessions.isEmpty {
                Text(query.isEmpty ? "暂无可发送的会话，请选择「新建会话」" : "无匹配的会话").foregroundStyle(.secondary).selectionDisabled()
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: false))
    }

    private var newSessionNote: some View {
        Text("下一步选择项目和 Agent（Claude Code 或这台电脑上的其他 Agent），内容会作为新会话的第一条消息发送，也可设为定时任务。")
            .font(.app(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: 动作

    /// 取走 KitelineModel 上等着的那批；默认选中正在看的会话（多半就是要发给它）
    private func take() {
        guard let next = model.sharedPayload else { return }
        model.sharedPayload = nil
        if let payload, payload.id != next.id { ShareInbox.discard(payload) }
        payload = next
        text = next.text
        message = nil
        if picked == nil || !sessions.contains(where: { $0.id == picked }) {
            picked = model.selection.flatMap { key in sessions.contains { $0.id == key } ? key : nil } ?? sessions.first?.id
        }
    }

    private func remove(_ file: SharedPayload.File) {
        try? FileManager.default.removeItem(at: file.url)
        payload?.files.removeAll { $0.id == file.id }
    }

    private func cancel() {
        if let payload { ShareInbox.discard(payload) }
        payload = nil
        model.showShare = false
    }

    private func send() {
        guard canSend, let payload else { return }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        sending = true
        message = nil
        let files = payload.files
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = ShareInbox.load(files)
            DispatchQueue.main.async {
                sending = false
                if loaded.images.isEmpty, loaded.files.isEmpty, body.isEmpty { message = L("无法读取文件"); return }
                if target == "project" {
                    // 新建会话：带着内容去「新任务」选项目、Agent（和定时）
                    model.newTask(share: (body, loaded.images, loaded.files.map { NewTaskSheet.SharedFile(name: $0.name, data: $0.data) }))
                } else if let key = picked {
                    // 和在对话里发一样：先挂在对话底下（发送中 / 失败可重发）；再打开这个会话
                    KitelineKit.send(key: key, text: body, images: loaded.images, files: loaded.files)
                    model.pick(key)
                }
                ShareInbox.discard(payload)
                self.payload = nil
                if target != "project" { model.showShare = false }
            }
        }
    }
}
