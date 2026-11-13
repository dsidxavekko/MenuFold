import Foundation

/// Fuzzy matching and ranking for search.
///
/// A score is `tier * 100 + fine`, so a better kind of match always beats a worse one:
/// exact name (6) > name prefix (5) > word prefix (4) > initials (3) > substring (2) > fuzzy (1).
/// `fine` (0…90) orders matches inside a tier: a query typed directly gets +30 over the same query
/// typed in the wrong keyboard layout, and fuzzy matches lose points for gaps. Equal scores are
/// left to the caller (usage, then name).
///
/// Everything is computed per call (no global caches that could go stale); folding a few hundred
/// short names per keystroke is cheap.
public enum SearchMatcher {
    /// Match quality of `query` against `text`, higher is better; nil = no match.
    public static func score(_ text: String, query: String) -> Double? {
        let q = Query(query)
        return q.isEmpty ? nil : score(text, q)
    }

    // MARK: - Prepared query

    /// A query folded once and reused over every candidate.
    struct Query {
        /// Folded query as typed.
        let direct: String
        /// Folded query re-typed through the other keyboard layout (ЙЦУКЕН ↔ QWERTY), if different.
        let converted: String?

        init(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            direct = SearchMatcher.fold(trimmed)
            let swapped = KeyboardLayout.convert(trimmed)
            let folded = swapped.map(SearchMatcher.fold)
            converted = folded == direct ? nil : folded
        }

        var isEmpty: Bool { direct.isEmpty }
    }

    /// Best score of `text` for a prepared query (direct, or slightly lower through the layout swap).
    static func score(_ text: String, _ query: Query) -> Double? {
        guard !query.isEmpty else { return nil }
        let candidate = Candidate(text)
        let direct = rawScore(candidate, query.direct).map { $0 + directBonus }
        let swapped = query.converted.flatMap { rawScore(candidate, $0) }
        switch (direct, swapped) {
        case let (d?, s?): return max(d, s)
        case let (d?, nil): return d
        case let (nil, s?): return s
        default: return nil
        }
    }

    /// Best score over several texts (name, alternate name, keywords); nil when none matches.
    static func bestScore<S: Sequence>(_ texts: S, _ query: Query) -> Double? where S.Element == String {
        var best: Double?
        for text in texts {
            if let s = score(text, query), s > (best ?? -1) { best = s }
        }
        return best
    }

    // MARK: - Tiers

    static let directBonus = 30.0
    private static let base = 60.0

    enum Tier: Int { case fuzzy = 1, substring, initials, wordPrefix, prefix, exact }

    /// Score without the direct-typing bonus; `q` is already folded.
    private static func rawScore(_ c: Candidate, _ q: String) -> Double? {
        func tier(_ t: Tier, _ fine: Double = base) -> Double { Double(t.rawValue) * 100 + fine }
        if c.folded == q { return tier(.exact) }
        if c.folded.hasPrefix(q) { return tier(.prefix) }
        if c.words.dropFirst().contains(where: { $0.hasPrefix(q) }) { return tier(.wordPrefix) }
        let tokens = q.split(separator: " ").map(String.init)
        if tokens.count > 1, tokensPrefixWords(tokens, c.words) { return tier(.wordPrefix) }
        // One character matches only the start of a word: anything looser is noise.
        guard q.count >= 2 else { return nil }
        let compact = tokens.joined()
        if c.initials.count >= 2 {
            if c.initials.hasPrefix(compact) { return tier(.initials) }
            if isSubsequence(compact, of: c.initials), compact.first == c.initials.first {
                return tier(.initials, base - 20)
            }
        }
        if c.folded.contains(q) { return tier(.substring) }
        return fuzzy(compact, c).map { tier(.fuzzy, $0) }
    }

    /// "vis stu" → "Visual Studio Code": every token starts a word, in order.
    private static func tokensPrefixWords(_ tokens: [String], _ words: [String]) -> Bool {
        var i = 0
        for token in tokens {
            while i < words.count, !words[i].hasPrefix(token) { i += 1 }
            guard i < words.count else { return false }
            i += 1
        }
        return true
    }

    private static func isSubsequence(_ q: String, of text: String) -> Bool {
        var it = text.makeIterator()
        for ch in q {
            var found = false
            while let t = it.next() { if t == ch { found = true; break } }
            if !found { return false }
        }
        return true
    }

    /// Subsequence match whose first character starts a word ("ps" → "Photo**s**hop"), so a query
    /// does not light up every name that merely contains its letters. Fine score 0…60: fewer and
    /// shorter gaps and more characters on word starts score higher. Tries every word start.
    private static func fuzzy(_ q: String, _ c: Candidate) -> Double? {
        let text = Array(c.compact)
        let query = Array(q)
        guard let first = query.first, query.count <= text.count else { return nil }
        var best: Double?
        for start in c.compactWordStarts where text[start] == first {
            var pos = start + 1
            var gaps = 0, gapChars = 0, onWordStarts = 0
            var ok = true
            for ch in query.dropFirst() {
                var j = pos
                while j < text.count, text[j] != ch { j += 1 }
                guard j < text.count else { ok = false; break }
                if j > pos { gaps += 1; gapChars += j - pos }
                if c.compactWordStarts.contains(j) { onWordStarts += 1 }
                pos = j + 1
            }
            guard ok else { continue }
            // Reject matches spread thinner than the query itself: too random to be meant.
            guard gapChars <= max(4, query.count * 3) else { continue }
            let fine = max(0, min(base, base - Double(gaps) * 6 - Double(gapChars) * 2
                                  + Double(onWordStarts) * 4 - Double(start) * 0.5))
            if fine > (best ?? -1) { best = fine }
        }
        return best
    }

    // MARK: - Candidate text

    /// A name split for matching: folded whole text, folded words (separators, camel case and
    /// letter/digit changes split them) and their initials.
    struct Candidate {
        let folded: String
        let words: [String]
        let initials: String
        /// Words joined without separators, and where each word starts in it (for fuzzy matching).
        let compact: String
        let compactWordStarts: Set<Int>

        init(_ text: String) {
            folded = SearchMatcher.fold(text)
            words = SearchMatcher.splitWords(text).map(SearchMatcher.fold).filter { !$0.isEmpty }
            initials = String(words.compactMap(\.first))
            compact = words.joined()
            var starts = Set<Int>()
            var offset = 0
            for w in words { starts.insert(offset); offset += w.count }
            compactWordStarts = starts
        }
    }

    /// Case- and diacritic-insensitive form used on both sides of every comparison.
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// "Visual Studio Code" → [Visual, Studio, Code]; "iMovie" → [i, Movie]; "VSCode" → [VS, Code];
    /// "Office365" → [Office, 365].
    static func splitWords(_ text: String) -> [String] {
        var words: [String] = []
        var current: [Character] = []
        let chars = Array(text)
        func flush() { if !current.isEmpty { words.append(String(current)); current = [] } }
        for (i, ch) in chars.enumerated() {
            guard ch.isLetter || ch.isNumber else { flush(); continue }
            if let prev = current.last {
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                let camel = prev.isLowercase && ch.isUppercase
                let acronymEnd = prev.isUppercase && ch.isUppercase && (next?.isLowercase ?? false)
                let digitChange = prev.isNumber != ch.isNumber
                if camel || acronymEnd || digitChange { flush() }
            }
            current.append(ch)
        }
        flush()
        return words
    }
}

/// Re-types a query through the other keyboard layout by physical key: macOS "Ukrainian" (ЙЦУКЕН)
/// ↔ US QWERTY. "іфа" → "saf", "сщву" → "code", "ghbdsn" → "привіт".
enum KeyboardLayout {
    /// Latin key → Ukrainian letter on the same key (lowercase).
    static let latinToCyrillic: [Character: Character] = [
        "q": "й", "w": "ц", "e": "у", "r": "к", "t": "е", "y": "н", "u": "г", "i": "ш", "o": "щ",
        "p": "з", "[": "х", "]": "ї", "a": "ф", "s": "і", "d": "в", "f": "а", "g": "п", "h": "р",
        "j": "о", "k": "л", "l": "д", ";": "ж", "'": "є", "\\": "ґ", "z": "я", "x": "ч", "c": "с",
        "v": "м", "b": "и", "n": "т", "m": "ь", ",": "б", ".": "ю",
    ]

    /// Ukrainian (and the Russian-only letters on the same keys) → Latin key.
    static let cyrillicToLatin: [Character: Character] = {
        var map: [Character: Character] = [:]
        for (latin, cyr) in latinToCyrillic { map[cyr] = latin }
        map["ы"] = "s"; map["э"] = "'"; map["ъ"] = "]"; map["ё"] = "`"
        return map
    }()

    /// The query re-typed in the other layout, or nil when it has no letters to swap. Cyrillic
    /// letters go to Latin; otherwise Latin keys go to Cyrillic. Other characters stay as they are.
    static func convert(_ query: String) -> String? {
        let lower = query.lowercased()
        let hasCyrillic = lower.contains { cyrillicToLatin[$0] != nil }
        let map = hasCyrillic ? cyrillicToLatin : latinToCyrillic
        var changed = false
        let out = String(lower.map { ch -> Character in
            guard let m = map[ch] else { return ch }
            changed = true
            return m
        })
        return changed ? out : nil
    }
}
