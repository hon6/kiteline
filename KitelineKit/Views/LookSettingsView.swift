#if !KITELINE_MAC
import SwiftUI

/// 设置 → 外观 → 主题色、字体、字号（只改这台 iPhone；Mac、网页版、Apple Watch 各自在设置里改）
struct LookSettingsView: View {
    @State private var look = Look.shared
    @AppStorage(HomeKite.key) private var homeKite = true
    @AppStorage(PadStatusBar.key) private var padStatusBar = false

    var body: some View {
        List {
            Section {
                LookPreview()
                    .background(Theme.chatBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            }
            Section {
                LookThemePicker(selection: $look.themeID)
                    .padding(.vertical, 6)
                    .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
                ColorPicker("自定义颜色", selection: look.customColorBinding, supportsOpacity: false)
            } header: {
                Text("主题色").font(.sectionHeader)
            } footer: { Group {
                    Text("主题色用于图标和链接的强调色、发送按钮与开关，以及你发送的消息气泡。选择自定义颜色后，浅色与深色模式下的气泡和按钮将自动适配。")
                }
                .font(.ui(.footnote))
            }
            ForEach(LookFont.groups, id: \.self) { group in
                Section {
                    ForEach(LookFont.all.filter { $0.group == group }) { option in
                        FontRow(option: option, selected: look.fontID == option.id) {
                            if look.fontID == option.id { look.retry(option) } else { look.fontID = option.id }
                        }
                    }
                } header: {
                    Text(group == LookFont.groups.first ? L("字体 · %@", "\(group)") : group).font(.sectionHeader)
                } footer: { Group {
                        if group == LookFont.groups.last {
                            Text("除系统字体和等宽字体外，其余字体由 Apple 字体服务提供：首次选择时下载（数 MB 至十余 MB），下载完成前以同风格的系统字体显示。长时间阅读建议选用「正文」或「书卷」类字体。代码始终使用等宽字体。")
                        }
                    }
                    .font(.ui(.footnote))
                }
            }
            Section {
                Toggle("跟随系统", isOn: Binding(get: { look.sizeID == LookSize.system }, set: { on in
                    look.sizeID = on ? LookSize.system : (LookSize.all.min { abs($0.scale - look.textScale) < abs($1.scale - look.textScale) }?.id ?? "l")
                }))
                if look.sizeID != LookSize.system {
                    SizeSlider(sizeID: $look.sizeID)
                }
            } header: {
                Text("字号").font(.sectionHeader)
            } footer: { Group {
                    Text(look.sizeID == LookSize.system ? "跟随 iPhone「设置 → 显示与亮度 → 文字大小」。" : "仅调整 Kiteline 内的文字，不影响其他 App。")
                }
                .font(.ui(.footnote))
            }
            Section {
                Toggle("首页顶部的纸鸢", isOn: $homeKite)
            } footer: { Group {
                    Text("在会话列表顶部飞行的纸鸢标志。列表滚动或搜索时自动隐去；开启「减弱动态效果」时保持静止。")
                }
                .font(.ui(.footnote))
            }
            if UIDevice.current.userInterfaceIdiom == .pad {
                Section {
                    Toggle("显示状态栏", isOn: $padStatusBar)
                } footer: { Group {
                        Text("关闭时不显示屏幕顶部的时间、电量等信息，界面延伸至屏幕顶端。")
                    }
                    .font(.ui(.footnote))
                }
            }
        }
        .navigationTitle("主题色、字体与字号")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 一种字体：名字用这种字体写出来；中文字体没下好时显示进度
    private struct FontRow: View {
        let option: LookFont
        let selected: Bool
        let pick: () -> Void
        @State private var look = Look.shared

        private var sample: Font {
            if let name = option.cjk, look.readyFonts.contains(name) { return .custom(name, size: 17, relativeTo: .body) }
            return .system(.body, design: option.design)
        }

        var body: some View {
            Button(action: pick) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(option.name)  Aa 你好").font(sample).foregroundStyle(.primary)
                        Text(look.fontState(option) ?? option.detail).font(.ui(.footnote))
                            .foregroundStyle(look.failures[option.cjk ?? ""] != nil ? Theme.removed : .secondary)
                    }
                    Spacer()
                    if let name = option.cjk, let progress = look.downloads[name] {
                        ProgressView(value: progress).progressViewStyle(.circular).controlSize(.small)
                    } else if selected {
                        Image(systemName: "checkmark").font(.ui(.body).weight(.semibold)).foregroundStyle(Theme.wechatGreen)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }

    /// 七档字号：左右两个大小不同的「A」，拖到哪档界面立刻跟着变
    private struct SizeSlider: View {
        @Binding var sizeID: String

        private var index: Double {
            Double(LookSize.all.firstIndex { $0.id == sizeID } ?? 3)
        }

        var body: some View {
            VStack(spacing: 6) {
                HStack(spacing: 12) {
                    Text("A").font(.system(size: 13))
                    Slider(value: Binding(get: { index }, set: { value in
                        let picked = LookSize.all[max(0, min(LookSize.all.count - 1, Int(value.rounded())))]
                        if picked.id != sizeID { sizeID = picked.id; Haptics.tap() }
                    }), in: 0...Double(LookSize.all.count - 1), step: 1)
                    Text("A").font(.system(size: 22))
                }
                Text(LookSize.named(sizeID)?.name ?? L("标准")).font(.ui(.footnote)).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("字号")
            .accessibilityValue(LookSize.named(sizeID)?.name ?? L("标准"))
            .accessibilityAdjustableAction { direction in
                let i = Int(index)
                let next = direction == .increment ? min(LookSize.all.count - 1, i + 1) : max(0, i - 1)
                sizeID = LookSize.all[next].id
            }
        }
    }
}

extension Look {
    /// 设置首页「外观」那一行右边的小字
    var summary: String {
        "\(theme.name) · \(font.name) · \(size?.name ?? L("跟随系统"))"
    }
}
#endif
