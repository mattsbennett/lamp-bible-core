import Foundation

extension LampPortableDevotionalContent {
    public enum EditError: LocalizedError {
        case invalidContentJSON

        public var errorDescription: String? {
            "This devotional's structured content cannot be edited because its JSON is invalid."
        }
    }

    /// Update a rich devotional after editing its Markdown projection. Identical
    /// blocks retain their original JSON, including fields from newer clients.
    /// Structured content retains its sections and available section metadata,
    /// including when the edited outline changes.
    public static func replacingMarkdown(
        _ editedMarkdown: String, in originalJSON: String
    ) throws -> String {
        if markdown(from: originalJSON) == editedMarkdown { return originalJSON }
        guard let original = try? JSONSerialization.jsonObject(
            with: Data(originalJSON.utf8)
        ) else { throw EditError.invalidContentJSON }
        let edited = blocks(from: editedMarkdown)
        let revised: Any
        if let oldBlocks = original as? [[String: Any]] {
            revised = merge(oldBlocks, with: edited)
        } else if let structured = original as? [String: Any] {
            revised = reviseStructured(structured, with: edited)
        } else {
            throw EditError.invalidContentJSON
        }
        guard JSONSerialization.isValidJSONObject(revised) else {
            throw EditError.invalidContentJSON
        }
        return String(decoding: try JSONSerialization.data(
            withJSONObject: revised, options: [.sortedKeys]
        ), as: UTF8.self)
    }

    /// This is the searchable text paired with rich JSON in the portable library.
    public static func plainText(from contentJSON: String) -> String? {
        guard let value = try? JSONSerialization.jsonObject(
            with: Data(contentJSON.utf8)
        ) else { return nil }
        return flattenText(value)
    }

    /// Shared Markdown-to-block parser. The returned JSON uses the iOS block
    /// schema, so clients can decode it into their local devotional model.
    public static func blocksJSON(from markdown: String) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: blocks(from: markdown), options: [.sortedKeys]
        )
    }

    private static func flattenText(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let array = value as? [Any] {
            let text = array.compactMap(flattenText).joined(separator: "\n\n")
            return text.isEmpty ? nil : text
        }
        if let object = value as? [String: Any] {
            for key in ["text", "content", "value", "note", "body"] {
                if let text = flattenText(object[key]) { return text }
            }
            let ignored: Set<String> = ["id", "type", "style", "level", "annotations"]
            let text = object.filter { !ignored.contains($0.key) }
                .sorted { $0.key < $1.key }
                .compactMap { flattenText($0.value) }
                .joined(separator: "\n\n")
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private static func reviseStructured(
        _ original: [String: Any], with edited: [[String: Any]]
    ) -> Any {
        if outlineChanged(original, edited: edited) {
            return rebuildStructured(original, edited: edited)
        }
        var positions: [ContentPosition] = []
        var oldBlocks: [[String: Any]] = []
        for block in original["introduction"] as? [[String: Any]] ?? [] {
            positions.append(.introduction)
            oldBlocks.append(block)
        }
        func collect(_ section: [String: Any], path: [Int]) {
            positions.append(.heading(path))
            oldBlocks.append(sectionHeading(section))
            for block in section["blocks"] as? [[String: Any]] ?? [] {
                positions.append(.block(path))
                oldBlocks.append(block)
            }
            for (index, nested) in (section["subsections"] as? [[String: Any]] ?? []).enumerated() {
                collect(nested, path: path + [index])
            }
        }
        for (index, section) in (original["sections"] as? [[String: Any]] ?? []).enumerated() {
            collect(section, path: [index])
        }
        for block in original["conclusion"] as? [[String: Any]] ?? [] {
            positions.append(.conclusion)
            oldBlocks.append(block)
        }
        guard positions.count == edited.count,
              zip(positions, edited).allSatisfy({ position, block in
                  if case .heading = position { return block["type"] as? String == "heading" }
                  return true
              }) else {
                  return reviseStructuredWithAnchors(original, edited: edited)
                      ?? rebuildStructured(original, edited: edited)
              }

        let merged = merge(oldBlocks, with: edited)
        guard merged.count == positions.count else {
            return rebuildStructured(original, edited: edited)
        }
        var result = original
        var introduction: [[String: Any]] = []
        var conclusion: [[String: Any]] = []
        var sections = original["sections"] as? [[String: Any]] ?? []
        func clearBlocks(_ section: inout [String: Any]) {
            if section["blocks"] != nil { section["blocks"] = [[String: Any]]() }
            if var nested = section["subsections"] as? [[String: Any]] {
                for index in nested.indices { clearBlocks(&nested[index]) }
                section["subsections"] = nested
            }
        }
        for index in sections.indices { clearBlocks(&sections[index]) }
        for (position, block) in zip(positions, merged) {
            switch position {
            case .introduction:
                introduction.append(block)
            case .conclusion:
                conclusion.append(block)
            case .heading(let path):
                mutateSection(&sections, path: path) { section in
                    section["title"] = (block["content"] as? [String: Any])?["text"]
                        ?? section["title"]
                    section["level"] = block["level"] ?? section["level"]
                }
            case .block(let path):
                mutateSection(&sections, path: path) { section in
                    var blocks = section["blocks"] as? [[String: Any]] ?? []
                    blocks.append(block)
                    section["blocks"] = blocks
                }
            }
        }
        if original["introduction"] != nil { result["introduction"] = introduction }
        result["sections"] = sections
        if original["conclusion"] != nil { result["conclusion"] = conclusion }
        return result
    }

    private struct EditableSection {
        var value: [String: Any]
        var title: String
        var level: Int
        var blocks: [[String: Any]]
    }

    private struct EditedSection {
        var title: String
        var level: Int
        var blocks: [[String: Any]]
    }

    private static func sectionsInReadingOrder(_ original: [String: Any]) -> [EditableSection] {
        var result: [EditableSection] = []
        func collect(_ section: [String: Any]) {
            result.append(EditableSection(
                value: section,
                title: section["title"] as? String ?? "",
                level: section["level"] as? Int ?? 2,
                blocks: section["blocks"] as? [[String: Any]] ?? []
            ))
            for nested in section["subsections"] as? [[String: Any]] ?? [] {
                collect(nested)
            }
        }
        for section in original["sections"] as? [[String: Any]] ?? [] {
            collect(section)
        }
        return result
    }

    private static func sectionMarkers(
        _ original: [String: Any], edited: [[String: Any]], old: [EditableSection]
    ) -> [Int] {
        let sectionSignatures = Set(old.map { signature(sectionHeading($0.value)) })
        var headingSlots: [Bool] = []
        var contentSignatures: Set<String> = []
        let intro = original["introduction"] as? [[String: Any]] ?? []
        let conclusion = original["conclusion"] as? [[String: Any]] ?? []
        for block in intro + conclusion + old.flatMap(\.blocks)
        where block["type"] as? String == "heading" {
            contentSignatures.insert(signature(block))
        }
        headingSlots += intro.filter { $0["type"] as? String == "heading" }.map { _ in false }
        func collectSlots(_ section: [String: Any]) {
            headingSlots.append(true)
            headingSlots += (section["blocks"] as? [[String: Any]] ?? [])
                .filter { $0["type"] as? String == "heading" }.map { _ in false }
            for nested in section["subsections"] as? [[String: Any]] ?? [] {
                collectSlots(nested)
            }
        }
        for section in original["sections"] as? [[String: Any]] ?? [] {
            collectSlots(section)
        }
        headingSlots += conclusion.filter { $0["type"] as? String == "heading" }
            .map { _ in false }
        let editedHeadings = edited.indices.filter {
            edited[$0]["type"] as? String == "heading"
        }
        // When the number of headings is stable, their roles are stable too:
        // changing a heading inside a section must not create a new section.
        // Exact headings retain their roles even if sections move around them.
        if editedHeadings.count == headingSlots.count {
            return zip(editedHeadings, headingSlots).compactMap { index, wasSection in
                let rendered = signature(edited[index])
                if sectionSignatures.contains(rendered) { return index }
                if contentSignatures.contains(rendered) { return nil }
                return wasSection ? index : nil
            }
        }
        return editedHeadings.filter { index in
            let block = edited[index]
            let rendered = signature(block)
            if sectionSignatures.contains(rendered) { return true }
            if contentSignatures.contains(rendered) { return false }
            return true
        }
    }

    private static func outlineChanged(
        _ original: [String: Any], edited: [[String: Any]]
    ) -> Bool {
        let old = sectionsInReadingOrder(original)
        let markers = sectionMarkers(original, edited: edited, old: old)
        let originalHeadings = old.map { signature(sectionHeading($0.value)) }
        return Set(originalHeadings).count != originalHeadings.count
            || originalHeadings != markers.map { signature(edited[$0]) }
    }

    private static func rebuildStructured(
        _ original: [String: Any], edited: [[String: Any]]
    ) -> [String: Any] {
        let old = sectionsInReadingOrder(original)
        let markers = sectionMarkers(original, edited: edited, old: old)
        let signatures = edited.map(signature)
        let oldConclusion = original["conclusion"] as? [[String: Any]] ?? []
        let afterLastHeading = (markers.last.map { $0 + 1 } ?? 0)
        let conclusionStart: Int
        if let first = oldConclusion.first,
           afterLastHeading < edited.count,
           let match = (afterLastHeading..<edited.count).first(where: {
               signatures[$0] == signature(first)
           }) {
            conclusionStart = match
        } else if !oldConclusion.isEmpty {
            conclusionStart = max(afterLastHeading, edited.count - oldConclusion.count)
        } else {
            conclusionStart = edited.count
        }

        let introductionEnd = min(markers.first ?? conclusionStart, conclusionStart)
        let introduction = Array(edited[..<introductionEnd])
        let conclusion = Array(edited[conclusionStart...])
        let changed: [EditedSection] = markers.enumerated().map { offset, marker in
            let end = min(markers.indices.contains(offset + 1)
                ? markers[offset + 1] : conclusionStart, conclusionStart)
            let heading = edited[marker]
            return EditedSection(
                title: (heading["content"] as? [String: Any])?["text"] as? String ?? "",
                level: heading["level"] as? Int ?? 2,
                blocks: marker + 1 <= end ? Array(edited[(marker + 1)..<end]) : []
            )
        }

        var matches = Array<Int?>(repeating: nil, count: changed.count)
        var used: Set<Int> = []
        func bodyOverlap(_ changed: EditedSection, _ old: EditableSection) -> Int {
            let rendered = Set(changed.blocks.map(signature))
            return old.blocks.filter {
                !isUnrenderable($0) && rendered.contains(signature($0))
            }.count
        }
        func assign(_ predicate: (EditedSection, EditableSection) -> Bool) {
            for index in changed.indices where matches[index] == nil {
                let candidate = old.indices.filter {
                    !used.contains($0) && predicate(changed[index], old[$0])
                }.sorted { left, right in
                    let leftScore = bodyOverlap(changed[index], old[left])
                    let rightScore = bodyOverlap(changed[index], old[right])
                    return leftScore == rightScore ? left < right : leftScore > rightScore
                }.first
                if let candidate {
                    matches[index] = candidate
                    used.insert(candidate)
                }
            }
        }
        assign { $0.title == $1.title && $0.level == $1.level }
        assign { $0.title == $1.title }
        for index in changed.indices where matches[index] == nil {
            let candidate = old.indices.filter { !used.contains($0) }
                .map { oldIndex in
                    (oldIndex, bodyOverlap(changed[index], old[oldIndex]))
                }
                .max { $0.1 < $1.1 }
            if let candidate, candidate.1 > 0 {
                matches[index] = candidate.0
                used.insert(candidate.0)
            }
        }
        if changed.count == old.count {
            for index in changed.indices where matches[index] == nil {
                if let candidate = old.indices.first(where: { !used.contains($0) }) {
                    matches[index] = candidate
                    used.insert(candidate)
                }
            }
        }

        var sections: [[String: Any]] = []
        var parents: [(level: Int, path: [Int])] = []
        for index in changed.indices {
            let section = changed[index]
            let oldSection = matches[index].map { old[$0] }
            var value = oldSection?.value ?? [:]
            value["title"] = section.title
            value["level"] = section.level
            value["blocks"] = merge(oldSection?.blocks ?? [], with: section.blocks)
            if value["subsections"] != nil { value["subsections"] = [[String: Any]]() }
            while let last = parents.last, last.level >= section.level {
                parents.removeLast()
            }
            let path: [Int]
            if let parent = parents.last {
                var childIndex = 0
                mutateSection(&sections, path: parent.path) { container in
                    var nested = container["subsections"] as? [[String: Any]] ?? []
                    childIndex = nested.count
                    nested.append(value)
                    container["subsections"] = nested
                }
                path = parent.path + [childIndex]
            } else {
                path = [sections.count]
                sections.append(value)
            }
            parents.append((section.level, path))
        }

        var result = original
        let oldIntroduction = original["introduction"] as? [[String: Any]] ?? []
        if original["introduction"] != nil || !introduction.isEmpty {
            result["introduction"] = merge(oldIntroduction, with: introduction)
        }
        result["sections"] = sections
        if original["conclusion"] != nil || !conclusion.isEmpty {
            result["conclusion"] = merge(oldConclusion, with: conclusion)
        }
        return result
    }

    /// When blocks are inserted or removed, section headings provide stable
    /// boundaries. Preserve the original section tree and merge within each
    /// section instead of flattening its metadata.
    private static func reviseStructuredWithAnchors(
        _ original: [String: Any], edited: [[String: Any]]
    ) -> [String: Any]? {
        var headings: [(path: [Int], signature: String)] = []
        var originalBlocks: [String: [[String: Any]]] = [:]
        func collect(_ section: [String: Any], path: [Int]) {
            headings.append((path, signature(sectionHeading(section))))
            originalBlocks[pathKey(path)] = section["blocks"] as? [[String: Any]] ?? []
            for (index, nested) in (section["subsections"] as? [[String: Any]] ?? []).enumerated() {
                collect(nested, path: path + [index])
            }
        }
        for (index, section) in (original["sections"] as? [[String: Any]] ?? []).enumerated() {
            collect(section, path: [index])
        }
        guard !headings.isEmpty else { return nil }
        let signatures = edited.map(signature)
        var markers: [(index: Int, path: [Int])] = []
        var searchStart = 0
        for heading in headings {
            guard searchStart < edited.count,
                  let index = (searchStart..<edited.count).first(where: {
                      signatures[$0] == heading.signature
                  }) else { return nil }
            markers.append((index, heading.path))
            searchStart = index + 1
        }

        let oldConclusion = original["conclusion"] as? [[String: Any]] ?? []
        let conclusionStart: Int
        if let first = oldConclusion.first,
           searchStart < edited.count,
           let match = (searchStart..<edited.count).first(where: {
               signatures[$0] == signature(first)
           }) {
            conclusionStart = match
        } else if !oldConclusion.isEmpty {
            conclusionStart = max(searchStart, edited.count - oldConclusion.count)
        } else {
            conclusionStart = edited.count
        }

        var introduction: [[String: Any]] = []
        var conclusion: [[String: Any]] = []
        var assigned: [String: [[String: Any]]] = [:]
        var markerIndex = 0
        for (index, block) in edited.enumerated() {
            if markerIndex < markers.count, index == markers[markerIndex].index {
                markerIndex += 1
                continue
            }
            if index < markers[0].index {
                introduction.append(block)
            } else if index >= conclusionStart {
                conclusion.append(block)
            } else {
                let path = markers[markerIndex - 1].path
                assigned[pathKey(path), default: []].append(block)
            }
        }
        var result = original
        let oldIntroduction = original["introduction"] as? [[String: Any]] ?? []
        if original["introduction"] != nil || !introduction.isEmpty {
            result["introduction"] = merge(oldIntroduction, with: introduction)
        }
        if original["conclusion"] != nil || !conclusion.isEmpty {
            result["conclusion"] = merge(oldConclusion, with: conclusion)
        }
        var sections = original["sections"] as? [[String: Any]] ?? []
        for heading in headings {
            let key = pathKey(heading.path)
            mutateSection(&sections, path: heading.path) { section in
                let changed = assigned[key] ?? []
                if section["blocks"] != nil || !changed.isEmpty {
                    section["blocks"] = merge(originalBlocks[key] ?? [], with: changed)
                }
            }
        }
        result["sections"] = sections
        return result
    }

    private static func pathKey(_ path: [Int]) -> String {
        path.map(String.init).joined(separator: "/")
    }

    private enum ContentPosition {
        case introduction
        case heading([Int])
        case block([Int])
        case conclusion
    }

    private static func mutateSection(
        _ sections: inout [[String: Any]], path: [Int],
        _ mutation: (inout [String: Any]) -> Void
    ) {
        guard let index = path.first, sections.indices.contains(index) else { return }
        if path.count == 1 {
            mutation(&sections[index])
        } else {
            var nested = sections[index]["subsections"] as? [[String: Any]] ?? []
            mutateSection(&nested, path: Array(path.dropFirst()), mutation)
            sections[index]["subsections"] = nested
        }
    }

    private static func sectionHeading(_ section: [String: Any]) -> [String: Any] {
        ["type": "heading", "level": section["level"] ?? 2,
         "content": ["text": section["title"] ?? ""]]
    }

    private static func merge(
        _ original: [[String: Any]], with edited: [[String: Any]]
    ) -> [[String: Any]] {
        let oldSignatures = original.map(signature)
        let newSignatures = edited.map(signature)
        let oldCount = original.count
        let newCount = edited.count
        var lengths = Array(
            repeating: Array(repeating: 0, count: newCount + 1), count: oldCount + 1
        )
        if oldCount > 0 && newCount > 0 {
            for old in stride(from: oldCount - 1, through: 0, by: -1) {
                for new in stride(from: newCount - 1, through: 0, by: -1) {
                    lengths[old][new] = oldSignatures[old] == newSignatures[new]
                        ? 1 + lengths[old + 1][new + 1]
                        : max(lengths[old + 1][new], lengths[old][new + 1])
                }
            }
        }
        var matches: [(Int, Int)] = []
        var old = 0
        var new = 0
        while old < oldCount && new < newCount {
            if oldSignatures[old] == newSignatures[new] {
                matches.append((old, new))
                old += 1
                new += 1
            } else if lengths[old + 1][new] >= lengths[old][new + 1] {
                old += 1
            } else {
                new += 1
            }
        }
        var result: [[String: Any]] = []
        var oldStart = 0
        var newStart = 0
        for (oldEnd, newEnd) in matches + [(oldCount, newCount)] {
            let newGap = newEnd - newStart
            let gap = Array(original[oldStart..<oldEnd])
            let visible = gap.filter { !isUnrenderable($0) }
            if visible.count == newGap {
                var offset = 0
                for block in gap {
                    if isUnrenderable(block) {
                        result.append(block)
                    } else {
                        result.append(mergingFields(block, edited[newStart + offset]))
                        offset += 1
                    }
                }
            } else {
                result += gap.filter(isUnrenderable)
                result += edited[newStart..<newEnd]
            }
            if oldEnd < oldCount {
                result.append(original[oldEnd])
            }
            oldStart = oldEnd + 1
            newStart = newEnd + 1
        }
        return result
    }

    private static func isUnrenderable(_ block: [String: Any]) -> Bool {
        guard JSONSerialization.isValidJSONObject([block]),
              let data = try? JSONSerialization.data(withJSONObject: [block]) else {
            return true
        }
        return LampPortableDevotionalContent.markdown(
            from: String(decoding: data, as: UTF8.self)
        )?.isEmpty ?? true
    }

    private static func signature(_ block: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject([block]),
              let data = try? JSONSerialization.data(
                  withJSONObject: [block], options: [.sortedKeys]
              ) else { return "" }
        // Equality based on rendered content keeps unknown JSON on untouched blocks.
        let serialized = String(decoding: data, as: UTF8.self)
        guard let projected = LampPortableDevotionalContent.markdown(from: serialized),
              !projected.isEmpty else { return serialized }
        return projected
    }

    private static func mergingFields(
        _ original: [String: Any], _ changed: [String: Any]
    ) -> [String: Any] {
        guard original["type"] as? String == changed["type"] as? String else {
            return changed
        }
        var result = original
        for (key, value) in changed {
            if key == "content", let old = original[key] as? [String: Any],
               let new = value as? [String: Any] {
                let retained = old.filter {
                    !["text", "annotations", "footnote_refs"].contains($0.key)
                }
                result[key] = retained.merging(new) { _, replacement in replacement }
            } else if key == "tableData", let old = original[key] as? [String: Any],
                      let new = value as? [String: Any] {
                result[key] = old.merging(new) { _, replacement in replacement }
            } else {
                result[key] = value
            }
        }
        return result
    }

    private static func blocks(from markdown: String) -> [[String: Any]] {
        let lines = markdown.components(separatedBy: .newlines)
        var blocks: [[String: Any]] = []
        var paragraph: [String] = []
        var index = 0
        func flushParagraph() {
            let text = paragraph.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                blocks.append(["type": "paragraph", "content": annotated(text)])
            }
            paragraph = []
        }
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[^"), trimmed.contains("]:") {
                index += 1
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }
            if index + 1 < lines.count,
               let headers = tableCells(trimmed),
               let separator = tableCells(lines[index + 1]),
               headers.count == separator.count,
               separator.allSatisfy({ isTableSeparator($0) }) {
                flushParagraph()
                index += 2
                var rows: [[String]] = []
                while index < lines.count, let row = tableCells(lines[index]),
                      row.count == headers.count {
                    rows.append(row)
                    index += 1
                }
                blocks.append(["type": "table", "tableData": [
                    "headers": headers, "rows": rows,
                ]])
                continue
            }
            if let media = mediaBlock(trimmed) {
                flushParagraph()
                blocks.append(media)
                index += 1
                continue
            }
            let hashes = trimmed.prefix { $0 == "#" }
            let headingText = trimmed.dropFirst(hashes.count)
                .trimmingCharacters(in: .whitespaces)
            if (1...6).contains(hashes.count), !headingText.isEmpty {
                flushParagraph()
                blocks.append(["type": "heading", "level": hashes.count,
                               "content": annotated(headingText)])
                index += 1
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix(">") else { break }
                    quote.append(String(current.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(["type": "blockquote", "content": annotated(quote.joined(separator: "\n"))])
                continue
            }
            if let item = listItem(line) {
                flushParagraph()
                let numbered = item.numbered
                var items: [[String: Any]] = []
                while index < lines.count {
                    if let current = listItem(lines[index]), current.numbered == numbered {
                        let node: [String: Any] = ["content": annotated(current.text)]
                        appendListItem(node, depth: current.depth, to: &items)
                        index += 1
                    } else if lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                              let next = lines[(index + 1)...].first(where: {
                                  !$0.trimmingCharacters(in: .whitespaces).isEmpty
                              }),
                              listItem(next)?.numbered == numbered {
                        index += 1
                    } else if lines[index].first?.isWhitespace == true,
                              !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                              !items.isEmpty {
                        appendTextToLastListItem(
                            lines[index].trimmingCharacters(in: .whitespaces), to: &items
                        )
                        index += 1
                    } else {
                        break
                    }
                }
                blocks.append(["type": "list", "listType": numbered ? "numbered" : "bullet",
                               "items": items])
                continue
            }
            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private static func appendListItem(
        _ item: [String: Any], depth: Int, to items: inout [[String: Any]]
    ) {
        guard depth > 0, !items.isEmpty else {
            items.append(item)
            return
        }
        var parent = items.removeLast()
        var children = parent["children"] as? [[String: Any]] ?? []
        appendListItem(item, depth: depth - 1, to: &children)
        parent["children"] = children
        items.append(parent)
    }

    private static func appendTextToLastListItem(
        _ continuation: String, to items: inout [[String: Any]]
    ) {
        guard !items.isEmpty else { return }
        var last = items.removeLast()
        if var children = last["children"] as? [[String: Any]], !children.isEmpty {
            appendTextToLastListItem(continuation, to: &children)
            last["children"] = children
        } else {
            let current = (last["content"] as? [String: Any])?["text"] as? String ?? ""
            last["content"] = ["text": current + " " + continuation]
        }
        items.append(last)
    }

    private static func mediaBlock(_ line: String) -> [String: Any]? {
        let isImage = line.hasPrefix("![")
        let start = isImage ? 2 : 1
        guard line.hasPrefix(isImage ? "![" : "["),
              let end = line.range(of: "]("), line.hasSuffix(")") else { return nil }
        let label = String(line.dropFirst(start)[..<end.lowerBound])
        let url = String(line[end.upperBound..<line.index(before: line.endIndex)])
        guard url.hasPrefix("media/"), !url.dropFirst(6).isEmpty else { return nil }
        var block: [String: Any] = [
            "type": isImage ? "image" : "audio",
            "mediaId": String(url.dropFirst(6)),
        ]
        if !label.isEmpty { block["caption"] = ["text": label] }
        if isImage { block["alignment"] = "center" }
        else { block["showWaveform"] = true }
        return block
    }

    private static func listItem(_ line: String) -> (numbered: Bool, depth: Int, text: String)? {
        let depth = line.prefix { $0 == " " }.count / 2
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return (false, depth, String(trimmed.dropFirst(2)))
        }
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty, trimmed.dropFirst(digits.count).first == "." else { return nil }
        return (true, depth, String(trimmed.dropFirst(digits.count + 1))
            .trimmingCharacters(in: .whitespaces))
    }

    private static func tableCells(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|"),
              trimmed.hasPrefix("|") || trimmed.hasSuffix("|") else { return nil }
        var cells = trimmed
        if cells.hasPrefix("|") { cells.removeFirst() }
        if cells.hasSuffix("|") { cells.removeLast() }
        return cells.split(
            separator: "|", omittingEmptySubsequences: false
        ).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isTableSeparator(_ cell: String) -> Bool {
        let dashes = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        return dashes.count >= 3 && dashes.allSatisfy { $0 == "-" }
    }

    private static func annotated(_ markdown: String) -> [String: Any] {
        let characters = Array(markdown)
        var text: [Character] = []
        var annotations: [[String: Any]] = []
        var footnotes: [[String: Any]] = []

        func parse(_ start: Int, _ end: Int) {
            var index = start
            while index < end {
                if index + 1 < end, characters[index] == "[", characters[index + 1] == "^",
                   let close = ((index + 2)..<end).first(where: { characters[$0] == "]" }) {
                    footnotes.append(["id": String(characters[(index + 2)..<close]),
                                      "offset": text.count])
                    index = close + 1
                    continue
                }
                if characters[index] == "[",
                   let close = ((index + 1)..<end).first(where: { characters[$0] == "]" }),
                   close + 1 < end, characters[close + 1] == "(",
                   let urlEnd = ((close + 2)..<end).first(where: { characters[$0] == ")" }) {
                    let offset = text.count
                    parse(index + 1, close)
                    let url = String(characters[(close + 2)..<urlEnd])
                    var kind = "link"
                    var data: [String: Any] = ["url": url]
                    if url.hasPrefix("lampbible://verse/"),
                       let sv = Int(url.dropFirst("lampbible://verse/".count).split(separator: "/").first ?? "") {
                        kind = "scripture"
                        data = ["sv": sv]
                        let parts = url.dropFirst("lampbible://verse/".count).split(separator: "/")
                        if parts.count > 1, let ev = Int(parts[1]) { data["ev"] = ev }
                    } else if url.hasPrefix("lampbible://strongs/") {
                        kind = "strongs"
                        data = ["strongs": String(url.dropFirst("lampbible://strongs/".count))]
                    }
                    annotations.append(["type": kind, "start": offset,
                                        "end": text.count, "data": data])
                    index = urlEnd + 1
                    continue
                }
                let marker = characters[index]
                let isEmphasisMarker = marker == "*" || marker == "_"
                let bold = index + 1 < end && isEmphasisMarker
                    && characters[index + 1] == marker
                let width = bold ? 2 : 1
                if isEmphasisMarker,
                   let close = stride(from: index + width, to: end, by: 1).first(where: { cursor in
                       characters[cursor] == marker && (width == 1 ||
                           (cursor + 1 < end && characters[cursor + 1] == marker))
                   }), close > index + width {
                    let offset = text.count
                    parse(index + width, close)
                    annotations.append(["type": "emphasis", "start": offset,
                                        "end": text.count,
                                        "data": ["style": bold ? "bold" : "italic"]])
                    index = close + width
                    continue
                }
                text.append(characters[index])
                index += 1
            }
        }
        parse(0, characters.count)
        var result: [String: Any] = ["text": String(text)]
        if !annotations.isEmpty { result["annotations"] = annotations }
        if !footnotes.isEmpty { result["footnote_refs"] = footnotes }
        return result
    }
}
