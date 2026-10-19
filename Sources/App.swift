import AppKit
import SwiftUI
import Carbon
import UniformTypeIdentifiers

final class SubtitlePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct FontSizeControl: View {
    let title:String
    @Binding var size:Double
    var body: some View {
        HStack {
            Text(title).frame(width:70,alignment:.leading)
            Slider(value:$size,in:8...72,step:1).accessibilityLabel(title)
            Text("\(Int(size.rounded())) pt").monospacedDigit().frame(width:48)
            Stepper(title,value:$size,in:8...72,step:1).labelsHidden()
        }
    }
}

struct PreferencesView: View {
    @ObservedObject var model:AppModel
    var body: some View {
        ScrollView {
        VStack(alignment:.leading,spacing:20) {
            HStack(spacing:14) {
                Image(nsImage:NSApp.applicationIconImage)
                    .resizable().scaledToFit().frame(width:52,height:52)
                    .accessibilityHidden(true)
                VStack(alignment:.leading,spacing:3) {
                    HStack(alignment:.firstTextBaseline,spacing:8) {
                        Text("雪笺").font(.system(size:25,weight:.semibold))
                        Text("XueScribe").font(.system(size:13,weight:.medium)).foregroundStyle(.secondary)
                    }
                    Text("Turn speech into text, quietly.").font(.system(size:13)).foregroundStyle(.secondary)
                    Text("作者 · 吕宣谊").font(.system(size:11)).foregroundStyle(.secondary)
                    Text("微信 · yukiyah").font(.system(size:11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Form {
                Picker("显示模式",selection:$model.displayMode) { Text("单句字幕").tag("single"); Text("长段转录与翻译").tag("history") }
                if model.displayMode == "history" {
                    Picker("窗口保留记录",selection:$model.historyLimit) { Text("50 段").tag(50); Text("100 段").tag(100); Text("300 段").tag(300); Text("1000 段").tag(1000) }
                    Text("上滚暂停跟随，可回看英中记录；完整 transcript 始终保存。").font(.caption).foregroundStyle(.secondary)
                }
                Picker("ASR Provider",selection:Binding(get:{ model.provider },set:{ model.selectProvider($0) })) {
                    ForEach(ASRProviderKind.allCases) { kind in Text(kind.title).tag(kind) }
                }.disabled(model.busy || model.switchingSource)
                Text(model.provider == .local ? "音频与中文翻译均在本机处理。" : "音频实时发送至 AssemblyAI；中文仍由本机 Hy-MT2 翻译。")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(alignment:.leading,spacing:6) {
                    HStack(spacing:7) {
                        Image(systemName:model.modelsReady ? "checkmark.circle.fill" : "arrow.down.circle")
                            .foregroundStyle(model.modelsReady ? Color.green : Color.secondary)
                        Text(model.modelsReady ? "两个本地模型已下载并通过校验" : "首次开始时自动下载两个开源模型 · 约 1.7 GB")
                        Spacer()
                    }
                    if let progress = model.modelDownloadProgress {
                        ProgressView(value:progress)
                        Text(model.modelDownloadStatus).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("模型保存在 Application Support/XueScribe/Models，不包含在 App 内；删除该目录后会在下次开始时重新下载。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment:.leading,spacing:7) {
                    HStack {
                        SecureField(model.hasAssemblyAIKey ? "已保存；输入新 Key 可替换" : "粘贴 AssemblyAI API Key",text:$model.assemblyAIKeyDraft)
                            .textFieldStyle(.roundedBorder)
                        Button("保存 Key") {
                            do {
                                try model.saveAssemblyAIKey(model.assemblyAIKeyDraft)
                            } catch { model.assemblyAIKeyMessage = error.localizedDescription }
                        }.disabled(model.assemblyAIKeyDraft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                        if model.hasAssemblyAIKey {
                            Button("删除",role:.destructive) {
                                do {
                                    try model.deleteAssemblyAIKey()
                                } catch { model.assemblyAIKeyMessage = error.localizedDescription }
                            }
                        }
                    }
                    Text(model.assemblyAIKeyMessage.isEmpty ? (model.hasAssemblyAIKey ? "Cloud Key 已保存在仅当前账户可读的本机文件中，不会写入偏好设置或日志。" : "只有选择 Cloud 时才会使用；默认 Local 不需要 Key。") : model.assemblyAIKeyMessage)
                        .font(.caption).foregroundStyle(model.assemblyAIKeyMessage.hasPrefix("无法") ? Color.red : Color.secondary)
                }
                Picker("音频来源",selection:Binding(get:{ model.source },set:{ model.selectSource($0) })) { Text("麦克风").tag("microphone"); Text("Mac 系统音频").tag("system") }.disabled(model.busy || model.switchingSource)
                HStack { Text("背景不透明度"); Slider(value:$model.opacity,in:0...1); Text("\(Int(model.opacity*100))%").monospacedDigit().frame(width:40) }
                Picker("外观",selection:$model.appearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                Toggle("显示 AI 回答面板",isOn:$model.showAssistantPane)
                FontSizeControl(title:"中文字号",size:$model.fontSize)
                FontSizeControl(title:"英文字号",size:$model.englishFontSize)
                Toggle("显示英文（包含即时 partial）",isOn:$model.showEnglish)
                Toggle("显示简体中文",isOn:$model.showChinese)
                Toggle("始终置顶",isOn:$model.onTop)
                Toggle("点击穿透（从菜单栏关闭）",isOn:$model.clickThrough)
                Toggle("屏幕共享 / 截屏时隐藏窗口",isOn:$model.hideFromCapture)
                Text("使用 macOS 原生的窗口捕获排除（NSWindow.sharingType = none），本机照常显示和操作。是否生效取决于会议软件的采集方式，不能保证所有共享场景都隐藏；最稳妥的方式是只共享某个窗口或应用，而不是整个屏幕。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            AssistantSettings(assistant:model.assistant)
            Divider()
            VStack(alignment:.leading,spacing:8) {
                Text("课程术语表").font(.headline)
                Text("每行：English = 中文。仅匹配当前英文的术语会发送给本地翻译模型。").font(.caption).foregroundStyle(.secondary)
                TextEditor(text:$model.glossary).font(.system(size:13,design:.monospaced)).frame(height:120).scrollContentBackground(.hidden).padding(8).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
            }
            HStack {
                Button("打开双语记录") { model.openTranscripts() }
                Button("测试示例音频") { model.start(sampleSeconds:24) }.disabled(model.running || model.busy)
                Spacer()
                Button(model.running || model.busy ? "停止" : "开始字幕") { model.toggle() }.buttonStyle(.borderedProminent).tint(.mint)
            }
            Text("⌥⌘S  隐藏 / 显示悬浮窗。拖动顶部左侧横条移动，拖动边缘缩放。系统音频开始时请选择屏幕并确认共享；仅处理音频，不保存画面。").font(.caption).foregroundStyle(.secondary)
        }.padding(26)
        }.frame(width:560,height: min(760, (NSScreen.main?.visibleFrame.height ?? 850)-100))
    }
}

struct AssistantSettings: View {
    @ObservedObject var assistant: AnswerAssistant
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text("AI 回答助手 · Gemini").font(.headline)
            Text("点击悬浮窗控制栏的 ✨，Gemini 会结合最近的转录与下方资料，生成可直接说出口的回答。转录照常进行。")
                .font(.caption).foregroundStyle(.secondary)
            Picker("模型",selection:$assistant.model) {
                ForEach(AnswerModel.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).frame(width:360)
            Text("资料会提前上传并预读进 Gemini 上下文缓存，点击时只发送转录。实测（约 3.6 万 token 资料）首字：3.8 Flash 约 3–5 秒，3.5 Flash-Lite 约 2 秒。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                SecureField(assistant.hasKey ? "已保存；输入新 Key 可替换" : "粘贴 Gemini API Key",text:$assistant.keyDraft)
                    .textFieldStyle(.roundedBorder)
                Button("保存 Key") { assistant.saveKey() }
                    .disabled(assistant.keyDraft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                if assistant.hasKey { Button("删除",role:.destructive) { assistant.deleteKey() } }
            }
            Text(assistant.keyMessage.isEmpty ? (assistant.hasKey ? "Key 保存在仅当前账户可读的本机文件中。" : "需要 Gemini API Key 才能生成回答。") : assistant.keyMessage)
                .font(.caption).foregroundStyle(assistant.keyMessage.hasPrefix("无法") ? Color.red : Color.secondary)
            Picker("默认回答长度",selection:$assistant.mode) {
                ForEach(AnswerMode.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).frame(width:300)
            HStack {
                Text("参考资料 · \(assistant.documents.count) 个").font(.subheadline.weight(.medium))
                Spacer()
                Button("添加文件…") { chooseFiles() }
            }
            if !assistant.cacheStatus.isEmpty {
                Label(assistant.cacheStatus,systemImage:assistant.cacheStatus.hasPrefix("资料已预读") ? "bolt.fill" : "info.circle")
                    .font(.caption).foregroundStyle(assistant.cacheStatus.hasPrefix("预读失败") ? Color.orange : Color.secondary)
            }
            if assistant.documents.isEmpty {
                Text("尚未添加。支持 Gemini 可读取的格式：PDF、Word (docx)、Excel (xlsx/xls)、PowerPoint (pptx)、ODT、RTF、Markdown、CSV、JSON、HTML 与各类文本/代码，图片 (PNG/JPG/HEIC/WebP/GIF…)，音频 (MP3/WAV/M4A/FLAC…) 和视频 (MP4/MOV/WebM…)，单个文件不超过 2 GB。添加后会提前上传，过期前自动重新上传；音视频越长，回答越慢。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(assistant.documents) { document in
                HStack(spacing:10) {
                    Image(systemName:document.symbol).foregroundStyle(.secondary).frame(width:18)
                    VStack(alignment:.leading,spacing:2) {
                        Text(document.name).lineLimit(1).truncationMode(.middle)
                        Text(assistant.status(of:document)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { NSWorkspace.shared.open(assistant.localURL(document)) } label: { Image(systemName:"eye") }
                        .buttonStyle(.borderless).help("查看")
                    Button(role:.destructive) { assistant.remove(document) } label: { Image(systemName:"trash") }
                        .buttonStyle(.borderless).help("删除")
                }
                .padding(8).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
            }
            if !assistant.libraryMessage.isEmpty {
                HStack {
                    Text(assistant.libraryMessage).font(.caption).foregroundStyle(Color.red)
                    Button("重试") { assistant.syncInBackground() }.controlSize(.small)
                }
            }
            Text("自定义 Prompt").font(.subheadline.weight(.medium)).padding(.top,4)
            Text("额外的回答要求，每次点击 ✨ 时与参考资料、最近转录一起发送。没有资料也可以单独使用。例如：我在面试数据科学岗位；回答时多提和用户增长相关的经历。")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text:$assistant.customPrompt).font(.system(size:13)).frame(height:90)
                .scrollContentBackground(.hidden).padding(8).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
            DisclosureGroup("内置回答规则（可修改）") {
                VStack(alignment:.leading,spacing:6) {
                    Text("这是发送给 Gemini 的基础指令，包含问题识别、不编造经历、语言匹配和「【中文翻译】」输出格式（删掉最后一条规则即不再附中文翻译）。自定义 Prompt 会追加在它之后；长度要求放在每次请求的最后，最容易被遵守。")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text:$assistant.basePrompt).font(.system(size:12,design:.monospaced)).frame(height:240)
                        .scrollContentBackground(.hidden).padding(8).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
                    Text("Short 长度规则（每次请求最后发送）").font(.caption.weight(.medium)).padding(.top,4)
                    TextEditor(text:$assistant.shortRule).font(.system(size:12,design:.monospaced)).frame(height:48)
                        .scrollContentBackground(.hidden).padding(6).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
                    Text("Detailed 长度规则").font(.caption.weight(.medium))
                    TextEditor(text:$assistant.detailedRule).font(.system(size:12,design:.monospaced)).frame(height:48)
                        .scrollContentBackground(.hidden).padding(6).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
                    HStack {
                        Spacer()
                        Button("全部恢复默认") {
                            assistant.basePrompt = AnswerPrompt.defaultSystem
                            assistant.shortRule = AnswerPrompt.defaultShortRule
                            assistant.detailedRule = AnswerPrompt.defaultDetailedRule
                        }
                        .disabled(assistant.basePrompt == AnswerPrompt.defaultSystem && assistant.shortRule == AnswerPrompt.defaultShortRule && assistant.detailedRule == AnswerPrompt.defaultDetailedRule)
                    }
                }.padding(.top,6)
            }
            Text("英文回答会由 Gemini 在同一次回复中紧接着附上简体中文翻译（显示在英文下方）；中文回答不重复翻译。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = KnowledgeFormat.openPanelTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { assistant.add(panel.urls) }
    }
}

@MainActor
final class AppDelegate:NSObject,NSApplicationDelegate,NSWindowDelegate {
    lazy var model = AppModel()
    var panel:SubtitlePanel!
    var settings:NSWindow?
    var item:NSStatusItem!
    var hotKey:EventHotKeyRef?
    var handler:EventHandlerRef?
    var terminationSignals:[DispatchSourceSignal] = []
    func applicationDidFinishLaunching(_ notification:Notification) {
        migrateLegacyPreferences()
        let model = self.model
        NSApp.setActivationPolicy(.accessory)
        // A normal key-capable borderless panel lets selected SwiftUI text receive
        // standard keyboard commands such as Command-C.
        panel = SubtitlePanel(contentRect:NSRect(x:160,y:120,width:980,height:580),styleMask:[.borderless,.resizable],backing:.buffered,defer:false)
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        panel.acceptsMouseMovedEvents = true; panel.isMovableByWindowBackground = false; panel.hidesOnDeactivate = false; panel.isFloatingPanel = true
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.minSize = NSSize(width:Workspace.minWindowWidth,height:Workspace.minHeightWithAnswer); panel.delegate = self
        panel.contentView = NSHostingView(rootView:WorkspaceView(model:model))
        if !panel.setFrameUsingName("XueScribe.Subtitles"), !panel.setFrameUsingName("LumaCaption.Subtitles") { panel.center(); if let screen = panel.screen { var f = panel.frame; f.origin.y = screen.visibleFrame.minY+70; panel.setFrame(f,display:false) } }
        if !NSScreen.screens.contains(where:{$0.visibleFrame.intersects(panel.frame)}) { panel.center() }
        panel.setFrameAutosaveName("XueScribe.Subtitles")
        model.windowChange = { [weak self] in self?.updatePanel() }
        model.showSettings = { [weak self] in self?.openSettings() }
        model.hideWindow = { [weak self] in self?.panel.orderOut(nil) }
        model.quitApp = { [weak self] in self?.quit() }
        updatePanel()
        if !CommandLine.arguments.contains("--headless") { panel.orderFrontRegardless() }
        item = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName:"captions.bubble",accessibilityDescription:"雪笺")
        let menu = NSMenu()
        add(menu,"显示 / 隐藏字幕  ⌥⌘S",#selector(togglePanel))
        add(menu,"开始 / 停止字幕",#selector(toggleRecording))
        add(menu,"AI 回答",#selector(generateAnswer))
        add(menu,"设置与术语表…",#selector(openSettings))
        add(menu,"切换点击穿透",#selector(toggleThrough))
        add(menu,"打开双语记录",#selector(openTranscripts))
        menu.addItem(.separator()); add(menu,"关于雪笺",#selector(showAbout)); add(menu,"退出雪笺",#selector(quit),key:"q")
        item.menu = menu
        if CommandLine.arguments.contains("--headless") { NSStatusBar.system.removeStatusItem(item) }
        let appMenu = NSMenu(); let root = NSMenuItem(); appMenu.addItem(root)
        let submenu = NSMenu(); root.submenu = submenu
        add(submenu,"关于雪笺",#selector(showAbout)); submenu.addItem(.separator())
        add(submenu,"设置…",#selector(openSettings),key:",")
        add(submenu,"退出雪笺",#selector(quit),key:"q")
        // Text fields only receive ⌘ shortcuts through main-menu items, so every
        // standard edit command needs one; nil targets reach the focused field.
        let editRoot = NSMenuItem(title:"编辑",action:nil,keyEquivalent:"")
        let editMenu = NSMenu(title:"编辑")
        let editItems: [(String,Selector,String,NSEvent.ModifierFlags)] = [
            ("撤销",Selector(("undo:")),"z",[.command]),
            ("重做",Selector(("redo:")),"z",[.command,.shift]),
            ("",Selector(("separator")),"",[]),
            ("剪切",#selector(NSText.cut(_:)),"x",[.command]),
            ("复制",#selector(NSText.copy(_:)),"c",[.command]),
            ("粘贴",#selector(NSText.paste(_:)),"v",[.command]),
            ("粘贴并匹配样式",#selector(NSTextView.pasteAsPlainText(_:)),"v",[.command,.option,.shift]),
            ("删除",#selector(NSText.delete(_:)),"",[]),
            ("全选",#selector(NSText.selectAll(_:)),"a",[.command]),
        ]
        for (title,action,key,modifiers) in editItems {
            if title.isEmpty { editMenu.addItem(.separator()); continue }
            let entry = NSMenuItem(title:title,action:action,keyEquivalent:key)
            entry.keyEquivalentModifierMask = modifiers; entry.target = nil
            editMenu.addItem(entry)
        }
        editRoot.submenu = editMenu; appMenu.addItem(editRoot)
        NSApp.mainMenu = appMenu
        var spec = EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _,_,userData in
            guard let userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in delegate.togglePanel() }; return noErr
        },1,&spec,Unmanaged.passUnretained(self).toOpaque(),&handler)
        let result = CommandLine.arguments.contains("--headless") ? noErr : RegisterEventHotKey(UInt32(kVK_ANSI_S),UInt32(cmdKey | optionKey),EventHotKeyID(signature:0x4C554D41,id:1),GetApplicationEventTarget(),0,&hotKey)
        if result != noErr { model.status = "全局快捷键注册失败，请使用菜单栏显示字幕" }
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal:sig,queue:.main)
            source.setEventHandler { [weak self] in self?.quit() }; source.resume(); terminationSignals.append(source)
        }
        let args = CommandLine.arguments
        if let index = args.firstIndex(of:"--sample-seconds"),args.count > index+1,let seconds = Double(args[index+1]) { model.start(sampleSeconds:seconds) }
    }
    func migrateLegacyPreferences() {
        let defaults = UserDefaults.standard
        guard let legacy = defaults.persistentDomain(forName:"local.lumacaption.mac") else { return }
        let keys = ["displayMode","historyLimit","asrProvider","source","opacity","textTone","englishFontSize","fontSize","showEnglish","showChinese","glossary"]
        for key in keys where defaults.object(forKey:key) == nil {
            if let value = legacy[key] { defaults.set(value,forKey:key) }
        }
    }
    func add(_ menu:NSMenu,_ title:String,_ action:Selector,key:String = "") { let entry = NSMenuItem(title:title,action:action,keyEquivalent:key);entry.target = self;menu.addItem(entry) }
    func updatePanel() {
        panel.ignoresMouseEvents = model.clickThrough
        panel.level = model.onTop ? .floating : .normal
        let appearance: NSAppearance? = model.appearance == "light" ? NSAppearance(named:.aqua) : model.appearance == "dark" ? NSAppearance(named:.darkAqua) : nil
        panel.appearance = appearance; settings?.appearance = appearance
        panel.hasShadow = model.opacity > 0
        // Narrow windows stack the panes; a frame below the minimum (e.g. saved by the old
        // subtitle strip) is enlarged in place with the top edge fixed.
        panel.minSize = NSSize(width:Workspace.minWindowWidth,height:model.showAssistantPane ? Workspace.minHeightWithAnswer : Workspace.minHeightTranscriptOnly)
        var frame = panel.frame
        if frame.width < panel.minSize.width || frame.height < panel.minSize.height {
            let top = frame.maxY
            frame.size.width = max(frame.width,panel.minSize.width)
            frame.size.height = max(frame.height,panel.minSize.height)
            frame.origin.y = top - frame.height
            if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame { frame.origin.x = min(frame.origin.x,visible.maxX-frame.width); frame.origin.y = max(frame.origin.y,visible.minY) }
            panel.setFrame(frame,display:true)
        }
        // Native capture exclusion: the windows stay fully visible and interactive
        // locally. Whether a given screen-sharing app honors it is up to its capture path.
        let sharing: NSWindow.SharingType = model.hideFromCapture ? .none : .readOnly
        panel.sharingType = sharing
        settings?.sharingType = sharing
    }
    @objc func togglePanel() { if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() } }
    @objc func toggleRecording() { model.toggle() }
    @objc func generateAnswer() { panel.orderFrontRegardless(); model.showAssistantPane = true; model.assistant.generate() }
    @objc func toggleThrough() { model.clickThrough.toggle() }
    @objc func openTranscripts() { model.openTranscripts() }
    @objc func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options:[
            .applicationName:"雪笺",
            .credits:NSAttributedString(string:"作者：吕宣谊\n微信：yukiyah")
        ])
        NSApp.activate(ignoringOtherApps:true)
    }
    @objc func openSettings() {
        if settings == nil { settings = NSWindow(contentRect:NSRect(x:0,y:0,width:572,height:660),styleMask:[.titled,.closable],backing:.buffered,defer:false);settings!.title = "雪笺设置";settings!.isReleasedWhenClosed = false; settings!.level = NSWindow.Level(rawValue:NSWindow.Level.floating.rawValue+1); settings!.contentView = NSHostingView(rootView:PreferencesView(model:model));settings!.center(); updatePanel() }
        settings!.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    @objc func quit() { Task { await model.stop(); NSApp.terminate(nil) } }
    func applicationWillTerminate(_ notification:Notification) { model.shutdown(); if let hotKey { UnregisterEventHotKey(hotKey) }; if let handler { RemoveEventHandler(handler) } }
    func windowDidMove(_ notification:Notification) { panel.saveFrame(usingName:"XueScribe.Subtitles") }
    func windowDidResize(_ notification:Notification) { panel.saveFrame(usingName:"XueScribe.Subtitles"); panel.invalidateShadow() }
}

@main
struct XueScribeMain {
    @MainActor static func main() { let app = NSApplication.shared; let delegate = AppDelegate();app.delegate = delegate;withExtendedLifetime(delegate) { app.run() } }
}
