import Foundation
import Combine
import UniformTypeIdentifiers

/// Measured on a 36k-token library with a warm cache: 3.8 Flash ~3-5 s to the
/// first word (occasional server spikes), 3.5 Flash-Lite ~2 s.
enum AnswerModel: String, CaseIterable, Identifiable {
    case flash = "gemini-3.8-flash"
    case flashLite = "gemini-3.5-flash-lite"
    var id: String { rawValue }
    var title: String { self == .flash ? "3.8 Flash · 质量优先" : "3.5 Flash-Lite · 速度优先" }
}

/// An image the user pasted or dropped into the composer, already downscaled for upload.
struct ImageAttachment: Identifiable, Equatable {
    let id = UUID()
    let data: Data
    let mimeType: String
}

/// A question typed in the composer, optionally with images. It replaces
/// "find the question in the transcript"; the transcript stays as context.
struct ManualQuestion: Equatable {
    let text: String
    let images: [ImageAttachment]
}

enum AnswerMode: String, CaseIterable, Identifiable {
    case short, detailed
    var id: String { rawValue }
    var title: String { self == .short ? "Short" : "Detailed" }
}

/// File formats Gemini reads natively through the Files API. Most were checked
/// against gemini-3.8-flash; legacy .doc/.ppt upload but their text is not read.
enum KnowledgeFormat {
    static let mimeTypes: [String: String] = [
        "pdf": "application/pdf", "rtf": "application/rtf",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "odt": "application/vnd.oasis.opendocument.text",
        "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "xls": "application/vnd.ms-excel",
        "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "txt": "text/plain", "md": "text/markdown", "markdown": "text/markdown", "csv": "text/csv",
        "json": "application/json", "html": "text/html", "htm": "text/html", "xml": "text/xml",
        "css": "text/css", "js": "text/javascript", "py": "text/x-python",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp",
        "heic": "image/heic", "heif": "image/heif", "gif": "image/gif", "bmp": "image/bmp",
        "tif": "image/tiff", "tiff": "image/tiff",
        "wav": "audio/wav", "mp3": "audio/mpeg", "aif": "audio/aiff", "aiff": "audio/aiff",
        "aac": "audio/aac", "ogg": "audio/ogg", "flac": "audio/flac", "m4a": "audio/mp4",
        "mp4": "video/mp4", "m4v": "video/mp4", "mov": "video/quicktime", "webm": "video/webm",
        "mpeg": "video/mpeg", "mpg": "video/mpeg", "avi": "video/avi", "flv": "video/x-flv",
        "wmv": "video/wmv", "3gp": "video/3gpp",
    ]
    /// Files API per-file limit.
    static let maxBytes: Int64 = 2 * 1024 * 1024 * 1024

    /// Unlisted plain-text and source files (.swift, .java, .tex …) go up as text/plain.
    static func mimeType(for url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if let known = mimeTypes[ext] { return known }
        guard let type = UTType(filenameExtension: ext), type.conforms(to: .text) || type.conforms(to: .sourceCode) else { return nil }
        return "text/plain"
    }

    static var openPanelTypes: [UTType] {
        mimeTypes.keys.compactMap { UTType(filenameExtension: $0) } + [.text, .sourceCode]
    }
}

/// A reference file kept in Application Support plus its current Gemini Files API
/// reference. Remote files expire after 48 h; the local copy lets us re-upload silently.
struct KnowledgeDocument: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var remoteName: String?
    var remoteURI: String?
    var expiresAt: Date?
    /// Absent in libraries saved when only PDFs were supported.
    var mimeType: String?
    var fileExtension: String?
    var mime: String { mimeType ?? "application/pdf" }
    var symbol: String {
        if mime.hasPrefix("image/") { return "photo" }
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime.hasPrefix("video/") { return "film" }
        if mime == "application/pdf" { return "doc.richtext" }
        if mime.contains("sheet") || mime.contains("excel") || mime == "text/csv" { return "tablecells" }
        if mime.contains("presentation") { return "rectangle.on.rectangle" }
        return "doc.text"
    }
    /// Refresh well before expiry so a request never races the deadline.
    func needsUpload(now: Date = Date()) -> Bool {
        guard remoteURI != nil, let expiresAt else { return true }
        return expiresAt.timeIntervalSince(now) < 30 * 60
    }
}

struct GeminiError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
    /// Expired or deleted Files API references come back as 403/404 naming the file.
    var isMissingFile: Bool { (status == 403 || status == 404) && message.localizedCaseInsensitiveContains("file") }
    /// Explicit caches expire or get deleted; rebuild and retry once.
    var isMissingCache: Bool { (status == 403 || status == 404) && message.localizedCaseInsensitiveContains("CachedContent") }
    /// Gemini rejects caches under 1,024 tokens; those requests are fast without one.
    var isCacheTooSmall: Bool { status == 400 && message.localizedCaseInsensitiveContains("too small") }
    static func from(status: Int, body: Data) -> GeminiError {
        let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let message = (json?["error"] as? [String: Any])?["message"] as? String
        return GeminiError(status: status, message: message ?? "Gemini 请求失败 (HTTP \(status))")
    }
}

enum AnswerPrompt {
    /// Built-in instructions, shown and editable in Settings. The length rule is
    /// sent separately at the end of each request.
    static let defaultSystem = """
    你是用户（运行本应用的人）在会议、面试或日常对话中的实时回答助手。
    你会收到：(1) 用户提前提供的参考资料（可能没有），例如简历、项目笔记、技术文档、表格、幻灯片、图片、音频或视频；(2) 最近一段对话的语音转录；(3) 可能还有用户的额外指令。

    任务：找出对方最近一次向用户提出的问题或请求。请通读整段转录，而不是只看最后一句：问题可能跨越多行、被换种说法重复，或后面跟着语气词和闲聊。然后结合参考资料、对话上下文和用户指令，写出用户现在就能直接说出口的回答。

    规则：
    - 优先使用参考资料中的事实。谈到用户本人的背景和经历时，以用户的身份用第一人称回答。
    - 不得编造参考资料或用户指令中没有的经历、雇主、项目、数字、日期或技能。如果资料无法支撑某个关于用户本人的问题，就基于已有信息如实回答，不要虚构。
    - 不要在资料之外补充用户工作的具体难点、指标、实现细节或轶事。对方问到这些细节而资料中没有时，就概括地回答，或简短表示可以之后再详细展开。
    - 资料没有涉及的通用或技术问题，可以使用你的通用知识回答。
    - 用对方说话所用的语言回答：对方用英文就必须用英文回答，用中文就用中文回答。本指令虽然用中文写成，但这不代表要用中文回答。
    - 口语化、自然、直接。不要使用 Markdown、LaTeX 公式、列表或标题，也不要用"好的""下面是回答"之类的开场白。
    - 转录来自语音识别，没有说话人标签，可能有识别错误，也可能包含用户自己说的话。请合理推断对方的意图。
    - 只要对话中有指向用户的问题或请求，就一定要回答，即使参考资料里没有相关内容（此时用通用知识或如实说明）。只有完全找不到任何问题或请求时，才只输出一行："⚠️ 未识别到明确的问题：" 后接一句简短的中文，说明当前对话在讲什么。
    - 严格遵守每次请求末尾给出的长度要求；长度只针对回答本身，不包括中文翻译。除回答和下面要求的中文翻译外，不要输出任何其他内容。
    - 如果回答是英文：先输出英文回答，然后另起一行输出"【中文翻译】"，再给出这段回答的简体中文翻译。如果回答是中文，不要输出翻译部分。
    """

    /// Sent last in every request, where models follow length limits most reliably.
    static let defaultShortRule = "长度要求：只说 1–2 句简短的口语句子，英文合计不超过 30 个单词（中文不超过 60 个字）。只给出核心答案，不要背景或解释。"
    static let defaultDetailedRule = "长度要求：较完整的口语回答，英文约 120–220 个单词（中文约 250–400 字），保持口语化；相关时举一个参考资料中的具体例子。"

    /// Gemini puts the Simplified Chinese translation of an English answer after this line.
    static let translationMarker = "【中文翻译】"

    /// Splits a (possibly still streaming) reply into the answer and its translation,
    /// hiding a marker that has only partly arrived.
    static func splitTranslation(_ raw: String) -> (answer: String, translation: String) {
        if let range = raw.range(of: translationMarker) {
            return (raw[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines),
                    raw[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var answer = raw
        for length in stride(from: translationMarker.count - 1, through: 1, by: -1)
        where answer.hasSuffix(String(translationMarker.prefix(length))) {
            answer.removeLast(length); break
        }
        return (answer.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    /// The user's custom prompt is appended as extra instructions, so answer mode,
    /// language matching and the Chinese translation keep working.
    static func system(base: String, custom: String) -> String {
        let base = base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultSystem : base
        let custom = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !custom.isEmpty else { return base }
        return base + "\n\n用户的额外指令（在以上规则基础上执行；与风格类规则冲突时，以用户指令为准）：\n" + custom
    }

    /// Newest-first walk so the budget always keeps the latest lines.
    static func recentTranscript(lines: [String], partial: String, maxCharacters: Int = 6000) -> String {
        var kept: [String] = []
        var used = 0
        let all = lines + (partial.isEmpty ? [] : [partial])
        for line in all.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if used + trimmed.count > maxCharacters, !kept.isEmpty { break }
            kept.append(trimmed); used += trimmed.count + 1
        }
        return kept.reversed().joined(separator: "\n")
    }
}

struct GeminiClient {
    private static let host = "https://generativelanguage.googleapis.com"
    let apiKey: String

    struct RemoteFile: Decodable {
        let name: String
        let uri: String
        let state: String?
        let expirationTime: String?
        var expiresAt: Date { GeminiClient.parseTime(expirationTime) ?? Date().addingTimeInterval(47 * 3600) }
    }
    private struct FileEnvelope: Decodable { let file: RemoteFile }

    private func request(_ path: String, method: String = "GET", timeout: TimeInterval = 60) -> URLRequest {
        var request = URLRequest(url: URL(string: Self.host + path)!, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        return request
    }

    private func send(_ request: URLRequest, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = body == nil ? try await URLSession.shared.data(for: request)
                                           : try await URLSession.shared.upload(for: request, from: body!)
        guard let http = response as? HTTPURLResponse else { throw GeminiError(status: 0, message: "Gemini 无响应") }
        guard (200..<300).contains(http.statusCode) else { throw GeminiError.from(status: http.statusCode, body: data) }
        return (data, http)
    }

    /// Resumable upload: one call opens the session, the second sends and finalizes the bytes.
    func upload(_ file: URL, displayName: String, mimeType: String) async throws -> RemoteFile {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        var start = request("/upload/v1beta/files", method: "POST", timeout: 30)
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue(String(size), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let meta = try JSONSerialization.data(withJSONObject: ["file": ["display_name": displayName]])
        let (_, opened) = try await send(start, body: meta)
        guard let uploadURL = opened.value(forHTTPHeaderField: "X-Goog-Upload-URL").flatMap(URL.init(string:)) else {
            throw GeminiError(status: 0, message: "Gemini 未返回上传地址")
        }
        var finish = URLRequest(url: uploadURL, timeoutInterval: 600)
        finish.httpMethod = "POST"
        finish.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        finish.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        // Stream from disk so large audio or video never sits in memory.
        let (sent, response) = try await URLSession.shared.upload(for: finish, fromFile: file)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GeminiError.from(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: sent)
        }
        var remote = try JSONDecoder().decode(FileEnvelope.self, from: sent).file
        // Video and long audio are processed server-side before they can be referenced.
        for _ in 0..<300 where remote.state == "PROCESSING" {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let (status, _) = try await send(request("/v1beta/\(remote.name)"))
            remote = try JSONDecoder().decode(RemoteFile.self, from: status)
        }
        if remote.state == "FAILED" { throw GeminiError(status: 0, message: "Gemini 无法处理 \(displayName)") }
        return remote
    }

    func delete(remoteName: String) async {
        _ = try? await send(request("/v1beta/\(remoteName)", method: "DELETE", timeout: 15))
    }

    static func fileParts(_ documents: [KnowledgeDocument]) -> [[String: Any]] {
        documents.flatMap { document -> [[String: Any]] in
            guard let uri = document.remoteURI else { return [] }
            return [["text": "[参考资料：\(document.name)]"],
                    ["fileData": ["mimeType": document.mime, "fileUri": uri]]]
        }
    }

    /// Pre-reads the reference files and instructions once. Without this Gemini
    /// re-processes every file on each click (~25 s for a 36k-token library).
    func createCache(model: AnswerModel, system: String, documents: [KnowledgeDocument],
                     ttl: Int) async throws -> (name: String, expiresAt: Date) {
        var request = request("/v1beta/cachedContents", method: "POST", timeout: 120)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "model": "models/\(model.rawValue)",
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": Self.fileParts(documents)]],
            "ttl": "\(ttl)s",
        ]
        let (data, _) = try await send(request, body: try JSONSerialization.data(withJSONObject: payload))
        return try Self.cacheInfo(data)
    }

    func extendCache(name: String, ttl: Int) async throws -> Date {
        var request = request("/v1beta/\(name)?updateMask=ttl", method: "PATCH", timeout: 15)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await send(request, body: try JSONSerialization.data(withJSONObject: ["ttl": "\(ttl)s"]))
        return try Self.cacheInfo(data).expiresAt
    }

    func deleteCache(name: String) async {
        _ = try? await send(request("/v1beta/\(name)", method: "DELETE", timeout: 15))
    }

    private static func cacheInfo(_ data: Data) throws -> (name: String, expiresAt: Date) {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let name = json?["name"] as? String else { throw GeminiError(status: 0, message: "Gemini 未返回缓存") }
        return (name, parseTime(json?["expireTime"] as? String) ?? Date().addingTimeInterval(50 * 60))
    }

    /// Streams the answer so the first words appear as soon as Gemini produces them.
    /// With a cache, files and instructions are already inside it; only the transcript is sent.
    func streamAnswer(model: AnswerModel, system: String, documents: [KnowledgeDocument], cache: String?,
                      transcript: String, question: ManualQuestion?, lengthRule: String,
                      onText: @escaping @MainActor (String) -> Void) async throws {
        var parts = cache == nil ? Self.fileParts(documents) : []
        parts.append(["text": transcript.isEmpty ? "（目前没有对话转录。）" : """
            最近的对话转录（按时间先后）：
            <<<
            \(transcript)
            >>>
            """])
        if let question {
            let images = question.images.isEmpty ? "" : "（附 \(question.images.count) 张图片）"
            parts.append(["text": """
                用户手动输入了一个问题\(images)。请直接回答这个问题，不需要再从转录中识别问题；转录和参考资料只作为背景。用这个问题所用的语言回答；如果只有图片没有文字，就用中文解释图片内容。
                <<<
                \(question.text.isEmpty ? "请解释这些图片。" : question.text)
                >>>
                """])
            for image in question.images {
                parts.append(["inlineData": ["mimeType": image.mimeType, "data": image.data.base64EncodedString()]])
            }
        }
        parts.append(["text": "\(lengthRule)\n现在请输出回答。"])
        var payload: [String: Any] = [
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": ["thinkingConfig": ["thinkingLevel": "low"]],
        ]
        if let cache { payload["cachedContent"] = cache }
        else { payload["systemInstruction"] = ["parts": [["text": system]]] }
        var request = request("/v1beta/models/\(model.rawValue):streamGenerateContent?alt=sse", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            throw GeminiError.from(status: status, body: body)
        }
        var produced = false
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let text = try Self.text(fromChunk: Data(line.dropFirst(5).utf8))
            if !text.isEmpty { produced = true; await onText(text) }
        }
        if !produced { throw GeminiError(status: 0, message: "Gemini 没有返回内容，请重试") }
    }

    /// Extracts visible answer text from one SSE `data:` payload, skipping thought parts.
    static func text(fromChunk data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        if let error = json["error"] as? [String: Any] {
            throw GeminiError(status: error["code"] as? Int ?? 0, message: error["message"] as? String ?? "Gemini 返回错误")
        }
        let candidates = json["candidates"] as? [[String: Any]] ?? []
        let parts = (candidates.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        return parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
    }

    /// Google returns nanosecond timestamps, which ISO8601DateFormatter rejects.
    static func parseTime(_ value: String?) -> Date? {
        guard let value, value.count >= 19 else { return nil }
        return ISO8601DateFormatter().date(from: String(value.prefix(19)) + "Z")
    }
}

/// Owns the reference-file library and the current answer. Kept separate from AppModel so
/// streamed tokens re-render only the answer view, never the caption history.
@MainActor
final class AnswerAssistant: ObservableObject {
    @Published private(set) var documents: [KnowledgeDocument] = []
    @Published private(set) var uploading: Set<UUID> = []
    @Published private(set) var text = ""
    @Published private(set) var generating = false
    @Published private(set) var phase = ""
    @Published private(set) var errorMessage = ""
    @Published private(set) var visible = false
    /// Composer state: typed text and images waiting to be sent.
    @Published var draft = ""
    @Published private(set) var attachments: [ImageAttachment] = []
    @Published private(set) var composerMessage = ""
    /// The manual question behind the current answer, shown above it; nil for transcript answers.
    @Published private(set) var question: ManualQuestion?
    static let maxAttachments = 6
    @Published private(set) var copied = false
    @Published private(set) var translation = ""
    /// The reply as streamed; `text` and `translation` are split from it.
    private var raw = ""
    @Published var basePrompt = UserDefaults.standard.string(forKey: "answerBasePrompt") ?? AnswerPrompt.defaultSystem {
        didSet { Self.store(basePrompt, default: AnswerPrompt.defaultSystem, key: "answerBasePrompt"); scheduleCacheRefresh() }
    }
    @Published var customPrompt = UserDefaults.standard.string(forKey: "answerCustomPrompt") ?? "" {
        didSet { UserDefaults.standard.set(customPrompt, forKey: "answerCustomPrompt"); scheduleCacheRefresh() }
    }
    @Published var shortRule = UserDefaults.standard.string(forKey: "answerShortRule") ?? AnswerPrompt.defaultShortRule {
        didSet { Self.store(shortRule, default: AnswerPrompt.defaultShortRule, key: "answerShortRule") }
    }
    @Published var detailedRule = UserDefaults.standard.string(forKey: "answerDetailedRule") ?? AnswerPrompt.defaultDetailedRule {
        didSet { Self.store(detailedRule, default: AnswerPrompt.defaultDetailedRule, key: "answerDetailedRule") }
    }
    /// Store only real edits so future default improvements still apply.
    private static func store(_ value: String, default fallback: String, key: String) {
        if value == fallback { UserDefaults.standard.removeObject(forKey: key) } else { UserDefaults.standard.set(value, forKey: key) }
    }
    @Published var model = AnswerModel(rawValue: UserDefaults.standard.string(forKey: "answerModel") ?? "") ?? .flashLite {
        didSet { UserDefaults.standard.set(model.rawValue, forKey: "answerModel"); scheduleCacheRefresh(after: 0) }
    }
    @Published private(set) var cacheStatus = ""
    @Published var mode = AnswerMode(rawValue: UserDefaults.standard.string(forKey: "answerMode") ?? "") ?? .short {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "answerMode") }
    }
    @Published private(set) var hasKey = CredentialStore.hasGeminiKey
    @Published var keyDraft = ""
    @Published var keyMessage = ""
    @Published private(set) var libraryMessage = ""
    /// Supplied by AppModel: the latest transcript lines, oldest first.
    var transcriptProvider: (() -> String)?
    private let directory: URL
    private var index: URL { directory.appendingPathComponent("library.json") }
    private var inflight: [UUID: Task<GeminiClient.RemoteFile, Error>] = [:]
    private var answerTask: Task<Void, Never>?
    private var runID = UUID()
    private struct PromptCache { let key: String; let name: String; var expiresAt: Date }
    private var cache: PromptCache?
    private var cacheBuild: (key: String, task: Task<PromptCache?, Error>)?
    private var uncacheableKey: String?
    private var cacheRefresh: Task<Void, Never>?
    private static let cacheTTL = 60 * 60

    init(support: URL) {
        directory = support.appendingPathComponent("Knowledge", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: index),
           let saved = try? JSONDecoder().decode([KnowledgeDocument].self, from: data) {
            documents = saved.filter { FileManager.default.fileExists(atPath: localURL($0).path) }
        }
        syncInBackground()
    }

    // MARK: Context cache

    private var system: String { AnswerPrompt.system(base: basePrompt, custom: customPrompt) }
    private var lengthRule: String {
        let rule = (mode == .short ? shortRule : detailedRule).trimmingCharacters(in: .whitespacesAndNewlines)
        return rule.isEmpty ? (mode == .short ? AnswerPrompt.defaultShortRule : AnswerPrompt.defaultDetailedRule) : rule
    }
    private func cacheKey() -> String {
        ([model.rawValue, system] + documents.compactMap(\.remoteURI)).joined(separator: "\n")
    }

    /// Debounced so typing in the prompt editors does not rebuild on every keystroke.
    private func scheduleCacheRefresh(after seconds: Double = 2) {
        cacheRefresh?.cancel()
        cacheRefresh = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let key = CredentialStore.geminiKey(),
                  !documents.contains(where: { $0.needsUpload() }) else { return }
            _ = await readyCache(GeminiClient(apiKey: key))
        }
    }

    /// Returns a warm cache for the current model, prompt and files, building or
    /// extending it as needed. nil means send the files directly (none, or too small).
    private func readyCache(_ client: GeminiClient) async -> String? {
        let key = cacheKey()
        guard documents.contains(where: { $0.remoteURI != nil }), key != uncacheableKey else {
            cacheStatus = documents.isEmpty ? "" : "资料较少，无需预读缓存"
            return nil
        }
        if let current = cache, current.key == key, current.expiresAt.timeIntervalSinceNow > 120 {
            if current.expiresAt.timeIntervalSinceNow < Double(Self.cacheTTL) / 2 {
                Task { if let date = try? await client.extendCache(name: current.name, ttl: Self.cacheTTL), cache?.name == current.name { cache?.expiresAt = date } }
            }
            return current.name
        }
        if let build = cacheBuild, build.key == key { return try? await build.task.value?.name }
        let model = model, system = system, files = documents
        let task = Task { () throws -> PromptCache? in
            do {
                let created = try await client.createCache(model: model, system: system, documents: files, ttl: Self.cacheTTL)
                return PromptCache(key: key, name: created.name, expiresAt: created.expiresAt)
            } catch let error as GeminiError where error.isCacheTooSmall { return nil }
        }
        cacheBuild = (key, task)
        cacheStatus = "正在预读资料…"
        defer { if cacheBuild?.key == key { cacheBuild = nil } }
        do {
            guard let built = try await task.value else {
                uncacheableKey = key; cacheStatus = "资料较少，无需预读缓存"; return nil
            }
            if let old = cache, old.name != built.name { Task { await client.deleteCache(name: old.name) } }
            cache = built
            cacheStatus = "资料已预读 · 缓存会在使用时自动续期"
            return built.name
        } catch {
            cacheStatus = "预读失败，回答时直接发送文件：\(Self.describe(error))"
            return nil
        }
    }

    func localURL(_ document: KnowledgeDocument) -> URL {
        directory.appendingPathComponent("\(document.id.uuidString).\(document.fileExtension ?? "pdf")")
    }

    func status(of document: KnowledgeDocument) -> String {
        if uploading.contains(document.id) { return "正在上传到 Gemini…" }
        if !document.needsUpload(), let expiresAt = document.expiresAt {
            return "已上传 · 引用有效至 " + expiresAt.formatted(.dateTime.month().day().hour().minute())
        }
        return hasKey ? "待上传（生成回答前会自动上传）" : "保存 Gemini Key 后自动上传"
    }

    // MARK: Library

    func add(_ urls: [URL]) {
        var rejected: [String] = []
        for url in urls {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            guard let mime = KnowledgeFormat.mimeType(for: url), size <= KnowledgeFormat.maxBytes else {
                rejected.append(url.lastPathComponent); continue
            }
            let document = KnowledgeDocument(id: UUID(), name: url.lastPathComponent, mimeType: mime,
                                             fileExtension: url.pathExtension.lowercased())
            do {
                try FileManager.default.copyItem(at: url, to: localURL(document))
                documents.append(document)
            } catch { libraryMessage = "无法添加 \(url.lastPathComponent)：\(error.localizedDescription)" }
        }
        if !rejected.isEmpty { libraryMessage = "Gemini 不支持或超过 2 GB，未添加：" + rejected.joined(separator: "、") }
        persist()
        syncInBackground()
    }

    func remove(_ document: KnowledgeDocument) {
        inflight[document.id]?.cancel()
        documents.removeAll { $0.id == document.id }
        try? FileManager.default.removeItem(at: localURL(document))
        persist()
        scheduleCacheRefresh(after: 0)
        if let remoteName = document.remoteName, let key = CredentialStore.geminiKey() {
            Task { await GeminiClient(apiKey: key).delete(remoteName: remoteName) }
        }
    }

    /// Upload ahead of time so pressing "AI 回答" normally sends only references.
    /// Also pre-reads them into a context cache so the click only sends the transcript.
    func syncInBackground() {
        guard let key = CredentialStore.geminiKey() else { return }
        let client = GeminiClient(apiKey: key)
        Task {
            do {
                if documents.contains(where: { $0.needsUpload() }) { try await syncAll(client); libraryMessage = "" }
                _ = await readyCache(client)
            } catch { libraryMessage = "资料上传失败：\(error.localizedDescription)" }
        }
    }

    private func syncAll(_ client: GeminiClient) async throws {
        let ids = documents.filter { $0.needsUpload() }.map(\.id)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { try await self.ensureUploaded(id, client: client) } }
            try await group.waitForAll()
        }
    }

    /// Joins an upload already in flight instead of sending the same file twice.
    private func ensureUploaded(_ id: UUID, client: GeminiClient) async throws {
        if let running = inflight[id] { _ = try await running.value; return }
        guard let document = documents.first(where: { $0.id == id }), document.needsUpload() else { return }
        let file = localURL(document)
        let upload = Task { try await client.upload(file, displayName: document.name, mimeType: document.mime) }
        inflight[id] = upload; uploading.insert(id)
        defer { inflight[id] = nil; uploading.remove(id) }
        let remote = try await upload.value
        guard let position = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[position].remoteName = remote.name
        documents[position].remoteURI = remote.uri
        documents[position].expiresAt = remote.expiresAt
        persist()
    }

    private func forgetRemoteReferences() {
        for position in documents.indices {
            documents[position].remoteName = nil; documents[position].remoteURI = nil; documents[position].expiresAt = nil
        }
        persist()
    }

    private func persist() {
        do { try JSONEncoder().encode(documents).write(to: index, options: .atomic) }
        catch { libraryMessage = "无法保存资料列表：\(error.localizedDescription)" }
    }

    // MARK: Key

    func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            // File references belong to the key's project; a new key needs fresh uploads.
            if key != CredentialStore.geminiKey() { forgetRemoteReferences() }
            try CredentialStore.saveGeminiKey(key)
            hasKey = true; keyDraft = ""; keyMessage = "已保存到本机"
            syncInBackground()
        } catch { keyMessage = "无法保存：\(error.localizedDescription)" }
    }

    func deleteKey() {
        do { try CredentialStore.deleteGeminiKey(); hasKey = false; keyMessage = "已从本机删除" }
        catch { keyMessage = "无法删除：\(error.localizedDescription)" }
    }

    // MARK: Answer

    /// Always reads the newest transcript, so "regenerate" also picks up a
    /// question that finished after the previous click.
    func generate() { run(nil) }

    /// Re-runs the current kind of answer: the same typed question, or the transcript.
    func regenerate() { run(question) }

    func attach(_ images: [ImageAttachment]) {
        let room = Self.maxAttachments - attachments.count
        attachments += images.prefix(max(0, room))
        composerMessage = images.count > room ? "最多附加 \(Self.maxAttachments) 张图片" : ""
    }

    func removeAttachment(_ id: UUID) { attachments.removeAll { $0.id == id }; composerMessage = "" }

    func ask() {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty || !attachments.isEmpty else { return }
        let manual = ManualQuestion(text: typed, images: attachments)
        draft = ""; attachments = []; composerMessage = ""
        run(manual)
    }

    private func run(_ manual: ManualQuestion?) {
        answerTask?.cancel()
        let id = UUID(); runID = id
        visible = true; text = ""; errorMessage = ""
        translation = ""; raw = ""; question = manual
        guard let key = CredentialStore.geminiKey() else { errorMessage = "请先在设置中保存 Gemini API Key"; generating = false; return }
        let transcript = transcriptProvider?() ?? ""
        guard !transcript.isEmpty || manual != nil else { errorMessage = "还没有转录内容。开始字幕并等对方提问后再点击，或在下方直接输入问题。"; generating = false; return }
        generating = true
        let client = GeminiClient(apiKey: key)
        answerTask = Task {
            do {
                if documents.contains(where: { $0.needsUpload() }) { phase = "正在同步资料…"; try await syncAll(client) }
                phase = cache?.key == cacheKey() ? "正在生成…" : "正在预读资料…"
                do { try await stream(client, cache: await readyCache(client), transcript: transcript, question: manual, run: id) }
                catch let error as GeminiError where (error.isMissingFile || error.isMissingCache) && text.isEmpty {
                    phase = "资料已失效，正在重新准备…"
                    if error.isMissingFile { forgetRemoteReferences(); try await syncAll(client) }
                    cache = nil
                    try await stream(client, cache: await readyCache(client), transcript: transcript, question: manual, run: id)
                }
            } catch {
                if runID == id && !Task.isCancelled { errorMessage = Self.describe(error) }
            }
            if runID == id { generating = false; phase = "" }
        }
    }

    private func stream(_ client: GeminiClient, cache: String?, transcript: String, question: ManualQuestion?,
                        run id: UUID) async throws {
        phase = question?.images.isEmpty == false ? "正在读取图片并生成…" : "正在生成…"
        try await client.streamAnswer(model: model, system: system, documents: documents, cache: cache,
                                      transcript: transcript, question: question, lengthRule: lengthRule) { [weak self] chunk in
            guard let self, self.runID == id else { return }
            self.raw += chunk
            (self.text, self.translation) = AnswerPrompt.splitTranslation(self.raw)
        }
    }

    func selectMode(_ next: AnswerMode) {
        guard next != mode else { return }
        mode = next
        if visible && (generating || !text.isEmpty) { regenerate() }
    }

    /// Briefly flips the copy button to a checkmark; the view does the pasteboard write.
    func markCopied() {
        copied = true
        Task { try? await Task.sleep(nanoseconds: 1_200_000_000); copied = false }
    }

    func dismiss() {
        answerTask?.cancel(); runID = UUID()
        visible = false; generating = false; phase = ""; text = ""; errorMessage = ""
        translation = ""; raw = ""; question = nil
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? URLError {
            switch error.code {
            case .timedOut: return "Gemini 请求超时，请重试"
            case .notConnectedToInternet, .networkConnectionLost: return "网络不可用，请检查连接后重试"
            default: return error.localizedDescription
            }
        }
        if let error = error as? GeminiError, error.status == 400 || error.status == 401,
           error.message.localizedCaseInsensitiveContains("API key") { return "Gemini API Key 无效，请在设置中重新保存" }
        if let error = error as? GeminiError, error.status == 429 { return "Gemini 配额或频率受限，请稍后重试" }
        return error.localizedDescription
    }
}
