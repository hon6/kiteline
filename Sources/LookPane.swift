import SwiftUI
import KitelineKit

/// 设置 → 通用 → 外观：浅色 / 深色、主题色、字体、字号（只改这台 Mac；手机、网页版各自在设置里改）。
/// 主题、字体、字号的表在 KitelineKit/Views/Look.swift，和 iPhone App 共用
/// 设置 → 通用 → 会话之间的消息：几样效果各自开关（存的键和 iPhone 一样，见 KitelineKit/Model/Peers.swift 的 PeerPrefs）
struct PeerSection: View {
    @AppStorage("peerFlights") private var flights = true
    @AppStorage("peerLanes") private var lanes = true
    @AppStorage("peerCards") private var cards = true
    @AppStorage("peerRopes") private var ropes = true

    var body: some View {
        Section {
            Toggle("纸鸢传信：纸鸢从发信会话飞到收信会话", isOn: $flights)
            Toggle("风筝线：流动的虚线连起最近 15 分钟有往来的会话", isOn: $lanes)
            Toggle("对话中显示「致 / 来自」某会话的信件", isOn: $cards)
            Toggle("信绳：分屏中同一封信的两张信件用绳子连起", isOn: $ropes).disabled(!cards)
        } header: {
            Text("会话之间的消息")
        } footer: {
            Text("会话之间用 SendMessage 互发消息时显示。会话开在分屏中时，纸鸢在标签之间飞；信绳平时较淡，鼠标移到信件或绳子上时变得明显，按住绳子可以拖动。")
                .font(.app(size: 11)).foregroundStyle(.secondary)
        }
    }
}

struct LookSection: View {
    @State private var appearance = AppAppearance.current
    @State private var look = Look.shared
    @State private var kite = KiteOverlay.enabled

    var body: some View {
        Section {
            LabeledContent("外观") {
                LookSegmented(selection: $appearance, options: [("system", L("跟随系统")), ("light", L("浅色")), ("dark", L("深色"))])
                    .frame(width: 260)
            }
            .onChange(of: appearance) { _, value in AppAppearance.set(value) }
            // 界面语言（同手机）：跟随系统（中文系统用中文，其余用英文）/ 简体中文 / English，选了马上换、不用重启
            LabeledContent("语言") {
                LookSegmented(selection: Bindable(Lang.shared).choice, options: Lang.Choice.allCases.map { ($0, Lang.title($0)) })
                    .frame(width: 260)
            }
            Toggle("主窗口顶部的纸鸢", isOn: $kite)
                .onChange(of: kite) { _, value in KiteOverlay.enabled = value }
            VStack(alignment: .leading, spacing: 10) {
                Text("主题色")
                LookThemePicker(selection: $look.themeID, diameter: 28, columns: 8)
            }
            .padding(.vertical, 2)
            ColorPicker("自定义颜色", selection: look.customColorBinding, supportsOpacity: false)
            // 字体：一行一种，名字就用这种字体写（系统的弹出菜单换不了字体，看不出差别）
            VStack(alignment: .leading, spacing: 6) {
                Text("字体")
                ForEach(LookFont.groups, id: \.self) { group in
                    let options = LookFont.all.filter { $0.group == group }
                    Text(group).font(.app(size: 11)).foregroundStyle(.secondary).padding(.top, 4)
                    VStack(spacing: 0) {
                        ForEach(options) { option in
                            FontRow(option: option, selected: look.fontID == option.id) {
                                if look.fontID == option.id { look.retry(option) } else { look.fontID = option.id }
                            }
                            if option.id != options.last?.id { Divider().padding(.leading, 10) }
                        }
                    }
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(.vertical, 2)
            LabeledContent("字号") {
                HStack(spacing: 10) {
                    Text("A").font(.system(size: 11))
                    Slider(value: Binding(get: { Double(LookSize.all.firstIndex { $0.id == look.sizeID } ?? 3) }, set: { value in
                        look.sizeID = LookSize.all[max(0, min(LookSize.all.count - 1, Int(value.rounded())))].id
                    }), in: 0...Double(LookSize.all.count - 1), step: 1)
                    .frame(width: 220)
                    Text("A").font(.system(size: 17))
                    Text(look.size?.name ?? L("标准")).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
                }
            }
            LookPreview()
                .frame(maxWidth: 420)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(maxWidth: .infinity)
        } header: {
            Text("外观")
        } footer: {
            Text("主题色用于强调色、主按钮以及你发送的消息气泡。宋体为系统内置字体，其余中文字体在首次选择时从 Apple 字体服务下载。选择自定义颜色后，浅色与深色模式下的气泡和按钮将自动适配。代码始终使用等宽字体；窗口标题和工具栏属于系统界面，保持系统字体。主窗口顶部的纸鸢飞在窗口外侧，不响应鼠标，主窗口被遮挡时暂停。此处设置仅作用于这台 Mac：iPhone 和网页版请在各自的设置中修改，Apple Watch 请在「Apple Watch」页修改。")
                .foregroundStyle(.secondary)
        }
    }
}

/// 字体列表的一行：名字和示例字用这种字体写；中文字体在下载时显示进度，失败了点一下重试
private struct FontRow: View {
    let option: LookFont
    let selected: Bool
    let pick: () -> Void
    @State private var look = Look.shared

    private var sample: Font {
        if let name = option.cjk, look.readyFonts.contains(name) { return .custom(name, fixedSize: 14 * look.textScale) }
        let design: Font.Design = switch option.designName {
        case "rounded": .rounded
        case "serif": .serif
        case "monospaced": .monospaced
        default: .default
        }
        return .system(size: 14 * look.textScale, design: design)
    }

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 10) {
                Text("\(option.name)　Aa 你好").font(sample)
                Text(look.fontState(option) ?? option.detail).font(.app(size: 11))
                    .foregroundStyle(look.failures[option.cjk ?? ""] != nil ? Color.red : Color.secondary)
                Spacer()
                if let name = option.cjk, look.downloads[name] != nil {
                    ProgressView().controlSize(.small)
                } else if selected {
                    Image(systemName: "checkmark").font(.app(size: 12, weight: .semibold)).foregroundStyle(look.palette.action)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
