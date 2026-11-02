import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)   // 手机的输入栏（带按住说话、拍照）；Mac 上用 MacComposer，样子照网页版
/// 输入栏（同微信）：左边语音 / 键盘切换，中间输入框或「按住 说话」，右边「+」，有字时换成绿色「发送」；
/// Claude 在干活时「+」左边多一个停止键。键盘上的换行键就是发送。「+」点开是相册、拍摄、常用语这些格子。
/// 群聊页用的也是它（group 不为空）：发到群里，下面那排换成「发给全部成员」
struct Composer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.homeBottom) private var homeBottom
    let key: String
    let session: SessionInfo?
    let chat: ChatStore
    let voice: VoiceSession
    var onStop: () -> Void = {}
    var onCompact: () -> Void = {}
    var onMode: () -> Void = {}
    var onModel: () -> Void = {}
    var onAgents: () -> Void = {}
    var onTodos: () -> Void = {}
    /// 发到群里（群聊页）：没有停止键、权限模式那排；按住说话松开先转成文字再发到群里
    var group: ComposeGroup? = nil
    @State private var picks: [PhotosPickerItem] = []
    @State private var attachments: [Attachment] = []
    @State private var showCamera = false
    @State private var showPhrases = false
    /// 「+」→「文件」：从「文件」App（iCloud 云盘、微信存下的文件……）选 PDF、Excel 这类发给 Claude
    @State private var importingFiles = false
    #if os(iOS)
    /// 「你可能要发送的截图」：点开「+」时刚截过图，在「+」上方弹个小气泡
    @State private var recentShot: RecentScreenshot.Shot?
    #endif
    /// 剪贴板里有图（截图后点了「拷贝」、在别的 App 里拷贝了图片）：打字或点开「+」时输入框上面一条「粘贴」
    @State private var clipboardImage = false
    @AppStorage("voiceMode") private var voiceMode = false
    @FocusState private var focused: Bool
    /// 对话区多宽：分列时窄的一列（不到 300）打字时收起语音、停止键，输入框才有地方
    @Environment(\.chatWidth) private var chatWidth
    /// 横着的 iPhone（高度紧凑）：「+」面板排成一行小图标，免得把输入框顶出屏幕（10-27）
    @Environment(\.verticalSizeClass) private var verticalSize
    /// 输入栏在屏幕上的位置：横着的 iPhone 算 Home 横条落在这一栏的哪一段
    @State private var barFrame: CGRect = .zero
    /// 键盘弹着（哪一列在打字都算）：横着的 iPhone 各列都收起下面那排，输入框才一样高（10-27）
    @State private var keyboardUp = false
    private var narrow: Bool { chatWidth > 0 && chatWidth < 300 }

    typealias Attachment = ComposeAttachment

    /// 已结束的会话也能发：Mac 会先在 VS Code 里恢复这段对话
    private var enabled: Bool { session?.canReply ?? true }
    private var draft: String { model.drafts[key] ?? "" }
    private var text: Binding<String> { Binding(get: { model.drafts[key] ?? "" }, set: { model.setDraft(key, $0) }) }
    private var empty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty }
    /// 能按住说话：会话（发语音给它），群（转成文字发到群里）
    private var voiceable: Bool { session != nil || group != nil }
    /// 能附图：会话都能；群要电脑端收得了群里的图（老版本只收文字）
    private var canAttach: Bool { group == nil || model.supportsGroupMedia }
    private var talking: Bool {
        #if os(iOS)
        voiceMode && enabled && voiceable && RemoteConfig.shared.isOn(.voice)
        #else
        false
        #endif
    }
    private var placeholder: String {
        if group != nil { return voice.converting ? L("正在转写…") : "" }
        guard let session else { return L("发送消息即可在 VS Code 中继续对话") }
        if session.canReply { return voice.converting ? L("正在转写…") : "" }
        return session.readOnlyNote
    }

    var body: some View {
        VStack(spacing: 0) {
            // 横着的 iPhone 键盘一弹就只剩一百多点高：快捷短语这一行不放（「+」→ 常用语里有）
            if focused, enabled, empty, !talking, !(session?.isWaiting ?? false), !model.quickReplies.isEmpty, chat.quote == nil, verticalSize != .compact {
                phrases.transition(.opacity)
            }
            if !attachments.isEmpty { attachmentStrip }
            if clipboardImage, enabled, canAttach, !talking, focused || chat.panelOpen, attachments.count < 6 {
                pasteRow.transition(.opacity)
            }
            HStack(alignment: .bottom, spacing: Bar.spacing - Bar.iconInset) {
                #if os(iOS)
                if voiceable, !(narrow && focused), RemoteConfig.shared.isOn(.voice) {
                    RoundIcon(symbol: voiceMode ? "keyboard" : "waveform", label: voiceMode ? L("切换到键盘输入") : L("切换到语音输入")) {
                        voiceMode.toggle()
                        chat.panelOpen = false
                        focused = !voiceMode
                    }
                    .disabled(!enabled)
                }
                if talking {
                    HoldToTalk(key: key, voice: voice,
                               images: { attachments.filter { !$0.isFile }.map { ($0.name, $0.data, $0.preview) } },
                               files: { attachments.filter(\.isFile).map { ($0.name, $0.data) } },
                               sent: { attachments = [] },
                               // 群：转好的字连同附着的图、文件发到群里
                               spoken: group.map { target in { text, images, files in model.send(target, text: text, images: images, files: files) } })
                } else {
                    field
                }
                #else
                field
                #endif
                if let session, session.isBusy, session.canReply, !(narrow && (focused || !empty)) {
                    // 同网页版：红圈里一个方块，点了确认后中断（= 按 Esc）
                    RoundIcon(symbol: "stop.fill", label: L("中断 %@", "\(session.speaker)"), tint: Theme.removed, size: 12, action: onStop)
                        .transition(.scale.combined(with: .opacity))
                }
                if !empty, !talking {
                    Button(action: send) {
                        Text("发送").font(.app(size: 15, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 56, height: 34)
                            .background(Theme.wechatGreen, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .frame(width: Bar.iconWidth + 26, height: Bar.rowHeight)
                    }
                    .disabled(!enabled)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else {
                    RoundIcon(symbol: "plus", label: chat.panelOpen ? L("收起更多功能") : L("更多功能")) {
                        focused = false
                        withAnimation(.snappy(duration: 0.25)) { chat.panelOpen.toggle() }
                        #if os(iOS)
                        if chat.panelOpen, canAttach {
                            Task {
                                let shot = await RecentScreenshot.find()
                                withAnimation(.snappy) { recentShot = shot }
                            }
                        }
                        #endif
                    }
                    .disabled(!enabled)
                    #if os(iOS)
                    .overlay(alignment: .bottomTrailing) {
                        if let recentShot {
                            shotBubble(recentShot)
                                .fixedSize()
                                .offset(y: -(Bar.rowHeight + 6))
                                .transition(.scale(scale: 0.85, anchor: .bottomTrailing).combined(with: .opacity))
                        }
                    }
                    #endif
                }
            }
            .padding(.horizontal, Bar.edge - Bar.iconInset)
            .padding(.vertical, verticalSize == .compact ? 4 : Bar.spacing)
            .animation(.snappy(duration: 0.2), value: empty)
            .animation(.snappy, value: session?.isBusy)
            if let session, session.canReply {
                if verticalSize != .compact {
                    toolbar(session)
                } else if band != nil {
                    bandRow(session)
                } else if !focused, !keyboardUp, !chat.panelOpen, chat.quote == nil {
                    // 横着的 iPhone 里正好压在 Home 横条上的那一列（三列的中间）：两边放不下，照常单占一行
                    toolbar(session)
                }
            } else if let group, verticalSize != .compact || (!focused && !keyboardUp && !chat.panelOpen) {
                // 群：那一排只有「发给全部成员 ⌄」
                GroupRecipientsChip(target: group)
                    .environment(\.chipHeight, verticalSize == .compact ? 22 : 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Bar.edge)
                    .padding(.bottom, Bar.spacing)
            }
            if let quote = chat.quote { quoteBar(quote) }
            if chat.panelOpen { panel.transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        // 最后一行是下面那排按钮时，往 Home 条上方的空白里挪一点，底下不留一大块（键盘弹出时不挪）；
        // 横着的 iPhone 那排挪进 Home 横条两边的空白里，整排沉到底
        .padding(.bottom, band != nil ? -max(0, Bar.home(homeBottom) - 2) : (toolbarIsLast ? -Bar.homeOverlap(bottom: Bar.home(homeBottom)) : 0))
        // 只要左右位置（高度变了不用重算）
        .onGeometryChange(for: CGRect.self) { let f = $0.frame(in: .global); return CGRect(x: f.minX, y: 0, width: f.width, height: 0) } action: { barFrame = $0 }
        .background(Theme.inputBar)
        .overlay(alignment: .top) { Divider() }
        .onChange(of: picks) { _, items in
            guard !items.isEmpty else { return }
            picks = []
            chat.panelOpen = false
            Task { await load(items) }
        }
        // 别给整个输入栏挂「焦点一变就做动画」：输入栏跟着键盘升降，自己再按另一套节奏动，两个动画打架，弹出 / 收起键盘时一顿一顿的
        .onChange(of: focused) { _, on in
            if on, chat.panelOpen { withAnimation(.snappy(duration: 0.2)) { chat.panelOpen = false } }
            if on { checkClipboard() }
        }
        .onChange(of: chat.panelOpen) { _, open in if open { checkClipboard() } }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        .onAppear(perform: checkClipboard)
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in checkClipboard() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in checkClipboard() }
        .onChange(of: voice.transcript) { _, text in
            // 「转文字」回来了：放进输入框，切回键盘，改好再发
            guard let text else { return }
            voice.transcript = nil
            model.setDraft(key, draft.isEmpty ? text : draft + " " + text)
            voiceMode = false
            focused = true
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                if let data = image.jpegData(compressionQuality: 0.9), let prepared = ImagePrep.prepare(data) {
                    attachments.append(Attachment(name: "photo-\(attachments.count + 1).jpg", data: prepared.jpeg, preview: prepared.preview))
                }
            }
            .ignoresSafeArea()
        }
        #endif
        .sheetPanel(isPresented: $showPhrases) { phraseSheet }
        .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls where attachments.count < 6 { attachFile(url) }
        }
    }

    /// 选来的文件：图片照发图那样压缩（显示在对话里），其他原样传到电脑（一个最多 25 MB）
    private func attachFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { model.flash(L("无法读取文件：%@", url.lastPathComponent)); return }
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true, let prepared = ImagePrep.prepare(data) {
            attachments.append(Attachment(name: "image-\(attachments.count + 1).jpg", data: prepared.jpeg, preview: prepared.preview))
            return
        }
        guard data.count <= InboundFiles.maxFile else { model.flash(L("「%@」超过 25 MB，无法发送", url.lastPathComponent)); return }
        attachments.append(Attachment(name: url.lastPathComponent, data: data, preview: Data(), isFile: true))
    }

    /// 横着的 iPhone：模式、模型、上下文那排放进底部 Home 横条左边或右边（横条正中让开，10-27），哪边宽放哪边。
    /// 返回放哪边、能占多宽；打字、开着「+」面板、引用时不放；两边都太窄时也不放（照样能从「⋯」里改）
    private var band: (leading: Bool, width: CGFloat)? {
        guard verticalSize == .compact, session?.canReply == true, !focused, !keyboardUp, !chat.panelOpen, chat.quote == nil,
              barFrame.width > 0, Bar.bottomInset > 0 else { return nil }
        let mid = Bar.windowWidth / 2 - barFrame.minX
        let left = mid - Bar.homeHalf - Bar.edge
        let right = barFrame.width - (mid + Bar.homeHalf) - Bar.edge
        guard max(left, right) >= 110 else { return nil }
        return left >= right ? (true, left) : (false, right)
    }

    /// 底部横条一边的那排小按钮（横着滚）
    private func bandRow(_ session: SessionInfo) -> some View {
        let side = band ?? (true, 0)
        return ScrollView(.horizontal, showsIndicators: false) {
            SessionChips(key: key, session: session, chat: chat, onMode: onMode, onModel: onModel,
                         onCompact: onCompact, onTodos: onTodos, onAgents: onAgents)
                .environment(\.chipHeight, 22)
                .padding(.top, Bar.badgeRoom)
        }
        .padding(.top, -Bar.badgeRoom)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .defaultScrollAnchor(side.leading ? .leading : .trailing)
        .frame(minWidth: 0, idealWidth: 0, maxWidth: side.width)
        .frame(maxWidth: .infinity, alignment: side.leading ? .leading : .trailing)
        .padding(.horizontal, Bar.edge)
        .frame(height: 24)
    }

    private var toolbarIsLast: Bool {
        (session?.canReply == true || group != nil) && !focused && !chat.panelOpen && chat.quote == nil && verticalSize != .compact
    }

    /// 输入框下面一排（同 VS Code 里输入框下面那排）：权限模式、模型和思考等级、上下文、任务清单进度、派过的子 agent
    private func toolbar(_ session: SessionInfo) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            SessionChips(key: key, session: session, chat: chat, onMode: onMode, onModel: onModel,
                         onCompact: onCompact, onTodos: onTodos, onAgents: onAgents)
                .padding(.horizontal, Bar.edge)
                .padding(.top, Bar.badgeRoom)
        }
        .padding(.top, -Bar.badgeRoom)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        // 横着滚的一排别把自己的总宽当成「理想宽度」往上报：字大了、小标签多了，会把整个对话页撑得比屏幕宽（左右被裁）
        .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity)
        .padding(.bottom, Bar.spacing)
    }

    #if os(iOS)
    /// 同微信：小气泡里是刚截的图，点一下加进要发的图（收起「+」面板，输入框旁边变成「发送」）；10 秒没点就收起
    private func shotBubble(_ shot: RecentScreenshot.Shot) -> some View {
        Button {
            withAnimation(.snappy) { recentShot = nil }
            Task {
                guard let data = await RecentScreenshot.data(shot.asset), let prepared = ImagePrep.prepare(data) else {
                    model.flash(L("无法读取此截图"))
                    return
                }
                attachments.append(Attachment(name: "screenshot-\(attachments.count + 1).jpg", data: prepared.jpeg, preview: prepared.preview))
                withAnimation(.snappy(duration: 0.25)) { chat.panelOpen = false }
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text("最近的截图").font(.ui(.caption2)).foregroundStyle(.secondary)
                Image(uiImage: shot.thumb).resizable().scaledToFill()
                    .frame(width: 84, height: 136)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .padding(8)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        }
        .buttonStyle(PressableStyle())
        .task(id: shot.id) {
            try? await Task.sleep(for: .seconds(10))
            withAnimation(.snappy) { if recentShot?.id == shot.id { recentShot = nil } }
        }
    }
    #endif

    private var field: some View {
        TextField(placeholder, text: text, axis: .vertical)
            .lineLimit(1...5)
            .focused($focused)
            .submitLabel(.send)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(minHeight: 40)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .disabled(!enabled)
            .onChange(of: draft) { old, new in
                // 换行键 = 发送（同微信）：只认「在末尾多打了一个换行」，粘贴进来的多行文字不算
                if new == old + "\n" {
                    model.setDraft(key, old)
                    send()
                }
            }
    }

    /// 常用语：输入框空着时一排，点一下直接发
    private var phrases: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.quickReplies, id: \.self) { phrase in
                    Button {
                        Haptics.tap()
                        submit(phrase)
                    } label: {
                        Text(phrase).font(.ui(.subheadline)).lineLimit(1)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Theme.field, in: Capsule())
                    }
                    .buttonStyle(.steady(.plain))
                    .contextMenu {
                        Button { model.setDraft(key, phrase); focused = true } label: { Label("填入输入框编辑", systemImage: "pencil") }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity)   // 同 toolbar：别把一排的总宽往上报
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { item in
                    ZStack(alignment: .topTrailing) {
                        if item.isFile {
                            // 文件：类型图标 + 文件名
                            VStack(spacing: 3) {
                                Image(systemName: FileLink.symbol(item.name)).font(.system(size: 18))
                                Text(item.name).font(.ui(.caption2)).lineLimit(2).truncationMode(.middle).multilineTextAlignment(.center)
                            }
                            .padding(4)
                            .frame(width: 64, height: 64)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        } else if let image = PlatformImage(data: item.preview) {
                            Image(platform: image).resizable().scaledToFill().frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        Button { attachments.removeAll { $0.id == item.id } } label: {
                            Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6)).font(.ui(.title3))
                        }
                        .offset(x: 6, y: -6)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
        }
        .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity)   // 同 toolbar：别把一排的总宽往上报
    }

    /// 引用的那段（同微信：灰底小字在输入框下面）
    private func quoteBar(_ quote: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(quote).font(.ui(.footnote)).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
            Button { chat.quote = nil } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.steady(.plain))
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .padding(.horizontal, 58)
        .padding(.bottom, 8)
    }

    /// 剪贴板里有图：一条提示 + 系统的「粘贴」按钮（点它取图不弹「允许粘贴」）；✕ 了这一份就不再提示
    private var pasteRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard").foregroundStyle(.secondary)
            Text("剪贴板里有图片").font(.ui(.subheadline)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            PasteButton(supportedContentTypes: [.image]) { providers in
                Task { await paste(providers) }
            }
            .labelStyle(.titleAndIcon)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .tint(Theme.wechatGreen)
            Button {
                ClipboardImage.handled = ClipboardImage.changeCount
                withAnimation(.snappy) { clipboardImage = false }
            } label: {
                Image(systemName: "xmark").font(.ui(.footnote).weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.steady(.plain))
            .accessibilityLabel("不粘贴")
        }
        .padding(.leading, 14).padding(.trailing, 6)
        .padding(.top, verticalSize == .compact ? 4 : 8)
    }

    private func checkClipboard() {
        let offer = ClipboardImage.offer
        if offer != clipboardImage { withAnimation(.snappy) { clipboardImage = offer } }
    }

    /// 粘贴进来的图：同相册选的，长边缩到 2048、转 JPEG
    private func paste(_ providers: [NSItemProvider]) async {
        ClipboardImage.handled = ClipboardImage.changeCount
        withAnimation(.snappy) { clipboardImage = false }
        let images = await DroppedImages.load(providers)
        guard !images.isEmpty else { model.flash(L("无法读取剪贴板里的图片")); return }
        for data in images where attachments.count < 6 {
            guard let prepared = ImagePrep.prepare(data) else { continue }
            attachments.append(Attachment(name: "image-\(attachments.count + 1).jpg", data: prepared.jpeg, preview: prepared.preview))
        }
        withAnimation(.snappy(duration: 0.25)) { chat.panelOpen = false }
    }

    /// 「+」面板：一格一个功能（同微信）。横着的 iPhone 高度只有三百多点，排成一行小图标，面板矮一半多
    private var panel: some View {
        let compact = verticalSize == .compact
        let icon: CGFloat = compact ? 34 : 58
        let columns = Array(repeating: GridItem(.flexible(), spacing: compact ? 8 : 12), count: compact ? 5 : 4)
        return LazyVGrid(columns: columns, spacing: 18) {
            // 群：老版本电脑端群里只收文字，不给相册、拍摄、文件
            if canAttach {
            PhotosPicker(selection: $picks, maxSelectionCount: 6, matching: .images) {
                PanelTile(symbol: "photo", title: L("相册"), size: icon)
            }
            .buttonStyle(.steady(.plain))
            #if os(iOS)
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { chat.panelOpen = false; showCamera = true } label: { PanelTile(symbol: "camera", title: L("拍摄"), size: icon) }
                    .buttonStyle(.steady(.plain))
            }
            #endif
            #if os(iOS)
            // 电脑端是旧版（收不了文件）就不给
            if model.hostFeatures.contains("files") {
                Button { chat.panelOpen = false; importingFiles = true } label: { PanelTile(symbol: "doc", title: L("文件"), size: icon) }
                    .buttonStyle(.steady(.plain))
            }
            #endif
            }
            Button { showPhrases = true } label: { PanelTile(symbol: "text.bubble", title: L("常用语"), size: icon) }
                .buttonStyle(.steady(.plain))
            if session?.canReply == true {
                Button { chat.panelOpen = false; onCompact() } label: { PanelTile(symbol: "arrow.down.right.and.arrow.up.left", title: L("压缩上下文"), size: icon) }
                    .buttonStyle(.steady(.plain))
                Button { chat.panelOpen = false; model.send(key, text: L("截图查看效果"), images: []) } label: {
                    PanelTile(symbol: "camera.viewfinder", title: L("请求截图"), size: icon)
                }
                .buttonStyle(.steady(.plain))
            }
        }
        .padding(.horizontal, compact ? 14 : 22)
        .padding(.top, compact ? 10 : 18)
        .padding(.bottom, compact ? 8 : 24)
        .overlay(alignment: .top) { Divider() }
    }

    private var phraseSheet: some View {
        FitSheet(title: L("常用语")) {
            SheetSection(footer: L("轻点直接发送给 Claude；长按可填入输入框编辑后再发送。")) {
                ForEach(Array(model.quickReplies.enumerated()), id: \.element) { index, phrase in
                    if index > 0 { SheetDivider() }
                    Button {
                        showPhrases = false
                        chat.panelOpen = false
                        submit(phrase)
                    } label: {
                        Text(phrase).foregroundStyle(.primary).padding(.horizontal, 14).padding(.vertical, 12)
                    }
                    .buttonStyle(RowButtonStyle())
                    .contextMenu {
                        Button {
                            showPhrases = false
                            model.setDraft(key, phrase)
                            focused = true
                        } label: { Label("填入输入框编辑后发送", systemImage: "pencil") }
                    }
                }
            }
        }
    }

    private func send() {
        var message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty || !attachments.isEmpty else { return }
        if let quote = chat.quote {
            // 引用的那几行用 > 开头，Claude 一看就知道你说的是哪段（和网页版一样）
            message = quote.split(separator: "\n").map { "> \($0)" }.joined(separator: "\n") + "\n\n" + message
            chat.quote = nil
        }
        Haptics.tap()
        let images = attachments.filter { !$0.isFile }.map { ($0.name, $0.data, $0.preview) }
        let files = attachments.filter(\.isFile).map { ($0.name, $0.data) }
        if let group {
            model.send(group, text: message, images: images, files: files)
        } else {
            model.send(key, text: message, images: images, files: files)
        }
        model.setDraft(key, "")
        attachments = []
    }

    /// 常用语：点一下直接发（会话、群）
    private func submit(_ phrase: String) {
        if let group { model.send(group, text: phrase) } else { model.send(key, text: phrase, images: []) }
    }

    /// 和网页版一样：长边缩到 2048、转 JPEG 再发，手机拍的大图也很快
    private func load(_ items: [PhotosPickerItem]) async {
        for (index, item) in items.enumerated() {
            guard let raw = try? await item.loadTransferable(type: Data.self),
                  let prepared = ImagePrep.prepare(raw) else { continue }
            attachments.append(Attachment(name: "image-\(attachments.count + index + 1).jpg", data: prepared.jpeg, preview: prepared.preview))
        }
    }
}

#endif

/// 要发的一张图：原图（压过的 JPEG）+ 小预览。手机输入栏、Mac 输入栏、新建任务共用
struct ComposeAttachment: Identifiable {
    let id = UUID()
    var name: String
    var data: Data
    var preview: Data
    /// 文件（PDF、Excel……）：原样传到电脑，不是图
    var isFile = false
}

/// 拖进来、粘贴进来的东西里的图：访达里的图片文件、或者别的 App 拖出来 / 拷贝的图（Mac 拖图、手机和 Mac 的「粘贴」按钮共用）
enum DroppedImages {
    static func load(_ providers: [NSItemProvider]) async -> [Data] {
        var result: [Data] = []
        for provider in providers.prefix(6) {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = await withCheckedContinuation({ (done: CheckedContinuation<URL?, Never>) in
                   _ = provider.loadObject(ofClass: URL.self) { url, _ in done.resume(returning: url) }
               }),
               UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
               let data = try? Data(contentsOf: url) {
                result.append(data)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                      let data = await withCheckedContinuation({ (done: CheckedContinuation<Data?, Never>) in
                          provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in done.resume(returning: data) }
                      }) {
                result.append(data)
            }
        }
        return result
    }
}

/// 剪贴板里有没有图：只看类型、不读内容（iPhone 上读内容会弹「允许粘贴」；真正取图交给系统的「粘贴」按钮 PasteButton，不弹）。
/// 系统输入框只粘贴文字，剪贴板里只有图时长按菜单里连「粘贴」都没有，所以有图时另给一个「粘贴」（10-22 反馈：VS Code 都能粘贴截图）
enum ClipboardImage {
    @MainActor static var available: Bool {
        #if canImport(UIKit)
        UIPasteboard.general.hasImages
        #elseif KITELINE_MAC
        InputTextView.hasImage
        #else
        false
        #endif
    }

    /// 剪贴板内容的编号：换了新内容就变
    @MainActor static var changeCount: Int {
        #if canImport(UIKit)
        UIPasteboard.general.changeCount
        #elseif KITELINE_MAC
        NSPasteboard.general.changeCount
        #else
        0
        #endif
    }

    /// 点过「不用」或已经粘贴过的那一份剪贴板内容：同一份不再提示
    @MainActor static var handled = -1

    /// 现在要不要提示「剪贴板里有图片」
    @MainActor static var offer: Bool { available && changeCount != handled }
}

/// 输入框下面那排里的一个小按钮
extension EnvironmentValues {
    /// 输入框下面那排小按钮的高度：横着的 iPhone 放进底部横条两边时矮一点
    @Entry var chipHeight: CGFloat = 28
    /// 对话页实际贴着的底部安全区（ChatView 量了往下传）：nil = 按整个窗口算（见 Bar.home）
    @Entry var homeBottom: CGFloat? = nil
}

struct ToolChip: View {
    @Environment(\.chipHeight) private var height
    let symbol: String
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.app(size: 11, weight: .semibold))
                Text(text).font(.ui(.caption)).lineLimit(1)
            }
            .foregroundStyle(.primary.opacity(0.75))
            .padding(.horizontal, 9).frame(height: height)
            .background(Theme.field, in: Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}

/// 输入框下面那排小按钮（同 VS Code 里输入框下面那排）：权限模式、模型和思考等级、上下文、任务清单进度、派过的子 agent。
/// 手机、Mac 共用，外面自己套横着滚的 ScrollView
struct SessionChips: View {
    @Environment(AppModel.self) private var model
    @Environment(\.chipHeight) private var height
    let key: String
    let session: SessionInfo
    let chat: ChatStore
    let onMode: () -> Void
    let onModel: () -> Void
    let onCompact: () -> Void
    let onTodos: () -> Void
    let onAgents: () -> Void

    var body: some View {
        HStack(spacing: Bar.spacing) {
            if session.can("mode") || session.can("model") {
                claudeTune
            } else {
                // 没有权限模式、换模型的 agent（Codex、OpenCode……）：只标出是谁、用的什么模型
                HStack(spacing: 5) {
                    AgentGlyph(session.agent, size: 12)
                    Text(session.usage?.model ?? Agents.info(session.agent).name).foregroundStyle(.primary.opacity(0.75))
                }
                .font(.ui(.caption)).lineLimit(1)
                .padding(.horizontal, 9).frame(height: height)
                .background(Theme.field, in: Capsule())
            }
            if let percent = session.usage?.percent {
                // 压缩上下文：电脑端说有才能点（caps）
                Button(action: onCompact) {
                    HStack(spacing: 4) {
                        ContextRing(percent: percent)
                        Text("\(percent)%").font(.ui(.caption).monospacedDigit())
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).frame(height: height)
                    .background(Theme.field, in: Capsule())
                }
                .buttonStyle(PressableStyle())
                .allowsHitTesting(session.can("compact"))
            }
            // 目标（/goal）：没设时点开写一个，设了的显示进行中 / 暂停（会话支持才有）
            if session.can("goal"), session.canReply { GoalChip(key: key, session: session) }
            TodoChip(todos: chat.todos, action: onTodos)
            if session.subagents > 0, session.can("subagents") {
                ToolChip(symbol: "point.3.connected.trianglepath.dotted", text: L("子 agent %@", "\(session.subagents)"), action: onAgents)
            }
            // 会话里的终端（开在会话所在的电脑上）：点开从底下升起终端面板，角标是开着几个
            if session.can("term") { TerminalChip(session: session, chat: chat) }
        }
    }

    /// 权限模式 + 同 VS Code 的「Opus 5.5 Extra high」：点开换模型、调思考等级
    @ViewBuilder private var claudeTune: some View {
        let mode = model.permissionMode(key)
        let tune = ModelLabel.parts(model, key)
        if session.can("mode") {
            ToolChip(symbol: mode?.symbol ?? "exclamationmark.shield", text: mode?.title ?? L("跳过确认"), action: onMode)
        }
        if session.can("model") {
            Button(action: onModel) {
                HStack(spacing: 4) {
                    Text(tune.name).foregroundStyle(.primary.opacity(0.75))
                    if let effort = tune.effort { Text(effort).foregroundStyle(.secondary) }
                }
                .font(.ui(.caption)).lineLimit(1)
                .padding(.horizontal, 9).frame(height: height)
                .background(Theme.field, in: Capsule())
            }
            .buttonStyle(PressableStyle())
        }
    }
}

/// 上下文占用的小圆环
struct ContextRing: View {
    let percent: Int
    var body: some View {
        let color: Color = percent >= 90 ? Theme.removed : (percent >= 70 ? .orange : Theme.added)
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2.5)
            Circle().trim(from: 0, to: CGFloat(min(percent, 100)) / 100).stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 13, height: 13)
    }
}

/// 输入栏两边的圆圈图标（同微信：细线圆圈里一个图标）
struct RoundIcon: View {
    let symbol: String
    /// 读屏念的名字（只有图标的按钮，不写的话 VoiceOver 念的是图标名）
    var label: String
    /// 圈和图标的颜色（默认跟文字一样的灰黑）
    var tint: Color? = nil
    var size: CGFloat = 15
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 30, height: 30)
                .overlay(Circle().stroke(tint ?? Color.primary.opacity(0.75), lineWidth: 1.4))
                .frame(width: Bar.iconWidth, height: Bar.rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.steady(.plain))
        .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary.opacity(0.8)))
        .accessibilityLabel(label)
    }
}

/// 「+」面板里的一格
struct PanelTile: View {
    let symbol: String
    let title: String
    var size: CGFloat = 58

    var body: some View {
        VStack(spacing: size < 40 ? 4 : 7) {
            TarsIcon(symbol: symbol, size: size)
            Text(title).font(size < 40 ? .ui(.caption2) : .ui(.caption)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

#if os(iOS)
/// 「拍摄」：系统相机拍一张
struct CameraPicker: UIViewControllerRepresentable {
    let picked: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.picked(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
#endif

enum ImagePrep {
    static func prepare(_ data: Data) -> (jpeg: Data, preview: Data)? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        guard let jpeg = resized(image, max: 2048).jpegData(compressionQuality: 0.85),
              let preview = resized(image, max: 240).jpegData(compressionQuality: 0.8) else { return nil }
        return (jpeg, preview)
        #else
        guard let jpeg = scaled(data, max: 2048, quality: 0.85), let preview = scaled(data, max: 240, quality: 0.8) else { return nil }
        return (jpeg, preview)
        #endif
    }

    #if !canImport(UIKit)
    /// 长边缩到 max 以内（不放大），转成 JPEG
    private static func scaled(_ data: Data, max side: Int, quality: Double) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: side,
              ] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
    #endif

    #if canImport(UIKit)
    private static func resized(_ image: UIImage, max side: CGFloat) -> UIImage {
        let longest = Swift.max(image.size.width, image.size.height)
        guard longest > side else { return image }
        let scale = side / longest
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
    #endif
}

/// Claude 在干活：「纸鸢 Smooshing… (1m 20s · Bash)」，左边是晃着的小纸鸢（代替 Claude Code 的 ✻），状态词和 Claude Code 一样
struct WorkingView: View {
    let since: Date
    let activity: String?
    /// 正在干活却很久没动静（可能卡在不会自己结束的命令上）：这一行变红提示，中断用输入框旁边的停止键
    var stuckMinutes: Int?

    /// 一行时多高：最小高度 + 上下边距（见 body 末尾，改那几个数要一起改）。对话页按这个高度留位置，这一行放在上面一层（见 ChatView）
    static var rowHeight: CGFloat { ChatType.size * 1.85 + 4 + 8 }

    private static let verbs = ["Accomplishing", "Actualizing", "Baking", "Booping", "Brewing", "Calculating", "Cerebrating", "Churning",
                                "Clauding", "Coalescing", "Cogitating", "Combobulating", "Concocting", "Considering", "Contemplating",
                                "Cooking", "Crafting", "Crunching", "Deciphering", "Deliberating", "Discombobulating", "Doing",
                                "Elucidating", "Enchanting", "Envisioning", "Finagling", "Flibbertigibbeting", "Forging", "Frolicking",
                                "Generating", "Germinating", "Hatching", "Herding", "Honking", "Ideating", "Imagining", "Incubating",
                                "Inferring", "Manifesting", "Marinating", "Meandering", "Moseying", "Mulling", "Mustering", "Noodling",
                                "Percolating", "Perusing", "Philosophizing", "Pondering", "Processing", "Puttering", "Puzzling",
                                "Reticulating", "Ruminating", "Schlepping", "Shimmying", "Simmering", "Smooshing", "Spelunking",
                                "Spinning", "Stewing", "Sussing", "Synthesizing", "Thinking", "Tinkering", "Transmuting", "Unfurling",
                                "Unraveling", "Vibing", "Wandering", "Whirring", "Wibbling", "Working", "Wrangling"]

    var body: some View {
        HStack(spacing: 8) {
            if let minutes = stuckMinutes {
                Label {
                    Text("可能停滞：") + Text(minutes >= 120 ? "\(minutes / 60) 小时" : "\(minutes) 分钟").bold()
                        + Text(L("无新进展") + (activity.map { L("（正在 %@）", "\($0)") } ?? ""))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(ChatType.body)
                .foregroundStyle(Theme.removed)
                .lineLimit(2)
            } else {
            HStack(spacing: 6) {
                // 纸鸢放在 TimelineView 外面：每秒刷新时间不会打断它的晃动
                KiteSpinner(size: ChatType.size * 1.25, color: Theme.claude)
                    .frame(width: 18)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = max(0, context.date.timeIntervalSince(since))
                    // 状态词每 5 秒换一个；同一轮里顺序固定（按开始时间取种子）
                    let seed = Int(since.timeIntervalSince1970) &* 2654435761
                    let verb = Self.verbs[abs((seed &+ Int(elapsed / 5) &* 40503) % Self.verbs.count)]
                    HStack(spacing: 6) {
                        Text(verb + "…").lineLimit(1).fixedSize()
                        Text("(\(Format.duration(Int(elapsed)))\(activity.map { " · \($0)" } ?? ""))")
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .font(ChatType.body)   // 照 VS Code 的状态行：和正文一样的字、一样大
            .foregroundStyle(Theme.claude)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: ChatType.size * 1.85)
        #if os(macOS)
        .padding(.leading, 64).padding(.trailing, 24)   // 照网页版：和气泡左边对齐（24 边距 + 30 头像 + 10 间隔）
        #else
        .padding(.leading, 59).padding(.trailing, 10)   // 和气泡左边对齐（10 边距 + 40 头像 + 9 间隔）
        #endif
        .padding(.top, 4)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum Keyboard {
    /// 收起键盘（不管焦点在哪个输入框）
    @MainActor static func hide() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}

/// 底部输入区的尺寸：所有看得见的间距都是 spacing，左右到屏幕边都是 edge
enum Bar {
    static let spacing: CGFloat = 8
    /// 输入框下面那排小按钮上方给角标（终端个数）留的地方：横着滚的一排会裁掉超出自己的部分，内容往下挪这么多、整排再往上提回来
    static let badgeRoom: CGFloat = 6
    static let edge: CGFloat = 12
    /// 一行的高度（单行输入框、圆形按钮的占位）
    static let rowHeight: CGFloat = 40
    /// 圆形按钮占位宽：圈 30，左右各空 2
    static let iconWidth: CGFloat = 34
    static let iconInset: CGFloat = 2
    /// 往 Home 条上方空白里挪多少：只在底部有 Home 条的机型上挪（有 Home 键的、Mac 上的截图版底下没留空白，不挪）。
    /// iPhone 底下留 34，挪 12；iPad 只留 20、Home 条又细又贴底，挪到按钮离屏幕底边只剩 10
    /// （以前 iPad 一点没挪，按钮下面空出将近 30 点，10-24 反馈）
    /// 屏幕底部安全区（Home 横条那一带）多高
    @MainActor static var bottomInset: CGFloat {
        #if canImport(UIKit)
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.safeAreaInsets.bottom ?? 0
        #else
        0
        #endif
    }

    /// 窗口宽（Home 横条在正中）
    @MainActor static var windowWidth: CGFloat {
        #if canImport(UIKit)
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.bounds.width ?? 0
        #else
        0
        #endif
    }

    /// 横着时 Home 横条连两边留的空一半有多宽（横条本身二百出头）
    static let homeHalf: CGFloat = 125

    @MainActor static var homeOverlap: CGFloat { homeOverlap(bottom: bottomInset) }

    /// 底下有 bottom 这么高的 Home 横条空白时往里挪多少
    @MainActor static func homeOverlap(bottom: CGFloat) -> CGFloat {
        #if canImport(UIKit)
        if UIDevice.current.userInterfaceIdiom == .pad { return max(0, bottom + spacing - 10) }
        return min(12, max(0, bottom - 10))
        #else
        return 0
        #endif
    }

    /// 输入栏底下实际有多少 Home 横条空白：对话页量到的底部安全区（homeBottom）和整个窗口的取小。
    /// 浮在 iPad 中间的卡片（世界里点出来的会话页）底下没有横条，量到 0，就不往下挪
    /// （10-27 反馈：按窗口算往下挪了一截，最下面那排按钮被切掉一半）；键盘弹出时量到的更大，取窗口的照旧
    @MainActor static func home(_ measured: CGFloat?) -> CGFloat {
        min(measured ?? bottomInset, bottomInset)
    }
}

/// 任务清单进度（「任务 3/7」）：没有清单、或者都做完了就不显示；点开看清单
struct TodoChip: View {
    let todos: [JSONValue]
    let action: () -> Void

    var body: some View {
        let done = todos.filter { $0["status"]?.string == "completed" }.count
        if !todos.isEmpty, done < todos.count {
            ToolChip(symbol: "checklist", text: L("任务 %@/%@", "\(done)", "\(todos.count)"), action: action)
        }
    }
}
