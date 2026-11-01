import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

// MARK: 头像、昵称的数据

/// 用户给某个会话（或某家 agent 的全部会话）设的头像和昵称：电脑上存着（Sources/AgentFaces.swift），/api/state 的 faces 带来。
/// avatar 的写法：mark:<agentId|kite>:<底色> / emoji:<表情>:<底色> / text:<底色> / image:<id>；空 = agent 自己的标志
struct AgentFace: Decodable, Hashable {
    var name = ""
    var avatar = ""

    init(name: String = "", avatar: String = "") {
        self.name = name
        self.avatar = avatar
    }

    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        name = ((try? c?.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? ""
        avatar = ((try? c?.decodeIfPresent(String.self, forKey: .avatar)) ?? nil) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case name, avatar }

    var isEmpty: Bool { name.isEmpty && avatar.isEmpty }
}

/// /api/state 的 faces：会话自己的（按会话 key）、某家 agent 默认的（按 agent id）。格式不对时当没有，不连累整份状态
struct FacesPayload: Decodable, Hashable {
    var sessions: [String: AgentFace] = [:]
    var agents: [String: AgentFace] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        sessions = ((try? c?.decodeIfPresent([String: AgentFace].self, forKey: .sessions)) ?? nil) ?? [:]
        agents = ((try? c?.decodeIfPresent([String: AgentFace].self, forKey: .agents)) ?? nil) ?? [:]
    }

    private enum CodingKeys: String, CodingKey { case sessions, agents }

    /// 某个会话现在用的：会话自己的优先，没有就用这家 agent 默认的
    func face(key: String, agent: String) -> AgentFace? {
        sessions[key] ?? agents[agent]
    }
}

/// 设置里的机器列表点开设备详情（sheetPanel(item:) 要 Identifiable）
extension SourceInfo: Identifiable {}

// MARK: 头像怎么画

/// 头像的底色：几种压低了饱和度的颜色（界面少颜色、不花哨），paper 是浅底深字
enum FaceTone: String, CaseIterable, Identifiable {
    case brand, ink, slate, sky, sage, sand, rust, plum, paper

    var id: String { rawValue }

    var fill: Color {
        switch self {
        case .brand: Theme.claude
        case .ink: Color(white: 0.22)
        case .slate: Theme.dynamic(light: 0x5B6878, dark: 0x5B6878)
        case .sky: Theme.dynamic(light: 0x4C7FA8, dark: 0x4C7FA8)
        case .sage: Theme.dynamic(light: 0x6A8A70, dark: 0x6A8A70)
        case .sand: Theme.dynamic(light: 0xA8875A, dark: 0xA8875A)
        case .rust: Theme.dynamic(light: 0xA9614A, dark: 0xA9614A)
        case .plum: Theme.dynamic(light: 0x7A6488, dark: 0x7A6488)
        case .paper: Theme.dynamic(light: 0xECE9E3, dark: 0x3A3A3C)
        }
    }

    /// 底上的标志、首字用什么颜色
    var ink: Color { self == .paper ? Color.primary.opacity(0.78) : .white }

    var title: String {
        switch self {
        case .brand: L("主题色")
        case .ink: L("石墨")
        case .slate: L("岩灰")
        case .sky: L("雾蓝")
        case .sage: L("青苔")
        case .sand: L("沙金")
        case .rust: L("赭石")
        case .plum: L("暮紫")
        case .paper: L("宣纸")
        }
    }
}

/// avatar 字符串解出来的样子
enum FaceSpec: Hashable {
    /// 没设：agent 自己的标志（Claude Code 在主题色上，别家在石墨上）
    case standard
    /// 某家 agent 的标志（kite = 纸鸢）放在某种底色上
    case mark(String, FaceTone)
    case emoji(String, FaceTone)
    /// 昵称首字
    case text(FaceTone)
    /// 上传的图
    case image(String)

    init(_ raw: String) {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        func tone(_ i: Int) -> FaceTone { parts.count > i ? FaceTone(rawValue: parts[i]) ?? .ink : .ink }
        switch parts.first {
        case "mark" where parts.count >= 2 && !parts[1].isEmpty: self = .mark(parts[1], tone(2))
        case "emoji" where parts.count >= 2 && !parts[1].isEmpty: self = .emoji(parts[1], tone(2))
        case "text": self = .text(tone(1))
        case "image" where parts.count >= 2 && !parts[1].isEmpty: self = .image(parts[1])
        default: self = .standard
        }
    }

    var raw: String {
        switch self {
        case .standard: ""
        case .mark(let id, let tone): "mark:\(id):\(tone.rawValue)"
        case .emoji(let emoji, let tone): "emoji:\(emoji):\(tone.rawValue)"
        case .text(let tone): "text:\(tone.rawValue)"
        case .image(let id): "image:\(id)"
        }
    }

    var tone: FaceTone? {
        switch self {
        case .mark(_, let tone), .emoji(_, let tone), .text(let tone): tone
        default: nil
        }
    }

    /// 换底色（图片和默认样子没有底色，原样）
    func with(_ tone: FaceTone) -> FaceSpec {
        switch self {
        case .mark(let id, _): .mark(id, tone)
        case .emoji(let emoji, _): .emoji(emoji, tone)
        case .text: .text(tone)
        default: self
        }
    }
}

/// 助手的头像：用户设过就按设的画（标志 / 表情 / 昵称首字 / 上传的图），没设过是 agent 自己的样子（AgentAvatar）。
/// corner 是圆角占边长的比例（对话里同 avatarCorner，列表里的头像稍圆）
struct AgentFaceView: View {
    let agent: String
    var face: AgentFace?
    var size: CGFloat = 40
    var corner: CGFloat = avatarCorner

    var body: some View {
        switch FaceSpec(face?.avatar ?? "") {
        case .standard:
            if agent == Agents.defaultID {
                tile(Theme.claude) { AgentGlyph(agent, size: size * 0.6).foregroundStyle(.white) }
            } else {
                tile(Color(white: 0.22)) { AgentGlyph(agent, size: size * 0.56).foregroundStyle(.white) }
            }
        case .mark(let id, let tone):
            tile(tone.fill) {
                if id == "kite" {
                    KiteMark(color: tone.ink).frame(width: size * 0.66, height: size * 0.66)
                } else {
                    AgentGlyph(id, size: size * 0.56).foregroundStyle(tone.ink)
                }
            }
        case .emoji(let emoji, let tone):
            tile(tone.fill) { Text(verbatim: emoji).font(.system(size: size * 0.56)).minimumScaleFactor(0.5) }
        case .text(let tone):
            tile(tone.fill) {
                Text(Format.initials(displayName)).font(.appFixed(size: size * 0.4, weight: .semibold)).foregroundStyle(tone.ink)
                    .minimumScaleFactor(0.5).lineLimit(1).padding(2)
            }
        case .image(let id):
            RemoteImage(path: "/api/agent-avatar", query: ["id": id])
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * corner, style: .continuous))
        }
    }

    private var displayName: String {
        let name = face?.name.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? Agents.info(agent).speaker : name
    }

    private func tile<Content: View>(_ color: Color, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: size, height: size)
            .background(color, in: RoundedRectangle(cornerRadius: size * corner, style: .continuous))
    }
}

/// 对话里点助手头像：打开 Agent 详情（包成相等的值，环境里换了闭包也不当成变了，消息行不跟着重画；同 OpenRoute）
struct AgentInfoOpener: Equatable {
    let action: () -> Void
    func callAsFunction() { action() }
    static func == (a: AgentInfoOpener, b: AgentInfoOpener) -> Bool { true }
}

extension EnvironmentValues {
    /// 这段对话里助手用的头像、昵称（用户没设为 nil）
    @Entry var chatFace: AgentFace? = nil
    /// 点助手头像做什么（对话页给；别处不给就是不能点）
    @Entry var openAgentInfo: AgentInfoOpener? = nil
}

// MARK: 详情的数据（/api/machine、/api/agent-info）

struct MachineAddress: Decodable, Hashable {
    var name: String
    var ip: String

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        name = c.text("name") ?? ""
        ip = c.text("ip") ?? ""
    }
}

/// 那台机器的 watcher 报的系统信息（machine_info）
struct MachineSystem: Decodable, Hashable {
    var hostname: String?
    var os: String?
    var arch: String?
    var cores: Int?
    var cpuModel: String?
    var python: String?
    var watcher: String?
    var user: String?
    var memTotal: Double?
    var uptime: Double?
    var diskTotal: Double?
    var diskFree: Double?
    var ips: [MachineAddress]
    var primaryIp: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        hostname = c.text("hostname"); os = c.text("os"); arch = c.text("arch"); cores = c.one("cores")
        cpuModel = c.text("cpuModel"); python = c.text("python"); watcher = c.text("watcher"); user = c.text("user")
        memTotal = c.one("memTotal"); uptime = c.one("uptime"); diskTotal = c.one("diskTotal"); diskFree = c.one("diskFree")
        ips = c.list("ips"); primaryIp = c.text("primaryIp")
    }
}

/// 某台机器上的一家 agent：装没装、各种形态的版本、我们插件的版本
struct MachineAgent: Decodable, Hashable, Identifiable {
    var id: String
    var name: String
    var installed: Bool
    var plugin: String?
    var source: String?
    var state: String?
    var forms: [String: String]
    var abilities: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        id = c.text("id") ?? ""
        name = c.text("name") ?? id
        installed = c.truthy("installed")
        plugin = c.text("plugin"); source = c.text("source"); state = c.text("state")
        forms = c.one("forms") ?? [:]
        abilities = c.list("abilities")
    }
}

struct MachineDetail: Decodable {
    var id: String
    var name: String
    var kind: String
    var online: Bool
    var status: String?
    var computer: String?
    var sshHost: String?
    var watcher: String?
    var sessions: Int
    var busy: Int
    var info: MachineSystem?
    /// outdated（watcher 太旧，没有 machine_info）/ failed
    var infoError: String?
    var detail: String?
    var agents: [MachineAgent]

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        id = c.text("id") ?? ""
        name = c.text("name") ?? ""
        kind = c.text("kind") ?? "local"
        online = c.truthy("online")
        status = c.text("status"); computer = c.text("computer"); sshHost = c.text("sshHost"); watcher = c.text("watcher")
        sessions = c.int("sessions"); busy = c.int("busy")
        info = c.one("info"); infoError = c.text("infoError"); detail = c.text("detail")
        agents = c.list("agents")
    }
}

struct AgentDetail: Decodable {
    var key: String
    var agent: String
    var sourceId: String
    var live: Bool
    var face: AgentFace?
    var agentFace: AgentFace?
    var title: String?
    var sessionId: String?
    var cwd: String?
    var entrypoint: String
    var tmux: Bool
    var version: String?
    var pid: Int?
    var startedAt: Double?
    var model: String?
    var plugin: MachineAgent?
    var machine: MachineDetail?

    init(from decoder: Decoder) throws {
        let c = try decoder.fields()
        key = c.text("key") ?? ""
        agent = c.text("agent").flatMap { $0.isEmpty ? nil : $0 } ?? Agents.defaultID
        sourceId = c.text("sourceId") ?? ""
        live = c.truthy("live")
        face = c.one("face"); agentFace = c.one("agentFace")
        title = c.text("title"); sessionId = c.text("sessionId"); cwd = c.text("cwd")
        entrypoint = c.text("entrypoint") ?? ""
        tmux = c.truthy("tmux")
        version = c.text("version"); pid = c.one("pid"); startedAt = c.one("startedAt"); model = c.text("model")
        plugin = c.one("plugin"); machine = c.one("machine")
    }
}

/// 详情里各种代号换成给人看的字
enum DetailText {
    /// 会话跑在哪：VS Code 扩展 / 终端 / 终端（tmux）/ 桌面版
    static func frontend(_ entry: String, tmux: Bool) -> String {
        switch entry {
        case "claude-vscode", "codex-vscode": L("VS Code 扩展")
        case "cli", "codex", "opencode", "qwen-code": tmux ? L("终端（tmux）") : L("终端")
        case "codex-desktop", "claude-desktop", "dsh", "proma": L("桌面版")
        case let other where other.hasPrefix("sdk"): "SDK"
        case "": tmux ? L("终端（tmux）") : "—"
        default: entry
        }
    }

    static func form(_ form: String) -> String {
        ["cli": L("终端"), "vscode": L("VS Code 扩展"), "desktop": L("桌面版")][form] ?? form
    }

    /// 「终端 · VS Code 扩展 1.2.3 · 桌面版 26.1」
    static func forms(_ forms: [String: String]) -> String {
        let order = ["cli", "vscode", "desktop"]
        return forms.sorted { (order.firstIndex(of: $0.key) ?? 9, $0.key) < (order.firstIndex(of: $1.key) ?? 9, $1.key) }
            .map { $0.value.isEmpty ? form($0.key) : "\(form($0.key)) \($0.value)" }
            .joined(separator: " · ")
    }

    static func abilities(_ list: [String]) -> String {
        let names = ["view": L("查看"), "reply": L("回复"), "approve": L("审批"), "answer": L("回答提问")]
        return list.compactMap { names[$0] }.joined(separator: " · ")
    }

    /// 插件：内置 2.24.0 / 单独安装 1.0.1
    static func plugin(_ agent: MachineAgent) -> String {
        let source = agent.source == "external" ? L("单独安装") : L("内置")
        return [source, agent.plugin].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// 开机多久：3 天 4 小时 / 5 小时 12 分钟 / 8 分钟
    static func uptime(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60), hours = minutes / 60, days = hours / 24
        if days > 0 { return L("%lld 天", count: days) + " " + L("%lld 小时", count: hours % 24) }
        if hours > 0 { return L("%lld 小时", count: hours) + " " + L("%lld 分钟", count: minutes % 60) }
        return L("%lld 分钟", count: max(minutes, 1))
    }

    static func machineKind(_ detail: MachineDetail) -> String {
        detail.kind == "ssh" ? "Remote-SSH" : L("本机")
    }

    /// 「Mac Studio（本机）」「gpu-server · Remote-SSH」：本机的来源名多半就叫「本机」，换成电脑名
    static func machineName(_ detail: MachineDetail) -> String {
        if detail.kind == "ssh" { return detail.name + " · Remote-SSH" }
        let computer = detail.computer.flatMap { $0.isEmpty ? nil : $0 } ?? detail.name
        return computer == L("本机") || computer == "本机" ? computer : L("%@（本机）", computer)
    }
}

// MARK: Agent 详情

/// 对话里点助手头像弹出的 Agent 详情：头像和昵称放最上面、能改（轻点头像换，名字直接改），
/// 下面只读：哪家 agent、什么版本、跑在 VS Code 还是终端、插件、会话、所在设备（IP、系统、CPU、内存）。
/// 头像昵称存在电脑上，手机、iPad、Mac 都一样；可以只给这个会话用，也可以给这家 agent 的所有会话用
struct AgentInfoSheet: View {
    @Environment(AppModel.self) private var model
    let key: String
    /// 打开时就知道的 agent（详情还没拉回来时先按它画头像）
    var agent: String
    @State private var detail: AgentDetail?
    @State private var error: String?
    @State private var name = ""
    /// 正在编辑的是会话自己的（session）还是这家 agent 所有会话的（agent）
    @State private var scope = "session"
    @State private var picking = false
    @State private var saving = false
    @State private var savedName = ""
    @FocusState private var naming: Bool

    private var agentId: String { detail?.agent ?? agent }
    private var info: AgentInfo { Agents.info(agentId) }
    /// 现在用的头像、昵称（会话自己的 → 这家 agent 默认的）
    private var face: AgentFace? { model.faces.face(key: key, agent: agentId) }

    var body: some View {
        FitSheet(title: L("Agent 详情")) {
            header
            if picking {
                FacePicker(agent: agentId, current: FaceSpec(face?.avatar ?? ""), name: shownName) { spec, image in
                    Task { await save(avatar: spec?.raw, image: image) }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            SheetSection(footer: scope == "agent"
                         ? L("此电脑上所有 %@ 会话（包括之后的新会话）都使用这个头像和昵称；单独设置过的会话除外。", info.name)
                         : L("头像和昵称保存在电脑上，连接这台电脑的手机、iPad 和电脑上都会同步显示。")) {
                SwitchRow(isOn: Binding(get: { scope == "agent" }, set: { on in Task { await setScope(on ? "agent" : "session") } })) {
                    Text(L("用于所有 %@ 会话", info.name))
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                if face?.isEmpty == false {
                    SheetDivider()
                    Button(L("恢复默认头像和昵称")) { Task { await reset() } }
                        .foregroundStyle(Theme.removed)
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .buttonStyle(.plain)
                }
            }
            if let detail {
                agentSection(detail)
                if detail.live { sessionSection(detail) }
                if let machine = detail.machine { MachineSections(detail: machine, compact: true) }
            } else if let error {
                LoadFailed(error: error) { await load() }.padding(.top, 10)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
            }
        }
        .task { await load() }
        #if SNAPSHOT
        .onAppear { if ProcessInfo.processInfo.environment["TARS_DEMO_PICK"] == "1" { picking = true } }   // 截图版看头像选择
        #endif
        .onDisappear { if name != savedName { Task { await save(avatar: nil, image: nil) } } }
        .animation(.snappy, value: picking)
    }

    private var shownName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? info.speaker : trimmed
    }

    // MARK: 顶上：头像 + 昵称

    private var header: some View {
        VStack(spacing: 10) {
            Button { withAnimation(.snappy) { picking.toggle() } } label: {
                AgentFaceView(agent: agentId, face: AgentFace(name: name, avatar: face?.avatar ?? ""), size: 76)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: picking ? "chevron.up" : "pencil")
                            .font(.app(size: 11, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Theme.wechatGreen, in: Circle())
                            .overlay(Circle().strokeBorder(Theme.pageBackground, lineWidth: 2))
                            .offset(x: 6, y: 6)
                    }
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(picking ? L("收起头像选择") : L("更换头像"))
            TextField(info.speaker, text: $name)
                .font(.app(size: 20, weight: .semibold))
                .multilineTextAlignment(.center)
                .textFieldStyle(.plain)
                .focused($naming)
                .submitLabel(.done)
                .onSubmit { Task { await save(avatar: nil, image: nil) } }
                .onChange(of: naming) { _, on in if !on, name != savedName { Task { await save(avatar: nil, image: nil) } } }
                .frame(maxWidth: 280)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(naming ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel(L("昵称"))
            Text(subtitle).font(.ui(.footnote)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6).padding(.bottom, 16)
    }

    private var subtitle: String {
        var parts = [info.name]
        if let detail { parts.append(DetailText.frontend(detail.entrypoint, tmux: detail.tmux)) }
        if let machine = detail?.machine?.name, !machine.isEmpty { parts.append(machine) }
        return parts.filter { $0 != "—" }.joined(separator: " · ")
    }

    // MARK: 只读的几块

    private func agentSection(_ d: AgentDetail) -> some View {
        SheetSection(title: "Agent") {
            SheetInfoRow(L("类型"), info.name)
            if let version = d.version {
                SheetDivider()
                SheetInfoRow(L("版本"), version)
            }
            SheetDivider()
            SheetInfoRow(L("运行于"), DetailText.frontend(d.entrypoint, tmux: d.tmux) + (d.machine?.kind == "ssh" ? " · Remote-SSH" : ""))
            if let plugin = d.plugin {
                SheetDivider()
                SheetInfoRow(L("Kiteline 插件"), DetailText.plugin(plugin))
                if !plugin.abilities.isEmpty {
                    SheetDivider()
                    SheetInfoRow(L("可远程"), DetailText.abilities(plugin.abilities))
                }
                if !plugin.forms.isEmpty {
                    SheetDivider()
                    SheetInfoRow(L("已安装"), DetailText.forms(plugin.forms))
                }
            }
        }
    }

    private func sessionSection(_ d: AgentDetail) -> some View {
        SheetSection(title: L("会话")) {
            SheetInfoRow(L("标题"), d.title ?? "—")
            if let model = d.model {
                SheetDivider()
                SheetInfoRow(L("模型"), model)
            }
            if let started = d.startedAt {
                SheetDivider()
                SheetInfoRow(L("开始于"), Format.messageTime(started))
            }
            if let pid = d.pid {
                SheetDivider()
                CopyRow(title: L("进程"), value: "\(pid)")
            }
            if let id = d.sessionId {
                SheetDivider()
                CopyRow(title: L("会话 ID"), value: id, mono: true)
            }
            if let cwd = d.cwd, !cwd.isEmpty {
                SheetDivider()
                CopyRow(title: L("目录"), value: cwd, mono: true)
            }
        }
    }

    // MARK: 读、存

    private func load() async {
        do {
            let loaded = try await model.api.get(AgentDetail.self, "/api/agent-info", ["key": key, "agent": agent])
            detail = loaded
            error = nil
            // 会话自己设过就是改会话的；只有默认的（或都没有、但默认的设过）就是改默认的
            scope = loaded.face == nil && loaded.agentFace != nil ? "agent" : "session"
            if !naming {
                name = (loaded.face ?? loaded.agentFace)?.name ?? ""
                savedName = name
            }
        } catch {
            if detail == nil { self.error = error.localizedDescription }
        }
    }

    /// 存一次：avatar 为 nil = 头像不变（只改了昵称）；image = 上传的图（JPEG）
    private func save(avatar: String?, image: Data?, in target: String? = nil, name override: String? = nil) async {
        let cleanName = (override ?? name).trimmingCharacters(in: .whitespacesAndNewlines)
        var body: [String: Any] = ["key": key, "agent": agentId, "scope": target ?? scope, "name": cleanName,
                                   "avatar": avatar ?? face?.avatar ?? ""]
        if let image { body["image"] = image.base64EncodedString() }
        saving = true
        defer { saving = false }
        do {
            let reply = try await model.api.post("/api/agent-face", body: body)
            savedName = cleanName
            applyReply(reply)
        } catch { model.show(error) }
    }

    /// 「用于所有会话」开关：开 = 现在的头像昵称变成这家 agent 的默认（会话自己的那份不再留）；
    /// 关 = 这个会话自己留一份，默认的清掉（别的会话回到原来的样子）
    private func setScope(_ next: String) async {
        guard next != scope else { return }
        let current = AgentFace(name: name.trimmingCharacters(in: .whitespacesAndNewlines), avatar: face?.avatar ?? "")
        if next == "agent" {
            scope = "agent"
            await save(avatar: current.avatar, image: nil, in: "agent")
        } else {
            scope = "session"
            await save(avatar: current.avatar, image: nil, in: "session")
            await save(avatar: "", image: nil, in: "agent", name: "")
        }
        model.flash(next == "agent" ? L("已用于所有 %@ 会话", info.name) : L("仅用于此会话"))
    }

    private func reset() async {
        name = ""
        await save(avatar: "", image: nil, name: "")
        picking = false
        model.flash(L("已恢复默认"))
    }

    private func applyReply(_ reply: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["sessions": reply["sessions"] ?? [:], "agents": reply["agents"] ?? [:]]),
              let faces = try? JSONDecoder().decode(FacesPayload.self, from: data) else { return }
        model.setFaces(faces)
    }
}

/// 一行能拷贝的信息（进程号、会话 ID、目录、IP）：长按 / 右键拷贝，Mac 上还能直接选中文字
struct CopyRow: View {
    let title: String
    let value: String
    var mono = false

    var body: some View {
        SheetInfoRow(title: title) {
            Text(value)
                .font(mono ? .ui(.footnote).monospaced() : nil)
                .fontDesign(nil)
                .textSelection(.enabled)
        }
        .contextMenu { Button(Clipboard.verb) { Clipboard.copy(value) } }
    }
}

// MARK: 选头像

/// 头像选择：上传照片、agent 自己的标志、纸鸢、昵称首字、表情，下面一排底色。点了马上存
struct FacePicker: View {
    let agent: String
    let current: FaceSpec
    let name: String
    /// 选了一个：spec（nil = 上传的图，图在 image 里）
    let choose: (FaceSpec?, Data?) -> Void
    @State private var tone: FaceTone = .ink
    #if os(iOS)
    @State private var photo: PhotosPickerItem?
    #else
    @State private var importing = false
    #endif

    private static let emojis = ["🦊", "🐱", "🐼", "🐨", "🦉", "🐙", "🐳", "🐧", "🦁", "🐯", "🐶", "🐰",
                                 "🐢", "🐝", "🦄", "🐲", "🤖", "👾", "🚀", "⚡️", "🌙", "🔥", "🍀", "☕️"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 12) {
                upload
                option(.standard, label: L("默认"))
                option(.mark(agent, tone), label: L("标志"))
                option(.mark("kite", tone), label: L("纸鸢"))
                option(.text(tone), label: L("首字"))
                if case .image = current { option(current, label: L("照片")) }
                ForEach(Self.emojis, id: \.self) { option(.emoji($0, tone), label: nil) }
            }
            Text("底色").font(.ui(.footnote)).foregroundStyle(.secondary).padding(.top, 4)
            HStack(spacing: 0) {
                ForEach(FaceTone.allCases) { item in
                    Button {
                        tone = item
                        // 现在用的是有底色的样子：换底色直接存
                        if current.tone != nil { choose(current.with(item), nil) }
                    } label: {
                        Circle().fill(item.fill)
                            .frame(width: 26, height: 26)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(item == .paper ? 0.15 : 0), lineWidth: 1))
                            .padding(3)
                            .overlay(Circle().strokeBorder(tone == item ? Theme.wechatGreen : .clear, lineWidth: 2))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.title)
                    .help(item.title)
                }
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.bottom, 14)
        .onAppear { tone = current.tone ?? (agent == Agents.defaultID ? .brand : .ink) }
        #if os(iOS)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task {
                if let raw = try? await item.loadTransferable(type: Data.self), let prepared = ImagePrep.prepare(raw) { choose(nil, prepared.jpeg) }
            }
        }
        #else
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let raw = try? Data(contentsOf: url), let prepared = ImagePrep.prepare(raw) { choose(nil, prepared.jpeg) }
        }
        #endif
    }

    @ViewBuilder private var upload: some View {
        let label = VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 44 * avatarCorner, style: .continuous)
                .fill(Color.primary.opacity(0.07))
                .frame(width: 44, height: 44)
                .overlay(Image(systemName: "photo.badge.plus").font(.app(size: 17)).foregroundStyle(.secondary))
            Text("上传").font(.ui(.caption2)).foregroundStyle(.secondary).lineLimit(1)
        }
        #if os(iOS)
        PhotosPicker(selection: $photo, matching: .images) { label }
            .buttonStyle(.plain)
            .accessibilityLabel(L("从照片中选择"))
        #else
        Button { importing = true } label: { label }
            .buttonStyle(.plain)
            .help(L("选择一张图片（将居中裁剪为正方形）"))
        #endif
    }

    private func option(_ spec: FaceSpec, label: String?) -> some View {
        let selected = spec == current || (spec.tone != nil && spec.with(.ink) == current.with(.ink) && current.tone == tone)
        return Button { choose(spec, nil) } label: {
            VStack(spacing: 4) {
                AgentFaceView(agent: agent, face: AgentFace(name: name, avatar: spec.raw), size: 44)
                    .overlay(RoundedRectangle(cornerRadius: 44 * avatarCorner + 3, style: .continuous)
                        .strokeBorder(selected ? Theme.wechatGreen : .clear, lineWidth: 2.5).padding(-4))
                if let label { Text(label).font(.ui(.caption2)).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: 设备详情

/// 某台机器（本机 / Remote-SSH 远端）的详情：网络、系统、硬件、装了哪些 agent、Kiteline 组件。
/// 设置里的机器列表、列表组头的 CPU / 内存、Mac 设置 → 来源都能点开
struct MachineInfoSheet: View {
    @Environment(AppModel.self) private var model
    let sourceId: String
    /// 拉回来之前标题先写的名字
    var name: String = ""
    @State private var detail: MachineDetail?
    @State private var error: String?

    var body: some View {
        FitSheet(title: detail?.name ?? (name.isEmpty ? L("设备详情") : name)) {
            if let detail {
                MachineHeader(detail: detail)
                MachineSections(detail: detail, compact: false)
            } else if let error {
                LoadFailed(error: error) { await load() }.padding(.top, 20)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            detail = try await model.api.get(MachineDetail.self, "/api/machine", ["source": sourceId])
            error = nil
        } catch {
            if detail == nil { self.error = error.localizedDescription }
        }
    }
}

private struct MachineHeader: View {
    let detail: MachineDetail

    var body: some View {
        HStack(spacing: 14) {
            TarsIcon(symbol: detail.kind == "ssh" ? "server.rack" : "desktopcomputer", size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(detail.computer.flatMap { $0.isEmpty || $0 == detail.name ? nil : $0 } ?? detail.name)
                    .font(.ui(.headline)).lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(detail.online ? Theme.added : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                    Text([DetailText.machineKind(detail), detail.online ? L("在线") : L("离线"),
                          detail.sessions > 0 ? L("%lld 个会话", count: detail.sessions) : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                }
                .font(.ui(.footnote)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4).padding(.bottom, 16)
    }
}

/// 设备详情的几块（Agent 详情里也用：compact 时只放一块「设备」，是网络、系统、硬件里最常看的几行）
struct MachineSections: View {
    @Environment(AppModel.self) private var model
    let detail: MachineDetail
    var compact = false

    /// 一行：名字、值、能不能拷贝（地址、主机名这类）、等宽
    private struct Row: Hashable {
        var title: String
        var value: String
        var copy = false
        var mono = false
    }

    var body: some View {
        let info = detail.info
        if compact {
            SheetSection(title: L("设备")) {
                rows([Row(title: L("名称"), value: DetailText.machineName(detail))]
                     + addresses(info, all: false)
                     + [info?.os.map { Row(title: L("系统"), value: $0 + (info?.arch.map { " · \($0)" } ?? "")) },
                        cpuText(info).map { Row(title: L("处理器"), value: $0) }].compactMap { $0 })
                liveRows
            }
            note
        } else {
            SheetSection(title: L("网络")) {
                let network = [detail.sshHost.map { Row(title: L("SSH 地址"), value: $0, copy: true) },
                               info?.hostname.map { Row(title: L("主机名"), value: $0, copy: true) }].compactMap { $0 } + addresses(info, all: true)
                rows(network.isEmpty ? [Row(title: L("IP 地址"), value: "—")] : network)
            }
            SheetSection(title: L("系统")) {
                rows([Row(title: L("系统"), value: info?.os ?? "—"),
                      info?.arch.map { Row(title: L("架构"), value: $0) },
                      info?.user.map { Row(title: L("用户"), value: $0) },
                      info?.uptime.map { Row(title: L("已运行"), value: DetailText.uptime($0)) }].compactMap { $0 })
            }
            SheetSection(title: L("硬件")) {
                let cores = info?.cores ?? model.machineStats[detail.id]?.cores
                let disk: Row? = info?.diskTotal.flatMap { total in
                    info?.diskFree.map { Row(title: L("磁盘"), value: L("可用 %@，共 %@", MachineFormat.gigabytes($0), MachineFormat.gigabytes(total))) }
                }
                rows([Row(title: L("处理器"), value: info?.cpuModel.flatMap { $0.isEmpty ? nil : $0 } ?? "—"),
                      cores.map { Row(title: L("核心数"), value: "\($0)") },
                      info?.memTotal.map { Row(title: L("内存"), value: MachineFormat.gigabytes($0)) },
                      disk].compactMap { $0 })
                liveRows
            }
            note
            let agents = detail.agents.filter(\.installed)
            if !agents.isEmpty {
                SheetSection(title: "Agent") {
                    ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                        if index > 0 { SheetDivider(inset: 44) }
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            AgentGlyph(agent.id, size: 16).foregroundStyle(.secondary).frame(width: 20)
                                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                            // 名字一行，下面是装了哪些形态（版本）、我们插件的版本：放右边会把形态挤成两行
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.name)
                                Group {
                                    if !agent.forms.isEmpty { Text(DetailText.forms(agent.forms)) }
                                    Text(L("Kiteline 插件：%@", DetailText.plugin(agent)))
                                }
                                .font(.ui(.caption)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                    }
                }
            }
            SheetSection(title: "Kiteline") {
                rows([Row(title: L("连接"), value: detail.status ?? (detail.online ? L("在线") : L("离线"))),
                      (info?.watcher ?? detail.watcher).map { Row(title: L("组件版本"), value: $0) },
                      info?.python.map { Row(title: "Python", value: $0) },
                      Row(title: L("会话"), value: detail.busy > 0 ? L("%@ 个，%@ 个运行中", "\(detail.sessions)", "\(detail.busy)")
                                                               : L("%lld 个会话", count: detail.sessions))].compactMap { $0 })
            }
        }
    }

    private func rows(_ list: [Row]) -> some View {
        ForEach(Array(list.enumerated()), id: \.offset) { index, row in
            if index > 0 { SheetDivider() }
            if row.copy {
                CopyRow(title: row.title, value: row.value, mono: row.mono)
            } else {
                SheetInfoRow(row.title, row.value)
            }
        }
    }

    /// 现在的 CPU 占用、已用内存：跟着 sys 事件每 5 秒变（离线时不给）
    @ViewBuilder private var liveRows: some View {
        if let stats = model.liveStats(detail.id) {
            SheetDivider()
            SheetInfoRow(title: L("当前占用")) {
                MachineStatsLine(stats: stats).font(.ui(.subheadline))
            }
        }
    }

    /// IP：主 IP（去外网用的那块网卡）排第一，all 时其余网卡的跟在后面；没有系统信息时简版给 SSH 地址
    private func addresses(_ info: MachineSystem?, all: Bool) -> [Row] {
        guard let info else {
            return !all ? detail.sshHost.map { [Row(title: L("SSH 地址"), value: $0, copy: true)] } ?? [] : []
        }
        // Remote-SSH 的机器：SSH 连的就是它的某个 IP 时，那个最有用，排第一
        let sshIP = detail.sshHost.map { host -> String in
            let bare = host.split(separator: "@").last.map(String.init) ?? host
            return bare.split(separator: ":").first.map(String.init) ?? bare
        }
        guard let primary = info.ips.first(where: { $0.ip == sshIP })?.ip ?? info.primaryIp ?? info.ips.first?.ip else { return [] }
        let card = info.ips.first { $0.ip == primary }?.name ?? ""
        var out = [Row(title: L("IP 地址"), value: primary + (card.isEmpty ? "" : "（\(card)）"), copy: true)]
        if all {
            out += info.ips.filter { $0.ip != primary }.map { Row(title: $0.name.isEmpty ? L("其他地址") : $0.name, value: $0.ip, copy: true) }
        }
        return out
    }

    private func cpuText(_ info: MachineSystem?) -> String? {
        let name = info?.cpuModel.flatMap { $0.isEmpty ? nil : $0 }
        let cores = info?.cores.map { L("%lld 核", count: $0) }
        let text = [name, cores].compactMap { $0 }.joined(separator: " · ")
        return text.isEmpty ? nil : text
    }

    /// 读不到系统信息时说一句为什么
    @ViewBuilder private var note: some View {
        if detail.info == nil {
            Text(!detail.online ? L("设备离线，暂时无法读取系统信息。")
                 : detail.infoError == "outdated" ? L("该设备上的 Kiteline 组件版本较旧，更新后可查看系统信息（IP、处理器、内存等）。")
                 : L("暂时无法读取系统信息：%@", detail.detail ?? ""))
                .font(.ui(.caption)).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.top, -8).padding(.bottom, 14)
        }
    }
}

#if KITELINE_MAC
// MARK: Mac 主窗口用（Sources/）

/// 设备详情面板（设置 → 来源、侧栏组头点开的）
public struct TarsMachineInfoView: View {
    let sourceId: String
    public init(sourceId: String) { self.sourceId = sourceId }

    public var body: some View {
        if let model = KitelineKit.model {
            MachineInfoSheet(sourceId: sourceId).environment(model).lookRoot()
        }
    }
}

/// Agent 详情面板（侧栏右键「Agent 详情…」）
public struct TarsAgentInfoView: View {
    let key: String
    public init(key: String) { self.key = key }

    public var body: some View {
        if let model = KitelineKit.model {
            AgentInfoSheet(key: key, agent: model.session(key)?.agent ?? Agents.defaultID).environment(model).lookRoot()
        }
    }
}

/// 侧栏会话卡片的头像：这个会话自己设了头像就画它，没设画 fallback（标题首字）
public struct TarsSessionFace<Fallback: View>: View {
    let key: String
    let size: CGFloat
    let corner: CGFloat
    let fallback: Fallback

    public init(key: String, size: CGFloat, corner: CGFloat, @ViewBuilder fallback: () -> Fallback) {
        self.key = key
        self.size = size
        self.corner = corner
        self.fallback = fallback()
    }

    public var body: some View {
        if let model = KitelineKit.model, let face = model.faces.sessions[key], !face.avatar.isEmpty {
            AgentFaceView(agent: model.session(key)?.agent ?? Agents.defaultID, face: face, size: size, corner: corner).environment(model)
        } else {
            fallback
        }
    }
}
#endif
