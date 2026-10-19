import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One spacing and type scale for the whole floating workspace. Colors are
/// semantic system colors, so light and dark mode follow the window appearance.
enum Workspace {
    static let corner: CGFloat = 14
    static let toolbarHeight: CGFloat = 44
    static let headerHeight: CGFloat = 38
    static let gutter: CGFloat = 18
    static let minTranscriptWidth: CGFloat = 260
    static let minAnswerWidth: CGFloat = 340
    /// Below this width the panes stack vertically instead of squeezing side by side.
    static let sideBySideWidth: CGFloat = 640
    static let minTranscriptHeight: CGFloat = 90
    static let minAnswerHeight: CGFloat = 240
    static let minWindowWidth: CGFloat = 360
    static let minHeightWithAnswer: CGFloat = 400
    static let minHeightTranscriptOnly: CGFloat = 220
    static let defaultSplit = 0.55
    static let defaultStackSplit = 0.4
    static let separator = Color(nsColor: .separatorColor)
    static let subtleFill = Color.primary.opacity(0.05)
}

/// Hover flags live in an object because this toolchain has no SwiftUI macro
/// plugin, so `@State` is unavailable.
final class HoverState: ObservableObject { @Published var on = false }

private struct CursorRegion: NSViewRepresentable {
    let cursor: NSCursor
    final class Region: NSView {
        var cursor = NSCursor.arrow
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.invalidateCursorRects(for: self)
        }
        override func setFrameSize(_ newSize: NSSize) {
            let changed = frame.size != newSize
            super.setFrameSize(newSize)
            if changed { window?.invalidateCursorRects(for: self) }
        }
        override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
    }
    func makeNSView(context: Context) -> Region {
        let region = Region(); region.cursor = cursor; region.setAccessibilityElement(false); return region
    }
    func updateNSView(_ region: Region, context: Context) { region.cursor = cursor }
}

/// Centers content when there is room and scrolls it when there is not, so
/// empty states never overflow onto headers in short windows.
private struct CenteredScroll<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                content.frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollIndicators(.never)
        }
    }
}

extension View {
    /// Use a real AppKit cursor rect. SwiftUI's hover callback can be skipped by
    /// transparent panels and by sibling NSViewRepresentable overlays.
    func captionTextSelection() -> some View {
        textSelection(.enabled).overlay(CursorRegion(cursor: .iBeam))
    }
}

/// Behind-window blur for the borderless panel. A mask image (not a SwiftUI
/// clip) is what rounds behind-window blending.
private struct WindowSurface: NSViewRepresentable {
    let opacity: Double
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Self.mask(radius: Workspace.corner)
        view.alphaValue = opacity
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.alphaValue = opacity }
    private static func mask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

// MARK: Controls

private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.65 : 1)
    }
}

struct IconButton: View {
    let icon: String
    let help: String
    var active = false
    var disabled = false
    let action: () -> Void
    @StateObject private var hover = HoverState()
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hover.on && !disabled ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .onHover { hover.on = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

struct PillButton: View {
    let title: String
    let icon: String
    var prominent = false
    var iconTint: Color? = nil
    var showsTitle = true
    var disabled = false
    let action: () -> Void
    @StateObject private var hover = HoverState()
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(iconTint ?? (prominent ? Color.white : Color.primary))
                if showsTitle { Text(title).font(.system(size: 12, weight: .medium)) }
            }
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, showsTitle ? 10 : 7)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(prominent ? Color.accentColor.opacity(hover.on ? 0.88 : 1) : Color.primary.opacity(hover.on ? 0.11 : 0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .onHover { hover.on = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct PaneHeader<Trailing: View>: View {
    let icon: String
    let title: String
    var detail = ""
    var iconTint: Color = .secondary
    @ViewBuilder let trailing: Trailing
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(iconTint)
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .fixedSize().layoutPriority(1)
            if !detail.isEmpty {
                Text(detail).font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, Workspace.gutter)
        .frame(height: Workspace.headerHeight)
    }
}

// MARK: Root

struct WorkspaceView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            WorkspaceToolbar(model: model)
            Divider()
            SplitPane(showRight: model.showAssistantPane) {
                TranscriptPane(model: model)
            } right: {
                AnswerPane(assistant: model.assistant, fontSize: max(14, min(model.englishFontSize, 22)))
            }
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.55 * model.opacity))
        .background(WindowSurface(opacity: model.opacity))
        .overlay(RoundedRectangle(cornerRadius: Workspace.corner, style: .continuous)
            .strokeBorder(Color.primary.opacity(model.opacity == 0 ? 0 : 0.14), lineWidth: 0.5))
        .overlay(WindowResizeBorder())
    }
}

/// Side by side when wide (draggable, persisted, double-click restores 55 / 45);
/// stacked with a horizontal divider when narrow, so neither pane is ever cut off.
private struct SplitPane<Left: View, Right: View>: View {
    let showRight: Bool
    @ViewBuilder let left: Left
    @ViewBuilder let right: Right
    @AppStorage("workspaceSplit") private var ratio = Workspace.defaultSplit
    @AppStorage("workspaceStackSplit") private var stackRatio = Workspace.defaultStackSplit
    @GestureState private var drag: CGFloat = 0
    @StateObject private var hover = HoverState()

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            if !showRight {
                left.frame(width: size.width, height: size.height)
            } else if size.width >= Workspace.sideBySideWidth {
                let leftWidth = clampWidth(size.width * ratio + drag, total: size.width)
                HStack(spacing: 0) {
                    left.frame(width: leftWidth)
                    divider(vertical: true, total: size.width)
                    right.frame(maxWidth: .infinity)
                }
            } else {
                let topHeight = clampHeight(size.height * stackRatio + drag, total: size.height)
                VStack(spacing: 0) {
                    left.frame(height: topHeight)
                    divider(vertical: false, total: size.height)
                    right.frame(maxHeight: .infinity)
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: showRight)
    }

    private func clampWidth(_ width: CGFloat, total: CGFloat) -> CGFloat {
        let upper = max(Workspace.minTranscriptWidth, total - Workspace.minAnswerWidth - 1)
        return min(max(width, Workspace.minTranscriptWidth), upper)
    }

    private func clampHeight(_ height: CGFloat, total: CGFloat) -> CGFloat {
        let upper = max(Workspace.minTranscriptHeight, total - Workspace.minAnswerHeight - 1)
        return min(max(height, Workspace.minTranscriptHeight), upper)
    }

    private func divider(vertical: Bool, total: CGFloat) -> some View {
        let line = Rectangle().fill(hover.on || drag != 0 ? Color.accentColor.opacity(0.55) : Workspace.separator)
        let handle = Color.clear
            .frame(width: vertical ? 9 : nil, height: vertical ? nil : 9)
            .contentShape(Rectangle())
            .overlay(CursorRegion(cursor: vertical ? .resizeLeftRight : .resizeUpDown))
            .onHover { hover.on = $0 }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .updating($drag) { value, state, _ in state = vertical ? value.translation.width : value.translation.height }
                .onEnded { value in
                    if vertical {
                        ratio = Double(clampWidth(total * ratio + value.translation.width, total: total) / total)
                    } else {
                        stackRatio = Double(clampHeight(total * stackRatio + value.translation.height, total: total) / total)
                    }
                })
            .onTapGesture(count: 2) {
                if vertical { ratio = Workspace.defaultSplit } else { stackRatio = Workspace.defaultStackSplit }
            }
        return line
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .overlay(handle)
            .zIndex(1)
            .help("拖动调整大小 · 双击恢复默认")
    }
}

// MARK: Toolbar

private struct WorkspaceToolbar: View {
    @ObservedObject var model: AppModel

    private var statusText: String {
        if model.switchingSource { return "正在切换输入…" }
        if model.running && model.status.hasPrefix("正在聆听") { return "正在聆听" }
        if model.running || model.busy { return model.status }
        if model.status.hasPrefix("就绪") || model.status.hasPrefix("已停止") { return "未在转录" }
        return model.status
    }
    private var statusColor: Color {
        if model.running { return .green }
        if model.busy || model.switchingSource { return .orange }
        return Color(nsColor: .tertiaryLabelColor)
    }
    private var sourceTitle: String { model.source == "system" ? "系统音频" : "麦克风" }
    private var transcribing: Bool { model.running || model.busy }

    private func status(showsText: Bool) -> some View {
        HStack(spacing: 7) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
                .shadow(color: model.running ? Color.green.opacity(0.5) : .clear, radius: 3)
            if showsText {
                Text(statusText).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
        }
        .help(model.status)
        .accessibilityLabel(model.running ? "正在转录" : "未在转录")
    }

    private func inputMenu(iconOnly: Bool) -> some View {
        Menu {
            Picker("音频来源", selection: Binding(get: { model.source }, set: { model.selectSource($0) })) {
                Text("系统音频").tag("system"); Text("麦克风").tag("microphone")
            }
            Picker("识别服务", selection: Binding(get: { model.provider }, set: { model.selectProvider($0) })) {
                ForEach(ASRProviderKind.allCases) { Text($0.title).tag($0) }
            }
        } label: {
            if iconOnly {
                Image(systemName: model.source == "system" ? "speaker.wave.2" : "mic").font(.system(size: 12))
            } else {
                Text("\(sourceTitle) · \(model.provider.shortTitle)").font(.system(size: 12))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .disabled(model.busy || model.switchingSource)
        .help("音频来源与识别服务")
    }

    /// The narrowest bar folds the window buttons into this menu.
    private func moreMenu(includesWindowActions: Bool) -> some View {
        Menu {
            if includesWindowActions {
                Toggle("显示 AI 回答面板", isOn: $model.showAssistantPane)
                Button("设置…") { model.showSettings?() }
                Button("隐藏窗口") { model.hideWindow?() }
                Divider()
            }
            Button("打开双语记录") { model.openTranscripts() }
            Divider()
            Toggle("始终置顶", isOn: $model.onTop)
            Toggle("点击穿透", isOn: $model.clickThrough)
            Toggle("屏幕共享 / 截屏时隐藏", isOn: $model.hideFromCapture)
            Divider()
            Button("退出雪笺") { model.quitApp?() }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 26, height: 26)
        .help("更多")
    }

    /// level 0: full · 1: icon buttons · 2: minimal (window actions in the menu).
    private func bar(level: Int) -> some View {
        HStack(spacing: level == 2 ? 6 : 8) {
            status(showsText: level == 0)
            inputMenu(iconOnly: level == 2)
            Color.clear.frame(minWidth: 8, maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle()).overlay(WindowDragRegion())
            PillButton(title: transcribing ? "停止" : "开始转录", icon: transcribing ? "stop.fill" : "play.fill",
                       iconTint: transcribing ? .red : nil, showsTitle: level == 0,
                       disabled: model.switchingSource) { model.toggle() }
            PillButton(title: "AI 回答", icon: "sparkles", prominent: true, showsTitle: level == 0) {
                model.showAssistantPane = true
                model.assistant.generate()
            }
            if level < 2 {
                Divider().frame(height: 16).padding(.horizontal, 2)
                IconButton(icon: "sidebar.right", help: model.showAssistantPane ? "隐藏 AI 回答面板" : "显示 AI 回答面板",
                           active: model.showAssistantPane) { model.showAssistantPane.toggle() }
                IconButton(icon: "gearshape", help: "设置") { model.showSettings?() }
                IconButton(icon: "minus", help: "隐藏窗口 · ⌥⌘S 恢复") { model.hideWindow?() }
            }
            moreMenu(includesWindowActions: level == 2)
        }
        .padding(.leading, 14).padding(.trailing, 10)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) { bar(level: 0); bar(level: 1); bar(level: 2) }
            .frame(height: Workspace.toolbarHeight)
            .background(WindowDragRegion())
    }
}

// MARK: Transcript

/// Observes only LiveCaption, so ~10 Hz partial updates do not re-evaluate the history list.
private struct PartialCaption: View {
    @ObservedObject var live: LiveCaption
    let visible: Bool
    let fontSize: Double
    var body: some View {
        if visible && !live.partial.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(Color.green.opacity(0.8)).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 2 }
                Text(live.partial).font(.system(size: fontSize)).foregroundStyle(.secondary)
                    .lineSpacing(fontSize * 0.2).captionTextSelection()
            }
        }
    }
}

private struct LatestAnchor: View {
    @ObservedObject var live: LiveCaption
    let follow: Bool
    let proxy: ScrollViewProxy
    var body: some View {
        Color.clear.frame(height: 1).id("latest")
            .onChange(of: live.partial) { _, _ in if follow { proxy.scrollTo("latest", anchor: .bottom) } }
    }
}

/// Shown over the empty transcript; observes LiveCaption so the first partial hides it.
private struct TranscriptEmptyState: View {
    @ObservedObject var live: LiveCaption
    let hasEntries: Bool
    let running: Bool
    let busy: Bool
    let start: () -> Void
    var body: some View {
        if !hasEntries && live.partial.isEmpty {
            CenteredScroll {
            VStack(spacing: 10) {
                Image(systemName: running ? "waveform" : "waveform.slash")
                    .font(.system(size: 22, weight: .regular)).foregroundStyle(.tertiary)
                    .symbolEffect(.variableColor.iterative, isActive: running)
                Text(running ? "正在聆听" : "尚未开始转录").font(.system(size: 13, weight: .semibold))
                Text(running ? "检测到语音后，英文原文与中文翻译会实时出现在这里。" : "开始后，实时识别的英文与中文翻译会显示在这里，完整记录自动保存。")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 260)
                if !running && !busy {
                    PillButton(title: "开始转录", icon: "play.fill", action: start).padding(.top, 4)
                }
            }
            .padding(20)
            }
        }
    }
}

private struct TranscriptPane: View {
    @ObservedObject var model: AppModel

    private var showsBanner: Bool {
        model.busy || model.switchingSource || model.modelDownloadProgress != nil ||
            (!model.running && !model.status.hasPrefix("就绪") && !model.status.hasPrefix("已停止"))
    }

    private var banner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if model.busy || model.switchingSource { ProgressView().controlSize(.small) }
                else { Image(systemName: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.orange) }
                Text(model.switchingSource ? "正在切换输入或识别服务…" : model.status)
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if let progress = model.modelDownloadProgress { ProgressView(value: progress).controlSize(.small) }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Workspace.subtleFill))
        .padding(.horizontal, Workspace.gutter).padding(.bottom, 6)
    }

    private func entry(english: String, chinese: String?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if model.showEnglish {
                Text(english).font(.system(size: model.englishFontSize)).foregroundStyle(.primary)
                    .lineSpacing(model.englishFontSize * 0.2).captionTextSelection()
            }
            if model.showChinese {
                Text(chinese ?? "翻译中…").font(.system(size: model.fontSize))
                    .foregroundStyle(chinese == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    .lineSpacing(model.fontSize * 0.18).captionTextSelection()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hasEntries: Bool {
        model.displayMode == "history" ? !model.history.entries.isEmpty : !(model.english.isEmpty && model.chinese.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(icon: "text.bubble", title: "实时转录",
                       detail: model.displayMode == "history" && !model.history.entries.isEmpty ? "\(model.history.entries.count) 段" : "") {
                if !model.latency.isEmpty {
                    Text(model.latency).font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
            if showsBanner { banner }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if model.displayMode == "history" {
                            ForEach(model.history.entries) { item in entry(english: item.english, chinese: item.chinese).id(item.id) }
                        } else if hasEntries {
                            entry(english: model.english, chinese: model.chinese.isEmpty ? nil : model.chinese)
                        }
                        PartialCaption(live: model.live, visible: model.showEnglish, fontSize: model.englishFontSize)
                        LatestAnchor(live: model.live, follow: model.followLatest, proxy: proxy)
                    }
                    .padding(.horizontal, Workspace.gutter).padding(.top, 2).padding(.bottom, 18)
                }
                .scrollIndicators(.automatic)
                .background(ReadingScrollMonitor { if model.displayMode == "history" { model.followLatest = false } })
                .onChange(of: model.history.entries.last) { _, _ in if model.followLatest { proxy.scrollTo("latest", anchor: .bottom) } }
                .onChange(of: model.followLatest) { _, follow in if follow { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("latest", anchor: .bottom) } } }
                .onChange(of: model.displayMode) { _, _ in if model.followLatest { proxy.scrollTo("latest", anchor: .bottom) } }
                .overlay(TranscriptEmptyState(live: model.live, hasEntries: hasEntries, running: model.running,
                                              busy: model.busy || model.switchingSource) { model.toggle() })
                .overlay(alignment: .bottom) {
                    if !model.followLatest {
                        PillButton(title: "回到最新", icon: "arrow.down") { model.followLatest = true }
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.regularMaterial))
                            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
                            .padding(.bottom, 12)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .animation(.easeOut(duration: 0.15), value: model.followLatest)
            }
        }
    }
}

// MARK: AI answer

private struct AnswerSkeleton: View {
    let phase: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(phase.isEmpty ? "正在生成…" : phase).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            TimelineView(.animation) { context in
                let pulse = 0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 2.4)
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(0..<3, id: \.self) { line in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.05 + 0.04 * pulse))
                            .frame(height: 10)
                            .padding(.trailing, CGFloat([0, 36, 110][line]))
                    }
                }
            }
        }
        .accessibilityLabel(phase.isEmpty ? "正在生成" : phase)
    }
}

private struct AnswerEmptyState: View {
    let documentCount: Int
    let generate: () -> Void
    var body: some View {
        CenteredScroll {
            VStack(spacing: 10) {
                Image(systemName: "sparkles").font(.system(size: 22)).foregroundStyle(.tertiary)
                Text("等待提问").font(.system(size: 13, weight: .semibold))
                Text("对方提问后点击「AI 回答」，或在下方输入问题、粘贴图片。Gemini 会结合最近的转录与参考资料作答。")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 270)
                PillButton(title: "根据转录回答", icon: "sparkles", prominent: true, action: generate).padding(.top, 4)
                Text(documentCount == 0 ? "未添加参考资料 · 可在设置中添加" : "已加载 \(documentCount) 份参考资料")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary).padding(.top, 2)
            }
            .padding(20)
        }
    }
}

private struct AttachmentThumbnail: View {
    let attachment: ImageAttachment
    var size: CGFloat = 48
    var remove: (() -> Void)? = nil
    var body: some View {
        Group {
            if let image = NSImage(data: attachment.data) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .overlay(alignment: .topTrailing) {
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                        .symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(PressableStyle()).offset(x: 5, y: -5).help("移除图片")
            }
        }
    }
}

/// Converts pasted or dropped images into downscaled JPEGs for Gemini.
enum ImageImport {
    static let maxPixel: CGFloat = 1600

    /// Cheap check without decoding, used to enable Paste for image-only clipboards.
    static func hasImages(in pasteboard: NSPasteboard) -> Bool {
        let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: fileOptions) { return true }
        let types = pasteboard.types ?? []
        if types.contains(.fileURL) || pasteboard.string(forType: .string) != nil { return false }
        return pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    /// Image files first (Finder copies also carry a filename string), then
    /// raw image data. Plain text without images returns nothing.
    static func attachments(from pasteboard: NSPasteboard) -> [ImageAttachment] {
        let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [URL], !urls.isEmpty {
            return urls.compactMap { NSImage(contentsOf: $0).flatMap(attachment(from:)) }
        }
        // Copied non-image files and rich text from Office apps also carry image
        // representations; those are pasted as text, not as pictures.
        let types = pasteboard.types ?? []
        if types.contains(.fileURL) || pasteboard.string(forType: .string) != nil { return [] }
        let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] ?? []
        return images.compactMap(attachment(from:))
    }

    static func attachment(from image: NSImage) -> ImageAttachment? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, maxPixel / CGFloat(max(source.width, source.height)))
        let width = max(1, Int(CGFloat(source.width) * scale)), height = max(1, Int(CGFloat(source.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        // Flatten transparency onto white so screenshots of dark-on-clear UI stay readable.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage(),
              let jpeg = NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else { return nil }
        return ImageAttachment(data: jpeg, mimeType: "image/jpeg")
    }
}

/// Multi-line input that grows with its text. Return sends, Shift-Return adds a
/// line, and Return while an input method is composing confirms the candidate.
/// Pasting or dropping images hands them to the composer instead of inserting text.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let onSubmit: () -> Void
    let onImages: ([ImageAttachment]) -> Void

    final class TextView: NSTextView {
        var onImages: (([ImageAttachment]) -> Void)?
        /// A plain-text view disables Paste when the clipboard holds no text
        /// (e.g. a screenshot), so ⌘V would never reach `paste(_:)`.
        override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
            if item.action == #selector(paste(_:)), ImageImport.hasImages(in: .general) { return true }
            return super.validateUserInterfaceItem(item)
        }
        override func paste(_ sender: Any?) {
            let images = ImageImport.attachments(from: .general)
            if !images.isEmpty { onImages?(images) } else { pasteAsPlainText(sender) }
        }
        private func droppedImages(_ info: NSDraggingInfo) -> [ImageAttachment] {
            ImageImport.attachments(from: info.draggingPasteboard)
        }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self, NSImage.self], options: nil) ? .copy : super.draggingEntered(sender)
        }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self, NSImage.self], options: nil) ? .copy : super.draggingUpdated(sender)
        }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let images = droppedImages(sender)
            if !images.isEmpty { onImages?(images); return true }
            return super.performDragOperation(sender)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        init(_ parent: ComposerTextView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            report(view)
        }
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.onSubmit()
            }
            return true
        }
        func report(_ view: NSTextView) {
            guard let manager = view.layoutManager, let container = view.textContainer else { return }
            manager.ensureLayout(for: container)
            let measured = ceil(manager.usedRect(for: container).height + view.textContainerInset.height * 2)
            if abs(measured - parent.height) > 0.5 {
                DispatchQueue.main.async { self.parent.height = measured }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = TextView()
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = .systemFont(ofSize: 13)
        view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 0, height: 3)
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator
        view.onImages = onImages
        view.registerForDraggedTypes([.fileURL, .png, .tiff])
        view.setAccessibilityLabel("向 AI 提问")
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? TextView else { return }
        view.onImages = onImages
        if view.string != text {
            view.string = text
            context.coordinator.report(view)
        }
    }
}

final class ComposerMetrics: ObservableObject { @Published var height: CGFloat = 20 }

private struct Composer: View {
    @ObservedObject var assistant: AnswerAssistant
    @StateObject private var metrics = ComposerMetrics()

    private var canSend: Bool {
        !assistant.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !assistant.attachments.isEmpty
    }

    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            assistant.attach(panel.urls.compactMap { NSImage(contentsOf: $0).flatMap(ImageImport.attachment(from:)) })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !assistant.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(assistant.attachments) { item in
                            AttachmentThumbnail(attachment: item) { assistant.removeAttachment(item.id) }
                        }
                    }
                    .padding(.top, 6).padding(.trailing, 6)
                }
                .scrollIndicators(.never)
            }
            ComposerTextView(text: $assistant.draft, height: $metrics.height,
                             onSubmit: { assistant.ask() }, onImages: { assistant.attach($0) })
                .frame(height: min(max(metrics.height, 20), 112))
                .overlay(alignment: .topLeading) {
                    if assistant.draft.isEmpty {
                        Text(assistant.attachments.isEmpty ? "输入问题，或粘贴 / 拖入图片…" : "说明你想问什么（可留空，直接解释图片）")
                            .font(.system(size: 13)).foregroundStyle(.tertiary).padding(.top, 3).allowsHitTesting(false)
                    }
                }
            HStack(spacing: 6) {
                IconButton(icon: "photo.badge.plus", help: "添加图片") { chooseImages() }
                Text(assistant.composerMessage.isEmpty ? footnote : assistant.composerMessage)
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Button { assistant.ask() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(canSend ? Color.white : Color.secondary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(canSend ? Color.accentColor : Color.primary.opacity(0.08)))
                }
                .buttonStyle(PressableStyle())
                .disabled(!canSend)
                .help("发送（Return）· Shift-Return 换行")
                .accessibilityLabel("发送问题")
            }
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .padding(.horizontal, 12).padding(.bottom, 12)
    }

    private var footnote: String {
        assistant.cacheStatus.isEmpty ? assistant.model.rawValue : "\(assistant.model.rawValue) · \(assistant.cacheStatus)"
    }
}

/// Observes only AnswerAssistant, so streamed tokens never re-render the transcript.
private struct AnswerPane: View {
    @ObservedObject var assistant: AnswerAssistant
    let fontSize: Double

    private var hasContent: Bool {
        assistant.generating || !assistant.text.isEmpty || !assistant.errorMessage.isEmpty || assistant.question != nil
    }

    private var copyButton: some View {
        IconButton(icon: assistant.copied ? "checkmark" : "doc.on.doc", help: "复制英文回答",
                   active: assistant.copied, disabled: assistant.text.isEmpty) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(assistant.text, forType: .string)
            assistant.markCopied()
        }
    }

    private func header(compact: Bool) -> some View {
        PaneHeader(icon: "sparkles", title: "AI 回答", iconTint: .accentColor) {
            if assistant.generating && !assistant.text.isEmpty { ProgressView().controlSize(.mini).padding(.trailing, 2) }
            if compact {
                Menu {
                    Picker("回答长度", selection: Binding(get: { assistant.mode }, set: { assistant.selectMode($0) })) {
                        ForEach(AnswerMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: { Text(assistant.mode.title).font(.system(size: 11.5)) }
                .menuStyle(.borderlessButton).fixedSize()
            } else {
                Picker("回答长度", selection: Binding(get: { assistant.mode }, set: { assistant.selectMode($0) })) {
                    ForEach(AnswerMode.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).controlSize(.small).fixedSize()
                .help("Short：1–2 句 · Detailed：完整回答")
            }
            IconButton(icon: "arrow.clockwise", help: "重新生成") { assistant.regenerate() }
            copyButton
            IconButton(icon: "xmark", help: "清除回答", disabled: !hasContent) { assistant.dismiss() }
        }
    }

    private func questionBlock(_ question: ManualQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("你的问题").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.tertiary).kerning(0.6)
            if !question.images.isEmpty {
                HStack(spacing: 8) {
                    ForEach(question.images) { AttachmentThumbnail(attachment: $0, size: 40) }
                }
            }
            if !question.text.isEmpty {
                Text(question.text).font(.system(size: 13)).foregroundStyle(.secondary).captionTextSelection()
            }
        }
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Workspace.separator).frame(height: 1) }
    }

    private var answer: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(assistant.text).font(.system(size: fontSize)).foregroundStyle(.primary)
                .lineSpacing(fontSize * 0.32).captionTextSelection()
            if !assistant.translation.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("中文翻译").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.tertiary).kerning(0.6)
                    Text(assistant.translation).font(.system(size: fontSize * 0.94)).foregroundStyle(.secondary)
                        .lineSpacing(fontSize * 0.3).captionTextSelection()
                }
                .padding(.top, 14)
                .overlay(alignment: .top) { Rectangle().fill(Workspace.separator).frame(height: 1) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var error: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 8) {
                Text(assistant.errorMessage).font(.system(size: 12.5)).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true).captionTextSelection()
                PillButton(title: "重试", icon: "arrow.clockwise") { assistant.regenerate() }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.08)))
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) { header(compact: false); header(compact: true) }
            Group {
                if !hasContent {
                    AnswerEmptyState(documentCount: assistant.documents.count) { assistant.generate() }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if let question = assistant.question { questionBlock(question) }
                            if !assistant.errorMessage.isEmpty { error }
                            else if assistant.text.isEmpty { AnswerSkeleton(phase: assistant.phase) }
                            else { answer }
                        }
                        .padding(.horizontal, Workspace.gutter).padding(.top, 4).padding(.bottom, 18)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            Composer(assistant: assistant)
        }
        .background(Color.primary.opacity(0.025))
    }
}
