import Foundation
var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fatalError(message) }
}
func segments(_ changes: [SegmentChange]) -> [CaptionSegment] {
    changes.compactMap { if case .upsert(let s) = $0 { return s }; return nil }
}
func texts(_ changes: [SegmentChange]) -> [String] { segments(changes).map(\.english) }
func feed(_ s: inout Segmenter, _ text: String, _ time: Double, final: Bool = false, u: Int = 0) -> [SegmentChange] {
    s.ingest(text, final: final, audio: time, utterance:u, now:time)
}
var s = Segmenter()
expect(texts(feed(&s,"The value is fifteen. Next",0)).isEmpty,"first partial must wait")
expect(s.tick(now:10).isEmpty,"timer must never confirm cached partial")
expect(feed(&s,"The value is fifteen. Next",0).isEmpty,"duplicate audio is not evidence")
let original = segments(feed(&s,"The value is fifteen. Next",0.6))
expect(original.map(\.english) == ["The value is fifteen."],"real repeated ASR update confirms prefix")
let correction = segments(feed(&s,"The value is fifty. Next example.",1,final:true))
expect(correction.count == 1 && correction[0].id == original[0].id && correction[0].revision == 1,"final correction retains ID")
expect(correction[0].english == "The value is fifty. Next example.","correction replaces suffix without duplicates")
expect(feed(&s,"The value is fifty. Next example.",1,final:true).isEmpty,"duplicate final ignored")

s = Segmenter()
expect(texts(feed(&s,"Well, I feel like if you're going to invest",0,final:true)).isEmpty,"unpunctuated endpoint held")
expect(texts(feed(&s,"So much in building AI",0.5,final:true,u:1)).isEmpty,"merge across endpoint")
let merged = texts(feed(&s,"then people should understand your values.",1,final:true,u:2))
expect(merged == ["Well, I feel like if you're going to invest So much in building AI then people should understand your values."],"carry must be lossless")
for input in ["Yes.","No!","Why?","The result is correct. We can proceed.","The signal drops. We should stop.","The value is 3. Next example.","The value is 3.14. Next example."] {
    var t = Segmenter()
    // Short "." sentences are held for the next utterance and saved on stop.
    let result = texts(feed(&t,input,0,final:true)) + texts(t.tick(now:1,force:true))
    expect(result.joined(separator:" ") == input,"no loss for \(input)")
    expect(result.count == (input.contains("Next") || input.contains("We ") ? 2 : 1),"natural boundaries: \(input) -> \(result)")
}
s = Segmenter()
_ = feed(&s,"Well",0,final:true)
expect(texts(feed(&s,"well, this works.",1,final:true,u:1)) == ["Well well, this works."],"do not delete real repeated words")
s = Segmenter()
_ = feed(&s,"A longer phrase that never gets any punctuation at all",0,final:true)
expect(s.tick(now:3).isEmpty,"endpoint waits for continuation")
expect(texts(s.tick(now:4.1)) == ["A longer phrase that never gets any punctuation at all"],"endpoint bounded flush")
expect(s.tick(now:5).isEmpty,"flush once")
s = Segmenter()
_ = feed(&s,"An unfinished hypothesis",0)
expect(texts(s.tick(now:1,force:true)) == ["An unfinished hypothesis"],"stop saves last partial")
expect(s.tick(now:2,force:true).isEmpty,"stop idempotent")
s = Segmenter()
_ = feed(&s,"First full sentence. Second full sentence. Third",0)
let first = segments(feed(&s,"First full sentence. Second full sentence. Third",0.6))
let second = segments(feed(&s,"First full sentence. Second full sentence. Third",1.2))
expect(first.count == 1 && second.count == 1,"multiple stable sentences")
let changes = feed(&s,"Replacement.",1.4,final:true)
expect(segments(changes).first?.id == first.first?.id,"cross-boundary correction keeps earliest ID")
expect(changes.contains { if case .remove(let id) = $0 { return id == second.first?.id }; return false },"obsolete suffix removed")

s = Segmenter()
_ = feed(&s,"The derivative tells us how quickly",0)
expect(feed(&s,"The derivative tells us how quickly a function",2.1).isEmpty,"never cut unpunctuated speech on a timer budget")
expect(texts(feed(&s,"The derivative tells us how quickly a function changes.",3,final:true)) == ["The derivative tells us how quickly a function changes."],"complete context reaches translator")
s = Segmenter()
_ = feed(&s,"When we train the model with a judge as reward, the",0)
expect(feed(&s,"When we train the model with a judge as reward, the model",2.1).isEmpty,"short budget never splits at a comma")
expect(texts(feed(&s,"When we train the model with a judge as reward, the model learns",4.1)) == ["When we train the model with a judge as reward,"],"stable clause boundary is a latency fallback")
s = Segmenter()
_ = feed(&s,"The judge's reward keeps rising, but the",0)
expect(feed(&s,"The judge's reward keeps rising, but the real",4.1).isEmpty,"a short clause is not a translation unit")
s = Segmenter()
_ = feed(&s,"We can proceed with the plan, and this is fine for now, so the",0)
expect(texts(feed(&s,"We can proceed with the plan, and this is fine for now, so the rest",4.1)) == ["We can proceed with the plan, and this is fine for now,"],"latest stable clause gives the most context")
s = Segmenter()
expect(texts(feed(&s,"Um. And that gap is reward hacking. So",0,final:true)) == ["Um. And that gap is reward hacking."],"filler sentence joins the next one")
s = Segmenter()
expect(texts(feed(&s,"Okay. Next slide. From the previous paper.",0,final:true)) == ["Okay. Next slide.","From the previous paper."],"short fillers merge until the unit is long enough")
s = Segmenter()
expect(texts(feed(&s,"Is that okay? Right? Now our question.",0,final:true)) == ["Is that okay?","Right?","Now our question."],"questions always stand alone")
s = Segmenter()
_ = feed(&s,"So. Having flaws is different. Next",0)
expect(texts(feed(&s,"So. Having flaws is different. Next",0.6)) == ["So. Having flaws is different."],"live partials merge a filler forward too")
s = Segmenter()
expect(texts(feed(&s,"What are the issues you're having? So",0,final:true)) == ["What are the issues you're having?"],"sentence released at endpoint")
expect(s.tick(now:5).isEmpty,"dangling function word is not translated alone")
expect(texts(feed(&s,"please start early.",6,final:true,u:1)) == ["So please start early."],"dangling word joins its continuation")
s = Segmenter()
_ = feed(&s,"Right? And",0,final:true)
expect(texts(s.tick(now:1,force:true)) == ["And"],"stop still saves a short carry")
for input in ["Dr. Smith is here.", "The value is 3.14.", "She said \"Yes.\" Next example."] {
    var t = Segmenter()
    expect((texts(feed(&t,input,0,final:true)) + texts(t.tick(now:1,force:true))).joined(separator:" ") == input,"abbreviations/quotes preserved")
}
// Deterministic edit cases after two committed sentences: replay the public
// changes exactly as the UI would, then compare against the authoritative final.
for final in ["", "First sentence.", "First sentence. Revised tail.",
              "Inserted first sentence. Second sentence. Third.",
              "First changed sentence. Third.",
              "First sentence. Second sentence. Third sentence."] {
    var t = Segmenter()
    var visible: [CaptionSegment] = []
    func apply(_ updates: [SegmentChange]) {
        for update in updates {
            switch update {
            case .upsert(let segment):
                if let index = visible.firstIndex(where: { $0.id == segment.id }) { visible[index] = segment }
                else { visible.append(segment) }
            case .remove(let id): visible.removeAll { $0.id == id }
            }
        }
    }
    apply(feed(&t,"First sentence. Second sentence. Third",0))
    apply(feed(&t,"First sentence. Second sentence. Third",0.6))
    apply(feed(&t,"First sentence. Second sentence. Third",1.2))
    apply(feed(&t,final,1.8,final:true))
    apply(t.tick(now:4,force:true))
    expect(visible.map(\.english).joined(separator:" ") == final,"authoritative edit must be lossless: \(final)")
}
s = Segmenter()
_ = feed(&s,"First unfinished phrase",0,final:true)
_ = feed(&s,"and its continuation",1,u:1)
expect(s.tick(now:3).isEmpty,"timer cannot flush carry separately from active continuation")
expect(texts(s.tick(now:3,force:true)) == ["First unfinished phrase and its continuation"],"stop retains cross-utterance carry")
expect(feed(&s,"late event",4,u:0).isEmpty,"old utterance cannot reappear")

let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at:root) }
let journal = try TranscriptJournal(root:root)
let before = CaptionSegment(english:"Wrong.")
try journal.upsert(before); try journal.translated(before,chinese:"错误。",latency:0.1)
let after = CaptionSegment(id:before.id,english:"Right.",revision:1)
try journal.upsert(after)
try journal.translated(before,chinese:"迟到的旧译文",latency:0.2)
try journal.translated(after,chinese:"正确。",latency:0.2)
let saved = try String(contentsOf:journal.directory.appendingPathComponent("transcript.txt"),encoding:.utf8)
expect(saved.contains("Right.") && !saved.contains("Wrong.") && !saved.contains("迟到"),"journal rejects stale revisions")
// Suffix rewrite must equal a full rebuild in order, including removals and
// an earlier segment translated after a later one.
let ordered = try TranscriptJournal(root:root)
let a = CaptionSegment(english:"A."), b = CaptionSegment(english:"B."), c = CaptionSegment(english:"C.")
for x in [a,b,c] { try ordered.upsert(x) }
try ordered.translated(a,chinese:"甲",latency:0); try ordered.translated(c,chinese:"丙",latency:0)
try ordered.translated(b,chinese:"乙",latency:0)
let b1 = CaptionSegment(id:b.id,english:"B revised.",revision:1)
try ordered.upsert(b1); try ordered.translated(b1,chinese:"乙改",latency:0)
try ordered.remove(c.id)
let d = CaptionSegment(english:"D."); try ordered.upsert(d); try ordered.translated(d,chinese:"丁",latency:0)
try ordered.finish()
let orderedText = try String(contentsOf:ordered.directory.appendingPathComponent("transcript.txt"),encoding:.utf8)
let lines = orderedText.split(separator:"\n").filter { $0.hasPrefix("中文") }
expect(lines == ["中文: 甲","中文: 乙改","中文: 丁"],"journal suffix rewrite keeps order: \(lines)")
expect(!orderedText.contains("English: B.\n") && !orderedText.contains("C."),"journal drops revised and removed pairs")
var history = CaptionHistory()
history.upsert(before,limit:3); history.translate(id:before.id,chinese:"旧译文")
history.upsert(after,limit:3)
expect(history.entries.count == 1 && history.entries[0].chinese == nil && history.entries[0].english == "Right.","history revision invalidates Chinese")
// v3 cloud events use the same segmenter contract as the local bridge.
let cloudPartial = try JSONDecoder().decode(AssemblyAIMessage.self,from:Data(#"{"type":"Turn","turn_order":3,"end_of_turn":false,"transcript":"A new turn","words":[{"end":1200}]}"#.utf8))
expect(cloudPartial.turn?.type == "partial" && cloudPartial.turn?.utterance == 3 && cloudPartial.turn?.audio == 1.2,"cloud partial and word time mapping")
let cloudFinal = try JSONDecoder().decode(AssemblyAIMessage.self,from:Data(#"{"type":"Turn","turn_order":3,"end_of_turn":true,"turn_is_formatted":true,"transcript":"A new turn.","words":[{"end":1500}]}"#.utf8))
expect(cloudFinal.turn?.type == "final","cloud end_of_turn authoritative")
var cloudSegments = Segmenter()
let cp = cloudPartial.turn!, cf = cloudFinal.turn!
_ = cloudSegments.ingest(cp.text!,final:false,audio:cp.audio!,utterance:cp.utterance!,now:0)
expect(texts(cloudSegments.ingest(cf.text!,final:true,audio:cf.audio!,utterance:cf.utterance!,now:1)) == ["A new turn."],"cloud events use existing segmenter")
let heartbeat = try JSONDecoder().decode(AssemblyAIMessage.self,from:Data(#"{"type":"Heartbeat","total_audio_received_ms":3000}"#.utf8))
expect(heartbeat.turn == nil,"heartbeat never confirms partial")
let begin = try JSONDecoder().decode(AssemblyAIMessage.self,from:Data(#"{"type":"Begin","configuration":{"model":"universal-3-5-pro"}}"#.utf8))
expect(begin.configuration?.model == "universal-3-5-pro","model echo decoded")
var packer = PCM16Packetizer()
let floats: [Float] = Array(repeating:0,count:320)
let bytes = floats.withUnsafeBytes { Data($0) }
expect(packer.append(bytes).isEmpty,"20ms buffered, no undersized wire frames")
expect(packer.append(bytes).isEmpty,"40ms buffered")
let packet = packer.append(bytes)
expect(packet.count == 1 && packet[0].count == 1600,"60ms produces one 50ms packet")
expect(packer.finish()?.count == 1600 && packer.finish() == nil,"10ms tail flushed exactly once with zero padding")
let extreme: [Float] = [-2,-1,0,1,2,.nan,.infinity]
var clipping = PCM16Packetizer()
_ = clipping.append(extreme.withUnsafeBytes { Data($0) })
let clipped = clipping.finish()!
let samples = clipped.withUnsafeBytes { raw in (0..<7).map { Int16(littleEndian:raw.loadUnaligned(fromByteOffset:$0*2,as:Int16.self)) } }
expect(samples == [-32768,-32768,0,32767,32767,0,0],"PCM clipping and nonfinite protection")
let request = AssemblyAIProvider.request(key:"test-key-not-real")
expect(request.value(forHTTPHeaderField:"Authorization") == "test-key-not-real","raw header auth, no Bearer")
expect(request.url!.path == "/v3/ws" && !request.url!.absoluteString.contains("test-key"),"v3 endpoint, key never in URL")
expect(request.url!.absoluteString.contains("universal-3-5-pro"),"exact current model ID")
let cloudError = try JSONDecoder().decode(AssemblyAIMessage.self,from:Data(#"{"type":"Error","error_code":3008,"error":"Session expired"}"#.utf8))
expect(cloudError.error_code == 3008,"official error_code field")
expect(ModelStore.catalog.count == 2 && ModelStore.totalDownloadBytes == 1_832_953_408,"model catalog pins exactly two expected downloads")
expect(Set(ModelStore.catalog.map(\.sha256)) == Set(["d9a01898d2a611c8764e23a1c2f45e70bbd5a425dc4de93692ac951dd603812d","dc5f44fcf1fa496ee7ad725982c0c8c553a4de00259b53af84c4b89fb0c06699"]),"downloaded models use pinned verified checksums")
var revisedPartial = Segmenter()
_ = revisedPartial.ingest("An old hypothesis",final:false,audio:1,utterance:0,now:0)
expect(revisedPartial.ingest("A revised hypothesis",final:false,audio:1,utterance:0,now:1).isEmpty,"same word timestamp cannot establish stability")
expect(revisedPartial.preview == "A revised hypothesis","latest cloud partial displayed even if word time unchanged")
let glossaryMatcher = GlossaryMatcher("AI = 人工智能\nmachine learning = 机器学习\nin = 错误匹配")
expect(glossaryMatcher.instructions(for:"Machine learning uses AI.").split(separator:"\n").count == 2,"compiled glossary matches case-insensitively with word boundaries")
expect(glossaryMatcher.instructions(for:"A thin model.").isEmpty,"glossary does not match inside a larger word")
let customGlossary = "machine learning = 自定义机器学习\ncourse-specific term = 课程专用译法"
let mergedGlossary = DefaultGlossary.merging(into:customGlossary)
expect(mergedGlossary.contains("course-specific term = 课程专用译法"),"glossary migration preserves custom entries")
expect(mergedGlossary.contains("FlashAttention = 闪速注意力") && mergedGlossary.contains("bounded concurrency = 有界并发"),"course glossary terms are appended")
expect(mergedGlossary.split(separator:"\n").filter { $0.lowercased().hasPrefix("machine learning =") }.count == 1,"glossary migration does not duplicate existing terms")
let transcriptTail = AnswerPrompt.recentTranscript(lines:["old line","", "So tell me about","a project you built"],partial:"recently",maxCharacters:50)
expect(transcriptTail == "So tell me about\na project you built\nrecently","assistant context keeps newest lines oldest-first within budget")
expect(AnswerPrompt.recentTranscript(lines:[],partial:"").isEmpty,"assistant context empty without transcript")
let sseChunk = Data(#"{"candidates":[{"content":{"parts":[{"text":"hidden","thought":true},{"text":"I built "},{"text":"XueScribe."}]}}]}"#.utf8)
expect((try? GeminiClient.text(fromChunk:sseChunk)) == "I built XueScribe.","SSE chunk keeps answer text and skips thoughts")
expect((try? GeminiClient.text(fromChunk:Data(#"{"error":{"code":403,"message":"File x may not exist"}}"#.utf8))) == nil,"SSE error chunk throws")
expect(GeminiError(status:403,message:"You do not have permission to access the File abc or it may not exist.").isMissingFile,"expired file reference detected")
expect(!GeminiError(status:403,message:"Permission denied: API key").isMissingFile,"key errors are not file errors")
let expiry = GeminiClient.parseTime("2026-10-21T18:38:18.709406029Z")
expect(expiry == ISO8601DateFormatter().date(from:"2026-10-21T18:38:18Z"),"nanosecond Google timestamps parse")
var knowledge = KnowledgeDocument(id:UUID(),name:"cv.pdf")
expect(knowledge.needsUpload(),"new PDF needs upload")
knowledge.remoteURI = "https://example.invalid/files/a"; knowledge.expiresAt = Date().addingTimeInterval(47*3600)
expect(!knowledge.needsUpload(),"fresh file reference is reused")
knowledge.expiresAt = Date().addingTimeInterval(10*60)
expect(knowledge.needsUpload(),"nearly expired reference is refreshed")
expect(AnswerPrompt.system(base:"BASE",custom:"  ") == "BASE","blank custom prompt adds nothing")
expect(AnswerPrompt.system(base:"",custom:"Be brief").hasPrefix(AnswerPrompt.defaultSystem) && AnswerPrompt.system(base:"",custom:"Be brief").hasSuffix("Be brief"),"empty base falls back to default; custom appended last")
let bilingual = AnswerPrompt.splitTranslation("I built XueScribe in Swift.\n【中文翻译】\n我用 Swift 开发了雪笺。")
expect(bilingual.answer == "I built XueScribe in Swift." && bilingual.translation == "我用 Swift 开发了雪笺。","Gemini reply splits into answer and translation")
expect(AnswerPrompt.splitTranslation("I built XueScribe.\n【中文").answer == "I built XueScribe.","partly streamed marker stays hidden")
expect(AnswerPrompt.splitTranslation("我用 Swift 开发了雪笺。") == ("我用 Swift 开发了雪笺。",""),"Chinese answers have no translation")
expect(KnowledgeFormat.mimeType(for:URL(fileURLWithPath:"/x/Resume.DOCX")) == "application/vnd.openxmlformats-officedocument.wordprocessingml.document","office files map case-insensitively")
expect(KnowledgeFormat.mimeType(for:URL(fileURLWithPath:"/x/talk.mov")) == "video/quicktime" && KnowledgeFormat.mimeType(for:URL(fileURLWithPath:"/x/a.m4a")) == "audio/mp4","audio and video types")
expect(KnowledgeFormat.mimeType(for:URL(fileURLWithPath:"/x/Main.swift")) == "text/plain","unlisted source files go up as plain text")
expect(KnowledgeFormat.mimeType(for:URL(fileURLWithPath:"/x/old.doc")) == nil && KnowledgeFormat.mimeType(for:URL(fileURLWithPath:"/x/app.dmg")) == nil,"unsupported formats rejected")
let legacyLibrary = try JSONDecoder().decode([KnowledgeDocument].self,from:Data(#"[{"id":"7C1F2B9E-5D3A-4E8B-9A6C-2F1D0E3B4A5C","name":"cv.pdf"}]"#.utf8))
expect(legacyLibrary[0].mime == "application/pdf" && legacyLibrary[0].fileExtension == nil,"PDF-only libraries still load")
expect(GeminiError(status:403,message:"CachedContent not found (or permission denied)").isMissingCache,"expired context cache detected")
expect(GeminiError(status:400,message:"Cached content is too small. total_token_count=36, min_total_token_count=1024").isCacheTooSmall,"small libraries skip caching")
expect(AnswerPrompt.defaultShortRule.contains("1–2 句") && AnswerPrompt.defaultSystem.contains(AnswerPrompt.translationMarker),"short mode is one or two sentences; prompt asks for the translation marker")
print("PASS: \(checks) regression checks")
