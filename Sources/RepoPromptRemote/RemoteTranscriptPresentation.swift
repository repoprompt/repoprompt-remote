import Foundation
import RepoPromptRemoteProtocol

enum RemoteTranscriptPresentationElement: Identifiable, Equatable {
    case narrative(RemoteTranscriptItem, RemoteTranscriptSemanticKind)
    case activityGroup([RemoteTranscriptItem], exceptional: Bool)

    var id: String {
        switch self {
        case let .narrative(item, _):
            return "narrative-\(item.id.uuidString)"
        case let .activityGroup(items, exceptional):
            return "activity-\(exceptional ? "exceptional" : "ordinary")-\(items.first?.id.uuidString ?? "empty")"
        }
    }
}

enum RemoteMarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case list([RemoteMarkdownListItem])
    case blockQuote(String)
    case codeBlock(language: String?, code: String)
    case table(RemoteMarkdownTable)
    case image(alt: String, url: URL)
    case thematicBreak
}

struct RemoteMarkdownTable: Equatable {
    let header: [String]
    let rows: [[String]]
}

struct RemoteMarkdownListItem: Equatable {
    enum Marker: Equatable {
        case bullet
        case ordered(Int)
    }

    let marker: Marker
    let depth: Int
    var text: String
}

enum RemoteMarkdownDocumentParser {
    static func parse(_ markdown: String) -> [RemoteMarkdownBlock] {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [RemoteMarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            if isBlank(line) {
                index += 1
                continue
            }
            if let image = imageBlock(line) {
                blocks.append(image)
                index += 1
                continue
            }

            if index + 1 < lines.count,
               let header = tableRow(in: line),
               header.count >= 2,
               isTableDelimiterRow(lines[index + 1])
            {
                index += 2
                var rows: [[String]] = []
                while index < lines.count, let row = tableRow(in: lines[index]) {
                    rows.append(row)
                    index += 1
                }
                blocks.append(.table(RemoteMarkdownTable(header: header, rows: rows)))
                continue
            }

            if leadingIndent(in: line) >= 4 {
                var codeLines: [String] = []
                while index < lines.count {
                    if isBlank(lines[index]) {
                        guard index + 1 < lines.count, leadingIndent(in: lines[index + 1]) >= 4 else { break }
                        codeLines.append("")
                        index += 1
                    } else {
                        guard leadingIndent(in: lines[index]) >= 4 else { break }
                        codeLines.append(removingLeadingIndent(4, from: lines[index]))
                        index += 1
                    }
                }
                blocks.append(.codeBlock(language: nil, code: codeLines.joined(separator: "\n")))
                continue
            }

            if let fence = openingFence(in: line) {
                index += 1
                var codeLines: [String] = []
                while index < lines.count, !isClosingFence(lines[index], matching: fence) {
                    codeLines.append(removingLeadingIndent(fence.indentation, from: lines[index]))
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.codeBlock(
                    language: fence.language,
                    code: codeLines.joined(separator: "\n")
                ))
                continue
            }

            if let heading = heading(in: line) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if index + 1 < lines.count,
               !isBlank(line),
               let level = setextHeadingLevel(in: lines[index + 1])
            {
                blocks.append(.heading(level: level, text: normalizedInlineText([line])))
                index += 2
                continue
            }

            if isThematicBreak(line) {
                blocks.append(.thematicBreak)
                index += 1
                continue
            }

            if quoteContent(in: line) != nil {
                var quoteLines: [String] = []
                while index < lines.count, let content = quoteContent(in: lines[index]) {
                    quoteLines.append(content)
                    index += 1
                }
                blocks.append(.blockQuote(normalizedInlineText(quoteLines)))
                continue
            }

            if listItem(in: line) != nil {
                var items: [RemoteMarkdownListItem] = []
                while index < lines.count {
                    if let item = listItem(in: lines[index]) {
                        items.append(item)
                        index += 1
                        continue
                    }
                    break
                }
                blocks.append(.list(items))
                continue
            }

            var paragraphLines: [String] = []
            while index < lines.count,
                  !isBlank(lines[index]),
                  imageBlock(lines[index]) == nil,
                  !startsBlock(lines[index], previousParagraphLines: paragraphLines)
            {
                paragraphLines.append(lines[index])
                index += 1
            }
            if paragraphLines.isEmpty {
                paragraphLines.append(line)
                index += 1
            }
            blocks.append(.paragraph(normalizedInlineText(paragraphLines)))
        }

        return blocks
    }

    private static let imagePattern = try! NSRegularExpression(
        pattern: #"^!\[([^\]]*)\]\(<?(https://[^\s)>]+)>?(?:\s+"[^"]*")?\)$"#,
        options: [.caseInsensitive]
    )

    private static func imageBlock(_ line: String) -> RemoteMarkdownBlock? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard leadingIndent(in: line) < 4, text.hasPrefix("!["),
              let match = imagePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let alt = Range(match.range(at: 1), in: text),
              let destination = Range(match.range(at: 2), in: text),
              let url = URL(string: String(text[destination])),
              url.host != nil, url.user == nil, url.password == nil
        else { return nil }
        return .image(alt: String(text[alt]), url: url)
    }

    private struct Fence {
        let marker: Character
        let length: Int
        let indentation: Int
        let language: String?
    }

    private static func openingFence(in line: String) -> Fence? {
        guard leadingIndent(in: line) <= 3 else { return nil }
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
        let length = trimmed.prefix(while: { $0 == marker }).count
        guard length >= 3 else { return nil }
        let info = trimmed.dropFirst(length).trimmingCharacters(in: .whitespaces)
        return Fence(
            marker: marker,
            length: length,
            indentation: leadingIndent(in: line),
            language: info.isEmpty ? nil : info
        )
    }

    private static func isClosingFence(_ line: String, matching fence: Fence) -> Bool {
        guard leadingIndent(in: line) <= 3 else { return false }
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        let markerCount = trimmed.prefix(while: { $0 == fence.marker }).count
        guard markerCount >= fence.length else { return false }
        return trimmed.dropFirst(markerCount).allSatisfy(\.isWhitespace)
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        guard leadingIndent(in: line) <= 3 else { return nil }
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        let level = trimmed.prefix(while: { $0 == "#" }).count
        guard (1 ... 6).contains(level) else { return nil }
        let remainder = trimmed.dropFirst(level)
        guard remainder.isEmpty || remainder.first?.isWhitespace == true else { return nil }
        var text = remainder.trimmingCharacters(in: .whitespaces)
        text = text.replacingOccurrences(
            of: #"\s+#+\s*$"#,
            with: "",
            options: .regularExpression
        )
        return (level, text)
    }

    private static func setextHeadingLevel(in line: String) -> Int? {
        guard leadingIndent(in: line) <= 3 else { return nil }
        let underline = line.trimmingCharacters(in: .whitespaces)
        guard !underline.isEmpty else { return nil }
        if underline.allSatisfy({ $0 == "=" }) { return 1 }
        if underline.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        guard leadingIndent(in: line) <= 3 else { return false }
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let marker = compact.first, ["*", "-", "_"].contains(marker) else {
            return false
        }
        return compact.allSatisfy { $0 == marker }
    }

    private static func quoteContent(in line: String) -> String? {
        guard leadingIndent(in: line) <= 3 else { return nil }
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard trimmed.first == ">" else { return nil }
        return String(trimmed.dropFirst().drop(while: { $0 == " " }))
    }

    private static func listItem(in line: String) -> RemoteMarkdownListItem? {
        let indent = leadingIndent(in: line)
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard !trimmed.isEmpty else { return nil }

        let marker: RemoteMarkdownListItem.Marker
        let contentStart: Substring.Index
        if let first = trimmed.first,
           ["-", "*", "+"].contains(first),
           trimmed.dropFirst().first?.isWhitespace == true
        {
            marker = .bullet
            contentStart = trimmed.index(after: trimmed.startIndex)
        } else {
            let digits = trimmed.prefix(while: \.isNumber)
            guard !digits.isEmpty,
                  let delimiter = trimmed.dropFirst(digits.count).first,
                  delimiter == "." || delimiter == ")"
            else {
                return nil
            }
            let afterDelimiter = trimmed.index(trimmed.startIndex, offsetBy: digits.count + 1)
            guard afterDelimiter < trimmed.endIndex, trimmed[afterDelimiter].isWhitespace else { return nil }
            marker = .ordered(Int(digits) ?? 1)
            contentStart = afterDelimiter
        }

        let content = trimmed[contentStart...].drop(while: \.isWhitespace)
        return RemoteMarkdownListItem(
            marker: marker,
            depth: max(0, indent / 2),
            text: String(content)
        )
    }

    private static func tableRow(in line: String) -> [String]? {
        guard leadingIndent(in: line) <= 3, line.contains("|") else { return nil }
        var cells = line.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") { cells.removeFirst() }
        if line.trimmingCharacters(in: .whitespaces).hasSuffix("|") { cells.removeLast() }
        return cells.isEmpty ? nil : cells
    }

    private static func isTableDelimiterRow(_ line: String) -> Bool {
        guard let cells = tableRow(in: line), cells.count >= 2 else { return false }
        return cells.allSatisfy { cell in
            cell.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil
        }
    }

    private static func removingLeadingIndent(_ indentation: Int, from line: String) -> String {
        var remaining = indentation
        var index = line.startIndex
        while index < line.endIndex, remaining > 0 {
            switch line[index] {
            case " ":
                remaining -= 1
            case "\t":
                remaining -= 4
            default:
                return String(line[index...])
            }
            index = line.index(after: index)
        }
        return String(line[index...])
    }

    private static func startsBlock(_ line: String, previousParagraphLines: [String]) -> Bool {
        guard !previousParagraphLines.isEmpty else { return false }
        return openingFence(in: line) != nil
            || heading(in: line) != nil
            || isThematicBreak(line)
            || quoteContent(in: line) != nil
            || listItem(in: line) != nil
    }

    private static func normalizedInlineText(_ lines: [String]) -> String {
        var result = ""
        var previousWasHardBreak = false

        for (offset, rawLine) in lines.enumerated() {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            let isHardBreak: Bool
            if line.hasSuffix("\\") {
                line.removeLast()
                isHardBreak = true
            } else if rawLine.hasSuffix("  ") {
                isHardBreak = true
            } else {
                isHardBreak = false
            }

            if offset > 0 {
                result += previousWasHardBreak ? "\n" : " "
            }
            result += line
            previousWasHardBreak = isHardBreak
        }

        return result
    }

    private static func leadingIndent(in line: String) -> Int {
        line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(into: 0) { count, character in
            count += character == "\t" ? 4 : 1
        }
    }

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy(\.isWhitespace)
    }
}

enum RemoteTranscriptPresentation {
    static func isAskUserTool(_ name: String?) -> Bool {
        let suffix = name?.lowercased().split(separator: ".").last?.components(separatedBy: "__").last
        return switch suffix {
        case "ask_user", "ask_user_question", "askuserquestion": true
        default: false
        }
    }

    static func recordedQuestionPreview(for item: RemoteTranscriptItem) -> String? {
        guard let text = item.text, !text.isEmpty else { return nil }
        let parts = text.components(separatedBy: " • ")
        if parts.count == 2, isAskUserTool(parts[0]), parts[1] == item.toolStatus {
            return nil
        }
        return text
    }

    static func diffSummaryText(_ summary: RemoteTranscriptDiffSummary) -> String {
        let title = summary.singleFilePath ?? (summary.fileCount == 1 ? "1 file" : "\(summary.fileCount) files")
        var text = title
        if let additions = summary.additions, let deletions = summary.deletions {
            text += "  +\(additions) −\(deletions)"
        }
        if summary.isTruncated { text += " · Partial" }
        return text
    }

    static func semanticKind(for item: RemoteTranscriptItem) -> RemoteTranscriptSemanticKind {
        if isAskUserTool(item.toolName), item.semanticKind != .error { return .question }
        if let semanticKind = item.semanticKind { return semanticKind }
        switch item.kind {
        case .request:
            return .userRequest
        case .conclusion:
            return .assistantAnswer
        case .summary:
            return .summary
        case .activity:
            if item.toolName != nil { return .compactActivity }
            let role = item.role.lowercased()
            return role == "assistant" ? .assistantPreamble : .compactActivity
        }
    }

    static func elements(from items: [RemoteTranscriptItem]) -> [RemoteTranscriptPresentationElement] {
        var result: [RemoteTranscriptPresentationElement] = []
        var ordinaryActivity: [RemoteTranscriptItem] = []

        func flushOrdinary() {
            guard !ordinaryActivity.isEmpty else { return }
            result.append(.activityGroup(ordinaryActivity, exceptional: false))
            ordinaryActivity.removeAll(keepingCapacity: true)
        }

        for item in items {
            let semantic = semanticKind(for: item)
            switch semantic {
            case .compactActivity:
                let exceptional = isExceptionalActivity(item)
                if item.diffSummary != nil || exceptional {
                    flushOrdinary()
                    result.append(.activityGroup([item], exceptional: exceptional))
                } else {
                    ordinaryActivity.append(item)
                }
            case .error, .permission, .question, .approval:
                flushOrdinary()
                result.append(.activityGroup([item], exceptional: true))
            case .userRequest, .assistantPreamble, .assistantAnswer, .summary:
                flushOrdinary()
                result.append(.narrative(item, semantic))
            }
        }
        flushOrdinary()
        return result
    }

    static func isExceptionalActivity(_ item: RemoteTranscriptItem) -> Bool {
        switch RemoteToolActivityState(item) {
        case .failed?, .warning?, .cancelled?: true
        default: false
        }
    }

    static func formattedToolPayload(_ raw: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed]) else { return raw }
        if let text = object as? String { return text }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              )
        else { return raw }
        return String(decoding: data, as: UTF8.self)
    }
}

enum RemoteToolActivityState: Int, Equatable {
    case completed, unknown, pending, running, cancelled, warning, failed

    init?(_ item: RemoteTranscriptItem) {
        if item.detail?.toolIsError == true {
            self = .failed
            return
        }
        guard let raw = item.toolStatus?.lowercased() else { return nil }
        switch raw {
        case "success", "completed": self = .completed
        case "pending", "queued": self = .pending
        case "running", "in_progress": self = .running
        case "cancelled", "canceled": self = .cancelled
        case "warning": self = .warning
        case "failed", "error": self = .failed
        default: self = .unknown
        }
    }

    static func aggregate(_ items: [RemoteTranscriptItem]) -> Self? {
        items.compactMap(Self.init).max { $0.rawValue < $1.rawValue }
    }

    var label: String {
        switch self {
        case .completed: "Completed"
        case .unknown: "Unknown"
        case .pending: "Queued"
        case .running: "Running"
        case .cancelled: "Cancelled"
        case .warning: "Warning"
        case .failed: "Failed"
        }
    }
}

enum RemoteToolCardKind: Equatable {
    case read, search, shell, edit

    init?(_ toolName: String?) {
        guard let name = toolName?.lowercased().split(separator: ".").last else { return nil }
        switch name.components(separatedBy: "__").last {
        case "read", "read_file": self = .read
        case "file_search", "grep", "glob", "list_files": self = .search
        case "bash", "shell", "local_shell", "unified_exec", "exec_command", "run_shell_command": self = .shell
        case "apply_edits", "apply_patch", "filechange", "file_change", "edit", "edit file", "edit_file", "write_file":
            self = .edit
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .read: "Read file"
        case .search: "Search files"
        case .shell: "Run command"
        case .edit: "Edit files"
        }
    }

    var icon: String {
        switch self {
        case .read: "doc.text"
        case .search: "magnifyingglass"
        case .shell: "terminal"
        case .edit: "pencil"
        }
    }

    func summary(for item: RemoteTranscriptItem) -> String? {
        guard let text = item.text else { return nil }
        let parts = text.components(separatedBy: " • ")
        if parts.count >= 2, RemoteToolCardKind(parts[0]) == self, parts[1] == item.toolStatus {
            return parts.count > 2 ? parts.dropFirst(2).joined(separator: " • ") : nil
        }
        return text
    }
}

struct RemoteToolDetailPresentation {
    struct Section {
        let title: String
        let text: String
        let isDiff: Bool

        init(_ title: String, _ text: String, isDiff: Bool = false) {
            self.title = title
            self.text = text
            self.isDiff = isDiff
        }
    }

    var sections: [Section] = []
    var metadata: [String] = []
    var exitCode: Int?
    var isPartial = false

    init?(kind: RemoteToolCardKind, detail: RemoteTranscriptDetail, summaryOnly: Bool) {
        let args = Self.object(detail.argumentsJSON)
        let raw = detail.resultJSON
        let result = Self.object(raw)
        let text = raw.map(RemoteTranscriptPresentation.formattedToolPayload)
        let isPlainText = text.map { !$0.hasPrefix("{") && !$0.hasPrefix("[") } ?? false
        isPartial = summaryOnly || result?["summary_only"] as? Bool == true
            || result?["diff_truncated"] as? Bool == true
            || result?["limit_hit"] as? Bool == true || result?["size_limit_hit"] as? Bool == true

        switch kind {
        case .read:
            if let path = Self.string(result, "display_path", "path")
                ?? Self.string(args, "path", "file_path", "filePath") ?? detail.keyPaths.first
            {
                sections.append(Section("File", path))
            }
            if let first = result?["first_line"] as? Int, first > 0,
               let last = result?["last_line"] as? Int, last >= first
            {
                metadata.append(first == last ? "Line \(first)" : "Lines \(first)–\(last)")
            }
            let content = Self.string(result, "content", "text", "output") ?? (isPlainText ? text : nil)
            appendResult("Content", content, raw: text)
        case .search:
            if let query = Self.string(args, "pattern", "query", "glob") {
                sections.append(Section("Query", query))
            }
            if let total = result?["total_matches"] as? Int {
                metadata.append("\(total) \(total == 1 ? "match" : "matches")")
            }
            let matches = Self.searchMatches(result)
            appendResult("Matches", matches.isEmpty ? (isPlainText ? text : nil) : matches, raw: text)
        case .shell:
            if let command = Self.string(result, "command", "cmd")
                ?? Self.string(args, "command", "cmd") ?? (args?["argv"] as? [String])?.joined(separator: " ")
            {
                sections.append(Section("Command", command))
            }
            exitCode = detail.exitCode ?? result?["exitCode"] as? Int ?? result?["exit_code"] as? Int
            let output = Self.string(result, "aggregatedOutput", "aggregated_output", "stdout", "output")
                ?? (isPlainText ? text : nil)
            let standardError = Self.string(result, "stderr")
            if let standardError {
                if let output { sections.append(Section("Output", output)) }
                sections.append(Section("Standard error", standardError))
            } else {
                appendResult("Output", output, raw: text)
            }
        case .edit:
            let changes = (result?["changes"] ?? result?["content"]) as? [[String: Any]] ?? []
            for change in changes {
                guard let path = Self.string(change, "path", "file_path") else { continue }
                if let diff = Self.string(change, "card_unified_diff", "unified_diff", "diff") {
                    sections.append(Section(path, diff, isDiff: true))
                } else {
                    sections.append(Section("File", path))
                }
                isPartial = isPartial || change["diff_truncated"] as? Bool == true
            }
            if changes.isEmpty || sections.isEmpty {
                let paths = detail.keyPaths.isEmpty ? (args?["paths"] as? [String] ?? []) : detail.keyPaths
                if !paths.isEmpty {
                    sections.append(Section("Files", paths.joined(separator: "\n")))
                } else if let path = Self.string(args, "path", "file_path", "filePath") {
                    sections.append(Section("File", path))
                }
                if let diff = Self.string(result, "card_unified_diff", "unified_diff", "diff") {
                    sections.append(Section("Diff", diff, isDiff: true))
                } else if let text, text.hasPrefix("diff --git ") || text.hasPrefix("--- ") || text.hasPrefix("@@ ") {
                    sections.append(Section("Diff", text, isDiff: true))
                } else {
                    appendResult("Result", Self.string(result, "output"), raw: text)
                }
            }
            if let added = result?["added_lines"] as? Int, let deleted = result?["deleted_lines"] as? Int {
                metadata.append("+\(added) −\(deleted) lines")
            } else if !isPartial, let counts = Self.diffCounts(sections.filter(\.isDiff)) {
                metadata.append("+\(counts.added) −\(counts.deleted) lines")
            } else if let total = result?["total_lines_changed"] as? Int {
                metadata.append("\(total) \(total == 1 ? "line" : "lines") changed")
            }
        }

        guard result != nil || isPlainText || raw == nil,
              !sections.isEmpty || exitCode != nil || !metadata.isEmpty
        else { return nil }
    }

    private mutating func appendResult(_ title: String, _ text: String?, raw: String?) {
        if let text, !text.isEmpty {
            sections.append(Section(title, text))
        } else if let raw, !raw.isEmpty {
            sections.append(Section("Result", raw))
        }
    }

    private static func object(_ raw: String?) -> [String: Any]? {
        guard let raw, let root = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { return nil }
        if let structured = (root["structuredContent"] ?? root["structured_content"] ?? root["result"]) as? [String: Any] {
            return structured
        }
        return root
    }

    private static func string(_ object: [String: Any]?, _ keys: String...) -> String? {
        keys.lazy.compactMap { object?[$0] as? String }.first { !$0.isEmpty }
    }

    private static func searchMatches(_ object: [String: Any]?) -> String {
        let groups = object?["content_match_groups"] as? [[String: Any]] ?? []
        let matchingPaths = object?["path_match_lines"] as? [String] ?? []
        let matches = groups.flatMap { group -> [String] in
            guard let path = group["path"] as? String,
                  let lines = group["lines"] as? [[String: Any]]
            else { return [] }
            return lines.compactMap { line in
                guard let number = line["line_number"] as? Int, let text = line["line_text"] as? String else { return nil }
                return "\(path):\(number): \(text)"
            }
        }
        return (matches + matchingPaths).joined(separator: "\n")
    }

    private static func diffCounts(_ sections: [Section]) -> (added: Int, deleted: Int)? {
        var added = 0
        var deleted = 0
        for section in sections {
            for line in section.text.split(separator: "\n") {
                if line.hasPrefix("+"), !line.hasPrefix("+++ ") { added += 1 }
                if line.hasPrefix("-"), !line.hasPrefix("--- ") { deleted += 1 }
            }
        }
        return added + deleted > 0 ? (added, deleted) : nil
    }
}
