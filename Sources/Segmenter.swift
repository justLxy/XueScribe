import Foundation
import NaturalLanguage

struct CaptionSegment: Identifiable, Equatable {
    let id: UUID
    let english: String
    let created: Date
    let revision: Int
    let bufferedSeconds: Double
    init(id: UUID = UUID(), english: String, created: Date = Date(), revision: Int = 0, bufferedSeconds: Double = 0) {
        self.id = id; self.english = english; self.created = created; self.revision = revision; self.bufferedSeconds = bufferedSeconds
    }
}

enum SegmentChange {
    case upsert(CaptionSegment)
    case remove(UUID)
}

/// Acoustic utterances and translation segments deliberately have separate lifetimes.
/// Only real decoder events establish stability. The timer may flush an endpoint,
/// but can never confirm a partial. All clocks used for decisions are monotonic.
struct Segmenter {
    struct Configuration {
        var confirmation: Double = 0.45
        /// Budget before an unpunctuated run may be cut at a comma. Live English is
        /// already on screen, so this only delays translation; short budgets split
        /// sentences into "rising, / but the real accuracy," fragments.
        var maxWait: Double = 4.0
        /// Minimum translatable unit for boundaries without terminal punctuation
        /// (clause fallback, endpoint carry). A lone "So" or "you know," gives the
        /// translator no context; it waits and joins the following words instead.
        /// Complete sentences ("Right?") are never held back by this.
        var minimumClauseWords = 8
        /// Sentences shorter than this that end in "." ("Um.", "So.", "Okay.") are
        /// usually ASR-punctuated fillers; they join the following sentence.
        /// "?" and "!" sentences ("Right?") always stand alone.
        var minimumSentenceWords = 3
    }
    var configuration = Configuration()
    private var carry = ""
    private var carrySince: Double?
    private var lead = ""
    private var leadSince: Double?
    private var active = ""
    private var committed: [CaptionSegment] = []
    /// Words of `committed`, cached so partials never re-tokenize committed text.
    private var committedWords: [String] = []
    private let sentences = SentenceSplitter()
    private var previousWords: [String] = []
    private var wordSince: [Double] = []
    private var pendingSince: Double?
    private var lastAudio: Double = -.infinity
    private var currentUtterance: Int?

    var preview: String {
        // previousWords is always words(join(lead, active)).
        // Never show the whole corrected hypothesis a second time below committed text.
        if !committedWords.isEmpty && !previousWords.starts(with: committedWords) { return "" }
        return join(carry, previousWords.dropFirst(committedWords.count).joined(separator: " "))
    }

    mutating func ingest(_ text: String, final: Bool, audio: Double, utterance: Int,
                         now: Double = ProcessInfo.processInfo.systemUptime) -> [SegmentChange] {
        if let currentUtterance, utterance < currentUtterance { return [] }
        var changes: [SegmentChange] = []
        if currentUtterance != utterance {
            // A missing final must not silently discard the previous hypothesis.
            if !active.isEmpty { changes += finish(now: now) }
            currentUtterance = utterance
            lastAudio = -.infinity
        }
        let advanced = audio > lastAudio
        if !final && !advanced && canonical(text) == active { return changes }
        if active.isEmpty && committed.isEmpty && !text.isEmpty {
            lead = carry; leadSince = carrySince; carry = ""
            pendingSince = carrySince ?? now; carrySince = nil
        }
        active = canonical(text)
        let full = words(join(lead, active))
        var common = 0
        while common < min(full.count, previousWords.count), full[common] == previousWords[common] { common += 1 }
        wordSince.removeSubrange(common...)
        wordSince.append(contentsOf: repeatElement(now, count: full.count - common))
        previousWords = full
        lastAudio = max(lastAudio, audio)
        if final {
            changes += finish(now: now)
            // Bridge advances utterance after every final; reject late/duplicate events.
            currentUtterance = utterance + 1
            lastAudio = -.infinity
            return changes
        }
        // A revised cloud partial can retain the same word-end timestamp. Display
        // it immediately, but do not treat it as new progress for early submission.
        guard advanced else { return changes }
        guard full.starts(with: committedWords) else { return changes } // Reconcile authoritatively at final.
        let remaining = full[committedWords.count...]
        guard !remaining.isEmpty else { return changes }
        let stableCount = wordSince[committedWords.count...].prefix { now - $0 >= configuration.confirmation }.count
        // Require a subsequent word: the end of a live hypothesis is especially revisable.
        let available = min(stableCount, remaining.count - 1)
        var count: Int?
        // Only a stable word ending in terminal punctuation can close a sentence, so
        // the tokenizer runs only when one exists, over the stable window plus one
        // word of lookahead (for abbreviations such as "Dr. Smith").
        if remaining.prefix(available).contains(where: Self.endsSentence) {
            let window = remaining.prefix(available + 1).joined(separator: " ")
            let words = Array(remaining)
            count = sentences.lengths(window).first { $0 <= available && standsAlone(words, from: 0, to: $0) }
        }
        if count == nil, now - (pendingSince ?? now) >= configuration.maxWait {
            // Prefer the latest stable clause boundary after the budget: it gives the
            // translator the most context while still releasing latency. Never an
            // arbitrary word count/time slice; long unpunctuated speech waits for endpoint.
            let minimum = configuration.minimumClauseWords
            count = remaining.prefix(available).indices.last { index in
                index - remaining.startIndex + 1 >= minimum && Self.endsClause(remaining[index])
            }.map { $0 - remaining.startIndex + 1 }
        }
        if let count {
            let segment = CaptionSegment(english: remaining.prefix(count).joined(separator: " "), bufferedSeconds: max(0, now - (pendingSince ?? now)))
            committed.append(segment); committedWords += remaining.prefix(count)
            changes.append(.upsert(segment)); pendingSince = now
        }
        return changes
    }

    mutating func tick(now: Double = ProcessInfo.processInfo.systemUptime, force: Bool = false) -> [SegmentChange] {
        if force {
            var result = finish(now: now)
            result += flushCarry(now:now)
            return result
        }
        // Carry moves into the active hypothesis on the next utterance. Never flush
        // it independently while the decoder is refining that joined hypothesis.
        // A short carry is kept for the next utterance (it stays visible in preview)
        // and is only flushed alone when capture stops.
        guard let since = carrySince, now - since >= configuration.maxWait,
              words(carry).count >= configuration.minimumClauseWords else { return [] }
        return flushCarry(now:now)
    }

    private mutating func finish(now: Double) -> [SegmentChange] {
        let full = words(join(lead, active))
        var offset = 0
        var changes: [SegmentChange] = []
        for (index, segment) in committed.enumerated() {
            let tokens = words(segment.english)
            if Array(full.dropFirst(offset)).starts(with: tokens) {
                offset += tokens.count
            } else {
                // Keep unaffected segments and replace the entire affected suffix.
                // This handles insertions/deletions across old boundaries without
                // guessed word offsets, duplicated text, or stale translations.
                let corrected = full.dropFirst(offset).joined(separator: " ")
                if corrected.isEmpty { changes.append(.remove(segment.id)) }
                else { changes.append(.upsert(CaptionSegment(id: segment.id, english: corrected,
                                      created: segment.created, revision: segment.revision + 1, bufferedSeconds: segment.bufferedSeconds))) }
                for obsolete in committed.dropFirst(index + 1) { changes.append(.remove(obsolete.id)) }
                resetActive()
                return changes
            }
        }
        let tailWords = Array(full.dropFirst(offset))
        let tail = tailWords.joined(separator: " ")
        var consumed = 0
        for boundary in sentences.lengths(tail) where standsAlone(tailWords, from: consumed, to: boundary) {
            let sentence = tailWords[consumed..<boundary].joined(separator: " ")
            if !sentence.isEmpty { changes.append(.upsert(CaptionSegment(english: sentence, bufferedSeconds: max(0, now - (pendingSince ?? now))))) }
            consumed = boundary
        }
        let remainder = tailWords.dropFirst(consumed).joined(separator: " ")
        if !remainder.isEmpty {
            carry = remainder
            // Preserve the budget across repeated short, unpunctuated endpoints.
            carrySince = leadSince ?? now
        }
        resetActive()
        return changes
    }

    private mutating func resetActive() {
        active = ""; lead = ""; leadSince = nil; committed = []; committedWords = []
        previousWords = []; wordSince = []; pendingSince = nil
    }
    private mutating func flushCarry(now: Double) -> [SegmentChange] {
        guard !carry.isEmpty else { return [] }
        defer { carry = ""; carrySince = nil }
        return [.upsert(CaptionSegment(english: carry, bufferedSeconds: max(0, now - (carrySince ?? now))))]
    }
    /// A short "."-terminated sentence is held so it joins the next one.
    private func standsAlone(_ words: [String], from start: Int, to end: Int) -> Bool {
        guard end > start else { return false }
        if end - start >= configuration.minimumSentenceWords { return true }
        guard let last = words[end - 1].last(where: { !Self.closingMarks.contains($0) }) else { return false }
        return last == "?" || last == "!"
    }
    private static let closingMarks: Set<Character> = ["\"", "'", "”", "’", ")", "]", "}"]
    private static func endsSentence(_ token: String) -> Bool {
        guard let last = token.last(where: { !closingMarks.contains($0) }) else { return false }
        return ".!?".contains(last)
    }
    private static func endsClause(_ token: String) -> Bool {
        guard let last = token.last else { return false }
        return ",;:".contains(last)
    }
    private func words(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }
    private func canonical(_ text: String) -> String { words(text).joined(separator: " ") }
    private func join(_ left: String, _ right: String) -> String { canonical(left + " " + right) }

}

/// Apple's language tokenizer handles sentence boundaries and abbreviations;
/// no course vocabulary, conjunction lists, or substring abbreviation rules.
/// NLTokenizer construction is far more expensive than tokenizing a short
/// string, so one instance is reused. Not thread-safe: owned by one Segmenter
/// on one actor.
final class SentenceSplitter {
    private let tokenizer: NLTokenizer = {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.setLanguage(.english)
        return tokenizer
    }()
    private static let closing = CharacterSet(charactersIn: "\"'”’)]}")

    /// Cumulative word counts at which a sentence ending in . ! or ? closes.
    func lengths(_ text: String) -> [Int] {
        guard !text.isEmpty else { return [] }
        tokenizer.string = text
        var result: [Int] = []
        var wordCount = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            wordCount += text[range].split(whereSeparator: \.isWhitespace).count
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: Self.closing)
            if let last = sentence.last, ".!?".contains(last) {
                result.append(wordCount)
            }
            return true
        }
        return result
    }
}

final class TranscriptJournal {
    let directory: URL
    private let json: FileHandle
    private let text: FileHandle
    private let timestampFormatter = ISO8601DateFormatter()
    private var jsonDirty = false
    private var textDirty = false
    private var closed = false

    init(root: URL) throws {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        directory = root.appendingPathComponent(stamp + "-" + UUID().uuidString.prefix(6))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let j = directory.appendingPathComponent("transcript.jsonl"), t = directory.appendingPathComponent("transcript.txt")
        FileManager.default.createFile(atPath: j.path, contents: nil)
        FileManager.default.createFile(atPath: t.path, contents: nil)
        json = try FileHandle(forWritingTo: j); text = try FileHandle(forWritingTo: t)
    }

    func record(_ values: [String: Any]) throws {
        var row = values; row["wall_time"] = timestampFormatter.string(from:Date())
        var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]); data.append(10)
        try json.write(contentsOf:data); jsonDirty = true
    }

    // transcript.txt holds the translated pairs in `order`. Corrections only touch
    // the live tail, so each change truncates at the first affected pair and
    // rewrites that suffix instead of the whole session transcript.
    private var order: [UUID] = []
    private var segments: [UUID: CaptionSegment] = [:]
    private var translations: [UUID: String] = [:]
    private var offsets: [UUID: UInt64] = [:]
    private var textEnd: UInt64 = 0

    func upsert(_ segment: CaptionSegment) throws {
        if segments[segment.id] == nil { order.append(segment.id) }
        segments[segment.id] = segment
        // A correction invalidates the pair already written for the old revision.
        guard translations[segment.id] != nil, let position = order.lastIndex(of: segment.id) else { return }
        let cut = firstOffset(from: position)
        translations.removeValue(forKey: segment.id)
        try rewriteText(from: position, at: cut)
    }
    func remove(_ id: UUID) throws {
        segments.removeValue(forKey: id)
        guard let position = order.lastIndex(of: id) else { return }
        let cut = firstOffset(from: position)
        order.remove(at: position); offsets.removeValue(forKey: id)
        if translations.removeValue(forKey: id) != nil { try rewriteText(from: position, at: cut) }
    }
    private func pair(_ segment: CaptionSegment, _ chinese: String) -> String {
        "[\(timestampFormatter.string(from:segment.created))]\nEnglish: \(segment.english)\n中文: \(chinese)\n\n"
    }
    private func firstOffset(from position: Int) -> UInt64 {
        order[position...].lazy.compactMap { self.offsets[$0] }.first ?? textEnd
    }
    private func rewriteText(from position: Int, at cut: UInt64) throws {
        var contents = Data()
        for id in order[position...] {
            guard let segment = segments[id], let chinese = translations[id] else { offsets.removeValue(forKey: id); continue }
            offsets[id] = cut + UInt64(contents.count)
            contents.append(contentsOf: pair(segment, chinese).utf8)
        }
        if cut < textEnd { try text.truncate(atOffset: cut) }
        try text.seek(toOffset: cut)
        try text.write(contentsOf: contents)
        textEnd = cut + UInt64(contents.count); textDirty = true
    }
    func translated(_ segment: CaptionSegment, chinese: String, latency: Double) throws {
        guard segments[segment.id]?.revision == segment.revision,
              let position = order.lastIndex(of: segment.id) else { return }
        try record(["type":"translation", "id":segment.id.uuidString,"revision":segment.revision,
                    "english":segment.english,"chinese":chinese,"latency_seconds":latency,
                    "segmentation_wait_seconds":segment.bufferedSeconds,
                    "buffer_and_translation_seconds":segment.bufferedSeconds + latency])
        let cut = firstOffset(from: position)
        translations[segment.id] = chinese
        // Usually nothing after this segment is written yet, so this is an append.
        try rewriteText(from: position, at: cut)
    }

    /// FileHandle writes are immediately visible to readers. A durability sync is
    /// needed at the session boundary, not after every small real-time event.
    func finish() throws {
        guard !closed else { return }
        if jsonDirty { try json.synchronize(); jsonDirty = false }
        if textDirty { try text.synchronize(); textDirty = false }
        try json.close(); try text.close(); closed = true
    }

    deinit { try? finish() }
}
