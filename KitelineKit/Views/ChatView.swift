import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// 一个会话的对话页
struct ChatView: View {
    @Environment(AppModel.self) private var model
    let key: String
    /// 滚动时的状态放在不会触发重画的地方：手指一滑就整页重画，会和列表的高度估算互相拉扯，画面来回跳
    @State private var scroll = ScrollState()
    /// 只渲染可视区附近的行（见 RowWindow）
    @State private var window = RowWindow()
    /// 手指在滑时冻住对话内容（见 rows(_:_:)）；松手后 thaw 加一，按最新内容重画
    @State private var freeze = RowFreeze()
    @State private var thaw = 0
    /// 现在画最后多少行（Int.max = 全画）。刚打开（切标签、点进会话）先画最后十几行，上屏以后每轮补一截更早的：
    /// 新建的对话页没有排版缓存，一页 60 条一次排完要 0.3 秒左右，切过去要等这么久才出来（10-26 Mac 切到长会话的标签）。
    /// 往上补行时贴底的照样贴底（Mac 的 follow、iPhone 的 defaultScrollAnchor）
    @State private var revealed = 12
    /// 最多画最后多少行（Int.max = 全画）。会话开着一直往下聊，行只增不减，几百上千行的 VStack 每来一点内容都要整列重排，
    /// 越聊越卡（11-10）。平时只画最后 shownRows 行，更早的点「查看更早的消息」再展开；回到底部来了新消息时收回
    @State private var limit = ChatView.shownRows
    static let shownRows = 100
    @State private var showInfo = false
    /// Agent 详情（点助手头像、标题栏的 agent 标志、会话菜单）
    @State private var showAgentInfo = false
    @State private var showShare = false
    /// 会话菜单里点了「拉群协作」
    @State private var showGroup = false
    @State private var showTodos = false
    /// 点了「当前会话支持后台托管」的提示：后台运行的设置面板（见 HostedViews.swift）
    @State private var showHosted = false
    @State private var confirmCompact = false
    @State private var confirmStop = false
    @State private var confirmClose = false
    @State private var showSearch = false
    @State private var showMenu = false
    @State private var showMode = false
    @State private var showModel = false
    @State private var showAgents = false
    /// 右上角悬浮按钮打开的「执行过程」（agent → 轮次 → 步骤，见 TracePanel.swift）：宽时占右半边，窄时半屏升起
    @State private var showTrace = false
    @State private var showNewTask = false
    /// 往上翻着看的时候来了新消息：底部冒一个「新消息 ↓」（同网页版、微信）
    @State private var newPill = false
    /// 搜索结果点了哪条：滚过去（还没加载到就往前翻页找）
    @State private var jumpTarget: String?
    @State private var flashRow: String?
    /// 在屏幕上（被推进来的页面盖住时为 false）：底下盖着的同一个会话别抢走要跳的那条
    @State private var onScreen = false
    @State private var catchupDismissed = false
    @State private var bottomRequest = 0
    /// 对话区多宽（分列时一列可能很窄）：消息气泡按它留边
    @State private var chatWidth: CGFloat = 0
    /// 对话页多高（分屏上下分时一块可能很矮）：确认卡片里能滚的那段跟着缩，别把输入框挤出去
    @State private var chatHeight: CGFloat = 0
    /// 对话页底下实际贴着多高的安全区（输入栏按它往 Home 条里挪；浮动卡片里是 0）
    @State private var homeBottom: CGFloat?
    /// iPhone Duo 半折时对话页里的折痕：消息放在上（左）边那块，输入框和操作放在下（右）边那块
    @State private var fold: ChatFold?
    /// 系统把工具栏竖排在侧边（iPhone Duo 外屏、内屏横放）：标题、按钮换成能竖排的写法
    @State private var sideBars = false
    #if os(macOS)
    /// 对话区去掉标题栏、输入区后露出来的高度：消息不多时内容至少撑这么高、贴底放
    @State private var visibleHeight: CGFloat = 0
    #endif
    @Environment(\.openRoute) private var open
    /// 在分屏里：哪一块、是不是当前块（不在分屏里是 nil）
    @Environment(\.chatPane) private var pane
    #if os(iOS)
    @State private var voice = VoiceSession()
    #endif

    var body: some View {
        let _ = PerfTrace.body("ChatView")
        let chat = model.chat(key)
        // 只看自己这个会话的状态（见 AppModel.sessionSlot）：别的会话变了不连带重算。
        // 整页只看在忙 / 等确认 / 空闲；标题、输入区、「正在工作」各自读会话详情（SessionReader），
        // 电脑每秒推一次状态（正在执行哪个工具、用量……）时只重算那几小块（10-22 真机追踪：整页重算一次 30–40 ms，滑动时一顿一顿）
        let slot = model.sessionSlot(key)
        let activity = slot.activity
        let all = rows(chat, activity)
        // 刚打开只画最后一截，更早的分几轮补上（见 revealed）；要跳到某条消息时全画
        let shown = min(revealed, limit)
        let rows = jumpTarget == nil && shown < all.count ? Array(all.suffix(shown)) : all
        ScrollViewReader { proxy in
            ScrollView {
                // 不用 LazyVStack：懒加载的行高是估算的，Claude 的回复边写边变长时，后面的行没跟着重排，
                // 新消息会叠在上一条上面；往上翻时估算高度一变还会被拽回底部。一页 60 条，分几轮排完（见 revealed）
                RowsStack {
                    // 还在补更早的行时不显示「查看更早的消息」（补完自然出现）
                    if rows.count == all.count {
                        historyHeader(chat) {
                            // 加载更早的消息：加载完停在原来看的那条上，不跳走
                            let anchor = rows.first?.id
                            scroll.stick = false
                            limit = .max
                            revealed = .max
                            await model.loadHistory(key, older: true)
                            if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { window.headerHeight = $0 }
                    } else if revealed >= limit {
                        // 只画着最后 limit 行（见 limit）：先在本地展开更早的一截，展开完停在原来看的那条上
                        Button("查看更早的消息") {
                            let anchor = rows.first?.id
                            scroll.stick = false
                            limit = limit > Int.max - Self.shownRows ? .max : limit + Self.shownRows
                            revealed = limit
                            if let anchor { DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) } }
                        }
                        .font(.ui(.footnote)).padding(10)
                        .frame(maxWidth: .infinity)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { window.headerHeight = $0 }
                    }
                    // 消息行单独成一个视图、按值比较：会话状态变了（正在执行哪个工具、用量……）但行没变时整段跳过，
                    // 不用把几十上百行逐个重新比一遍（10-22 真机追踪：每次推送更新都要重算整页，滑动时一顿一顿）
                    ChatRowsList(window: window, key: key, rows: rows, flashRow: flashRow).equatable()
                    if activity == "busy", model.connected {
                        SessionReader(slot: slot) { session in
                            if let session {
                                let working = WorkingView(since: Date(timeIntervalSince1970: (chat.turnStart ?? session.updatedAt ?? Date().timeIntervalSince1970 * 1000) / 1000),
                                                          activity: session.activityText, stuckMinutes: session.stuckMinutes)
                                if session.stuckMinutes != nil {
                                    working   // 变红的「可能停滞」可能折成两行，照常排（几分钟才变一次）
                                } else {
                                    // 平常这一行放在固定高度的一层上：每秒跳的计时、电脑每秒推来的「正在执行…」变了不牵动整列消息重新排版
                                    //（10-26 实测 Mac 4 列各有一个在跑：每秒整窗重排，CPU 26%；都空闲时 0.1%）
                                    Color.clear.frame(height: WorkingView.rowHeight)
                                        .overlay(alignment: .topLeading) { working }
                                }
                            }
                        }
                    }
                    Color.clear.frame(height: 6).id("bottom")
                }
                .padding(.bottom, 4)
                .environment(\.chatWidth, messageWidth)
                .environment(\.chatAgent, slot.agent)
                .environment(\.chatFace, slot.face)
                .environment(\.openAgentInfo, AgentInfoOpener { showAgentInfo = true })
                #if DEBUG && os(iOS)
                // 排查「能左右拖」：钉宽之前整列的宽（哪一块比屏幕宽，见 ScrollPerf.noteScrollWidth）
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { ScrollPerf.shared.stackWidth = $0 }
                #endif
                #if os(iOS)
                // 内容宽度钉成外面给这一块的宽（量法见下面的 chatWidth，不随内容变，不会互相依赖）：哪一行比屏幕宽也撑不宽整页，
                // 页面只能上下滑（10-22 反馈：加载几次更早的消息后能左右拖、松手弹回来）
                .frame(width: chatWidth > 0 ? chatWidth : nil, alignment: .leading)
                // 再把底下系统滚动区的横向回弹关掉（见 VerticalOnlyScroll）
                .background(VerticalOnlyScroll())
                #endif
                // 对话内容的字号、行高照 VS Code 里的 Claude Code：正文 13、行高 1.5（见 ChatType）
                .font(ChatType.body)
                .lineSpacing(ChatType.lineSpacing)
                #if os(macOS)
                // 照网页版 Mac 样式：内容最宽 880，居中
                .frame(maxWidth: 880)
                .frame(maxWidth: .infinity)
                // 消息少、不满一屏时内容撑满可视区贴底放：不然系统把标题栏下的滚动边缘效果（模糊 + 一道线）拉长到内容顶上，空白里横着一条线
                .frame(minHeight: visibleHeight, alignment: .bottom)
                .onGeometryChange(for: ContentMetrics.self) { geo in
                    ContentMetrics(height: geo.size.height, bottom: geo.frame(in: .named("chatScroll")).maxY)
                } action: { metrics in
                    follow(metrics, proxy: proxy)
                }
                #endif
            }
            // 手机上只上下滚：内容不比屏幕宽时横向不回弹。
            // 别用 containerRelativeFrame 把内容钉成可视区宽：滚动区宽和内容宽互相依赖，字号大时整页会随机被撑宽
            #if os(iOS)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            #endif
            .modifier(ChatScrollFollow(scroll: scroll, window: window, freeze: freeze, newPill: $newPill, proxy: proxy) { thaw += 1 })
            .onChange(of: rows.map(\.id), initial: true) { _, ids in window.setOrder(ids) }
            .onChange(of: messageWidth, initial: true) { _, width in
                // 宽度变了：换行跟着变、内容变高变矮，系统不挪滚动位置——贴底的会停在内容外面（整块空白，要碰一下才弹回来），
                // 往上翻着的会跳到别处（10-24 反馈 iPad 收起、拉出左栏时）。排完版再滚回去：贴底的回到底，
                // 翻着的回到原来顶上那一行（宽度刚量到、内容还按原来的宽排着时记下的，见下面量 chatWidth 的地方）
                window.setWidth(width)
                let anchor = scroll.widthAnchor
                scroll.widthAnchor = nil
                DispatchQueue.main.async {
                    if scroll.stick {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    } else if let anchor {
                        proxy.scrollTo(anchor, anchor: .top)
                    }
                }
            }
            #if SNAPSHOT
            .task {
                // 量滚动卡顿（TARS_BENCH_OUT）：先把更早的消息加载出来，等于点了几次「查看更早的消息」
                guard Snapshot.benchOutput != nil else { return }
                // 先等第一页加载完（还没加载完时 hasMore 是 false，会以为没有更早的消息）
                for _ in 0..<60 where !model.chat(key).loaded { try? await Task.sleep(for: .milliseconds(500)) }
                try? await Task.sleep(for: .seconds(1))
                for _ in 0..<Snapshot.benchPages where model.chat(key).hasMore {
                    scroll.stick = false
                    limit = .max
                    revealed = .max
                    await model.loadHistory(key, older: true)
                }
                Snapshot.benchReady = true
            }
            #endif
            #if (DEBUG || DEVICEBENCH) && os(iOS) && !SNAPSHOT
            .task {
                // 真机自动测试（DeviceBench）：先把更早的消息加载出来
                guard DeviceBench.active else { return }
                // 先等第一页加载完（还没加载完时 hasMore 是 false，会以为没有更早的消息）
                for _ in 0..<60 where !model.chat(key).loaded { try? await Task.sleep(for: .milliseconds(500)) }
                try? await Task.sleep(for: .seconds(1))
                for _ in 0..<DeviceBench.pages where model.chat(key).hasMore {
                    scroll.stick = false
                    limit = .max
                    revealed = .max
                    await model.loadHistory(key, older: true)
                }
                DeviceBench.ready = true
            }
            #endif
            // 量外面给这一块多宽，不量滚动区自己：哪一行比可用宽度宽会把滚动区撑宽，量到的宽又反过来定气泡留边、内容多宽……
            // 来回改个不停（10-22 Mac 分屏的窄列里死循环：CPU 占满，布局停在半路，左列钻到侧栏底下、右边空一大块）。
            // 最小宽写 0：这一层始终是外面给的宽，撑宽的内容靠左放、多出来的在右边被裁掉
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { geo in
                #if os(macOS)
                min(geo.size.width, 880)   // Mac 上内容最宽 880
                #else
                geo.size.width
                #endif
            } action: { width in
                // 要换宽度了：内容这时还按原来的宽排着，行高都是准的，记下可视区顶上那一行（排完新宽度再滚回它）
                if chatWidth > 0, abs(width - chatWidth) > 0.5 { scroll.widthAnchor = window.rowAtTop() }
                chatWidth = width
            }
            #if os(macOS)
            .coordinateSpace(.named("chatScroll"))
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                // 窗口拉高拉矮：贴着底的继续贴底
                scroll.viewport = height
                visibleHeight = height   // 已经是去掉标题栏、输入区后的高度
                if scroll.stick { DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            #endif
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.chatBackground)
            #if os(iOS)
            // 点对话区：收起键盘和「+」面板（同微信）。Mac 上没有这两样，不挂
            .simultaneousGesture(TapGesture().onEnded {
                Keyboard.hide()
                if chat.panelOpen { withAnimation(.snappy(duration: 0.2)) { chat.panelOpen = false } }
            })
            #endif
            .onChange(of: rows.last?.id) { _, _ in
                // 新消息来了：本来就在底部（或是我刚发的）就跟着滚下去；往上翻着看就只冒「新消息 ↓」
                if scroll.stick || rows.last.map(isPending) == true {
                    scroll.stick = true
                    newPill = false
                    // 看过更早的消息又回到底部了：收回只画最后 shownRows 行（见 limit）
                    if limit > Self.shownRows, jumpTarget == nil { limit = Self.shownRows }
                    withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
                } else {
                    newPill = true
                }
            }
            .onChange(of: bottomRequest) { _, _ in
                scroll.stick = true
                newPill = false
                withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .overlay(alignment: .top) {
                VStack(spacing: 6) {
                    NetStrip()
                    SessionReader(slot: slot) { session in
                        if let session { HostedTip(session: session) { showHosted = true } }
                    }
                    if let since = chat.newSince, !catchupDismissed {
                        CatchupPill(chat: chat, since: since, speaker: slot.speaker, expire: {
                            withAnimation(.easeOut(duration: 0.3)) { catchupDismissed = true }
                        }) {
                            catchupDismissed = true
                            scroll.stick = false
                            // 「以下是新消息」可能在只画的最后 limit 行之前：先全画出来再滚过去
                            limit = .max
                            revealed = .max
                            DispatchQueue.main.async { withAnimation { proxy.scrollTo("new-marker", anchor: .top) } }
                        }
                        .transition(.opacity)
                    }
                }
                .animation(.snappy, value: model.net.quality)
            }
            .overlay(alignment: .bottom) {
                if newPill {
                    Button { bottomRequest += 1 } label: {
                        Label("新消息", systemImage: "arrow.down").font(.ui(.footnote).weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .floatingPill()
                    }
                    .buttonStyle(.steady(.plain))
                    .foregroundStyle(Theme.wechatGreen)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: newPill)
            .task {
                // 先画的那一截上屏以后，每轮补 16 行更早的（见 revealed）
                while revealed < limit {
                    try? await Task.sleep(for: .milliseconds(16))
                    if Task.isCancelled { return }
                    revealed = min(revealed + 16, limit)
                }
            }
            .task(id: jumpTarget) {
                guard let target = jumpTarget else { return }
                revealed = .max   // 跳到某条消息要全画（跳完回到底部、来新消息时再收回，见 limit）
                limit = .max
                scroll.stick = false
                for _ in 0..<12 {
                    if let row = model.chat(key).rows(session: model.session(key)).first(where: { $0.contains(target) }) {
                        withAnimation(.snappy) { proxy.scrollTo(row.id, anchor: .center) }
                        flashRow = row.id
                        jumpTarget = nil
                        try? await Task.sleep(for: .seconds(1.6))
                        withAnimation { flashRow = nil }
                        return
                    }
                    guard model.chat(key).hasMore else { break }
                    await model.loadHistory(key, older: true)
                }
                model.flash(L("未找到此消息（可能尚未加载）"))
                jumpTarget = nil
            }
            // 输入区：平时在底下；iPhone Duo 半折时挪到折痕另一边（横折痕在下半块、竖折痕在右半块）
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if fold?.horizontal != false {
                    SessionReader(slot: slot) { foldable(session: $0, chat: chat) }
                        // 分屏里：输入栏上沿报给分屏，信绳不钉到输入栏上
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(ChatPanes.space)).minY } action: { top in
                            if let pane { pane.panes.composerTops[pane.id] = top }
                        }
                }
            }
            .safeAreaInset(edge: .trailing, spacing: 0) {
                if let fold, !fold.horizontal { SessionReader(slot: slot) { foldable(session: $0, chat: chat) } }
            }
        }
        // 右上角悬浮：打开 / 收起执行过程（在忙时按钮上一个呼吸的小点）
        .overlay(alignment: .topTrailing) { if TraceFeature.enabled { TraceButton(isOn: $showTrace, running: activity == "busy") } }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chatHeight = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { homeBottom = $0 }
        .environment(\.homeBottom, homeBottom)
        .readFold($fold)
        .readSideBars($sideBars)
        .modifier(TraceSplit(key: key, isOn: $showTrace && TraceFeature.enabled))
        #if os(iOS)
        .overlay { if voice.active { VoiceOverlay(voice: voice) } }
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if !KITELINE_MAC   // Mac 窗口有自己的标题栏（标题、文件、改动、测试、菜单），按钮点了走 externalAction
        // 工具栏竖排时（iPhone Duo）不放自己拼的标题，交给系统的标题、副标题
        .navigationTitle(sideBars && (pane?.ownsBar ?? true) ? (slot.info?.title ?? model.pastMeta[key]?.title ?? L("会话已结束")) : "")
        .sideSubtitle(sideBars && (pane?.ownsBar ?? true) ? (slot.info.map(ChatTitle.subtitle) ?? L("已结束")) : "")
        .toolbar {
            // 分屏时只有当前块往导航栏上放（几块都放会叠在一起）：标题、按钮都对当前块
            if pane?.ownsBar ?? true {
                if sideBars {
                    // iPhone Duo：工具栏竖排在侧边。系统只竖着放「名字 + 图标」的按钮，自己拼的视图会留在顶上横着占地方
                    ToolbarItemGroup(placement: .primaryAction) {
                        if slot.info != nil {
                            Button { model.setMarked(key, !model.isMarked(key)) } label: {
                                Label(model.isMarked(key) ? "取消标记" : "标记", systemImage: model.isMarked(key) ? "star.fill" : "star")
                            }
                            .tint(model.isMarked(key) ? Theme.claude : nil)
                        }
                        Button { speakLatest() } label: {
                            Label(Speaker.shared.speaking != nil ? "停止朗读" : "朗读",
                                  systemImage: Speaker.shared.speaking != nil ? "speaker.wave.2.fill" : "speaker.wave.2")
                        }
                        Button { showMenu = true } label: { Label("会话菜单", systemImage: "ellipsis") }
                    }
                } else {
                    ToolbarItem(placement: .principal) {
                        SessionReader(slot: slot) {
                            ChatTitle(session: $0, past: model.pastMeta[key], face: slot.face) { showAgentInfo = true }
                        }
                    }
                    // 同网页版：朗读（在读就停）+ ⋯ 会话菜单。放在一组里自己排，两个挨近一点
                    ToolbarItem(placement: .primaryAction) {
                        HStack(spacing: 0) {
                            // 标记：主题色实心星；点一下标记、再点取消（已结束的会话没有）
                            if slot.info != nil {
                                let marked = model.isMarked(key)
                                Button { model.setMarked(key, !marked) } label: {
                                    Image(systemName: marked ? "star.fill" : "star")
                                        .foregroundStyle(marked ? Theme.claude : Color.primary)
                                        .contentTransition(.symbolEffect(.replace))
                                        .barIcon()
                                }
                                .accessibilityLabel(marked ? "已标记，轻点取消标记" : "标记会话")
                            }
                            Button { speakLatest() } label: {
                                Image(systemName: Speaker.shared.speaking != nil ? "speaker.wave.2.fill" : "speaker.wave.2")
                                    .symbolEffect(.variableColor.iterative, isActive: Speaker.shared.speaking != nil)
                                    .barIcon()
                            }
                            .accessibilityLabel(Speaker.shared.speaking != nil ? "停止朗读" : "朗读最新回复")
                            Button { showMenu = true } label: { Image(systemName: "ellipsis").barIcon() }
                                .accessibilityLabel("会话菜单")
                        }
                    }
                }
            }
        }
        #endif
        // Mac 标题栏、横着的 iPhone 分屏标题条上的按钮：交给这个会话的对话页做
        .onChange(of: model.externalAction?.id) { _, _ in
            guard let request = model.externalAction, request.key == key else { return }
            model.externalAction = nil
            perform(request.action)
        }
        #if KITELINE_MAC
        // 把图拖进对话区：加进要发的图
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            Task { @MainActor in MacComposer.attach(await DroppedImages.load(providers), to: chat) }
            return true
        }
        #endif
        .modifier(ChatLinkOpener(key: key))
        .sheetPanel(isPresented: $showMenu) { SessionMenuSheet(key: key, perform: perform) }
        .sheetPanel(isPresented: $showMode) { ModeSheet(key: key) }
        .sheetPanel(isPresented: $showModel) { ModelSheet(key: key) }
        .sheetPanel(isPresented: goalSheet) { GoalSheet(key: key) }
        .sheetPanel(isPresented: $showAgents) { AgentMapSheet(key: key) }
        .sheetPanel(isPresented: $showInfo) { SessionReader(slot: slot) { session in if let session { SessionInfoView(session: session) } } }
        .sheetPanel(isPresented: $showAgentInfo) { AgentInfoSheet(key: key, agent: slot.agent) }
        .sheetPanel(isPresented: $showShare) { GuestShareSheet(key: key).environment(model) }
        .sheetPanel(isPresented: $showGroup) { GroupPickerSheet(mode: .create([key])) { open(.group($0)) }.environment(model) }
        .sheetPanel(isPresented: $showSearch) { ChatSearchSheet(key: key) { jumpTarget = $0 } }
        .sheetPanel(isPresented: $showNewTask) {
            SessionReader(slot: slot) { session in
                if let session, let cwd = session.cwd {
                    NewTaskView(preset: model.home.projects.first { $0.sourceId == session.sourceId && $0.cwd == cwd })
                } else {
                    NewTaskView()
                }
            }
        }
        .sheetPanel(isPresented: $showHosted) { HostedSetupSheet(sourceId: slot.info?.sourceId, key: key) }
        .sheetPanel(isPresented: $showTodos) {
            FitSheet(title: L("任务清单")) { TodoCard(todos: chat.todos).frame(maxWidth: .infinity) }
        }
        // 确认框：Mac 上是能拖动的小卡片，对着这块会话居中
        .confirmPanel(L("压缩上下文等同于在 Claude Code 中输入 /compact：将此前的对话总结为摘要以释放空间，部分细节可能丢失"),
                      isPresented: $confirmCompact, confirm: L("压缩上下文")) {
            model.send(key, text: "/compact", images: [])
        }
        .confirmPanel(slot.agent == Agents.defaultID ? L("中断 Claude 等同于在 Claude Code 中按 Esc：Claude 将停在当前步骤（正在执行的命令也会终止），之后可继续对话")
                                                     : L("中断 %@：将停在当前步骤（正在执行的命令也会终止），之后可继续对话", slot.speaker),
                      isPresented: $confirmStop, confirm: L("中断"), destructive: true) {
            Task { _ = await model.press(key, "esc", label: L("已中断（等同于按 Esc）")) }
        }
        // 要弹时才读会话详情：model.session 读的是整个会话列表，平时就读的话哪台电脑推一次状态，开着的几块对话页全要重算
        .confirmPanel(confirmClose ? CloseSessionText.message(model.session(key)) : "",
                      isPresented: $confirmClose, confirm: L("关闭会话"), destructive: true) {
            Task { _ = await model.closeSession(key) }
        }
        .onAppear {
            onScreen = true
            model.open(key, focus: pane?.isFocused ?? true)
            if let jump = model.jumpRequests.removeValue(forKey: key) { jumpTarget = jump }
        }
        // 已经开着这个会话时又要跳（待办里点「原消息」、分屏里换到这块）：onAppear 不会再来，在这里接
        .onChange(of: model.jumpRequests[key]) { _, target in
            guard let target, onScreen else { return }
            model.jumpRequests[key] = nil
            jumpTarget = target
        }
        .task { await model.loadPastMeta(key) }
        #if SNAPSHOT
        .task {
            if Snapshot.panel { chat.panelOpen = true }
            if Snapshot.terminal { chat.terminalOpen = true }
            if let back = Snapshot.scrollBack {
                try? await Task.sleep(for: .seconds(2.5))
                let rows = chat.rows(session: model.session(key))
                if case .bot(let item, _)? = rows.dropLast(back).last { jumpTarget = item.id }
                else if case .user(let item, _)? = rows.dropLast(back).last { jumpTarget = item.id }
            }
            if let zone = Snapshot.voiceZone {
                try? await Task.sleep(for: .seconds(2))
                voice.zone = ["cancel": .cancel, "text": .text][zone] ?? .send
                voice.active = true
            }
            if Snapshot.sheet == "menu" { try? await Task.sleep(for: .seconds(2)); showMenu = true }
            if Snapshot.sheet == "mode" { try? await Task.sleep(for: .seconds(2)); showMode = true }
            if Snapshot.sheet == "model" { try? await Task.sleep(for: .seconds(2)); showModel = true }
            if Snapshot.sheet == "agents" { try? await Task.sleep(for: .seconds(2)); showAgents = true }
            if Snapshot.sheet == "tracesplit" { try? await Task.sleep(for: .seconds(2)); showTrace = true }
            if Snapshot.sheet == "goal" { try? await Task.sleep(for: .seconds(2)); model.chat(key).goalSheet = true }
            if let text = Snapshot.send {
                try? await Task.sleep(for: .seconds(3))
                model.send(key, text: text, images: [])
            }
        }
        #endif
        .onDisappear {
            onScreen = false
            model.close(key)
        }
    }

    #if os(macOS)
    /// Mac 上判断「贴不贴底」只看位置：鼠标滚轮不报手势阶段，靠「手指在拖」判断的话，往上翻着看时一来新消息就会被拽回底部。
    /// 内容高度没变、位置变了 = 你在翻（滚轮、触控板、拖滚动条、翻页键）：离底部 160 以内算贴底，再往上就不贴；
    /// 内容高度变了 = 来了新内容：贴底的跟着滚到底，不贴底的不动（新消息会冒「新消息 ↓」）
    private func follow(_ metrics: ContentMetrics, proxy: ScrollViewProxy) {
        let distance = metrics.bottom - scroll.viewport
        if abs(metrics.height - scroll.contentHeight) > 0.5 {
            scroll.contentHeight = metrics.height
            if scroll.stick, distance > 1 { DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) } }
        } else {
            guard MacScrollInput.recent else {
                // 不是你在翻：显示器关了再开、窗口被系统挪到别的屏幕又挪回来时，窗口高度、滚动位置会被系统改动，
                // 以前一律当成「你往上翻了」，从此不再贴底，停在半截甚至最上面（11-10）。贴着底的拉回底部
                if scroll.stick, distance > 1 { DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) } }
                return
            }
            scroll.stick = distance < 160
            if scroll.stick, newPill { newPill = false }
        }
    }
    #endif

    /// 输入区：目标条、任务进展条、确认卡片、输入框；终端开着时输入框换成终端面板（确认卡片照常在上面）
    private func deck(session: SessionInfo?, chat: ChatStore) -> some View {
        VStack(spacing: 8) {
            if model.connected, let goal = session?.goal, GoalStrip.visible(goal) {
                GoalStrip(key: key, goal: goal)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if model.connected, let stage = session?.liveStage {
                StageStrip(stage: stage, available: chatHeight)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let session { PromptCard(session: session, chat: chat) }
            if chat.terminalOpen, let session, session.can("term") {
                TerminalPanel(key: key, session: session, chat: chat, available: chatHeight)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                composer(session: session, chat: chat)
            }
        }
        .animation(.snappy, value: session?.isWaiting)
        .animation(.snappy, value: session?.liveStage == nil)
        .animation(.snappy, value: session?.goal?.state)
        .environment(\.chatWidth, chatWidth)   // 分屏的窄块里：卡片按钮上下叠、打字时收起语音和停止键
        .environment(\.promptCap, promptCap)
        #if os(macOS)
        // 对话内容会滚到底部这一块下面：垫一层窗口底色，别从常用语、输入框之间透出来
        .padding(.top, 8)
        .background(Theme.chatBackground)
        #endif
    }

    @ViewBuilder
    private func composer(session: SessionInfo?, chat: ChatStore) -> some View {
        #if os(iOS)
        if let session { PluginUpdateHint(session: session) }   // 电脑上的插件要求更新版本的 Kiteline
        if voice.converting { ConvertingHint() }
        Composer(key: key, session: session, chat: chat, voice: voice,
                 onStop: { confirmStop = true }, onCompact: { confirmCompact = true },
                 onMode: { showMode = true }, onModel: { showModel = true }, onAgents: { showAgents = true },
                 onTodos: { showTodos = true })
        #elseif KITELINE_MAC
        MacComposer(key: key, session: session, chat: chat, onStop: { confirmStop = true },
                    onMode: { showMode = true }, onModel: { showModel = true }, onCompact: { confirmCompact = true },
                    onTodos: { showTodos = true }, onAgents: { showAgents = true })
        #endif
    }

    /// 输入区放在哪：平时就是输入区本身（在底下）；iPhone Duo 半折时占满折痕另一边那块，
    /// 输入框仍贴底（和没折时同一个位置），上面空出来的地方放会话当前状态和 Claude 的任务清单
    @ViewBuilder
    private func foldable(session: SessionInfo?, chat: ChatStore) -> some View {
        if let fold {
            VStack(spacing: 0) {
                FoldDeck(session: session, todos: chat.todos)
                deck(session: session, chat: chat)
            }
            .padding(fold.horizontal ? .top : .leading, fold.gap)
            .frame(width: fold.horizontal ? nil : fold.tail)
            .frame(height: fold.horizontal ? fold.tail : nil)
            .frame(maxHeight: fold.horizontal ? nil : .infinity)
            .background(Theme.chatBackground)
            .environment(\.chatWidth, fold.horizontal ? chatWidth : fold.tail - fold.gap)
        } else {
            deck(session: session, chat: chat)
        }
    }

    /// 消息区的宽：竖着的折痕把对话页分成左右两块时，消息只占左边那块
    private var messageWidth: CGFloat {
        guard let fold, !fold.horizontal else { return chatWidth }
        return fold.start
    }

    /// 分屏（多于一块）时确认卡片里能滚的那段最多多高：底下卡片 + 输入框最多占这一块七成，给消息留点地方；只有一块时不限
    /// iPhone Duo 横着半折时输入区只有下半块：卡片 + 输入框不超出这一块
    private var promptCap: CGFloat {
        if let fold, fold.horizontal { return max(48, fold.tail - fold.gap - 240) }
        guard let pane, pane.panes.count > 1, chatHeight > 0 else { return .infinity }
        #if os(macOS)
        let chrome: CGFloat = 210   // 卡片标题、按钮，加上输入框
        #else
        let chrome: CGFloat = 240
        #endif
        return max(48, chatHeight * 0.7 - chrome)
    }

    /// 目标面板（输入框下面的「目标」、目标条、会话菜单都改 ChatStore 的 goalSheet）
    private var goalSheet: Binding<Bool> {
        let chat = model.chat(key)
        return Binding(get: { chat.goalSheet }, set: { chat.goalSheet = $0 })
    }

    /// 会话菜单里点的：菜单收起后再做
    private func perform(_ action: SessionAction) {
        switch action {
        case .search: showSearch = true
        case .files: open(.files(key: key, path: ""))
        case .changes: open(.changes(key))
        case .tests: open(.tests(key))
        case .agents: showAgents = true
        case .stop: confirmStop = true
        case .mode: showMode = true
        case .model: showModel = true
        case .goal: model.chat(key).goalSheet = true
        case .compact: confirmCompact = true
        case .newTask: showNewTask = true
        case .info: showInfo = true
        case .agentInfo: showAgentInfo = true
        case .share: showShare = true
        case .group: showGroup = true
        case .bottom: bottomRequest += 1
        case .close: confirmClose = true
        case .menu: showMenu = true
        case .speak: speakLatest()
        case .terminal:
            let chat = model.chat(key)
            withAnimation(.snappy(duration: 0.25)) { chat.terminalOpen.toggle() }
        }
    }

    /// 朗读：在读就停；没在读就读 Claude 最新的一条回复
    private func speakLatest() {
        if Speaker.shared.speaking != nil { Speaker.shared.stop(); return }
        guard let latest = model.chat(key).items.values.filter({ $0.t == "text" && !($0.text ?? "").isEmpty }).max(by: ChatItem.ordered) else {
            model.flash(L("暂无可朗读的回复"))
            return
        }
        Speaker.shared.speak(latest.text ?? "", id: latest.id)
    }

    private func isPending(_ row: ChatRow) -> Bool {
        if case .pending = row { return true }
        return false
    }

    @ViewBuilder
    private func historyHeader(_ chat: ChatStore, loadOlder: @escaping () async -> Void) -> some View {
        Group {
            if chat.loading {
                ProgressView().padding(10)
            } else if chat.hasMore && chat.loaded {
                Button("查看更早的消息") { Task { await loadOlder() } }
                    .font(.ui(.footnote)).padding(10)
            } else if chat.loaded && !chat.items.isEmpty {
                Text("— 已是最早的消息 —").font(.ui(.caption)).foregroundStyle(.secondary).padding(10)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 要显示的行：手指在滑时用开始滑之前那一份（新内容先不放进来），平时按最新内容算
    private func rows(_ chat: ChatStore, _ activity: String?) -> [ChatRow] {
        _ = thaw   // 松手后重算
        #if (DEBUG || DEVICEBENCH) && os(iOS) && !SNAPSHOT
        // 真机自动测试：程序在滚时也冻住（TARS_BENCH_FREEZE=0 时不冻，用来对照）
        if DeviceBench.freeze, DeviceBench.scrolling, let rows = freeze.rows { return rows }
        #endif
        if freeze.active, let rows = freeze.rows { return rows }
        let rows = PerfTrace.measure("行布局 \(chat.items.count) 条") { chat.rows(activity: activity) }
        freeze.rows = rows
        return rows
    }

    /// 顶部浮着的任务进度（最新一次任务清单还没做完时）
}

/// 对话里的一行（对话页、子 agent 的完整记录共用）
struct ChatRowView: View {
    let key: String
    let row: ChatRow

    var body: some View {
        let _ = PerfTrace.body("ChatRowView")
        switch row {
        case .separator(_, let text):
            // 同微信：时间居中、浅灰小字（上面多空一点，和上一段对话分开）
            Text(text).font(.app(size: 12)).foregroundStyle(.secondary).padding(.top, 16)
        case .newMarker:
            HStack {
                VStack { Divider() }
                Text("以下是新消息").font(.ui(.caption)).foregroundStyle(Theme.claude).fixedSize()
                VStack { Divider() }
            }
            .padding(.horizontal, 40).padding(.top, 20).padding(.bottom, 4)
        case .user(let item, let first):
            // Kiteline 送进来的会话群消息：画成一张群消息卡片（不显示给 agent 看的群说明、回复方法）
            if let inbound = GroupText.parse(item.text ?? "") {
                GroupInboundMessage(key: key, item: item, inbound: inbound)
            } else {
                MessageRow(side: .me, first: first, time: item.ts, translate: UserMessage.translatable(item)) { UserMessage(key: key, item: item) }
            }
        case .bot(let item, let first):
            MessageRow(side: .bot, first: first, time: item.ts,
                       speak: item.t == "text" ? (item.text ?? "", item.id) : nil,
                       translate: BotText.translatable(item)) {
                if item.peer != nil {
                    PeerCard(key: key, item: item)
                } else if item.t == "agent_image" {
                    AgentImageMessage(key: key, item: item)
                } else if item.t == "agent_page" {
                    AgentPageMessage(key: key, item: item)
                } else if item.t == "agent_todo" {
                    AgentTodoMessage(key: key, item: item)
                } else if item.t == "agent_key" {
                    AgentKeyMessage(key: key, item: item)
                } else if item.t == "group_say" {
                    GroupSayMessage(key: key, item: item)
                } else if item.t == "tool" {
                    TodoCard(todos: item.input?["todos"]?.array ?? [])
                } else {
                    BotText(key: key, item: item)
                    // Claude 说有要你做的事：下面问一句「加入待办？」
                    if let asks = item.asks, !asks.isEmpty { AskPrompt(key: key, item: item, asks: asks) }
                }
            }
        case .steps(let id, let steps, let hidden, let first):
            MessageRow(side: .bot, first: first, time: steps.last?.item.ts) { StepsCard(key: key, groupId: id, steps: steps, hidden: hidden) }
        case .event(let item):
            EventRow(item: item)
        case .pending(let pending, let first):
            MessageRow(side: .me, first: first) { PendingMessage(key: key, pending: pending) }
        }
    }
}

/// 手指在滑时冻住的那一份行（普通 class，改了不触发重画）
final class RowFreeze {
    var active = false
    var rows: [ChatRow]?
}

/// 对话页滚动时要记的（普通 class，改了不触发重画）
final class ScrollState {
    /// 贴着底部：内容变多、键盘弹出时跟着滚到底。只有手指往上翻走才取消
    var stick = true
    var userScrolling = false
    /// 宽度要变时可视区顶上那一行：换完宽度滚回它（见 ChatView 里的 onChange(of: messageWidth)）
    var widthAnchor: String?
    /// Mac：上一次量到的内容高度、可视区高度（见 ChatView.follow）
    var contentHeight: CGFloat = 0
    var viewport: CGFloat = 0
}

/// Mac：对话内容的高度、内容底边在可视区里的位置
struct ContentMetrics: Equatable {
    var height: CGFloat
    var bottom: CGFloat
}

/// 对话页的滚动尺寸：内容高、可视区高、离底部还有多远
struct ScrollMetrics: Equatable {
    var content: CGFloat
    var container: CGFloat
    var distance: CGFloat
    /// 底下垫的高度（输入区、键盘）：滚到底时 distance 是它的负数，再往下就是停在了内容外面
    var bottomInset: CGFloat = 0
    /// 可视区在内容里的位置（只渲染附近的行，见 RowWindow）
    var visibleTop: CGFloat = 0
    var visibleHeight: CGFloat = 0
    #if DEBUG && os(iOS)
    /// 排查「能左右拖」：内容宽、可视区宽、横向偏移（见 ScrollPerf.noteScrollWidth）
    var contentWidth: CGFloat = 0
    var containerWidth: CGFloat = 0
    var offsetX: CGFloat = 0
    #endif
}

/// 只画可视区附近的行：离可视区一屏半以外的行设成全透明，系统不再为它们保留文字、图片的渲染结果。
/// 对话页用普通 VStack（不用 LazyVStack，原因见 ChatView 里的说明），不这样做的话翻过的行全画着：
/// 实测 400 行、80 张图的会话（iOS 模拟器）：全画 250–268 MB → 远处设透明 148–152 MB，滑动照样不掉帧。
/// 没有把远处的行换成空白占位：占位能再省一半，但行一换占位或换回来，整个 VStack 要把所有行重新排版一遍
/// （几百行时一次 20–60 ms），滑动时一顿一顿；设透明不动布局，没有这笔开销。
/// 总高度、滚动位置都不变，跳到某条消息照样能定位
@MainActor
final class RowWindow {
    /// 每行一个开关：重算时只拨动真正变了的那几行，别的行不重画
    @Observable @MainActor
    final class Slot {
        var live = true
    }

    private var slots: [String: Slot] = [:]
    private var heights: [String: CGFloat] = [:]
    private var order: [String] = []
    private var top: CGFloat = 0
    private var viewport: CGFloat = 0
    private var computedAt: CGFloat = -.greatestFiniteMagnitude
    private var width: CGFloat = 0
    private var scheduled = false
    /// 最后多少行不论位置都画出来
    private static let recentLive = 16

    var rowCount: Int { order.count }

    /// 量到的行高（测试「远处换占位」时用）
    func height(_ id: String) -> CGFloat? { heights[id] }

    func slot(_ id: String) -> Slot {
        if let slot = slots[id] { return slot }
        let slot = Slot()
        slots[id] = slot
        return slot
    }

    /// 行的高度（算哪些行在可视区附近用）。高度一变就重算（排到这一轮所有通知之后）：
    /// 以前只在第一次量到时重算，一大组工具步骤做完折叠、变矮好几屏时，下面的消息挪进了屏幕却还按旧位置算成「远处」，
    /// 一直是透明的，要再滑半屏才出来（10-22 反馈：新消息不显示，空出一大块）
    func measured(_ id: String, _ height: CGFloat) {
        guard height > 0, heights[id] != height else { return }
        heights[id] = height
        schedule()
    }

    func setOrder(_ ids: [String]) {
        order = ids
        schedule()
    }

    /// 宽度变了（转屏、分屏、折叠屏开合）：行高要重新量。透明的行照样排版、照样报新高度（measured 里高度一变就重算哪些画），
    /// 所以旧高度先留着当估计，不用把几百行全画出来——原来全画一遍，Mac 上加一列时几列同时变窄，一下卡零点几秒到几秒（10-26）。
    /// 远处换占位的测试模式例外：占位按量过的高度画、不会再报高度，只能全部换回真行重量
    func setWidth(_ value: CGFloat) {
        guard abs(value - width) > 0.5 else { return }
        width = value
        guard ChatRowsMode.current == .gone else { return }
        heights.removeAll()
        for slot in slots.values where !slot.live { slot.live = true }
    }

    /// 消息行上面「查看更早的消息」那一条的高度
    var headerHeight: CGFloat = 0

    /// 可视区顶上是哪一行（按量到的行高算）：露出来不到 24 点的不算。滚回去时那一行正好顶着可视区上沿，
    /// 差零点几点就会算成上一行，来回切几次宽度就一行一行往前漂
    func rowAtTop() -> String? {
        var bottom = headerHeight
        return order.first { id in
            bottom += heights[id] ?? 120
            return bottom > top + 24
        }
    }

    /// 滚动时每帧调：离上次算的位置超过半屏才重算。也排到这一轮通知之后再算：滚动位置的通知可能比行高的通知先到，
    /// 当场算会用上一轮的行高（比如刚折叠的步骤卡片还按原来的高度算），把正在屏幕上的行算成远处
    func scrolled(top: CGFloat, height: CGFloat) {
        self.top = top
        viewport = height
        if abs(top - computedAt) > height * 0.5 { schedule() }
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.scheduled = false
            self?.recompute()
        }
    }

    private func recompute() {
        guard viewport > 0 else { return }
        computedAt = top
        let above = top - viewport * 1.5, below = top + viewport * 2.5
        // 最新的十几行始终画出来：最常看的就是它们，也是变化最多的（正在输出、步骤折叠、新消息），万一位置算错也不会看不见
        let alwaysFrom = order.count - Self.recentLive
        var y: CGFloat = 0
        for (index, id) in order.enumerated() {
            let known = heights[id]
            let size = known ?? 120
            // 没量过高度的行（新来的、刚加载的更早消息）先画出来
            let live = known == nil || index >= alwaysFrom || (y + size >= above && y <= below)
            y += size
            if let slot = slots[id], slot.live != live { slot.live = live }
        }
    }
}

/// 消息里的链接：网址照常用浏览器开；文件（Claude 常写成 [README.md](README.md)、`~/Desktop/报价单.xlsx`）在手机上打开：
/// 项目目录里的代码、文本进项目文件页（能看内容和改动记录），目录外的（Claude 常放桌面）和办公文档、图片取回手机预览、能转发（见 FileOpener）。
/// 单独成一个只带 key 的修饰器：对话页每来一条新内容整页重算一次，直接在 body 里写 .environment(\.openURL, OpenURLAction { … })
/// 的话每次都是新闭包，SwiftUI 当成环境变了，整页几百行消息的环境全部重传一遍（10-26 Mac 4 列分屏，每来一条一卡几十到几百毫秒）
private struct ChatLinkOpener: ViewModifier {
    let key: String
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var open

    func body(content: Content) -> some View {
        content.environment(\.openURL, OpenURLAction { openLink($0) })
    }

    private func openLink(_ url: URL) -> OpenURLAction.Result {
        if Markdown.blockedLink(url) { return .handled }   // claude.ai 的链接不打开（Markdown.inline 里已经摘掉，这里兜底）
        if let path = FileLink.path(url) { openFile(path); return .handled }
        if let scheme = url.scheme?.lowercased(), scheme != "file" { return .systemAction }
        let path = url.path(percentEncoded: false)
        guard !path.isEmpty else { return .systemAction }
        openFile(path)
        return .handled
    }

    private func openFile(_ raw: String) {
        var path = raw
        // 「Sources/App.swift:42」带的行号去掉
        if let line = path.range(of: #":\d+(-\d+)?$"#, options: .regularExpression) { path.removeSubrange(line) }
        let cwd = (model.session(key)?.cwd ?? model.pastMeta[key]?.cwd).map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        var inProject: String?
        if !FileLink.isAbsolute(path) { inProject = path.hasPrefix("./") ? String(path.dropFirst(2)) : path }
        else if let cwd, path.hasPrefix(cwd) { inProject = String(path.dropFirst(cwd.count)) }
        if let inProject, !inProject.isEmpty, !inProject.hasPrefix("../"), !FileLink.documentExtensions.contains(FileLink.ext(path)) {
            open(.file(key: key, path: inProject))
        } else {
            FileOpener.shared.open(model, key: key, path: path)
        }
    }
}

/// 对话页的消息行（见 ChatView 里的说明）：行、高亮的行都没变就不重算
private struct ChatRowsList: View, Equatable {
    let window: RowWindow
    let key: String
    let rows: [ChatRow]
    let flashRow: String?

    static func == (a: Self, b: Self) -> Bool {
        a.key == b.key && a.flashRow == b.flashRow && a.window === b.window && a.rows == b.rows
    }

    var body: some View {
        let _ = PerfTrace.body("ChatRowsList")
        // 行在这里自己排成一列再交出去：body 直接是 ForEach（多个视图）的话，外面套上 .equatable() 后有时被当成一个视图，
        // 几十行全叠在同一处、居中摞着（10-27 iPhone 横屏从世界里点开的会话页：iOS 18 真机、iOS 27 模拟器都能复现）
        RowsStack {
            ForEach(rows) { row in
                WindowedRow(window: window, slot: window.slot(row.id), key: key, row: row).id(row.id)
                    .background(flashRow == row.id ? Theme.claude.opacity(0.12) : .clear)
            }
        }
    }
}

/// 对话行的渲染方式。正式版固定是 opacity（远处设透明）；真机自动测试时可以切换来比较（见 DeviceBench）
enum ChatRowsMode {
    case plain, opacity, gone, lazy

    static let current: ChatRowsMode = {
        #if (DEBUG || DEVICEBENCH) && os(iOS) && !SNAPSHOT
        switch DeviceBench.mode {
        case .plain: return .plain
        case .opacity: return .opacity
        case .gone: return .gone
        case .lazy: return .lazy
        }
        #else
        return .opacity
        #endif
    }()
}

/// 只在这一小块里读会话详情：电脑推来的状态一变（正在执行哪个工具、用量……）只重算这一块，不连带整个对话页
struct SessionReader<Content: View>: View {
    let slot: AppModel.SessionSlot
    @ViewBuilder let content: (SessionInfo?) -> Content

    var body: some View {
        let _ = PerfTrace.body("SessionReader")
        content(slot.info)
    }
}

/// 对话行的容器：普通 VStack（原因见 ChatView 里的说明）；测试懒加载时换 LazyVStack
private struct RowsStack<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if ChatRowsMode.current == .lazy {
            LazyVStack(spacing: 0) { content }
        } else {
            VStack(spacing: 0) { content }
        }
    }
}

/// 对话里的一行：离可视区远时设成全透明（见 RowWindow）
private struct WindowedRow: View {
    let window: RowWindow
    let slot: RowWindow.Slot
    let key: String
    let row: ChatRow

    var body: some View {
        switch ChatRowsMode.current {
        case .plain, .lazy:
            ChatRowView(key: key, row: row)
        case .gone:
            if !slot.live, let height = window.height(row.id) {
                Color.clear.frame(height: height)
            } else {
                ChatRowView(key: key, row: row)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { window.measured(row.id, $0) }
            }
        case .opacity:
            opacityRow
        }
    }

    private var opacityRow: some View {
        ChatRowView(key: key, row: row)
            .opacity(slot.live ? 1 : 0)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { window.measured(row.id, $0) }
            #if SNAPSHOT
            // 排查用（TARS_DEMO_WIDE=文件）：比可用宽度宽的行记下来（会把整页撑宽、能左右拖）
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { Snapshot.noteWidth(row.id, $0) }
            #elseif DEBUG && os(iOS)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { ScrollPerf.shared.noteWidth(row, $0) }
            #endif
    }
}

/// 标题栏：会话标题 + 「● 正在工作 · 本机 · Opus 5.5 · 上下文 38%」
struct ChatTitle: View {
    let session: SessionInfo?
    /// 已经结束的会话：标题、机器、目录
    var past: PastSession? = nil
    /// 用户给这个会话的 agent 设的头像、昵称：标题前换成小头像，副标题前加昵称
    var face: AgentFace? = nil
    /// 点标题前的 agent 标志 / 小头像：打开 Agent 详情
    var onAgent: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 5) {
                // 正在看的是哪个 agent 的会话（已结束的会话没记 agent，按 Claude Code 算）
                Button { onAgent?() } label: { mark.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .disabled(onAgent == nil)
                    .accessibilityLabel(L("Agent 详情"))
                Text(session?.title ?? past?.title ?? L("会话已结束")).font(.ui(.headline)).lineLimit(1)
            }
            if let session {
                HStack(spacing: 4) {
                    Circle().fill(StatusColor.of(session)).frame(width: 6, height: 6)
                    Text(([face?.name ?? ""] + [Self.subtitle(session)]).filter { !$0.isEmpty }.joined(separator: " · ")).lineLimit(1)
                }
                .font(.ui(.caption2))
                .foregroundStyle(.secondary)
            } else {
                Text(([L("已结束"), past?.sourceName ?? "", past?.cwd.map { ($0 as NSString).lastPathComponent } ?? ""]
                      .filter { !$0.isEmpty }).joined(separator: " · "))
                    .font(.ui(.caption2)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// 设了头像的画小头像，没设是 agent 的单色标志
    @ViewBuilder private var mark: some View {
        if let face, !face.avatar.isEmpty {
            AgentFaceView(agent: session?.agent ?? Agents.defaultID, face: face, size: 18, corner: 0.26)
        } else {
            AgentGlyph(session?.agent, size: 14).foregroundStyle(.secondary)
        }
    }

    static func subtitle(_ s: SessionInfo) -> String {
        let label = s.error != nil ? L("出错已停止") : (["waiting": L("待确认"), "busy": L("正在工作"), "idle": L("空闲")][s.activity] ?? L("未知"))
        // 模型、上下文在输入框下面那排已经有了，标题栏只写状态、是否只读、机器
        return [label, s.readOnly == true ? L("只读") : nil, s.sourceName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

enum StatusColor {
    static func of(_ s: SessionInfo) -> Color {
        if s.error != nil { return Theme.removed }
        switch s.activity {
        case "waiting": return .orange
        case "busy": return Theme.claude
        case "idle": return Theme.added
        default: return .secondary
        }
    }
}

struct SessionInfoView: View {
    let session: SessionInfo

    var body: some View {
        FitSheet(title: L("会话信息")) {
            SheetSection {
                SheetInfoRow(L("标题"), session.title)
                SheetDivider()
                SheetInfoRow(L("所在机器"), session.sourceName)
                if let cwd = session.cwd {
                    SheetDivider()
                    SheetInfoRow(title: L("目录")) { Text(cwd).font(.ui(.footnote).monospaced()).fontDesign(nil).textSelection(.enabled) }
                }
                if let branch = session.branch {
                    SheetDivider()
                    SheetInfoRow(L("Git 分支"), branch + (session.worktree != nil ? L("（工作树）") : ""))
                }
                if let started = session.startedAt {
                    SheetDivider()
                    SheetInfoRow(L("开始于"), Format.messageTime(started))
                }
            }
            if let usage = session.usage {
                SheetSection(title: L("用量")) {
                    if let model = usage.model { SheetInfoRow(L("模型"), modelName(model)) }
                    if let percent = usage.percent {
                        if usage.model != nil { SheetDivider() }
                        SheetInfoRow(title: L("上下文")) {
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("\(percent)%" + (usage.context.map { " · \($0 / 1000)k" } ?? "") + (usage.window.map { " / \($0 / 1000)k" } ?? ""))
                                ProgressView(value: Double(percent), total: 100)
                                    .tint(percent >= 90 ? Theme.removed : (percent >= 70 ? .orange : Theme.added))
                                    .frame(width: 140)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// 贴底跟随：贴着底部时用系统的「尺寸变化时贴底」（.sizeChanges）——键盘升起 / 收起、内容变高（新消息、Claude 开始干活、图加载出来），
/// 系统在同一帧里把内容顶上去，跟键盘动画严丝合缝。
/// 往上翻着看时关掉它（nil）：不然列表边滑边算高度，内容高度一变就被拽回底部。
/// 以前是每次尺寸一变就「排到下一帧再 scrollTo 底部」：键盘动画里每一帧都慢半拍追着滚，弹出、收起键盘时一顿一顿的。
/// 这几个接口 iOS 18 / macOS 15 起才有；更老的 Mac 退回普通的「从底部开始」，新消息照样会滚到底（见 onChange(of: rows.last?.id)）
private struct ChatScrollFollow: ViewModifier {
    let scroll: ScrollState
    let window: RowWindow
    let freeze: RowFreeze
    @Binding var newPill: Bool
    let proxy: ScrollViewProxy
    /// 滑动停下：冻住期间来的新内容这时候放进来
    let thaw: () -> Void
    /// scroll.stick 的可观察副本：决定要不要开「尺寸变化时贴底」（ScrollState 不触发重绘，这里只在真变了时才改）
    @State private var anchored = true

    private var userScrolling: Bool {
        #if SNAPSHOT
        if Snapshot.benchScrolling { return true }   // 量滚动卡顿时是程序在滚，当作手指在滑
        #endif
        #if (DEBUG || DEVICEBENCH) && os(iOS) && !SNAPSHOT
        if DeviceBench.scrolling { return true }
        #endif
        return scroll.userScrolling
    }

    func body(content: Content) -> some View {
        #if os(macOS)
        if #available(macOS 15.0, *) {
            // 告诉 RowWindow 可视区在哪：离得远的行设透明、不再画（以前 Mac 上没接，长会话几百行全画着，
            // 息屏再亮屏时整页几千处文字一起重画）
            content.defaultScrollAnchor(.bottom)
                .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { _, rect in
                    window.scrolled(top: rect.minY, height: rect.height)
                }
        } else {
            content.defaultScrollAnchor(.bottom)
        }
        #else
        if #available(iOS 18.0, *) {
            content
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(anchored ? .bottom : nil, for: .sizeChanges)
                .onScrollPhaseChange { _, phase in
                    scroll.userScrolling = phase == .interacting || phase == .decelerating || phase == .tracking
                    if phase == .idle, anchored != scroll.stick { anchored = scroll.stick }
                    // 手指在滑时冻住内容：Claude 正在输出时每秒都有新内容，每来一次整张工具卡片、长回复就要重排，
                    // iPhone 12 上一次几十毫秒，落在滑动中就是一顿（10-22 真机实测每次滑动卡 1–2 帧、45–70 ms）。停下再放进来
                    if scroll.userScrolling {
                        freeze.active = true
                    } else if phase == .idle, freeze.active {
                        freeze.active = false
                        thaw()
                    }
                    #if DEBUG && os(iOS)
                    // 调试版：记下这一次滑动卡不卡（见 ScrollPerf）
                    if scroll.userScrolling { ScrollPerf.shared.begin(rows: window.rowCount) } else if phase == .idle { ScrollPerf.shared.end() }
                    #endif
                }
                #if SNAPSHOT
                // 量滚动卡顿：一段滚完当作滑动停下
                .onReceive(NotificationCenter.default.publisher(for: Snapshot.benchIdle)) { _ in
                    if anchored != scroll.stick { anchored = scroll.stick }
                }
                #endif
                #if (DEBUG || DEVICEBENCH) && os(iOS) && !SNAPSHOT
                .onReceive(NotificationCenter.default.publisher(for: DeviceBench.idle)) { _ in
                    if anchored != scroll.stick { anchored = scroll.stick }
                    thaw()
                }
                #endif
                .onScrollGeometryChange(for: ScrollMetrics.self) { geo in
                    var metrics = ScrollMetrics(content: geo.contentSize.height, container: geo.containerSize.height,
                                                distance: geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height,
                                                bottomInset: geo.contentInsets.bottom,
                                                visibleTop: geo.visibleRect.minY, visibleHeight: geo.visibleRect.height)
                    #if DEBUG && os(iOS)
                    metrics.contentWidth = geo.contentSize.width
                    metrics.containerWidth = geo.containerSize.width
                    metrics.offsetX = geo.contentOffset.x + geo.contentInsets.leading
                    #endif
                    return metrics
                } action: { old, new in
                    window.scrolled(top: new.visibleTop, height: new.visibleHeight)
                    #if DEBUG && os(iOS)
                    ScrollPerf.shared.noteScrollWidth(content: new.contentWidth, container: new.containerWidth, offsetX: new.offsetX)
                    #endif
                    if userScrolling {
                        // 手指在滑：滑回底部附近就继续贴底，往上翻走了就不贴
                        scroll.stick = new.distance < 160
                        if scroll.stick, newPill { newPill = false }
                    } else if scroll.stick, new.distance > 40, new.content != old.content {
                        // 兜底：贴着底却离底部远了（系统贴底没接住，比如一下子来了很多内容）才手动滚一次；
                        // 键盘动画里的每一帧交给上面的 .sizeChanges，别在这里逐帧追
                        DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
                    } else if !userScrolling, new.distance < -new.bottomInset - 40 {
                        // 停在了内容外面（内容一下子变矮：宽度变了重新换行、大段步骤折叠）：系统要等手指碰一下才弹回来，这之前整块空白。
                        // 离得最近的有效位置就是底部
                        DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    // 手指在滑时一般先不切换「尺寸变化时贴底」：切换会让整页重新排版（长会话、几百行时要几十毫秒，手机上更久），
                    // 放在滑动中间就是明显的一顿（滑到底、从底部往上滑的那一下）。等滑动停下来再切，见 onScrollPhaseChange。
                    // 只有滑动中内容正在变高（Claude 在输出、图加载出来）时立刻切：不然离开底部后内容会跟着往上漂
                    if anchored != scroll.stick, !userScrolling || new.content != old.content { anchored = scroll.stick }
                }
        } else {
            content.defaultScrollAnchor(.bottom)
        }
        #endif
    }
}


#if os(iOS)
/// 对话页只能上下滑：关掉系统滚动区（UIScrollView）的横向回弹、锁定滑动方向。
/// 内容宽已经钉成可视区宽，10-22 真机记录里内容宽 = 可视区宽 = 390 时仍能左右拖开 2–3 点、松手弹回
/// （有的消息行比屏幕宽零点几点，系统按「内容比可视区宽」开着横向回弹）。SwiftUI 没有「横向永不回弹」的写法，
/// 这里从内容里往上找到所在的 UIScrollView 直接设；SwiftUI 更新滚动区时可能改回去，每次排版都再设一遍
struct VerticalOnlyScroll: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) { view.lock() }

    final class Probe: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isHidden = true
        }

        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            lock()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            lock()
        }

        func lock() {
            var view = superview
            while let current = view, !(current is UIScrollView) { view = current.superview }
            guard let scroll = view as? UIScrollView else { return }
            #if DEBUG
            ScrollPerf.shared.chatScroll = scroll
            #endif
            if scroll.alwaysBounceHorizontal { scroll.alwaysBounceHorizontal = false }
            if #available(iOS 17.4, *), scroll.bouncesHorizontally { scroll.bouncesHorizontally = false }
            if !scroll.isDirectionalLockEnabled { scroll.isDirectionalLockEnabled = true }
            if watched !== scroll {
                watched = scroll
                offsetWatch = scroll.observe(\.contentOffset) { scroll, _ in
                    MainActor.assumeIsolated { Probe.pinLeft(scroll) }
                }
            }
            Probe.pinLeft(scroll)
        }

        private weak var watched: UIScrollView?
        private var offsetWatch: NSKeyValueObservation?

        /// 内容不比可视区宽时，横向只能停在最左。10-27 实测的 iPhone（iOS 18）横屏分屏时，最左一块的消息整体往右挪了一个刘海宽、
        /// 右边被裁掉（输入框位置是对的）：转屏时系统临时给滚动区加了左边的安全区、把内容往右推，之后安全区撤了却没推回来——
        /// 横向回弹关了，不会自己弹回去。一偏就拉回来（调试版记一笔，见 DebugRemote 的 dump）
        @MainActor static func pinLeft(_ scroll: UIScrollView) {
            let inset = scroll.adjustedContentInset
            let left = -inset.left
            guard abs(scroll.contentOffset.x - left) > 0.5,
                  scroll.contentSize.width <= scroll.bounds.width - inset.left - inset.right + 1 else { return }
            #if DEBUG
            DebugRemote.note("横向偏移 \(Int(scroll.contentOffset.x))（应为 \(Int(left))），内容宽 \(Int(scroll.contentSize.width))，可视宽 \(Int(scroll.bounds.width))，已拉回")
            #endif
            scroll.contentOffset = CGPoint(x: left, y: scroll.contentOffset.y)
        }
    }
}
#endif

#if os(macOS)
/// Mac：最近有没有「人在滚对话」的操作（滚轮 / 触控板、拖滚动条、翻页键）。对话页靠位置变化判断贴不贴底，
/// 系统自己挪了位置（息屏亮屏、窗口换屏改了大小）不能算成你往上翻了（见 ChatView.follow）
@MainActor
enum MacScrollInput {
    private static var last: TimeInterval = 0
    private static var monitor: Any?

    /// 0.8 秒内有过滚动操作（触控板的惯性滚动会一直发滚轮事件）
    static var recent: Bool {
        install()
        return ProcessInfo.processInfo.systemUptime - last < 0.8
    }

    static func note() { last = ProcessInfo.processInfo.systemUptime }

    private static func install() {
        guard monitor == nil else { return }
        // 翻页键：Page Up / Down、Home / End、上下方向键、空格（在输入框里打字也会算上，只是让这段时间照旧按位置判断，没有坏处）
        let keys: Set<UInt16> = [116, 121, 115, 119, 126, 125, 49]
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .leftMouseDragged, .keyDown]) { event in
            if event.type != .keyDown || keys.contains(event.keyCode) { last = ProcessInfo.processInfo.systemUptime }
            return event
        }
    }
}
#endif
