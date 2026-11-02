import AppKit
import SwiftUI
import KitelineKit

/// 菜单栏图标点开的面板：一眼看清每个会话在干什么，等你确认的可以直接点允许 / 拒绝。
struct MenuBarPanel: View {
    @ObservedObject var model = KitelineModel.shared
    @ObservedObject private var screen = VirtualScreen.shared
    var openMain: (String?) -> Void
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.sessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "moon.stars").font(.app(size: 28)).foregroundStyle(.secondary)
                    Text("没有运行中的会话").font(.app(size: 13, weight: .medium))
                    Text("在 VS Code 中打开 Claude Code，或在终端运行 claude。")
                        .font(.app(size: 11.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        // 标记的会话单独一区排最上面
                        let marked = model.markedSessions
                        if !marked.isEmpty {
                            Label { Text("标记") } icon: { Image(systemName: "star.fill").foregroundStyle(Color.tarsBrand) }
                                .font(.app(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.top, 4)
                            ForEach(marked) { item in
                                MiniSessionRow(model: model, item: item) { openMain(item.id); close() }
                            }
                        }
                        ForEach([Activity.waiting, .busy, .idle], id: \.self) { activity in
                            let items = model.sessions(activity)
                            if !items.isEmpty {
                                Text(activity.sectionTitle)
                                    .font(.app(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.top, 4)
                                ForEach(items.prefix(activity == .idle ? 5 : 20)) { item in
                                    MiniSessionRow(model: model, item: item) { openMain(item.id); close() }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 440)
                .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(14)
        .frame(width: 372)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("Kiteline").font(.app(size: 15, weight: .bold, design: .rounded))
                Text(model.summary).font(.app(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            if VirtualScreen.supported {
                Button { screen.toggle() } label: {
                    Image(systemName: "display").font(.app(size: 14))
                        .foregroundStyle(screen.isOn ? Color.tarsBrand : Color.secondary)
                        .accessibilityLabel("虚拟屏幕")
                }
                .buttonStyle(.borderless)
                .hoverTip(screen.helpText)
            }
            Button { SettingsWindowController.shared.show(tab: .general); close() } label: {
                Image(systemName: "gearshape").font(.app(size: 14))
            }
            .buttonStyle(.borderless)
            .hoverTip(L("设置"))
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Label("\(model.onlineSources)/\(model.sources.count) 来源", systemImage: "antenna.radiowaves.left.and.right")
                .foregroundStyle(model.onlineSources > 0 ? Color.secondary : Color.red)
            Button { SettingsWindowController.shared.show(tab: .phone); close() } label: {
                Label("\(model.phoneClients) 台手机", systemImage: "iphone")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("手机访问")
            Spacer()
            Button { openMain(nil); close() } label: { Text("打开 Kiteline") }
                .tarsButton(prominent: true)
                .controlSize(.regular)
        }
        .font(.app(size: 11.5))
    }
}

struct MiniSessionRow: View {
    @ObservedObject var model: KitelineModel
    let item: SessionItem
    var open: () -> Void
    @State private var hovering = false
    @State private var sending = false

    /// 提问、计划这类不是简单的允许 / 拒绝，要进去看
    private var needsDetail: Bool {
        ["AskUserQuestion", "ExitPlanMode"].contains(item.pendingTool ?? "")
    }

    var body: some View {
        HStack(spacing: 10) {
            SessionAvatar(key: item.id, title: item.title, activity: item.activity, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    AgentGlyph(item.agent, size: 11).foregroundStyle(.secondary).help(Agents.info(item.agent).name)
                    Text(item.title).font(.app(size: 12.5, weight: .semibold)).lineLimit(1)
                }
                HStack(spacing: 4) {
                    if let goal = item.goal { GoalBadge(state: goal.state, round: goal.round, size: 10) }
                    if let stage = item.stage { StageBadge(step: stage.step, total: stage.total, label: stage.label, part: stage.part, dots: stage.dots, size: 10) }
                    Text(item.line.isEmpty ? item.folder : item.line)
                        .font(.app(size: 11))
                        .foregroundStyle(item.activity == .waiting ? Color.tarsOrange : (item.activity == .busy ? Color.tarsBrand : Color.secondary))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if item.activity == .waiting && item.canReply {
                if needsDetail {
                    Button("查看", action: open).tarsButton(prominent: true).controlSize(.small)
                } else {
                    Button("拒绝") { act("esc") }.tarsButton().controlSize(.small).disabled(sending)
                    Button("允许") { act("1") }.tarsButton(prominent: true).controlSize(.small).disabled(sending)
                }
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Format.short(item.updatedAt)).font(.app(size: 10.5)).foregroundStyle(.tertiary)
                    if let usage = item.usage, usage.percent >= 70 {
                        Text("\(usage.percent)%").font(.app(size: 10, weight: .medium))
                            .foregroundStyle(usage.percent >= 90 ? Color.red : Color.tarsOrange)
                            .help("上下文已用 \(usage.percent)%")
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(hovering ? 0.08 : 0.035)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
    }

    private func act(_ key: String) {
        sending = true
        model.press(key, on: item.id) { _ in sending = false }
    }
}
