import AVFAudio
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// 录音：16kHz 单声道 WAV（和网页版一样，Mac 上的语音识别一定认得）。iPhone、Mac（听写按钮）共用
@MainActor
@Observable
final class VoiceRecorder {
    private(set) var recording = false
    /// 最近一段时间的音量（0…1），画声波用，最新的在最后
    private(set) var levels: [Double] = Array(repeating: 0, count: 26)
    private(set) var started = Date()
    private var recorder: AVAudioRecorder?
    private var meter: Task<Void, Never>?
    private let file = FileManager.default.temporaryDirectory.appendingPathComponent("tars-voice.wav")

    /// 第一次用会弹系统的麦克风授权；没给权限返回 false
    func start() async -> Bool {
        guard await AVAudioApplication.requestRecordPermission() else { return false }
        // 录音时不朗读：正在读的停下，任务完成之类的播报等说完再读
        Speaker.shared.pauseForMic()
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            #endif
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            ]
            let recorder = try AVAudioRecorder(url: file, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else { Speaker.shared.resumeAfterMic(); return false }
            self.recorder = recorder
            recording = true
            started = Date()
            levels = Array(repeating: 0, count: levels.count)
            meter = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, let recorder = self.recorder else { return }
                    recorder.updateMeters()
                    // -50dB 以下当静音，0dB 满格
                    let level = max(0, min(1, (Double(recorder.averagePower(forChannel: 0)) + 50) / 50))
                    self.levels = Array(self.levels.dropFirst()) + [level]
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }
            return true
        } catch {
            Speaker.shared.resumeAfterMic()
            return false
        }
    }

    var elapsed: Double { recording ? Date().timeIntervalSince(started) : 0 }

    /// 停下：返回录音和时长；cancel = 取消，什么都不返回
    func stop(cancel: Bool) -> (data: Data, duration: Double)? {
        meter?.cancel()
        meter = nil
        let duration = recorder?.currentTime ?? 0
        recorder?.stop()
        recorder = nil
        recording = false
        levels = Array(repeating: 0, count: levels.count)
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        Speaker.shared.resumeAfterMic()
        guard !cancel, let data = try? Data(contentsOf: file) else { return nil }
        try? FileManager.default.removeItem(at: file)
        return (data, duration)
    }
}

#if os(iOS)
/// 一次「按住说话」：手指在哪、录了多久。对话页按它画微信那样的全屏录音层
@MainActor
@Observable
final class VoiceSession {
    enum Zone { case send, cancel, text }

    var active = false
    var zone: Zone = .send
    let recorder = VoiceRecorder()
    /// 录音层上「✕」「文」两个按钮在屏幕上的位置（手指滑过去就切换）
    var cancelFrame: CGRect = .zero
    var textFrame: CGRect = .zero
    /// 转好的文字：输入栏收到后放进输入框
    var transcript: String?
    var converting = false

    static let maxSeconds = 60.0

    func zone(at point: CGPoint) -> Zone {
        // 目标放大一圈，好按（和网页版一样）
        if cancelFrame.insetBy(dx: -30, dy: -40).contains(point) { return .cancel }
        if textFrame.insetBy(dx: -30, dy: -40).contains(point) { return .text }
        return .send
    }
}

/// 「按住 说话」：按住录，松开发；手指滑到 ✕ 取消，滑到「文」只转成文字放进输入框
struct HoldToTalk: View {
    @Environment(AppModel.self) private var model
    let key: String
    let voice: VoiceSession
    /// 输入栏里附着的图、文件，跟这段话一起发
    let images: () -> [(name: String, data: Data, preview: Data)]
    var files: () -> [(name: String, data: Data)] = { [] }
    let sent: () -> Void
    /// 不发语音、先转成文字再交给它发（群聊：群里收的是文字），连同附着的图、文件
    var spoken: ((String, [(name: String, data: Data, preview: Data)], [(name: String, data: Data)]) -> Void)? = nil
    @State private var waitingPermission = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Text(voice.active ? "松开 结束" : "按住 说话")
            .font(.appFixed(size: 16, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.85))
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(voice.active ? Theme.holdPressed : Theme.field, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if !voice.active, !waitingPermission { begin() }
                        if voice.active, voice.recorder.recording {
                            let zone = voice.zone(at: value.location)
                            if zone != voice.zone { Haptics.select() }
                            voice.zone = zone
                        }
                    }
                    .onEnded { _ in finish() }
            )
            .task(id: voice.active) {
                // 最长 60 秒：到点按当前手势结束
                guard voice.active else { return }
                try? await Task.sleep(for: .seconds(VoiceSession.maxSeconds))
                if voice.active { finish() }
            }
            // 按着时被系统打断（来电、拉下控制中心、切到后台收不到松手）或页面关了：这段不要，麦克风放掉，朗读接着来
            .onChange(of: phase) { _, phase in if phase != .active { abandon() } }
            .onDisappear { abandon() }
    }

    private func abandon() {
        guard voice.active else { return }
        voice.active = false
        if voice.recorder.recording { _ = voice.recorder.stop(cancel: true) }
    }

    private func begin() {
        // 麦克风还没问过：这次先弹系统框，允许后再按住说；拒绝过：弹引导去设置
        guard Permissions.shared.state(.microphone) == .granted else {
            waitingPermission = true
            Task {
                if await Permissions.shared.ensure(.microphone) { model.flash(L("麦克风已授权，请再次按住说话")) }
                waitingPermission = false
            }
            return
        }
        Haptics.tap()
        voice.zone = .send
        withAnimation(.easeOut(duration: 0.18)) { voice.active = true }
        Task {
            if !(await voice.recorder.start()) {
                withAnimation { voice.active = false }
                model.flash(L("录音未能开始，请重试"))
            } else if !voice.active {
                _ = voice.recorder.stop(cancel: true)   // 录音还没起来手指就松开了：别让麦克风一直开着
            }
        }
    }

    private func finish() {
        guard voice.active else { return }
        let zone = voice.zone
        withAnimation(.easeIn(duration: 0.15)) { voice.active = false }
        guard voice.recorder.recording else { return }
        let elapsed = voice.recorder.elapsed
        guard let clip = voice.recorder.stop(cancel: zone == .cancel) else { return }
        guard elapsed >= 0.8 else { model.flash(L("说话时间太短")); return }
        Haptics.tap()
        if zone == .text {
            voice.converting = true
            Task {
                let text = await model.transcribe(clip.data)
                voice.converting = false
                if let text, !text.isEmpty { voice.transcript = text } else if text != nil { model.flash(L("未能识别，请重新说一遍")) }
            }
        } else if let spoken {
            let images = images(), files = files()
            voice.converting = true
            Task {
                let text = await model.transcribe(clip.data)
                voice.converting = false
                if let text, !text.isEmpty {
                    spoken(text, images, files)
                    sent()
                } else if text != nil {
                    model.flash(L("未能识别，请重新说一遍"))
                }
            }
        } else {
            model.sendVoice(key, audio: clip.data, duration: clip.duration, images: images(), files: files())
            sent()
        }
    }
}

/// 按住说话时盖住整个对话页的录音层（同微信）：中间绿色声波气泡，左「✕」取消、右「文」转文字，底部大弧形「松开 发送」
struct VoiceOverlay: View {
    let voice: VoiceSession

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.76).ignoresSafeArea()
                VStack(spacing: 0) {
                    Spacer()
                    bubble.frame(maxWidth: .infinity)
                    Spacer().frame(height: 46)
                    HStack {
                        target(.cancel, symbol: "xmark", label: nil)
                        Spacer()
                        target(.text, symbol: nil, label: L("文"))
                    }
                    .padding(.horizontal, width * 0.14)
                    Text(hint)
                        .font(.appFixed(size: 15))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.top, 22)
                        .padding(.bottom, 12)
                    arc(width: width)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private var hint: String {
        switch voice.zone {
        case .send: return L("松开 发送")
        case .cancel: return L("松开 取消")
        case .text: return L("松开 转文字")
        }
    }

    /// 录音气泡：发送是绿色，滑到取消变红，滑到转文字变宽变白
    private var bubble: some View {
        let color: Color = voice.zone == .cancel ? Theme.removed : (voice.zone == .text ? .white : Theme.wechatBubbleGreen)
        return VStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(Array(voice.recorder.levels.enumerated()), id: \.offset) { _, level in
                    Capsule().fill(Color.black.opacity(voice.zone == .text ? 0.5 : 0.7))
                        .frame(width: 3, height: 4 + 26 * level)
                }
            }
            .frame(height: 32)
            .animation(.linear(duration: 0.08), value: voice.recorder.levels)
            if voice.zone == .text {
                Text("松开后转为文字，编辑后发送").font(.ui(.footnote)).foregroundStyle(.black.opacity(0.55))
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .frame(minWidth: voice.zone == .text ? 260 : 170)
        .background(color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .bottom) {
            Triangle().fill(color).frame(width: 16, height: 9).rotationEffect(.degrees(180)).offset(y: 8)
        }
        .overlay(alignment: .top) {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let elapsed = voice.recorder.elapsed
                let left = VoiceSession.maxSeconds - elapsed
                Text(left <= 10 ? L("剩余 %@ 秒", "\(max(0, Int(left.rounded(.up))))") : String(format: "%d:%02d", Int(elapsed) / 60, Int(elapsed) % 60))
                    .font(.ui(.footnote).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                    .offset(y: -26)
            }
        }
        .animation(.snappy(duration: 0.2), value: voice.zone)
    }

    private func target(_ zone: VoiceSession.Zone, symbol: String?, label: String?) -> some View {
        let on = voice.zone == zone
        return ZStack {
            Circle().fill(on ? Color.white : Color.white.opacity(0.16))
            if let symbol {
                Image(systemName: symbol).font(.system(size: on ? 28 : 24, weight: .medium))
            } else if let label {
                Text(label).font(.appFixed(size: on ? 28 : 24, weight: .medium))
            }
        }
        .foregroundStyle(on ? Color.black.opacity(0.8) : Color.white.opacity(0.75))
        .frame(width: on ? 86 : 72, height: on ? 86 : 72)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            if zone == .cancel { voice.cancelFrame = frame } else { voice.textFrame = frame }
        }
        .animation(.snappy(duration: 0.18), value: on)
    }

    /// 底部大弧形：手指还在上面（发送）时亮，滑走变暗
    private func arc(width: CGFloat) -> some View {
        let on = voice.zone == .send
        return ZStack(alignment: .top) {
            Ellipse()
                .fill(on ? Color(white: 0.93) : Color(white: 0.28))
                .frame(width: width * 1.7, height: 330)
                .offset(y: 0)
            Image(systemName: "waveform")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(on ? Color.black.opacity(0.55) : Color.white.opacity(0.6))
                .padding(.top, 48)
        }
        .frame(width: width, height: 150, alignment: .top)
        .clipped()
    }
}

/// 「按住 说话」只转文字（新任务这类还没有会话、不能直接发语音的地方）：按住录，松开把话转成文字交给 done，
/// 改好再点「开始」；手指移出按钮再松开 = 取消。录音中按钮本身显示声波和时长，不盖全屏
struct HoldToDictate: View {
    @Environment(AppModel.self) private var model
    let done: (String) -> Void
    @State private var recorder = VoiceRecorder()
    @State private var active = false
    @State private var inside = true
    @State private var converting = false
    @State private var waitingPermission = false
    @State private var frame: CGRect = .zero
    @Environment(\.scenePhase) private var phase

    var body: some View {
        HStack(spacing: 10) {
            if converting {
                ProgressView().controlSize(.small)
                Text("正在转写…")
            } else if active {
                HStack(spacing: 2) {
                    ForEach(Array(recorder.levels.suffix(14).enumerated()), id: \.offset) { _, level in
                        Capsule().fill(inside ? Color.primary.opacity(0.6) : Theme.removed)
                            .frame(width: 3, height: 3 + 16 * level)
                    }
                }
                .frame(height: 20)
                .animation(.linear(duration: 0.08), value: recorder.levels)
                Text(inside ? "松开 转文字" : "松开 取消").foregroundStyle(inside ? Color.primary : Theme.removed)
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    let elapsed = Int(recorder.elapsed)
                    Text(String(format: "%d:%02d", elapsed / 60, elapsed % 60)).monospacedDigit().foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "mic.fill")
                Text("按住 说话")
            }
        }
        .font(.ui(.subheadline).weight(.medium))
        .foregroundStyle(.primary.opacity(0.85))
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(active ? Theme.holdPressed : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if !active, !waitingPermission, !converting { begin() }
                    guard active else { return }
                    let now = frame.insetBy(dx: -24, dy: -60).contains(value.location)
                    if now != inside { Haptics.select(); inside = now }
                }
                .onEnded { _ in finish() }
        )
        .task(id: active) {
            // 最长 60 秒：到点按松开处理
            guard active else { return }
            try? await Task.sleep(for: .seconds(VoiceSession.maxSeconds))
            if active { finish() }
        }
        // 按着说的时候别把弹出的页面拖下去
        .interactiveDismissDisabled(active || converting)
        // 按着时被系统打断（来电、拉下控制中心、切到后台收不到松手）或页面关了：这段不要，麦克风放掉，朗读接着来
        .onChange(of: phase) { _, phase in if phase != .active { abandon() } }
        .onDisappear { abandon() }
    }

    private func abandon() {
        guard active else { return }
        active = false
        if recorder.recording { _ = recorder.stop(cancel: true) }
    }

    private func begin() {
        // 麦克风还没问过：这次先弹系统框，允许后再按住说；拒绝过：弹引导去设置（同对话页）
        guard Permissions.shared.state(.microphone) == .granted else {
            waitingPermission = true
            Task {
                if await Permissions.shared.ensure(.microphone) { model.flash(L("麦克风已授权，请再次按住说话")) }
                waitingPermission = false
            }
            return
        }
        Haptics.tap()
        inside = true
        active = true
        Task {
            if !(await recorder.start()) {
                active = false
                model.flash(L("录音未能开始，请重试"))
            } else if !active {
                _ = recorder.stop(cancel: true)   // 录音还没起来手指就松开了：别让麦克风一直开着
            }
        }
    }

    private func finish() {
        guard active else { return }
        active = false
        guard recorder.recording else { return }
        let elapsed = recorder.elapsed
        guard let clip = recorder.stop(cancel: !inside) else { return }
        guard elapsed >= 0.8 else { model.flash(L("说话时间太短")); return }
        Haptics.tap()
        converting = true
        Task {
            let text = await model.transcribe(clip.data)
            converting = false
            if let text, !text.isEmpty { done(text) } else if text != nil { model.flash(L("未能识别，请重新说一遍")) }
        }
    }
}

/// 正在把语音转成文字：输入栏上方的小提示
struct ConvertingHint: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("正在转写…").font(.ui(.footnote)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .floatingPill()
    }
}

#endif

/// 气泡的小尖角、录音气泡下面的小三角
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// 回放发过的语音（Mac 存着录音）
@MainActor
@Observable
final class VoicePlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = VoicePlayer()
    private(set) var playing: String?
    private var player: AVAudioPlayer?

    func toggle(_ id: String, api: MacAPI) {
        if playing == id { stop(); return }
        stop()
        playing = id
        Task {
            guard let data = try? await api.data("/api/voice-audio", ["id": id]), playing == id else {
                if playing == id { playing = nil }
                return
            }
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif
            player = try? AVAudioPlayer(data: data)
            player?.delegate = self
            if player?.play() != true { playing = nil }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playing = nil }
    }
}

#if os(macOS)
/// Mac 上的「听写」（手机上是「按住 说话」）：点一下开始录，说完再点一下（或满 60 秒）把话转成文字交给 done；
/// 录音时按钮里显示声波和时长，旁边的 ✕ 放弃这段。转写同手机，交给本机的语音识别（普通话走本机模型）
struct MacDictateButton: View {
    @Environment(AppModel.self) private var model
    /// 只画一个麦克风圆圈（放在单行输入框旁边）；录音、转写时照常显示声波和文字
    var compact = false
    let done: (String) -> Void
    @State private var recorder = VoiceRecorder()
    @State private var starting = false
    @State private var converting = false

    static let maxSeconds = 60.0

    var body: some View {
        HStack(spacing: 4) {
            if converting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(L("正在转写…"))
                }
                .foregroundStyle(.secondary)
                .modifier(DictateChip(active: false, hovering: false))
            } else if recorder.recording {
                Button(action: finish) {
                    HStack(spacing: 6) {
                        Circle().fill(MacPalette.red).frame(width: 6, height: 6)
                        HStack(spacing: 2) {
                            ForEach(Array(recorder.levels.suffix(10).enumerated()), id: \.offset) { _, level in
                                Capsule().fill(Color.primary.opacity(0.55)).frame(width: 2, height: 3 + 11 * level)
                            }
                        }
                        .frame(height: 14)
                        .animation(.linear(duration: 0.08), value: recorder.levels)
                        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                            let elapsed = Int(recorder.elapsed)
                            Text(String(format: "%d:%02d", elapsed / 60, elapsed % 60)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Text(L("完成")).fontWeight(.medium)
                    }
                }
                .buttonStyle(DictateChipStyle(active: true))
                .help(L("结束录音并转写为文字"))
                Button(action: cancel) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(DictateChipStyle(active: false, circle: true))
                .help(L("放弃这段录音"))
            } else if compact {
                Button(action: start) {
                    Image(systemName: "mic").font(.system(size: 12, weight: .medium))
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(DictateChipStyle(active: false, circle: true))
                .disabled(starting)
                .accessibilityLabel(L("听写"))
                .help(L("听写：点击开始录音，说完再次点击转写为文字（最长 %@ 秒）", "\(Int(Self.maxSeconds))"))
            } else {
                Button(action: start) {
                    Label(L("听写"), systemImage: "mic").labelStyle(.titleAndIcon)
                }
                .buttonStyle(DictateChipStyle(active: false))
                .disabled(starting)
                .help(L("点击开始录音，说完再次点击转写为文字（最长 %@ 秒）", "\(Int(Self.maxSeconds))"))
            }
        }
        .font(.ui(.subheadline))
        .task(id: recorder.recording) {
            guard recorder.recording else { return }
            try? await Task.sleep(for: .seconds(Self.maxSeconds))
            if recorder.recording { finish() }
        }
        // 录着音把面板关了：这段不要，麦克风也放掉
        .onDisappear { if recorder.recording { _ = recorder.stop(cancel: true) } }
    }

    private func start() {
        // 拒绝过：系统不会再弹授权框，直接打开「隐私与安全性 → 麦克风」
        guard AVAudioApplication.shared.recordPermission != .denied else { askInSettings(); return }
        starting = true
        Task {
            let ok = await recorder.start()
            starting = false
            guard !ok else { return }
            if AVAudioApplication.shared.recordPermission == .denied { askInSettings() } else { model.flash(L("录音未能开始，请重试")) }
        }
    }

    private func finish() {
        guard recorder.recording else { return }
        let elapsed = recorder.elapsed
        guard let clip = recorder.stop(cancel: false) else { return }
        guard elapsed >= 0.8 else { model.flash(L("说话时间太短")); return }
        converting = true
        Task {
            let text = await model.transcribe(clip.data)
            converting = false
            if let text, !text.isEmpty { done(text) } else if text != nil { model.flash(L("未能识别，请重新说一遍")) }
        }
    }

    private func cancel() { _ = recorder.stop(cancel: true) }

    private func askInSettings() {
        model.flash(L("麦克风权限未开启，请在「系统设置 → 隐私与安全性 → 麦克风」中允许 Kiteline"))
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
    }
}

/// 听写按钮的样子：浅灰胶囊，鼠标指上去深一点；录音中换成淡红底
private struct DictateChipStyle: ButtonStyle {
    let active: Bool
    var circle = false

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, active: active, circle: circle)
    }

    private struct Face: View {
        let configuration: Configuration
        let active: Bool
        let circle: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            Group {
                if circle {
                    configuration.label
                        .foregroundStyle(.secondary)
                        .background(Color.primary.opacity(hovering ? 0.12 : 0.06), in: Circle())
                } else {
                    configuration.label.modifier(DictateChip(active: active, hovering: hovering))
                }
            }
            .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
            .onHover { hovering = $0 }
        }
    }
}

private struct DictateChip: ViewModifier {
    let active: Bool
    let hovering: Bool

    func body(content: Content) -> some View {
        content
            .foregroundStyle(active ? Color.primary : MacPalette.text2)
            .padding(.horizontal, 10).frame(height: 26)
            .background(active ? MacPalette.red.opacity(hovering ? 0.2 : 0.13) : Color.primary.opacity(hovering ? 0.1 : 0.05),
                        in: Capsule())
            .contentShape(Capsule())
    }
}
#endif
