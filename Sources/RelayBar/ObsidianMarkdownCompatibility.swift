import Foundation

/// A deliberately small compatibility layer for Obsidian-flavoured reading syntax.
///
/// It translates constructs that MarkdownUI does not understand into safe GFM before
/// parsing. It never resolves a remote path, fetches an embed, or executes diagram code.
enum ObsidianMarkdownCompatibility {
    static let maximumFormulaCharacterCount = 4_096
    static let maximumCompatibilityLineCharacterCount = 64 * 1_024
    static let maximumRenderedMathCount = 256
    static let maximumFootnoteCount = 1_024
    static let maximumInternalLinkCount = 2_048
    static let maximumEmbedCount = 512
    static let maximumHighlightedCodeBlockCount = 128
    static let standaloneReferenceToken = "standalone"

    private struct Fence {
        let marker: Character
        let count: Int
    }

    private struct ListContainer {
        let contentIndent: Int
    }

    private struct ListItemLine {
        let markerIndent: Int
        let contentIndent: Int
        let contentStart: Int
        let contentIsIndentedCode: Bool
    }

    private struct MarkdownLineContext {
        let isIndentedCode: Bool
        let fenceContentStart: Int
        let listItem: ListItemLine?
    }

    private struct ListContextTracker {
        var containersByQuoteDepth: [Int: [ListContainer]] = [:]
    }

    private struct Footnote {
        let label: String
        let body: String
    }

    private struct FrontmatterProperty {
        let key: String
        var values: [String]
    }

    private struct RenderingOptions {
        let referenceToken: String
        let referenceLabels: Set<String>
        let mathValidator: @Sendable (String) -> Bool
    }

    private struct ReferenceDefinitionMatch {
        let label: String
        let consumesFollowingLine: Bool
    }

    private struct EnrichmentBudget {
        var remainingMath = maximumRenderedMathCount
        var remainingInternalLinks = maximumInternalLinkCount
        var remainingEmbeds = maximumEmbedCount
        var remainingHighlightedCodeBlocks = maximumHighlightedCodeBlockCount

        var canRenderMoreMath: Bool {
            remainingMath > 0
        }

        mutating func consumeMath() -> Bool {
            guard remainingMath > 0 else { return false }
            remainingMath -= 1
            return true
        }

        mutating func consumeInternalLink() -> Bool {
            guard remainingInternalLinks > 0 else { return false }
            remainingInternalLinks -= 1
            return true
        }

        mutating func consumeEmbed() -> Bool {
            guard remainingEmbeds > 0 else { return false }
            remainingEmbeds -= 1
            return true
        }

        mutating func consumeHighlightedCodeBlock() -> Bool {
            guard remainingHighlightedCodeBlocks > 0 else { return false }
            remainingHighlightedCodeBlocks -= 1
            return true
        }
    }

    private static let calloutExpression = try? NSRegularExpression(
        pattern: #"^([ \t]*(?:>[ \t]*)+)\[!([A-Za-z0-9_-]+)\]([+-])?(?:[ \t]+(.*))?$"#
    )

    static func renderSource(
        _ source: String,
        referenceToken: String = standaloneReferenceToken,
        mathValidator: @escaping @Sendable (String) -> Bool = { _ in true }
    ) -> String {
        guard !Task.isCancelled else { return source }
        let uncommented = strippingComments(from: source)
        guard !Task.isCancelled else { return source }
        let (frontmatter, body) = extractingFrontmatter(from: uncommented)
        guard !Task.isCancelled else { return source }
        let (bodyWithoutFootnotes, footnotes) = extractingFootnotes(from: body)
        guard !Task.isCancelled else { return source }
        let footnoteNumbers = Dictionary(
            uniqueKeysWithValues: footnotes.enumerated().map { ($0.element.label, $0.offset + 1) }
        )
        let referenceLabels = extractingReferenceLabels(
            from: bodyWithoutFootnotes
        )
        let options = RenderingOptions(
            referenceToken: referenceToken,
            referenceLabels: referenceLabels,
            mathValidator: mathValidator
        )
        var enrichmentBudget = EnrichmentBudget()

        var rendered = transformBlocks(
            in: bodyWithoutFootnotes,
            footnoteNumbers: footnoteNumbers,
            options: options,
            enrichmentBudget: &enrichmentBudget
        )
        guard !Task.isCancelled else { return source }
        if !frontmatter.isEmpty {
            rendered = frontmatter + (rendered.isEmpty ? "" : "\n\n\(rendered)")
        }

        if !footnotes.isEmpty {
            let notes = footnotes.enumerated().map { index, footnote in
                let compactBody = footnote.body
                    .split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                let transformedBody = transformInline(
                    compactBody,
                    footnoteNumbers: footnoteNumbers,
                    options: options,
                    enrichmentBudget: &enrichmentBudget
                )
                return "\(index + 1). \(transformedBody)"
            }
            rendered += rendered.isEmpty ? "" : "\n\n"
            rendered += "---\n\n#### Footnotes\n\n\(notes.joined(separator: "\n"))"
        }

        return rendered
    }

    private static func strippingComments(from source: String) -> String {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var output: [String] = []
        output.reserveCapacity(lines.count)
        var fence: Fence?
        var isInsideComment = false
        var inlineFenceLength: Int?
        var listContextTracker = ListContextTracker()
        var inlineFenceLookaheadBudget = min(
            max(source.count * 4, 1_024),
            4 * 1_024 * 1_024
        )

        for (lineIndex, line) in lines.enumerated() {
            guard !Task.isCancelled else { return source }
            if let currentFence = fence {
                output.append(line)
                if isClosingFence(line, fence: currentFence) {
                    fence = nil
                }
                continue
            }
            let context = markdownLineContext(
                for: line,
                tracker: &listContextTracker
            )
            if
                !isInsideComment,
                inlineFenceLength == nil,
                let openingFence = openingFence(
                    in: line,
                    contentStart: context.fenceContentStart
                )
            {
                output.append(line)
                fence = openingFence
                continue
            }
            if
                !isInsideComment,
                inlineFenceLength == nil,
                context.isIndentedCode
            {
                output.append(line)
                continue
            }

            let cleaned = stripCommentSegments(
                from: line,
                isInsideComment: &isInsideComment,
                inlineFenceLength: &inlineFenceLength,
                followingLines: lines.dropFirst(lineIndex + 1),
                inlineFenceLookaheadBudget: &inlineFenceLookaheadBudget
            )
            output.append(cleaned)
            if !isInsideComment, let openingFence = openingFence(in: cleaned) {
                fence = openingFence
                inlineFenceLength = nil
            }
        }

        return output.joined(separator: "\n")
    }

    private static func stripCommentSegments(
        from line: String,
        isInsideComment: inout Bool,
        inlineFenceLength: inout Int?,
        followingLines: ArraySlice<String>,
        inlineFenceLookaheadBudget: inout Int
    ) -> String {
        let characters = Array(line)
        var result = ""
        var index = 0

        while index < characters.count {
            guard !Task.isCancelled else { return line }
            if isInsideComment {
                if hasPair("%", at: index, in: characters) {
                    isInsideComment = false
                    index += 2
                } else {
                    index += 1
                }
                continue
            }

            if characters[index] == "`" {
                let runLength = repeatedCount(of: "`", at: index, in: characters)
                result.append(contentsOf: characters[index..<(index + runLength)])
                if let currentLength = inlineFenceLength {
                    if currentLength == runLength {
                        inlineFenceLength = nil
                    }
                } else if hasMatchingInlineFence(
                    length: runLength,
                    after: index + runLength,
                    in: characters,
                    followingLines: followingLines,
                    budget: &inlineFenceLookaheadBudget
                ) {
                    inlineFenceLength = runLength
                }
                index += runLength
                continue
            }

            if
                inlineFenceLength == nil,
                hasPair("%", at: index, in: characters),
                !isEscaped(index, in: characters)
            {
                if result.last?.isWhitespace == false {
                    result.append(" ")
                }
                isInsideComment = true
                index += 2
                continue
            }

            result.append(characters[index])
            index += 1
        }

        return result
    }

    private static func extractingFrontmatter(from source: String) -> (String, String) {
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return ("", source)
        }

        let searchLimit = min(lines.count, 200)
        guard let closingIndex = (1..<searchLimit).first(where: {
            let marker = lines[$0].trimmingCharacters(in: .whitespaces)
            return marker == "---" || marker == "..."
        }) else {
            return ("", source)
        }

        let renderedProperties = renderFrontmatterProperties(lines[1..<closingIndex])

        lines.removeSubrange(0...closingIndex)
        let body = lines.joined(separator: "\n")
        guard !renderedProperties.isEmpty else {
            return ("", body)
        }
        let separatedProperties = renderedProperties.enumerated().map { index, line in
            index < renderedProperties.count - 1 ? "\(line)  " : line
        }
        return (
            (["> **Properties**", ">"] + separatedProperties).joined(separator: "\n"),
            body
        )
    }

    private static func renderFrontmatterProperties(
        _ lines: ArraySlice<String>
    ) -> [String] {
        var properties: [FrontmatterProperty] = []

        for rawLine in lines {
            guard !Task.isCancelled else { return [] }
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            let isIndented = rawLine.first?.isWhitespace == true
            if
                !isIndented,
                let separator = trimmed.firstIndex(of: ":"),
                separator != trimmed.startIndex
            {
                let key = String(trimmed[..<separator])
                    .trimmingCharacters(in: .whitespaces)
                let value = normalizedFrontmatterValue(
                    String(trimmed[trimmed.index(after: separator)...]),
                    isContinuation: false
                )
                properties.append(
                    FrontmatterProperty(
                        key: key,
                        values: value.map { [$0] } ?? []
                    )
                )
                continue
            }

            if
                !properties.isEmpty,
                let value = normalizedFrontmatterValue(
                    trimmed,
                    isContinuation: true
                )
            {
                properties[properties.count - 1].values.append(value)
            } else if !isIndented {
                properties.append(FrontmatterProperty(key: trimmed, values: []))
            }
        }

        return properties.map { property in
            guard !property.values.isEmpty else {
                return "> \(codeSpan(property.key))"
            }
            let value = property.values
                .map(escapeMarkdownText)
                .joined(separator: " · ")
            return "> \(codeSpan(property.key)) — \(value)"
        }
    }

    private static func normalizedFrontmatterValue(
        _ value: String,
        isContinuation: Bool
    ) -> String? {
        var result = value.trimmingCharacters(in: .whitespaces)
        if
            isContinuation,
            result.hasPrefix("-"),
            result.count > 1
        {
            result = String(result.dropFirst())
                .trimmingCharacters(in: .whitespaces)
        }
        if ["|", "|-", "|+", ">", ">-", ">+"].contains(result) {
            return nil
        }
        return result.isEmpty || result.hasPrefix("#") ? nil : result
    }

    private static func extractingReferenceLabels(
        from source: String
    ) -> Set<String> {
        let lines = source.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        .map(String.init)
        var labels: Set<String> = []
        var fence: Fence?
        var listContextTracker = ListContextTracker()
        var previousContentAllowsDefinition = true
        var previousQuoteDepth = 0
        var index = 0

        while index < lines.count {
            guard !Task.isCancelled else { return [] }
            let line = lines[index]
            if let currentFence = fence {
                if isClosingFence(line, fence: currentFence) {
                    fence = nil
                    previousContentAllowsDefinition = true
                }
                index += 1
                continue
            }

            let context = markdownLineContext(
                for: line,
                tracker: &listContextTracker
            )
            let quoteDepth = blockquoteContext(in: Array(line)).depth
            if let openingFence = openingFence(
                in: line,
                contentStart: context.fenceContentStart
            ) {
                fence = openingFence
                previousContentAllowsDefinition = false
                previousQuoteDepth = quoteDepth
                index += 1
                continue
            }
            if context.isIndentedCode {
                previousContentAllowsDefinition = true
                previousQuoteDepth = quoteDepth
                index += 1
                continue
            }

            let startsNewContainer =
                context.listItem != nil
                || quoteDepth != previousQuoteDepth
            var lookaheadTracker = listContextTracker
            let followingLine: (line: String, context: MarkdownLineContext)?
            if index + 1 < lines.count {
                let candidate = lines[index + 1]
                followingLine = (
                    candidate,
                    markdownLineContext(
                        for: candidate,
                        tracker: &lookaheadTracker
                    )
                )
            } else {
                followingLine = nil
            }

            if
                previousContentAllowsDefinition || startsNewContainer,
                let definition = referenceDefinition(
                    in: line,
                    contentStart: context.fenceContentStart,
                    followingLine: followingLine
                )
            {
                labels.insert(definition.label)
                previousContentAllowsDefinition = true
                previousQuoteDepth = quoteDepth
                if definition.consumesFollowingLine {
                    listContextTracker = lookaheadTracker
                    index += 2
                } else {
                    index += 1
                }
                continue
            }

            previousContentAllowsDefinition = lineAllowsFollowingDefinition(
                line,
                contentStart: context.fenceContentStart
            )
            previousQuoteDepth = quoteDepth
            index += 1
        }

        return labels
    }

    private static func referenceDefinition(
        in line: String,
        contentStart: Int,
        followingLine: (line: String, context: MarkdownLineContext)?
    ) -> ReferenceDefinitionMatch? {
        let characters = Array(line)
        guard
            contentStart < characters.count,
            characters[contentStart] == "["
        else {
            return nil
        }
        var budget = min(max(characters.count * 2, 64), 8 * 1_024)
        guard
            let close = firstUnescapedCharacter(
                "]",
                after: contentStart + 1,
                in: characters,
                budget: &budget
            ),
            close + 1 < characters.count,
            characters[close + 1] == ":"
        else {
            return nil
        }
        let rawLabel = String(characters[(contentStart + 1)..<close])
        guard
            !containsUnescapedBracket(rawLabel),
            let label = normalizedReferenceLabel(rawLabel)
        else {
            return nil
        }

        let destinationStart = close + 2
        if referenceDestinationIsValid(
            in: characters,
            startingAt: destinationStart
        ) {
            return ReferenceDefinitionMatch(
                label: label,
                consumesFollowingLine: false
            )
        }

        guard
            characters[destinationStart...].allSatisfy({
                $0 == " " || $0 == "\t"
            }),
            let followingLine,
            !followingLine.context.isIndentedCode,
            openingFence(
                in: followingLine.line,
                contentStart: followingLine.context.fenceContentStart
            ) == nil,
            referenceDestinationIsValid(
                in: Array(followingLine.line),
                startingAt: followingLine.context.fenceContentStart
            )
        else {
            return nil
        }
        return ReferenceDefinitionMatch(
            label: label,
            consumesFollowingLine: true
        )
    }

    private static func referenceDestinationIsValid(
        in characters: [Character],
        startingAt start: Int
    ) -> Bool {
        var index = min(start, characters.count)
        while
            index < characters.count,
            characters[index] == " " || characters[index] == "\t"
        {
            index += 1
        }
        guard index < characters.count else { return false }

        if characters[index] == "<" {
            index += 1
            var closed = false
            while index < characters.count {
                if isEscaped(index, in: characters) {
                    index += 1
                    continue
                }
                if characters[index] == "<" {
                    return false
                }
                if characters[index] == ">" {
                    index += 1
                    closed = true
                    break
                }
                index += 1
            }
            guard closed else { return false }
        } else {
            var parenthesisDepth = 0
            let destinationStart = index
            while index < characters.count, !characters[index].isWhitespace {
                if isEscaped(index, in: characters) {
                    index += 1
                    continue
                }
                if characters[index] == "(" {
                    parenthesisDepth += 1
                } else if characters[index] == ")" {
                    guard parenthesisDepth > 0 else { return false }
                    parenthesisDepth -= 1
                }
                index += 1
            }
            guard
                index > destinationStart,
                parenthesisDepth == 0
            else {
                return false
            }
        }

        let titleStart = index
        while
            index < characters.count,
            characters[index] == " " || characters[index] == "\t"
        {
            index += 1
        }
        guard index < characters.count else { return true }
        guard index > titleStart else { return false }

        let openingTitle = characters[index]
        let closingTitle: Character
        switch openingTitle {
        case "\"": closingTitle = "\""
        case "'": closingTitle = "'"
        case "(": closingTitle = ")"
        default: return false
        }
        index += 1
        while index < characters.count {
            if isEscaped(index, in: characters) {
                index += 1
                continue
            }
            if characters[index] == closingTitle {
                index += 1
                while
                    index < characters.count,
                    characters[index] == " " || characters[index] == "\t"
                {
                    index += 1
                }
                return index == characters.count
            }
            index += 1
        }
        return false
    }

    private static func containsUnescapedBracket(_ value: String) -> Bool {
        let characters = Array(value)
        for index in characters.indices where
            (characters[index] == "[" || characters[index] == "]")
                && !isEscaped(index, in: characters)
        {
            return true
        }
        return false
    }

    private static func lineAllowsFollowingDefinition(
        _ line: String,
        contentStart: Int
    ) -> Bool {
        let characters = Array(line)
        let start = min(contentStart, characters.count)
        let content = String(characters[start...])
            .trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return true }

        if content.first == "#" {
            let markerCount = content.prefix(while: { $0 == "#" }).count
            if
                markerCount <= 6,
                markerCount == content.count
                    || content[content.index(
                        content.startIndex,
                        offsetBy: markerCount
                    )].isWhitespace
            {
                return true
            }
        }

        let compact = content.filter { !$0.isWhitespace }
        if
            compact.count >= 3,
            let marker = compact.first,
            ["*", "-", "_"].contains(marker),
            compact.allSatisfy({ $0 == marker })
        {
            return true
        }
        return !compact.isEmpty
            && compact.allSatisfy({ $0 == "=" || $0 == "-" })
    }

    private static func normalizedReferenceLabel(_ rawLabel: String) -> String? {
        guard !rawLabel.isEmpty, rawLabel.count <= 999 else { return nil }
        let collapsed = rawLabel
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.folding(
            options: .caseInsensitive,
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func extractingFootnotes(from source: String) -> (String, [Footnote]) {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var output: [String] = []
        var footnotes: [Footnote] = []
        var seenLabels: Set<String> = []
        var fence: Fence?
        var listContextTracker = ListContextTracker()
        var index = 0

        while index < lines.count {
            guard !Task.isCancelled else { return (source, []) }
            let line = lines[index]
            if let currentFence = fence {
                output.append(line)
                if isClosingFence(line, fence: currentFence) {
                    fence = nil
                }
                index += 1
                continue
            }
            let context = markdownLineContext(
                for: line,
                tracker: &listContextTracker
            )
            if let openingFence = openingFence(
                in: line,
                contentStart: context.fenceContentStart
            ) {
                fence = openingFence
                output.append(line)
                index += 1
                continue
            }
            if context.isIndentedCode {
                output.append(line)
                index += 1
                continue
            }

            guard let definition = footnoteDefinition(in: line) else {
                output.append(line)
                index += 1
                continue
            }

            var bodyParts = [definition.body]
            var nextIndex = index + 1
            while nextIndex < lines.count {
                guard !Task.isCancelled else { return (source, []) }
                let continuation = lines[nextIndex]
                if let body = footnoteContinuationBody(in: continuation) {
                    bodyParts.append(body)
                    nextIndex += 1
                } else if
                    continuation.trimmingCharacters(in: .whitespaces).isEmpty,
                    nextIndex + 1 < lines.count,
                    footnoteContinuationBody(in: lines[nextIndex + 1]) != nil
                {
                    bodyParts.append("")
                    nextIndex += 1
                } else {
                    break
                }
            }

            if
                !seenLabels.contains(definition.label),
                footnotes.count >= maximumFootnoteCount
            {
                var readableDefinition = Array(lines[index..<nextIndex])
                if !readableDefinition.isEmpty {
                    readableDefinition[0] = "\\\(readableDefinition[0])"
                }
                output.append(contentsOf: readableDefinition)
            } else if seenLabels.insert(definition.label).inserted {
                footnotes.append(
                    Footnote(label: definition.label, body: bodyParts.joined(separator: "\n"))
                )
            }
            index = nextIndex
        }

        return extractingInlineFootnotes(
            from: output.joined(separator: "\n"),
            footnotes: footnotes,
            seenLabels: seenLabels
        )
    }

    private static func footnoteContinuationBody(in line: String) -> String? {
        if line.hasPrefix("\t") {
            return String(line.dropFirst())
        }
        guard line.hasPrefix("  ") else { return nil }
        return String(line.dropFirst(2))
    }

    private static func extractingInlineFootnotes(
        from source: String,
        footnotes initialFootnotes: [Footnote],
        seenLabels initialSeenLabels: Set<String>
    ) -> (String, [Footnote]) {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var output: [String] = []
        output.reserveCapacity(lines.count)
        var footnotes = initialFootnotes
        var seenLabels = initialSeenLabels
        var nextInlineLabel = 1
        var fence: Fence?
        var inlineFenceLength: Int?
        var listContextTracker = ListContextTracker()
        var inlineFenceLookaheadBudget = min(
            max(source.count * 4, 1_024),
            4 * 1_024 * 1_024
        )

        for (lineIndex, line) in lines.enumerated() {
            guard !Task.isCancelled else { return (source, initialFootnotes) }
            if let currentFence = fence {
                output.append(line)
                if isClosingFence(line, fence: currentFence) {
                    fence = nil
                }
                continue
            }
            let context = markdownLineContext(
                for: line,
                tracker: &listContextTracker
            )
            if
                inlineFenceLength == nil,
                let openingFence = openingFence(
                    in: line,
                    contentStart: context.fenceContentStart
                )
            {
                fence = openingFence
                output.append(line)
                continue
            }
            if inlineFenceLength == nil, context.isIndentedCode {
                output.append(line)
                continue
            }

            let characters = Array(line)
            guard characters.count <= maximumCompatibilityLineCharacterCount else {
                output.append(line)
                continue
            }
            var renderedLine = ""
            var index = 0
            var lookaheadBudget = min(max(characters.count * 4, 1_024), 256 * 1_024)

            while index < characters.count {
                guard !Task.isCancelled else { return (source, initialFootnotes) }
                if characters[index] == "`" {
                    let runLength = repeatedCount(of: "`", at: index, in: characters)
                    renderedLine.append(contentsOf: characters[index..<(index + runLength)])
                    if let currentLength = inlineFenceLength {
                        if currentLength == runLength {
                            inlineFenceLength = nil
                        }
                    } else if hasMatchingInlineFence(
                        length: runLength,
                        after: index + runLength,
                        in: characters,
                        followingLines: lines.dropFirst(lineIndex + 1),
                        budget: &inlineFenceLookaheadBudget
                    ) {
                        inlineFenceLength = runLength
                    }
                    index += runLength
                    continue
                }

                guard inlineFenceLength == nil else {
                    renderedLine.append(characters[index])
                    index += 1
                    continue
                }

                if characters[index] == "\\", index + 1 < characters.count {
                    renderedLine.append(characters[index])
                    renderedLine.append(characters[index + 1])
                    index += 2
                    continue
                }

                if
                    hasSequence("^[", at: index, in: characters),
                    !isEscaped(index, in: characters),
                    let close = matchingClosingBracket(
                        after: index + 2,
                        in: characters,
                        budget: &lookaheadBudget
                    )
                {
                    let body = String(characters[(index + 2)..<close])
                        .trimmingCharacters(in: .whitespaces)
                    if
                        !body.isEmpty,
                        body.count <= maximumFormulaCharacterCount,
                        footnotes.count < maximumFootnoteCount
                    {
                        var label: String
                        repeat {
                            label = "relaybar-inline-\(nextInlineLabel)"
                            nextInlineLabel += 1
                        } while seenLabels.contains(label)
                        seenLabels.insert(label)
                        footnotes.append(Footnote(label: label, body: body))
                        renderedLine += "[^\(label)]"
                    } else {
                        renderedLine.append(contentsOf: characters[index...close])
                    }
                    index = close + 1
                    continue
                }

                renderedLine.append(characters[index])
                index += 1
            }
            output.append(renderedLine)
        }

        return (output.joined(separator: "\n"), footnotes)
    }

    private static func footnoteDefinition(in line: String) -> (label: String, body: String)? {
        guard line.hasPrefix("[^"), let close = line.range(of: "]:") else {
            return nil
        }
        let labelStart = line.index(line.startIndex, offsetBy: 2)
        guard labelStart < close.lowerBound else { return nil }
        let label = String(line[labelStart..<close.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        let body = String(line[close.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (label, body)
    }

    private static func transformBlocks(
        in source: String,
        footnoteNumbers: [String: Int],
        options: RenderingOptions,
        enrichmentBudget: inout EnrichmentBudget
    ) -> String {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var output: [String] = []
        output.reserveCapacity(lines.count)
        var fence: Fence?
        var inlineFenceLength: Int?
        var inlineFenceLookaheadBudget = min(
            max(source.count * 4, 1_024),
            4 * 1_024 * 1_024
        )
        var index = 0
        var listContextTracker = ListContextTracker()

        while index < lines.count {
            guard !Task.isCancelled else { return source }
            let line = lines[index]
            if let currentFence = fence {
                output.append(line)
                if isClosingFence(line, fence: currentFence) {
                    fence = nil
                }
                index += 1
                continue
            }
            let context = markdownLineContext(
                for: line,
                tracker: &listContextTracker
            )
            if
                inlineFenceLength == nil,
                let openingFence = openingFence(
                    in: line,
                    contentStart: context.fenceContentStart
                )
            {
                fence = openingFence
                output.append(
                    boundedOpeningFenceLine(
                        line,
                        fence: openingFence,
                        contentStart: context.fenceContentStart,
                        enrichmentBudget: &enrichmentBudget
                    )
                )
                index += 1
                continue
            }
            if
                inlineFenceLength == nil,
                context.isIndentedCode
            {
                output.append(line)
                index += 1
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inlineFenceLength == nil, trimmed == "$$" {
                var formulaLines: [String] = []
                var closingIndex: Int?
                var candidate = index + 1
                while candidate < lines.count {
                    guard !Task.isCancelled else { return source }
                    if lines[candidate].trimmingCharacters(in: .whitespaces) == "$$" {
                        closingIndex = candidate
                        break
                    }
                    formulaLines.append(lines[candidate])
                    candidate += 1
                }
                if let closingIndex {
                    let formula = formulaLines.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if
                        let renderedFormula = mathImageMarkdown(
                            formula: formula,
                            display: true,
                            options: options,
                            enrichmentBudget: &enrichmentBudget
                        )
                    {
                        output.append(renderedFormula)
                    } else {
                        output.append(contentsOf: lines[index...closingIndex])
                    }
                    index = closingIndex + 1
                    continue
                }
            } else if
                inlineFenceLength == nil,
                trimmed.hasPrefix("$$"),
                trimmed.hasSuffix("$$"),
                trimmed.count > 4
            {
                let formula = String(trimmed.dropFirst(2).dropLast(2))
                    .trimmingCharacters(in: .whitespaces)
                output.append(
                    mathImageMarkdown(
                        formula: formula,
                        display: true,
                        options: options,
                        enrichmentBudget: &enrichmentBudget
                    ) ?? line
                )
                index += 1
                continue
            }

            let taskLine = inlineFenceLength == nil
                ? transformObsidianTaskMarker(
                    line,
                    listItem: context.listItem
                )
                : line
            let calloutLine = inlineFenceLength == nil
                ? transformCallout(taskLine)
                : taskLine
            output.append(
                transformInline(
                    calloutLine,
                    footnoteNumbers: footnoteNumbers,
                    inlineFenceLength: &inlineFenceLength,
                    followingLines: lines.dropFirst(index + 1),
                    inlineFenceLookaheadBudget: &inlineFenceLookaheadBudget,
                    options: options,
                    enrichmentBudget: &enrichmentBudget
                )
            )
            index += 1
        }

        return output.joined(separator: "\n")
    }

    private static func transformObsidianTaskMarker(
        _ line: String,
        listItem: ListItemLine?
    ) -> String {
        var characters = Array(line)
        guard let listItem, !listItem.contentIsIndentedCode else {
            return line
        }
        let contentStart = listItem.contentStart
        guard
            contentStart + 2 < characters.count,
            characters[contentStart] == "[",
            characters[contentStart + 2] == "]",
            !characters[contentStart + 1].isWhitespace,
            contentStart + 3 == characters.count
                || characters[contentStart + 3].isWhitespace
        else {
            return line
        }

        let marker = characters[contentStart + 1]
        guard marker != "x", marker != "X" else { return line }
        characters[contentStart + 1] = "x"
        return String(characters)
    }

    private static func transformCallout(_ line: String) -> String {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard
            let calloutExpression,
            let match = calloutExpression.firstMatch(in: line, range: range),
            let prefixRange = Range(match.range(at: 1), in: line),
            let typeRange = Range(match.range(at: 2), in: line)
        else {
            return line
        }

        let prefix = String(line[prefixRange])
        let type = String(line[typeRange]).lowercased()
        let customTitle: String?
        if
            match.range(at: 4).location != NSNotFound,
            let titleRange = Range(match.range(at: 4), in: line)
        {
            let title = String(line[titleRange]).trimmingCharacters(in: .whitespaces)
            customTitle = title.isEmpty ? nil : title
        } else {
            customTitle = nil
        }
        let title = customTitle ?? type
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
        return "\(prefix)**\(calloutSymbol(for: type)) \(title)**  "
    }

    private static func calloutSymbol(for type: String) -> String {
        switch type {
        case "note": return "✎"
        case "abstract", "summary", "tldr": return "▤"
        case "info": return "ⓘ"
        case "todo": return "☑︎"
        case "tip", "hint", "important": return "💡"
        case "success", "check", "done": return "✓"
        case "question", "help", "faq": return "?"
        case "warning", "caution", "attention": return "⚠︎"
        case "failure", "fail", "missing": return "✕"
        case "danger", "error": return "⛔︎"
        case "bug": return "🐞"
        case "example": return "◇"
        case "quote", "cite": return "❝"
        default: return "ⓘ"
        }
    }

    private static func transformInline(
        _ line: String,
        footnoteNumbers: [String: Int],
        options: RenderingOptions,
        enrichmentBudget: inout EnrichmentBudget
    ) -> String {
        var inlineFenceLength: Int?
        var inlineFenceLookaheadBudget = max(line.count * 4, 1_024)
        return transformInline(
            line,
            footnoteNumbers: footnoteNumbers,
            inlineFenceLength: &inlineFenceLength,
            followingLines: [],
            inlineFenceLookaheadBudget: &inlineFenceLookaheadBudget,
            options: options,
            enrichmentBudget: &enrichmentBudget
        )
    }

    private static func transformInline(
        _ line: String,
        footnoteNumbers: [String: Int],
        inlineFenceLength: inout Int?,
        followingLines: ArraySlice<String>,
        inlineFenceLookaheadBudget: inout Int,
        options: RenderingOptions,
        enrichmentBudget: inout EnrichmentBudget
    ) -> String {
        let compatibilityEnabled = line.count <= maximumCompatibilityLineCharacterCount
        let characters = Array(line)
        let blockIdentifierStart = compatibilityEnabled
            ? trailingBlockIdentifierStart(in: characters)
            : nil
        var output = ""
        var index = 0
        var lookaheadBudget = min(max(characters.count * 4, 1_024), 256 * 1_024)

        while index < characters.count {
            guard !Task.isCancelled else { return line }
            if characters[index] == "`" {
                let runLength = repeatedCount(of: "`", at: index, in: characters)
                output.append(contentsOf: characters[index..<(index + runLength)])
                if let currentLength = inlineFenceLength {
                    if currentLength == runLength {
                        inlineFenceLength = nil
                    }
                } else if hasMatchingInlineFence(
                    length: runLength,
                    after: index + runLength,
                    in: characters,
                    followingLines: followingLines,
                    budget: &inlineFenceLookaheadBudget
                ) {
                    inlineFenceLength = runLength
                }
                index += runLength
                continue
            }

            guard inlineFenceLength == nil else {
                output.append(characters[index])
                index += 1
                continue
            }

            if blockIdentifierStart == index {
                break
            }

            if characters[index] == "\\", index + 1 < characters.count {
                output.append(characters[index])
                output.append(characters[index + 1])
                index += 2
                continue
            }

            if
                compatibilityEnabled,
                hasSequence("![[", at: index, in: characters),
                let close = firstSequence(
                    "]]",
                    after: index + 3,
                    in: characters,
                    budget: &lookaheadBudget
                )
            {
                let raw = String(characters[(index + 3)..<close])
                let target = wikiReferenceParts(in: raw).target
                    .trimmingCharacters(in: .whitespaces)
                if
                    !target.isEmpty,
                    target.count <= maximumFormulaCharacterCount
                {
                    if enrichmentBudget.consumeEmbed() {
                        output += "**Embedded file not loaded:** \(codeSpan(target))"
                    } else {
                        output.append(contentsOf: characters[index..<(close + 2)])
                    }
                    index = close + 2
                    continue
                }
            }

            if
                compatibilityEnabled,
                hasSequence("[[", at: index, in: characters),
                let close = firstSequence(
                    "]]",
                    after: index + 2,
                    in: characters,
                    budget: &lookaheadBudget
                )
            {
                let raw = String(characters[(index + 2)..<close])
                let parts = wikiReferenceParts(in: raw)
                let target = parts.target.trimmingCharacters(in: .whitespaces)
                let label = (parts.label ?? target)
                    .trimmingCharacters(in: .whitespaces)
                if
                    !target.isEmpty,
                    !label.isEmpty,
                    target.count <= maximumFormulaCharacterCount,
                    enrichmentBudget.consumeInternalLink(),
                    let url = internalURL(
                        scheme: "relaybar-wiki",
                        kind: "open",
                        value: target,
                        referenceToken: options.referenceToken
                    )
                {
                    output += "[\(escapeMarkdownText(label))](\(url.absoluteString))"
                    index = close + 2
                    continue
                } else if !target.isEmpty, !label.isEmpty {
                    output.append(contentsOf: characters[index..<(close + 2)])
                    index = close + 2
                    continue
                }
            }

            if
                compatibilityEnabled,
                hasSequence("[^", at: index, in: characters),
                let close = firstCharacter(
                    "]",
                    after: index + 2,
                    in: characters,
                    budget: &lookaheadBudget
                )
            {
                let label = String(characters[(index + 2)..<close])
                if
                    let number = footnoteNumbers[label],
                    label.count <= maximumFormulaCharacterCount,
                    enrichmentBudget.consumeInternalLink(),
                    let url = internalURL(
                        scheme: "relaybar-footnote",
                        kind: "note",
                        value: label,
                        referenceToken: options.referenceToken
                    )
                {
                    output += "[\(superscript(number))](\(url.absoluteString))"
                    index = close + 1
                    continue
                } else if footnoteNumbers[label] != nil {
                    output.append(contentsOf: characters[index...close])
                    index = close + 1
                    continue
                }
            }

            if
                compatibilityEnabled,
                let image = referenceMarkdownImage(
                    at: index,
                    in: characters,
                    referenceLabels: options.referenceLabels,
                    budget: &lookaheadBudget
                )
            {
                output += markdownImagePlaceholder(
                    label: String(
                        characters[image.labelStart..<image.labelEnd]
                    ),
                    source: String(characters[index...image.end]),
                    enrichmentBudget: &enrichmentBudget
                )
                index = image.end + 1
                continue
            }

            if let link = standardMarkdownLink(
                at: index,
                in: characters,
                budget: &lookaheadBudget
            ) {
                if hasSequence("![", at: index, in: characters) {
                    output += markdownImagePlaceholder(
                        label: String(
                            characters[link.labelStart..<link.labelEnd]
                        ),
                        source: String(characters[index...link.end]),
                        enrichmentBudget: &enrichmentBudget
                    )
                    index = link.end + 1
                    continue
                }
                output.append(contentsOf: characters[index..<link.labelStart])
                output += escapingRawHTML(
                    in: characters[link.labelStart..<link.labelEnd]
                )
                output.append(contentsOf: characters[link.labelEnd...link.end])
                index = link.end + 1
                continue
            }

            if
                characters[index] == "<",
                let close = firstUnescapedCharacter(
                    ">",
                    after: index + 1,
                    in: characters,
                    budget: &lookaheadBudget
                )
            {
                let value = String(characters[(index + 1)..<close])
                if isPermittedAutolinkSource(value) {
                    output.append(contentsOf: characters[index...close])
                } else {
                    output += "&lt;\(escapeHTMLText(value))>"
                }
                index = close + 1
                continue
            } else if
                characters[index] == "<",
                isPlausibleRawHTMLStart(at: index, in: characters)
            {
                // Escaping the opening bracket is enough to stop a tag that
                // continues on a later line from becoming a raw HTML node.
                output += "&lt;"
                index += 1
                continue
            }

            if
                compatibilityEnabled,
                hasSequence("==", at: index, in: characters),
                isHighlightBoundary(before: index, in: characters),
                let close = firstSequence(
                    "==",
                    after: index + 2,
                    in: characters,
                    budget: &lookaheadBudget
                ),
                isHighlightBoundary(after: close + 2, in: characters)
            {
                let highlighted = String(characters[(index + 2)..<close])
                if
                    !highlighted.trimmingCharacters(in: .whitespaces).isEmpty,
                    highlighted.count <= maximumFormulaCharacterCount
                {
                    output += "**\(highlighted)**"
                    index = close + 2
                    continue
                }
            }

            if
                compatibilityEnabled,
                characters[index] == "$",
                (index + 1 >= characters.count || characters[index + 1] != "$"),
                !isEscaped(index, in: characters),
                let close = firstUnescapedCharacter(
                    "$",
                    after: index + 1,
                    in: characters,
                    budget: &lookaheadBudget
                )
            {
                let formula = String(characters[(index + 1)..<close])
                if isPlausibleInlineMath(formula) {
                    if
                        let imageMarkdown = mathImageMarkdown(
                            formula: formula,
                            display: false,
                            options: options,
                            enrichmentBudget: &enrichmentBudget
                        )
                    {
                        output += imageMarkdown
                    } else {
                        output.append(contentsOf: characters[index...close])
                    }
                    index = close + 1
                    continue
                }
            }

            if
                compatibilityEnabled,
                let tag = obsidianTag(
                    at: index,
                    in: characters,
                    lookbehindBudget: &lookaheadBudget
                )
            {
                if
                    enrichmentBudget.consumeInternalLink(),
                    let url = internalURL(
                        scheme: "relaybar-tag",
                        kind: "open",
                        value: tag.value,
                        referenceToken: options.referenceToken
                    )
                {
                    output += "[\(escapeMarkdownText("#\(tag.value)"))]"
                        + "(\(url.absoluteString))"
                } else {
                    output.append(contentsOf: characters[index...tag.end])
                }
                index = tag.end + 1
                continue
            }

            output.append(characters[index])
            index += 1
        }

        return output
    }

    private static func wikiReferenceParts(in raw: String) -> (target: String, label: String?) {
        let characters = Array(raw)
        var target = ""
        var label = ""
        var hasLabel = false
        var index = 0

        while index < characters.count {
            let isEscapedPipe =
                characters[index] == "\\"
                && index + 1 < characters.count
                && characters[index + 1] == "|"
            if !hasLabel, characters[index] == "|" || isEscapedPipe {
                hasLabel = true
                index += isEscapedPipe ? 2 : 1
                continue
            }
            if hasLabel, isEscapedPipe {
                label.append("|")
                index += 2
                continue
            }

            if hasLabel {
                label.append(characters[index])
            } else {
                target.append(characters[index])
            }
            index += 1
        }

        return (target, hasLabel ? label : nil)
    }

    private static func trailingBlockIdentifierStart(in characters: [Character]) -> Int? {
        guard !characters.isEmpty else { return nil }
        var end = characters.count
        while end > 0, characters[end - 1].isWhitespace {
            end -= 1
        }
        guard end > 0 else { return nil }

        var identifierStart = end
        while
            identifierStart > 0,
            isBlockIdentifierCharacter(characters[identifierStart - 1])
        {
            identifierStart -= 1
        }
        guard
            identifierStart < end,
            identifierStart > 0,
            characters[identifierStart - 1] == "^"
        else {
            return nil
        }

        let caretIndex = identifierStart - 1
        guard !isEscaped(caretIndex, in: characters) else { return nil }
        if caretIndex == 0 {
            return 0
        }

        let contentStart = blockquoteContentStart(in: characters)
        if caretIndex == contentStart {
            return 0
        }
        guard characters[caretIndex - 1].isWhitespace else { return nil }

        var suffixStart = caretIndex
        while suffixStart > 0, characters[suffixStart - 1].isWhitespace {
            suffixStart -= 1
        }
        return suffixStart
    }

    private static func isBlockIdentifierCharacter(_ character: Character) -> Bool {
        guard
            character.unicodeScalars.count == 1,
            let scalar = character.unicodeScalars.first
        else {
            return false
        }
        return (48...57).contains(scalar.value)
            || (65...90).contains(scalar.value)
            || (97...122).contains(scalar.value)
            || scalar == "-"
    }

    private static func isPermittedAutolinkSource(_ value: String) -> Bool {
        guard
            !value.isEmpty,
            !value.contains(where: \.isWhitespace)
        else {
            return false
        }

        if
            let url = URL(string: value),
            let scheme = url.scheme?.lowercased(),
            ["http", "https", "mailto"].contains(scheme)
        {
            if scheme == "mailto" {
                return hasMailRecipient(in: value)
            }
            return url.user == nil
                && url.password == nil
                && url.host?.isEmpty == false
        }

        let emailParts = value.split(
            separator: "@",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        return emailParts.count == 2
            && !emailParts[0].isEmpty
            && emailParts[1].contains(".")
    }

    private static func hasMailRecipient(in value: String) -> Bool {
        guard let separator = value.firstIndex(of: ":") else {
            return false
        }
        let payload = value[value.index(after: separator)...]
        let recipient = payload.prefix { $0 != "?" && $0 != "#" }
        return !recipient.isEmpty
    }

    private static func escapeHTMLText(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
    }

    private static func isPlausibleInlineMath(_ value: String) -> Bool {
        guard
            !value.isEmpty,
            value.count <= maximumFormulaCharacterCount,
            value.first?.isWhitespace == false,
            value.last?.isWhitespace == false,
            !value.contains("\n")
        else {
            return false
        }

        if value.count == 1, value.first?.isLetter == true {
            return true
        }
        let mathematicalSignals = CharacterSet(charactersIn: #"\\^_{}=+-*/<>∑∫√≈≠≤≥"#)
        return value.unicodeScalars.contains { mathematicalSignals.contains($0) }
    }

    private static func mathImageMarkdown(
        formula: String,
        display: Bool,
        options: RenderingOptions,
        enrichmentBudget: inout EnrichmentBudget
    ) -> String? {
        let trimmed = formula.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            trimmed.count <= maximumFormulaCharacterCount,
            enrichmentBudget.canRenderMoreMath,
            options.mathValidator(trimmed),
            enrichmentBudget.consumeMath(),
            let url = internalURL(
                scheme: "relaybar-math",
                kind: display ? "display" : "inline",
                value: trimmed,
                referenceToken: options.referenceToken
            )
        else {
            return nil
        }
        return "![Math formula](\(url.absoluteString))"
    }

    static func internalValue(
        from url: URL,
        expectedScheme: String,
        referenceToken: String? = nil
    ) -> (kind: String, value: String)? {
        let pathComponents = url.pathComponents
        guard
            url.scheme?.lowercased() == expectedScheme,
            let kind = url.host,
            pathComponents.count == 3,
            pathComponents[0] == "/",
            referenceToken == nil || pathComponents[1] == referenceToken,
            let data = decodeURLSafeBase64(pathComponents[2]),
            data.count <= maximumFormulaCharacterCount * 4,
            let value = String(data: data, encoding: .utf8),
            value.count <= maximumFormulaCharacterCount
        else {
            return nil
        }
        return (kind, value)
    }

    private static func internalURL(
        scheme: String,
        kind: String,
        value: String,
        referenceToken: String
    ) -> URL? {
        guard
            value.count <= maximumFormulaCharacterCount,
            isSafeReferenceToken(referenceToken)
        else {
            return nil
        }
        let valueToken = Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(string: "\(scheme)://\(kind)/\(referenceToken)/\(valueToken)")
    }

    private static func isSafeReferenceToken(_ token: String) -> Bool {
        guard !token.isEmpty, token.count <= 128 else { return false }
        return token.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value)
                || (65...90).contains(scalar.value)
                || (97...122).contains(scalar.value)
                || scalar == "-"
                || scalar == "_"
        }
    }

    private static func decodeURLSafeBase64(_ token: String) -> Data? {
        var base64 = token
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }

    private static func boundedOpeningFenceLine(
        _ line: String,
        fence: Fence,
        contentStart: Int,
        enrichmentBudget: inout EnrichmentBudget
    ) -> String {
        let characters = Array(line)
        let markerIndex = min(contentStart, characters.count)
        let infoStart = min(markerIndex + fence.count, characters.count)
        let info = String(characters[infoStart...])
            .trimmingCharacters(in: .whitespaces)
        guard !info.isEmpty else { return line }

        let language = info
            .split(whereSeparator: \.isWhitespace)
            .first?
            .lowercased()
        if language == "mermaid" || enrichmentBudget.consumeHighlightedCodeBlock() {
            return line
        }

        return String(characters[..<markerIndex])
            + String(repeating: String(fence.marker), count: fence.count)
    }

    private static func openingFence(
        in line: String,
        contentStart: Int? = nil
    ) -> Fence? {
        let characters = Array(line)
        var index: Int
        if let contentStart {
            index = min(contentStart, characters.count)
        } else {
            index = containerContentStart(in: characters)
            let maximumMarkerIndex = index + 3
            while
                index < characters.count,
                characters[index] == " ",
                index < maximumMarkerIndex
            {
                index += 1
            }
        }
        guard index < characters.count, characters[index] == "`" || characters[index] == "~" else {
            return nil
        }
        let count = repeatedCount(of: characters[index], at: index, in: characters)
        guard count >= 3 else { return nil }
        return Fence(marker: characters[index], count: count)
    }

    private static func isClosingFence(_ line: String, fence: Fence) -> Bool {
        let characters = Array(line)
        let contentStart = blockquoteContentStart(in: characters)
        let trimmed = String(characters[contentStart...])
            .trimmingCharacters(in: .whitespaces)
        let trimmedCharacters = Array(trimmed)
        guard trimmedCharacters.first == fence.marker else { return false }
        let count = repeatedCount(of: fence.marker, at: 0, in: trimmedCharacters)
        guard count >= fence.count else { return false }
        return trimmedCharacters.dropFirst(count).allSatisfy(\.isWhitespace)
    }

    private static func isIndentedCodeLine(_ line: String) -> Bool {
        let characters = Array(line)
        var index = containerContentStart(in: characters)
        guard index < characters.count else { return false }
        if characters[index] == "\t" {
            return true
        }

        var spaceCount = 0
        while index < characters.count, characters[index] == " " {
            spaceCount += 1
            index += 1
        }
        return spaceCount >= 4
    }

    private static func markdownLineContext(
        for line: String,
        tracker: inout ListContextTracker
    ) -> MarkdownLineContext {
        let characters = Array(line)
        let quote = blockquoteContext(in: characters)
        tracker.containersByQuoteDepth = tracker.containersByQuoteDepth.filter {
            $0.key <= quote.depth
        }

        let indentation = indentation(
            from: quote.contentStart,
            in: characters
        )
        let isBlank = indentation.contentStart >= characters.count
        var containers = tracker.containersByQuoteDepth[quote.depth] ?? []

        if !isBlank,
           let candidate = parsedListItem(
               at: indentation.contentStart,
               markerIndent: indentation.columns,
               in: characters
           )
        {
            while
                let container = containers.last,
                candidate.markerIndent < container.contentIndent
            {
                containers.removeLast()
            }

            let isValidItem: Bool
            if let parent = containers.last {
                isValidItem =
                    candidate.markerIndent >= parent.contentIndent
                    && candidate.markerIndent <= parent.contentIndent + 3
            } else {
                isValidItem = candidate.markerIndent <= 3
            }

            if isValidItem {
                containers.append(
                    ListContainer(contentIndent: candidate.contentIndent)
                )
                tracker.containersByQuoteDepth[quote.depth] = containers
                return MarkdownLineContext(
                    isIndentedCode: candidate.contentIsIndentedCode,
                    fenceContentStart: candidate.contentStart,
                    listItem: candidate
                )
            }
        }

        if !isBlank {
            while
                let container = containers.last,
                indentation.columns < container.contentIndent
            {
                containers.removeLast()
            }
            tracker.containersByQuoteDepth[quote.depth] = containers
        }

        let containerIndent = containers.last?.contentIndent ?? 0
        return MarkdownLineContext(
            isIndentedCode:
                !isBlank
                && indentation.columns >= containerIndent + 4,
            fenceContentStart: indentation.contentStart,
            listItem: nil
        )
    }

    private static func parsedListItem(
        at markerIndex: Int,
        markerIndent: Int,
        in characters: [Character]
    ) -> ListItemLine? {
        guard markerIndex < characters.count else { return nil }
        var markerEnd = markerIndex

        if ["-", "+", "*"].contains(characters[markerEnd]) {
            markerEnd += 1
        } else {
            var digitCount = 0
            while
                markerEnd < characters.count,
                characters[markerEnd].isNumber,
                digitCount < 9
            {
                markerEnd += 1
                digitCount += 1
            }
            guard
                digitCount > 0,
                markerEnd < characters.count,
                characters[markerEnd] == "."
                    || characters[markerEnd] == ")"
            else {
                return nil
            }
            markerEnd += 1
        }

        let markerWidth = markerEnd - markerIndex
        guard markerEnd < characters.count else {
            return ListItemLine(
                markerIndent: markerIndent,
                contentIndent: markerIndent + markerWidth + 1,
                contentStart: markerEnd,
                contentIsIndentedCode: false
            )
        }
        guard
            characters[markerEnd] == " "
                || characters[markerEnd] == "\t"
        else {
            return nil
        }

        let markerEndColumn = markerIndent + markerWidth
        let content = indentation(
            from: markerEnd,
            startingColumn: markerEndColumn,
            in: characters
        )
        let whitespaceColumns = content.columns - markerEndColumn
        let contentIndent = markerIndent
            + markerWidth
            + (whitespaceColumns <= 4 ? whitespaceColumns : 1)
        let actualContentIndent = markerIndent + markerWidth + whitespaceColumns
        return ListItemLine(
            markerIndent: markerIndent,
            contentIndent: contentIndent,
            contentStart: content.contentStart,
            contentIsIndentedCode:
                content.contentStart < characters.count
                && actualContentIndent >= contentIndent + 4
        )
    }

    private static func indentation(
        from start: Int,
        startingColumn: Int = 0,
        in characters: [Character]
    ) -> (columns: Int, contentStart: Int) {
        var index = start
        var columns = startingColumn
        while index < characters.count {
            if characters[index] == " " {
                columns += 1
            } else if characters[index] == "\t" {
                columns += 4 - (columns % 4)
            } else {
                break
            }
            index += 1
        }
        return (columns, index)
    }

    /// Returns the first content character after any CommonMark blockquote
    /// markers while preserving ordinary content indentation.
    private static func blockquoteContentStart(in characters: [Character]) -> Int {
        blockquoteContext(in: characters).contentStart
    }

    private static func blockquoteContext(
        in characters: [Character]
    ) -> (depth: Int, contentStart: Int) {
        var index = 0
        var depth = 0

        while index < characters.count {
            guard !Task.isCancelled else { return (depth, index) }
            var markerIndex = index
            var leadingSpaces = 0
            while
                markerIndex < characters.count,
                characters[markerIndex] == " ",
                leadingSpaces < 3
            {
                markerIndex += 1
                leadingSpaces += 1
            }
            guard markerIndex < characters.count, characters[markerIndex] == ">" else {
                break
            }

            index = markerIndex + 1
            depth += 1
            if index < characters.count, characters[index] == " " {
                index += 1
            }
        }

        return (depth, index)
    }

    /// Returns content after blockquote and list markers on a container's
    /// opening line. Continuation lines retain their ordinary indentation.
    private static func containerContentStart(in characters: [Character]) -> Int {
        var index = 0

        while index < characters.count {
            guard !Task.isCancelled else { return index }
            var markerIndex = index
            var leadingSpaces = 0
            while
                markerIndex < characters.count,
                characters[markerIndex] == " ",
                leadingSpaces < 3
            {
                markerIndex += 1
                leadingSpaces += 1
            }
            guard markerIndex < characters.count else { break }

            if characters[markerIndex] == ">" {
                index = markerIndex + 1
                if index < characters.count, characters[index] == " " {
                    index += 1
                }
                continue
            }

            guard
                let contentStart = listItemContentStart(
                    at: markerIndex,
                    in: characters
                )
            else {
                break
            }
            index = contentStart
        }

        return index
    }

    private static func listItemContentStart(
        at markerIndex: Int,
        in characters: [Character]
    ) -> Int? {
        guard markerIndex < characters.count else { return nil }
        var index = markerIndex

        if ["-", "+", "*"].contains(characters[index]) {
            index += 1
        } else {
            var digitCount = 0
            while
                index < characters.count,
                characters[index].isNumber,
                digitCount < 9
            {
                digitCount += 1
                index += 1
            }
            guard
                digitCount > 0,
                index < characters.count,
                characters[index] == "." || characters[index] == ")"
            else {
                return nil
            }
            index += 1
        }

        guard
            index < characters.count,
            characters[index] == " " || characters[index] == "\t"
        else {
            return nil
        }
        return index + 1
    }

    private static func escapeMarkdownText(_ value: String) -> String {
        var output = ""
        output.reserveCapacity(value.count)
        for character in value {
            if "\\`*_{}[]()<>#+-.!|".contains(character) {
                output.append("\\")
            }
            output.append(character)
        }
        return output
    }

    private static func codeSpan(_ value: String) -> String {
        let characters = Array(value)
        var longestRun = 0
        var index = 0
        while index < characters.count {
            if characters[index] == "`" {
                let run = repeatedCount(of: "`", at: index, in: characters)
                longestRun = max(longestRun, run)
                index += run
            } else {
                index += 1
            }
        }
        let fence = String(repeating: "`", count: longestRun + 1)
        let padding = value.first == "`" || value.last == "`" ? " " : ""
        return "\(fence)\(padding)\(value)\(padding)\(fence)"
    }

    private static func superscript(_ number: Int) -> String {
        let digits: [Character: Character] = [
            "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
            "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹"
        ]
        return String(String(number).map { digits[$0] ?? $0 })
    }

    private static func hasPair(
        _ character: Character,
        at index: Int,
        in characters: [Character]
    ) -> Bool {
        index + 1 < characters.count
            && characters[index] == character
            && characters[index + 1] == character
    }

    private static func hasSequence(
        _ sequence: String,
        at index: Int,
        in characters: [Character]
    ) -> Bool {
        let target = Array(sequence)
        guard index + target.count <= characters.count else { return false }
        return Array(characters[index..<(index + target.count)]) == target
    }

    private static func firstSequence(
        _ sequence: String,
        after start: Int,
        in characters: [Character],
        budget: inout Int
    ) -> Int? {
        guard start < characters.count, budget > 0 else { return nil }
        var index = start
        while index < characters.count, budget > 0 {
            guard !Task.isCancelled else { return nil }
            budget -= 1
            if hasSequence(sequence, at: index, in: characters), !isEscaped(index, in: characters) {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func firstCharacter(
        _ character: Character,
        after start: Int,
        in characters: [Character],
        budget: inout Int
    ) -> Int? {
        guard start < characters.count, budget > 0 else { return nil }
        for index in start..<characters.count {
            guard budget > 0 else { return nil }
            budget -= 1
            if characters[index] == character {
                return index
            }
        }
        return nil
    }

    private static func firstUnescapedCharacter(
        _ character: Character,
        after start: Int,
        in characters: [Character],
        budget: inout Int
    ) -> Int? {
        guard start < characters.count, budget > 0 else { return nil }
        for index in start..<characters.count {
            guard budget > 0 else { return nil }
            budget -= 1
            if characters[index] == character, !isEscaped(index, in: characters) {
                return index
            }
        }
        return nil
    }

    private static func matchingClosingBracket(
        after start: Int,
        in characters: [Character],
        budget: inout Int
    ) -> Int? {
        guard start < characters.count, budget > 0 else { return nil }
        var depth = 1
        var index = start
        while index < characters.count, budget > 0 {
            guard !Task.isCancelled else { return nil }
            budget -= 1
            if isEscaped(index, in: characters) {
                index += 1
                continue
            }
            if characters[index] == "[" {
                depth += 1
            } else if characters[index] == "]" {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
            index += 1
        }
        return nil
    }

    private static func hasMatchingInlineFence(
        length: Int,
        after start: Int,
        in characters: [Character],
        followingLines: ArraySlice<String>,
        budget: inout Int
    ) -> Bool {
        func containsMatch(in candidateCharacters: [Character], from start: Int) -> Bool {
            guard start < candidateCharacters.count else { return false }
            var index = start
            while index < candidateCharacters.count, budget > 0 {
                guard !Task.isCancelled else { return false }
                budget -= 1
                if candidateCharacters[index] == "`" {
                    let runLength = repeatedCount(
                        of: "`",
                        at: index,
                        in: candidateCharacters
                    )
                    if runLength == length {
                        return true
                    }
                    index += runLength
                } else {
                    index += 1
                }
            }
            return false
        }

        if containsMatch(in: characters, from: start) {
            return true
        }

        for line in followingLines {
            guard !Task.isCancelled else { return false }
            guard budget > 0 else { return false }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                return false
            }
            if openingFence(in: line) != nil
                || isIndentedCodeLine(line)
            {
                return false
            }
            if containsMatch(in: Array(line), from: 0) {
                return true
            }
        }
        return false
    }

    private static func escapingRawHTML(
        in characters: ArraySlice<Character>
    ) -> String {
        let characters = Array(characters)
        var output = ""
        var index = 0
        var inlineFenceLength: Int?
        var lookaheadBudget = max(characters.count * 2, 64)

        while index < characters.count {
            guard !Task.isCancelled else { return String(characters) }
            if characters[index] == "`" {
                let runLength = repeatedCount(of: "`", at: index, in: characters)
                output.append(contentsOf: characters[index..<(index + runLength)])
                if inlineFenceLength == runLength {
                    inlineFenceLength = nil
                } else if inlineFenceLength == nil {
                    inlineFenceLength = runLength
                }
                index += runLength
                continue
            }

            guard inlineFenceLength == nil else {
                output.append(characters[index])
                index += 1
                continue
            }

            if
                characters[index] == "<",
                let close = firstUnescapedCharacter(
                    ">",
                    after: index + 1,
                    in: characters,
                    budget: &lookaheadBudget
                )
            {
                let value = String(characters[(index + 1)..<close])
                if isPermittedAutolinkSource(value) {
                    output.append(contentsOf: characters[index...close])
                } else {
                    output += "&lt;\(escapeHTMLText(value))>"
                }
                index = close + 1
                continue
            } else if
                characters[index] == "<",
                isPlausibleRawHTMLStart(at: index, in: characters)
            {
                output += "&lt;"
                index += 1
                continue
            }

            output.append(characters[index])
            index += 1
        }

        return output
    }

    private static func isPlausibleRawHTMLStart(
        at index: Int,
        in characters: [Character]
    ) -> Bool {
        guard index + 1 < characters.count else { return false }
        let next = characters[index + 1]
        if isASCIIHTMLTagLetter(next) || next == "!" || next == "?" {
            return true
        }
        return next == "/"
            && index + 2 < characters.count
            && isASCIIHTMLTagLetter(characters[index + 2])
    }

    private static func isASCIIHTMLTagLetter(_ character: Character) -> Bool {
        guard
            character.unicodeScalars.count == 1,
            let scalar = character.unicodeScalars.first
        else {
            return false
        }
        return (65...90).contains(scalar.value)
            || (97...122).contains(scalar.value)
    }

    private static func standardMarkdownLink(
        at start: Int,
        in characters: [Character],
        budget: inout Int
    ) -> (labelStart: Int, labelEnd: Int, end: Int)? {
        let labelStart: Int
        if hasSequence("![", at: start, in: characters) {
            labelStart = start + 2
        } else if characters[start] == "[" {
            labelStart = start + 1
        } else {
            return nil
        }

        guard
            let labelEnd = matchingClosingBracket(
                after: labelStart,
                in: characters,
                budget: &budget
            ),
            labelEnd + 1 < characters.count,
            characters[labelEnd + 1] == "("
        else {
            return nil
        }

        var depth = 1
        var index = labelEnd + 2
        while index < characters.count, budget > 0 {
            guard !Task.isCancelled else { return nil }
            budget -= 1
            if isEscaped(index, in: characters) {
                index += 1
                continue
            }
            if characters[index] == "(" {
                depth += 1
            } else if characters[index] == ")" {
                depth -= 1
                if depth == 0 {
                    return (labelStart, labelEnd, index)
                }
            }
            index += 1
        }
        return nil
    }

    private static func referenceMarkdownImage(
        at start: Int,
        in characters: [Character],
        referenceLabels: Set<String>,
        budget: inout Int
    ) -> (labelStart: Int, labelEnd: Int, end: Int)? {
        guard
            !referenceLabels.isEmpty,
            hasSequence("![", at: start, in: characters)
        else {
            return nil
        }
        let labelStart = start + 2
        guard
            let labelEnd = matchingClosingBracket(
                after: labelStart,
                in: characters,
                budget: &budget
            )
        else {
            return nil
        }

        let referenceStart = labelEnd + 1
        if
            referenceStart < characters.count,
            characters[referenceStart] == "("
        {
            return nil
        }
        if
            referenceStart < characters.count,
            characters[referenceStart] == "["
        {
            guard
                let referenceEnd = firstUnescapedCharacter(
                    "]",
                    after: referenceStart + 1,
                    in: characters,
                    budget: &budget
                )
            else {
                return nil
            }
            let explicitReference = String(
                characters[(referenceStart + 1)..<referenceEnd]
            )
            let rawReference = explicitReference.isEmpty
                ? String(characters[labelStart..<labelEnd])
                : explicitReference
            guard
                let normalized = normalizedReferenceLabel(rawReference),
                referenceLabels.contains(normalized)
            else {
                return nil
            }
            return (labelStart, labelEnd, referenceEnd)
        }

        guard
            let normalized = normalizedReferenceLabel(
                String(characters[labelStart..<labelEnd])
            ),
            referenceLabels.contains(normalized)
        else {
            return nil
        }
        return (labelStart, labelEnd, labelEnd)
    }

    private static func markdownImagePlaceholder(
        label rawLabel: String,
        source: String,
        enrichmentBudget: inout EnrichmentBudget
    ) -> String {
        guard enrichmentBudget.consumeEmbed() else {
            return codeSpan(source)
        }
        let label = markdownImageDisplayLabel(from: rawLabel)
        return "**Image not loaded:** "
            + (label.isEmpty ? "Unlabelled image" : escapeMarkdownText(label))
    }

    private static func markdownImageDisplayLabel(from rawLabel: String) -> String {
        let characters = Array(rawLabel)
        for pipeIndex in characters.indices.reversed()
        where characters[pipeIndex] == "|" {
            let sizeHint = String(characters[(pipeIndex + 1)...])
                .trimmingCharacters(in: .whitespaces)
            guard isObsidianImageSizeHint(sizeHint) else { continue }

            var labelEnd = pipeIndex
            if isEscaped(pipeIndex, in: characters), pipeIndex > 0 {
                labelEnd -= 1
            }
            return String(characters[..<labelEnd])
                .trimmingCharacters(in: .whitespaces)
        }
        return rawLabel.trimmingCharacters(in: .whitespaces)
    }

    private static func isObsidianImageSizeHint(_ value: String) -> Bool {
        let dimensions = value.split(
            separator: "x",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard dimensions.count == 1 || dimensions.count == 2 else {
            return false
        }
        return dimensions.allSatisfy { dimension in
            !dimension.isEmpty && dimension.unicodeScalars.allSatisfy {
                (48...57).contains($0.value)
            }
        }
    }

    private static func obsidianTag(
        at start: Int,
        in characters: [Character],
        lookbehindBudget: inout Int
    ) -> (value: String, end: Int)? {
        guard
            start < characters.count,
            characters[start] == "#",
            !isEscaped(start, in: characters),
            isObsidianTagBoundary(before: start, in: characters),
            !isInsideURLLikeToken(
                at: start,
                in: characters,
                budget: &lookbehindBudget
            )
        else {
            return nil
        }

        var end = start + 1
        while
            end < characters.count,
            isObsidianTagCharacter(characters[end])
        {
            end += 1
        }
        guard end > start + 1 else { return nil }

        let value = String(characters[(start + 1)..<end])
        guard
            value.count <= maximumFormulaCharacterCount,
            value.first != "/",
            value.last != "/",
            !value.contains("//"),
            value.contains(where: isObsidianTagSemanticCharacter)
        else {
            return nil
        }
        return (value, end - 1)
    }

    private static func isObsidianTagBoundary(
        before index: Int,
        in characters: [Character]
    ) -> Bool {
        guard index > 0 else { return true }
        let previous = characters[index - 1]
        return !isObsidianTagCharacter(previous)
            && previous != "#"
            && previous != "\\"
    }

    private static func isInsideURLLikeToken(
        at index: Int,
        in characters: [Character],
        budget: inout Int
    ) -> Bool {
        var cursor = index
        while cursor > 0 {
            guard budget > 0 else { return true }
            budget -= 1
            let previous = characters[cursor - 1]
            if previous.isWhitespace || "([{<".contains(previous) {
                return false
            }
            if ":/?=.".contains(previous) {
                return true
            }
            cursor -= 1
        }
        return false
    }

    private static func isObsidianTagCharacter(_ character: Character) -> Bool {
        character.isLetter
            || character.isNumber
            || "_-/".contains(character)
            || isObsidianTagSymbolCharacter(character)
    }

    private static func isObsidianTagSemanticCharacter(
        _ character: Character
    ) -> Bool {
        character.isLetter
            || "_-".contains(character)
            || isObsidianTagSymbolCharacter(character)
    }

    private static func isObsidianTagSymbolCharacter(
        _ character: Character
    ) -> Bool {
        character.unicodeScalars.contains {
            $0.value > 127
                && (
                    $0.properties.isEmoji
                    || CharacterSet.symbols.contains($0)
                )
        }
    }

    private static func isHighlightBoundary(
        before index: Int,
        in characters: [Character]
    ) -> Bool {
        guard index > 0 else { return true }
        return !characters[index - 1].isLetter && !characters[index - 1].isNumber
    }

    private static func isHighlightBoundary(
        after index: Int,
        in characters: [Character]
    ) -> Bool {
        guard index < characters.count else { return true }
        return !characters[index].isLetter && !characters[index].isNumber
    }

    // The leaf scanners below carry no cancellation check of their own. Each is
    // bounded by one run or one line and is reached from a loop that already
    // polls cancellation per line, so a check here would only add a
    // concurrency-runtime call to every character of the document.
    private static func repeatedCount(
        of character: Character,
        at start: Int,
        in characters: [Character]
    ) -> Int {
        guard start < characters.count else { return 0 }
        var index = start
        while index < characters.count, characters[index] == character {
            index += 1
        }
        return index - start
    }

    private static func isEscaped(_ index: Int, in characters: [Character]) -> Bool {
        guard index > 0 else { return false }
        var slashCount = 0
        var cursor = index - 1
        while characters[cursor] == "\\" {
            slashCount += 1
            guard cursor > 0 else { break }
            cursor -= 1
        }
        return slashCount.isMultiple(of: 2) == false
    }
}
