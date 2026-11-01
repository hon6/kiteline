import AppKit
import Combine
import SwiftUI
import KitelineKit

/// 侧栏底栏里的绿色向上箭头（手机数和右边几个图标中间）：只在有新版本、下载中、装好待重启时出现，没有更新时不占地方；
/// 下载中外圈一道进度；点开更新窗口
struct UpdateButton: View {
    @ObservedObject var updater = Updater.shared
    var size: CGFloat = 28
    @State private var hovering = false

    var body: some View {
        if updater.visible {
            Button { UpdateWindowController.shared.show() } label: {
                ZStack {
                    Circle().fill(Color.green.opacity(hovering ? 0.85 : 1))
                    Image(systemName: "arrow.up").font(.system(size: size * 0.46, weight: .bold)).foregroundStyle(.white)
                    if updater.phase == .downloading {
                        Circle().stroke(Color.white.opacity(0.3), lineWidth: 2).padding(2)
                        Circle().trim(from: 0, to: updater.progress)
                            .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90)).padding(2)
                    }
                }
                .frame(width: size, height: size)
                .shadow(color: .green.opacity(0.35), radius: 3, y: 1)
                // 和底栏其他按钮一样至少 32×32 好点中
                .frame(minWidth: 32, minHeight: 32)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(tip)
        }
    }

    private var tip: String {
        let version = updater.release?.version ?? ""
        switch updater.phase {
        case .ready: return L("新版本已安装，轻点重启以完成更新")
        case .downloading: return L("正在下载 Kiteline %@（%@）", version, "\(Int(updater.progress * 100))%")
        case .installing: return L("正在安装 Kiteline %@…", version)
        default: return L("有新版本：Kiteline %@", version)
        }
    }
}

/// 更新弹窗（同 Windows / Linux 客户端的 UpdateDialog）：新版本号、大小、更新说明 → 下载并安装（进度条）→ 装好后「立即重启 / 稍后」。
/// 一个窗口跟着状态变；下载装好后自动弹出来问要不要重启
final class UpdateWindowController: NSWindowController, NSWindowDelegate {
    static let shared = UpdateWindowController()
    private var watch: AnyCancellable?

    private init() {
        let hosting = NSHostingController(rootView: UpdateView().tarsLook())
        hosting.sizingOptions = [.preferredContentSize]
        let panel = NSPanel(contentViewController: hosting)
        panel.styleMask = [.titled, .closable, .fullSizeContentView]
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.title = "Kiteline"
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        // 装好了：弹出来问要不要现在重启
        watch = Updater.shared.$phase.removeDuplicates().sink { [weak self] phase in
            if phase == .ready { DispatchQueue.main.async { self?.show() } }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        guard let window else { return }
        if !window.isVisible {
            if let main = MainWindowController.shared.window, main.isVisible {
                let frame = main.frame
                window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.maxY - window.frame.height - 120))
            } else {
                window.center()
            }
        }
        // 测试实例不抢前台（用户可能正在用这台电脑）
        if !AppConfig.isolated { NSApp.activate(ignoringOtherApps: true) }
        window.makeKeyAndOrderFront(nil)
    }

    func close(_ sender: Any? = nil) { window?.close() }
}

private struct UpdateView: View {
    @ObservedObject var updater = Updater.shared

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
            Text(title).font(.app(size: 15, weight: .bold)).multilineTextAlignment(.center)
            if !detail.isEmpty {
                Text(detail).font(.app(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            if showsNotes, let notes = updater.release?.notes.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                ScrollView {
                    Text(notes).font(.app(size: 12)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(maxHeight: 200).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            switch updater.phase {
            case .downloading:
                ProgressView(value: updater.progress).tint(.green)
            case .installing, .restarting, .checking:
                ProgressView().progressViewStyle(.linear).tint(.green)
            default:
                EmptyView()
            }
            buttons.padding(.top, 4)
        }
        .padding(.horizontal, 22).padding(.top, 26).padding(.bottom, 20)
        .frame(width: 420)
        .animation(.snappy(duration: 0.2), value: updater.phase)
    }

    private var version: String { updater.release?.version ?? "" }
    private var showsNotes: Bool { updater.phase == .available || (updater.phase == .error && !updater.supported) }

    private var title: String {
        if !updater.supported && updater.phase == .available { return L("Kiteline %@ 可用", version) }
        switch updater.phase {
        case .available: return L("Kiteline %@ 可用", version)
        case .downloading: return L("正在下载 Kiteline %@", version)
        case .installing: return L("正在安装 Kiteline %@", version)
        case .ready: return L("新版本已安装")
        case .restarting: return L("正在重启 Kiteline…")
        case .error: return L("更新失败")
        case .checking: return L("正在检查更新…")
        default: return L("已是最新版本")
        }
    }

    private var detail: String {
        if !updater.supported && updater.phase == .available { return L("%@，请到官网下载新版本。", updater.reason) }
        switch updater.phase {
        case .available:
            let size = (updater.release?.size ?? 0) > 0 ? " · " + ByteCountFormatter.string(fromByteCount: updater.release!.size, countStyle: .file) : ""
            return L("当前版本 %@", updater.current) + size + "\n" + L("下载后在后台自动安装，装好后重启即可。")
        case .downloading:
            let total = updater.release?.size ?? 0
            let got = ByteCountFormatter.string(fromByteCount: updater.received, countStyle: .file)
            return total > 0 ? "\(got) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))" : got
        case .installing: return L("安装在后台进行，不影响使用。")
        case .ready: return L("重启 Kiteline 后生效，正在进行的会话不受影响。")
        case .restarting: return L("新版本启动后会自动打开。")
        case .error: return updater.error.isEmpty ? L("更新失败") : updater.error
        case .checking: return ""
        default: return L("当前版本 %@", updater.current)
        }
    }

    @ViewBuilder private var buttons: some View {
        let close = { UpdateWindowController.shared.close() }
        HStack(spacing: 10) {
            if !updater.supported && updater.phase == .available {
                pair(L("以后再说"), close, L("打开下载页")) { NSWorkspace.shared.open(updater.downloadPage); close() }
            } else {
                switch updater.phase {
                case .available: pair(L("以后再说"), { updater.later(); close() }, L("下载并安装")) { updater.begin() }
                case .downloading: pair(L("取消下载"), { updater.cancel() }, L("在后台下载"), close)
                case .installing: single(L("隐藏"), close)
                case .ready: pair(L("稍后"), close, L("立即重启")) { updater.restart() }
                case .error: pair(L("关闭"), close, L("重试")) { updater.begin() }
                case .restarting, .checking: EmptyView()
                default: single(L("好"), close)
                }
            }
        }
    }

    private func pair(_ secondary: String, _ secondaryAction: @escaping () -> Void, _ primary: String, _ primaryAction: @escaping () -> Void) -> some View {
        Group {
            Button(action: secondaryAction) { Text(secondary).frame(maxWidth: .infinity) }.tarsButton().controlSize(.large)
            Button(action: primaryAction) { Text(primary).frame(maxWidth: .infinity) }.tarsButton(prominent: true).controlSize(.large).tint(.green)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func single(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(label).frame(maxWidth: .infinity) }.tarsButton(prominent: true).controlSize(.large).tint(.green)
            .keyboardShortcut(.defaultAction)
    }
}
