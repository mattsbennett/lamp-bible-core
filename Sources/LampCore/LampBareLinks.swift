import Foundation

/// The web and email addresses written out in drawn text, to be tapped.
///
/// The writer's editor reads Markdown with linkify off, so a bare address is
/// words to it, and core reads it the same way (`LampProse`): what a file
/// says, and where review marks fall in it, never depend on this. This is
/// only for drawing. A reader shows the text as it reads, then makes each
/// address written out in it something to tap, as a reader of anything
/// expects to.
///
/// It works on the text as drawn, so it knows nothing of Markdown, review
/// marks or code. The caller says which ranges are already spoken for (a
/// link the writer made, a passage to review, code), and an address is
/// linked only where it isn't. Each part linked opens the whole address, so
/// one cut by a review mark still goes where it says.
public enum LampBareLinks {
    /// One address found, where it stands in the text (UTF-16) and what it
    /// opens.
    public struct Address: Equatable, Sendable {
        public let range: NSRange
        public let url: URL

        public init(range: NSRange, url: URL) {
            self.range = range
            self.url = url
        }
    }

    /// The addresses written out in `text`, after GitHub's rules for them
    /// (GFM's extended autolinks), which err towards leaving words alone.
    ///
    /// The text is read a word at a time (a run between spaces), each word
    /// once, and a word is linked only where the whole of it, less the
    /// sentence's punctuation around it, is an address: a web address that
    /// begins `https://`, `http://` or `www.` and names a host with a dot in
    /// it, or an email address whose name is letters, digits and
    /// `. + - _`. Never part of one, which would open somewhere else. A
    /// file's name (`outline.md`) or a reference (`John 3.16`) stays words.
    public static func addresses(in text: String) -> [Address] {
        let source = text as NSString
        var found: [Address] = []
        var at = 0
        while at < source.length {
            guard !isSpace(source.character(at: at)) else {
                at += 1
                continue
            }
            var end = at
            while end < source.length, !isSpace(source.character(at: end)) { end += 1 }
            if let address = address(in: source, word: NSRange(location: at, length: end - at)) { found.append(address) }
            at = end
        }
        return found
    }

    private static func isSpace(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// The address a word is, if it's one.
    private static func address(in source: NSString, word: NSRange) -> Address? {
        let scalars = Array(source.substring(with: word).unicodeScalars)
        // A web address may follow words it's written against with no space
        // (`参照：https://…`), but only after punctuation, never a letter.
        if let start = webStart(in: scalars) {
            var kept = Array(scalars[start...])
            // Up to the quote or bracket that closes the one before it, and
            // never past another script's closing punctuation (`」`, `。`).
            if start > 0, let opener = Optional(scalars[start - 1]), let closer = closers[opener] {
                if opener == "(" || opener == "[" {
                    // The bracket that closes the prose's: the first the
                    // address hasn't opened itself.
                    var depth = 0
                    for (index, scalar) in kept.enumerated() {
                        if scalar == opener { depth += 1 }
                        if scalar == closer {
                            if depth == 0 {
                                kept.removeSubrange(index...)
                                break
                            }
                            depth -= 1
                        }
                    }
                } else if let end = opener == "'" ? kept.lastIndex(of: closer) : kept.firstIndex(of: closer) {
                    // A quote: the first that closes it, but for an
                    // apostrophe, which may stand in the address: the last.
                    kept.removeSubrange(end...)
                }
            }
            if let end = kept.firstIndex(where: { !$0.isASCII && closingPunctuation.contains($0) }) {
                // Another script's punctuation ends it, unless it's a dot
                // between a host's labels (`example.com。au`): then it's
                // no address to guess at.
                let host = hasPrefix(kept[...], "https://") ? 8 : hasPrefix(kept[...], "http://") ? 7 : 0
                if end + 1 < kept.count, CharacterSet.alphanumerics.contains(kept[end + 1]),
                   host <= end, !kept[host..<end].contains("/") { return nil }
                kept.removeSubrange(end...)
            }
            trimClosing(&kept)
            if let address = web(kept, at: word.location + utf16Count(scalars[..<start])) { return address }
        }
        // An email address is the whole word, less the punctuation around it.
        guard scalars.contains("@") else { return nil }
        var start = 0
        while start < scalars.count, opening.contains(scalars[start]) { start += 1 }
        var kept = Array(scalars[start...])
        trimClosing(&kept)
        // `'`, `*` and `~` may begin a mailbox's name: one is taken as a
        // wrapper only where the same closes it.
        var head = 0
        var closer = start + kept.count
        while head < kept.count, "'*~".unicodeScalars.contains(kept[head]), closer < scalars.count, scalars[closer] == kept[head] {
            head += 1
            closer += 1
        }
        if head > 0 {
            start += head
            kept = Array(kept[head...])
        }
        // An address ended by `_` is no address (GFM).
        if start + kept.count < scalars.count, scalars[start + kept.count] == "_" { return nil }
        let written = String(String.UnicodeScalarView(kept))
        guard !written.isEmpty,
              written.wholeMatch(of: #/[A-Za-z0-9.+_-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]*[A-Za-z0-9])+/#) != nil,
              let url = URL(string: "mailto:" + written) else { return nil }
        return Address(range: NSRange(location: word.location + utf16Count(scalars[..<start]), length: (written as NSString).length), url: url)
    }

    private static func utf16Count(_ scalars: ArraySlice<Unicode.Scalar>) -> Int {
        scalars.reduce(0) { $0 + String($1).utf16.count }
    }

    /// A web address beginning `https://`, `http://` or `www.`, if `scalars`
    /// is one: a valid host, no user before it, and no `<`, which ends one.
    private static func web(_ scalars: [Unicode.Scalar], at location: Int) -> Address? {
        guard !scalars.isEmpty, !scalars.contains("<") else { return nil }
        let written = String(String.UnicodeScalarView(scalars))
        let full = hasPrefix(scalars[...], "www.") ? "http://" + written : written
        // A name before `@` would be what Foundation calls the host's user,
        // and the link would open the host after it.
        guard let url = URL(string: full), url.user == nil, url.password == nil,
              let host = url.host, isHost(host) else { return nil }
        return Address(range: NSRange(location: location, length: (written as NSString).length), url: url)
    }

    /// Whether `scalars` begins with ASCII `prefix`, either case.
    private static func hasPrefix(_ scalars: ArraySlice<Unicode.Scalar>, _ prefix: String) -> Bool {
        let wanted = Array(prefix.unicodeScalars)
        guard scalars.count >= wanted.count else { return false }
        return zip(scalars, wanted).allSatisfy { pair in
            pair.0 == pair.1 || (pair.0.isASCII && Character(pair.0).lowercased() == String(pair.1))
        }
    }

    /// Where a web address begins in a word: at its start, or after
    /// punctuation (a quote, a bracket, a colon in another script).
    private static func webStart(in scalars: [Unicode.Scalar]) -> Int? {
        for index in scalars.indices {
            let rest = scalars[index...]
            guard hasPrefix(rest, "http://") || hasPrefix(rest, "https://") || hasPrefix(rest, "www.") else { continue }
            guard index > 0 else { return 0 }
            // Inside another scheme's address (`ftp://…(https://…)`) it's
            // that address's.
            if scalars[..<index].contains(":") || hasPrefix(scalars[...], "//") { return nil }
            let before = scalars[index - 1]
            if CharacterSet.alphanumerics.contains(before) || ".+_-/:@=&?#%\\".unicodeScalars.contains(before) {
                // The word goes on, or names another scheme (`mailto:`).
                return nil
            }
            return index
        }
        return nil
    }

    /// A host to link to: labels of letters, digits, `-` and `_`, at least
    /// two of them, and no `_` in the last two (GFM's rule).
    private static func isHost(_ host: String) -> Bool {
        let labels = (host.hasSuffix(".") ? String(host.dropLast()) : host).split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard labels.allSatisfy({ $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return false }
        return !labels.suffix(2).contains { $0.contains("_") }
    }

    /// Where a trailing `&name;` begins, reading back only through its name.
    private static func entityStart(in scalars: [Unicode.Scalar]) -> Int? {
        var index = scalars.count - 2
        while index >= 0, CharacterSet.alphanumerics.contains(scalars[index]) { index -= 1 }
        guard index >= 0, index < scalars.count - 2, scalars[index] == "&" else { return nil }
        return index
    }

    /// What opens a quotation or an aside around an address.
    private static let opening = Set("([{<\"‘“«「『【〔《〈".unicodeScalars)

    /// Each opening quote or bracket, and what closes it.
    private static let closers: [Unicode.Scalar: Unicode.Scalar] = [
        "(": ")", "[": "]", "{": "}", "<": ">", "'": "'", "\"": "\"", "‘": "’", "“": "”", "«": "»",
        "「": "」", "『": "』", "【": "】", "〔": "〕", "《": "》", "〈": "〉",
    ]

    /// What ends a sentence or closes a quotation, never an address's own
    /// last character.
    private static let closingPunctuation = Set("?!.,:;*_~'\"’”»」』】〕》〉>}。、，：；！？…".unicodeScalars)

    /// The sentence's punctuation off an address's end: a closing bracket
    /// only where the address didn't open it, and a trailing `&name;` whole.
    private static func trimClosing(_ scalars: inout [Unicode.Scalar]) {
        var parens = (open: scalars.filter { $0 == "(" }.count, close: scalars.filter { $0 == ")" }.count)
        var squares = (open: scalars.filter { $0 == "[" }.count, close: scalars.filter { $0 == "]" }.count)
        while let last = scalars.last {
            if last == ")", parens.close > parens.open {
                parens.close -= 1
            } else if last == "]", squares.close > squares.open {
                squares.close -= 1
            } else if last == ";", let ampersand = entityStart(in: scalars) {
                scalars.removeSubrange(ampersand...)
                continue
            } else if !closingPunctuation.contains(last) {
                return
            }
            scalars.removeLast()
        }
    }

    /// The addresses to link in drawn text, `taken` being the ranges
    /// already spoken for: a link the writer made, a passage to review, a
    /// footnote's number, code, anything the reader drew that isn't the
    /// writer's words. Those split the text, and addresses are looked for
    /// only between them; one that runs up against one is left as words,
    /// since it may go on past it, or be cut by it, and a link to part of an
    /// address opens somewhere else.
    public static func links(in text: String, excluding taken: [NSRange]) -> [Address] {
        let source = text as NSString
        var merged: [NSRange] = []
        for range in taken.filter({ $0.length > 0 }).sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        var stretches: [NSRange] = []
        var from = 0
        for range in merged {
            if range.location > from { stretches.append(NSRange(location: from, length: range.location - from)) }
            from = max(from, NSMaxRange(range))
        }
        if from < source.length { stretches.append(NSRange(location: from, length: source.length - from)) }
        return stretches.flatMap { stretch -> [Address] in
            let piece = source.substring(with: stretch) as NSString
            // The words at the stretch's edges run on into what's spoken
            // for: an address in either may be cut by it, though the
            // sentence's punctuation trimmed off it no longer touches.
            var first = 0
            while first < piece.length, !isSpace(piece.character(at: first)) { first += 1 }
            var last = piece.length
            while last > 0, !isSpace(piece.character(at: last - 1)) { last -= 1 }
            return addresses(in: piece as String).compactMap { found in
                if stretch.location > 0, found.range.location < first { return nil }
                if NSMaxRange(stretch) < source.length, NSMaxRange(found.range) > last { return nil }
                return Address(range: NSRange(location: stretch.location + found.range.location, length: found.range.length), url: found.url)
            }
        }
    }


}
