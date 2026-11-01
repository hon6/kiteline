import SwiftUI

/// 代码 IDE 里几页共用的小东西：确认、起名字、改动状态字母、分支 / 标签胶囊、提交图配色

/// 要确认的操作（删除、丢弃、强推、重置……）
struct CodeAsk: Identifiable {
    let id = UUID()
    var message: String
    var confirm: String
    var destructive = false
    var action: () -> Void
}

/// 要起名字的操作（新建文件 / 文件夹 / 分支 / 标签、改名）
struct NameAsk: Identifiable {
    let id = UUID()
    var title: String
    var message: String? = nil
    var placeholder: String = ""
    var text: String = ""
    var confirm: String = L("确定")
    var action: (String) -> Void
}

private struct CodeAsksModifier: ViewModifier {
    @Binding var ask: CodeAsk?
    @Binding var name: NameAsk?
    @State private var draft = ""

    func body(content: Content) -> some View {
        content
            .confirmPanel(ask?.message ?? "", isPresented: Binding(get: { ask != nil }, set: { if !$0 { ask = nil } }),
                          confirm: ask?.confirm ?? "", destructive: ask?.destructive ?? false, cancel: L("取消")) {
                let action = ask?.action
                ask = nil
                action?()
            }
            .alert(name?.title ?? "", isPresented: Binding(get: { name != nil }, set: { if !$0 { name = nil } })) {
                TextField(name?.placeholder ?? "", text: $draft)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                Button(name?.confirm ?? L("确定")) {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    let action = name?.action
                    name = nil
                    if !text.isEmpty { action?(text) }
                }
                Button("取消", role: .cancel) { name = nil }
            } message: {
                if let message = name?.message { Text(message) }
            }
            .onChange(of: name?.id) { _, _ in draft = name?.text ?? "" }
    }
}

extension View {
    func codeAsks(_ ask: Binding<CodeAsk?>, _ name: Binding<NameAsk?>) -> some View {
        modifier(CodeAsksModifier(ask: ask, name: name))
    }
}

/// 改动状态字母（同 VS Code：M 改、A 增、D 删、R 名、U 未跟踪、! 冲突）
struct ChangeBadge: View {
    let status: String

    var body: some View {
        Text(ChangeMark.label(status))
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: 16)
            .help(ChangeMark.describe(status))
    }

    var color: Color { Self.color(status) }

    static func color(_ status: String) -> Color {
        switch status {
        case "D": Theme.removed
        case "A", "?", "??": Theme.added
        case "U": .orange
        default: Color(hex: 0xD29922)
        }
    }
}

/// 分支 / 标签 / 远端分支的小胶囊（提交图、提交详情里用）。当前分支用强调色实底，其余描边
struct RefChip: View {
    let ref: RefLabel
    var sessions = 0

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8.5, weight: .bold))
            Text(ref.name).lineLimit(1)
            if sessions > 0 {
                Text("\(sessions)").font(.system(size: 9, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 0.5)
                    .background(ref.current ? Color.white.opacity(0.28) : Theme.claude.opacity(0.18), in: Capsule())
                    .help(L("%lld 个会话在此分支上", count: sessions))
            }
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(ref.current ? Color.white : tint)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(ref.current ? AnyShapeStyle(Theme.claude) : AnyShapeStyle(tint.opacity(0.1)), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(ref.current ? Color.clear : tint.opacity(0.35), lineWidth: 0.7))
    }

    private var symbol: String {
        switch ref.type {
        case "tag": "tag.fill"
        case "remote": "cloud.fill"
        case "head": "scope"
        default: "arrow.triangle.branch"
        }
    }

    private var tint: Color {
        switch ref.type {
        case "tag": Color(hex: 0xB08800)
        case "remote": .secondary
        default: Theme.claude
        }
    }
}

/// 提交图的线条颜色：压低饱和度的 8 种，品牌色打头（线多了也不花）
enum GraphPalette {
    static func color(_ index: Int) -> Color {
        switch index % 8 {
        case 0: Theme.claude
        case 1: Color(hex: 0x5B8DEF)
        case 2: Color(hex: 0x3FA77A)
        case 3: Color(hex: 0xA178DF)
        case 4: Color(hex: 0xD9A13B)
        case 5: Color(hex: 0xD9668F)
        case 6: Color(hex: 0x3BA9B6)
        default: Color(hex: 0x8E8E93)
        }
    }
}

/// 会话的小头像（首字 + 状态点），分支与会话页、提交图里标在分支上
struct SessionChip: View {
    let session: SessionInfo
    var showTitle = true

    var body: some View {
        HStack(spacing: 5) {
            SessionDot(session: session, size: 7)
            if showTitle { Text(session.title).lineLimit(1) }
        }
        .font(.ui(.caption))
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Theme.tile, in: Capsule())
    }
}

enum CodePaths {
    static func name(_ path: String) -> String { (path as NSString).lastPathComponent }
    static func folder(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
    static func join(_ folder: String, _ name: String) -> String { folder.isEmpty ? name : folder + "/" + name }
}
