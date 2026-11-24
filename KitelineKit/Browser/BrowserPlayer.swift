import SwiftUI

/// 浏览器操作回放（11-16 用户要的）：就在放大视图「Agent 的操作」那一块里回放，不弹窗（用户：反复弹很烦）。
/// 平时上面是实时画面、进度条停在最右边（实时）；点播放或把进度条往回拖，上面换成录像，列表里高亮当时那条指令；「回到实时」回来。
/// 录像里只存画面变了的帧，相邻两帧的时间差就是画面停了多久：正常速度按实际时长停留；「跳过等待」把超过 1 秒的停顿压成 0.6 秒；还能 2 / 4 / 8 倍速
@MainActor 
final class BrowserReplay: KLObservable {
    let _klRegistrar = KLRegistrar.make()
    let key: String
    weak var store: BrowserStore?

    /// 正在看录像（上面的画面换成录像）；false = 实时
    @Tracked private(set) var active = false
    @Tracked private(set) var playing = false
    @Tracked private(set) var frames: [BrowserStore.RecFrame] = []
    @Tracked private(set) var index = 0
    @Tracked private(set) var loading = false
    @Tracked var speed: Double = 1
    @Tracked var skipWait = true
    @Tracked private var end: Double = 0
    @Tracked private var current: String?
    @Tracked private var images: [Int: PlatformImage] = [:]
    private var fetching: Set<Int> = []
    private var loop: Task<Void, Never>?

    init(key: String, store: BrowserStore) {
        self.key = key
        self.store = store
    }

    // MARK: 时长

    /// 第 i 帧停留多久（秒）：到下一帧（最后一帧到录制结束）的实际时长；跳过等待时超过 1 秒的压成 0.6 秒
    func hold(_ i: Int) -> Double {
        guard frames.indices.contains(i) else { return 0 }
        let next = i + 1 < frames.count ? frames[i + 1].time : max(end, frames[i].time)
        let gap = max(0, next - frames[i].time) / 1000
        return skipWait && gap > 1.0 ? 0.6 : gap
    }

    var total: Double { frames.indices.reduce(0) { $0 + hold($1) } / speed }
    var position: Double { (0..<min(index, frames.count)).reduce(0) { $0 + hold($1) } / speed }
    /// 进度条位置（0～1）；实时时在最右边
    var progress: Double { active && frames.count > 1 ? Double(index) / Double(frames.count - 1) : 1 }
    /// 正在播的那一刻（秒）：列表据此高亮当时的指令
    var moment: Double? { active && frames.indices.contains(index) ? frames[index].time / 1000 : nil }

    var image: PlatformImage? {
        for i in stride(from: index, through: max(0, index - 40), by: -1) { if let image = images[i] { return image } }
        return nil
    }

    // MARK: 操作

    /// 点播放：实时时从头放（录像只有最新那段：浏览器开着这一段）；在看录像时暂停 / 继续
    func togglePlay() {
        if playing { pause(); return }
        Task {
            if !active { await enter(); seek(0) }
            if index >= frames.count - 1 { seek(0) }
            start()
        }
    }

    /// 拖进度条：拖到最右边 = 回到实时
    func scrub(_ value: Double) {
        if value >= 0.999, active { goLive(); return }
        Task {
            if !active { await enter() }
            pause()
            seek(Int((value * Double(max(0, frames.count - 1))).rounded()))
        }
    }

    func goLive() {
        pause()
        active = false
    }

    /// 浏览器关了：一打开就放录像
    func startIfClosed(_ closed: Bool) {
        guard closed, !active else { return }
        togglePlay()
    }

    private func enter() async {
        guard let store else { return }
        loading = true
        defer { loading = false }
        let recs = await store.recordings(key)
        guard let latest = recs.first, let data = await store.recording(key, latest.id) else { return }
        if current != latest.id { images = [:]; fetching = [] }
        current = latest.id
        frames = data.frames
        end = data.end
        active = !frames.isEmpty
        await store.refreshActions(key, force: true)
    }

    private func start() {
        playing = true
        loop?.cancel()
        loop = Task { [weak self] in
            while let self, self.playing, !Task.isCancelled, self.frames.indices.contains(self.index) {
                await self.ensure(self.index)
                try? await Task.sleep(seconds: max(0.03, self.hold(self.index) / self.speed))
                if Task.isCancelled || !self.playing { return }
                if self.index + 1 >= self.frames.count { self.playing = false; return }
                self.index += 1
            }
        }
    }

    private func pause() {
        playing = false
        loop?.cancel()
    }

    private func seek(_ i: Int) {
        index = max(0, min(frames.count - 1, i))
        Task { await ensure(index) }
    }

    /// 取这一帧所在的一段（一次 20 帧）和下一段，播放不卡
    private func ensure(_ i: Int) async {
        guard let id = current, let store else { return }
        let block = (i / 20) * 20
        for start in [block, block + 20] where start < frames.count && images[start] == nil && !fetching.contains(start) {
            fetching.insert(start)
            let got = await store.recFrames(key, id, from: start, count: 20)
            images.merge(got) { old, _ in old }
            fetching.remove(start)
        }
    }

    static func span(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// 「Agent 的操作」上面的回放控制：播放 / 暂停、进度条、时间、倍速、跳过等待
struct BrowserReplayBar: KLView {
    @KLBindable var replay: BrowserReplay
    var closed: Bool

    var klBody: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Button { replay.togglePlay() } label: {
                    Image(systemName: replay.playing ? "pause.fill" : "play.fill").font(.app(size: 14)).frame(width: 28, height: 26)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(replay.playing ? L("暂停") : L("回放"))
                Slider(value: Binding(get: { replay.progress }, set: { replay.scrub($0) }), in: 0...1)
                    .controlSize(.small)
                Text(replay.active ? "\(BrowserReplay.span(replay.position))/\(BrowserReplay.span(replay.total))" : (closed ? L("录像") : L("实时")))
                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(replay.active ? Color.secondary : Theme.claude)
                    .lineLimit(1).fixedSize()
            }
            HStack(spacing: 6) {
                Toggle(isOn: $replay.skipWait) { Text("跳过等待").font(.ui(.caption2)).lineLimit(1).fixedSize() }   // 列表窄的时候别折成两行
                    .toggleStyle(.button).controlSize(.mini)
                Spacer(minLength: 4)
                ForEach([1.0, 2.0, 4.0, 8.0], id: \.self) { value in
                    Button { replay.speed = value } label: {
                        Text("\(Int(value))×").font(.ui(.caption2).weight(replay.speed == value ? .semibold : .regular))
                            .lineLimit(1).fixedSize()
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5).fill(replay.speed == value ? Theme.claude.opacity(0.12) : .clear))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(replay.speed == value ? Theme.claude.opacity(0.35) : .clear, lineWidth: 0.8))
                            .foregroundStyle(replay.speed == value ? Theme.claude : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}
