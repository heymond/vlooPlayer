import Foundation

struct SubtitleCue: Identifiable, Equatable {
    let id = UUID()
    let start: Double
    let end: Double
    let text: String
}

enum SubtitleParser {
    static func parse(url: URL) -> [SubtitleCue] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let rawText = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""

        let normalized = rawText
            .replacingOccurrences(of: "\u{feff}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(
                of: #"\n(?:[ \t]*\n)+"#,
                with: "\n\n",
                options: .regularExpression
            )

        if url.pathExtension.lowercased() == "smi" || normalized.localizedCaseInsensitiveContains("<sync") {
            return parseSMI(normalized)
        }

        let cues = parseTimedText(normalized).sorted { $0.start < $1.start }
        return removingRolledUpLines(from: removingDuplicateCues(cues))
    }

    private static func parseTimedText(_ text: String) -> [SubtitleCue] {
        let lines = text.components(separatedBy: "\n")
        var cues: [SubtitleCue] = []
        var index = 0

        while index < lines.count {
            guard lines[index].contains("-->") else {
                index += 1
                continue
            }

            let parts = lines[index].components(separatedBy: "-->")
            guard parts.count >= 2,
                  let start = parseTime(parts[0]),
                  let end = parseTime(parts[1]) else {
                index += 1
                continue
            }

            index += 1
            var bodyLines: [String] = []
            while index < lines.count {
                if lines[index].contains("-->") {
                    break
                }

                let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                let nextLineIsTime = index + 1 < lines.count && lines[index + 1].contains("-->")
                if Int(trimmed) != nil && nextLineIsTime {
                    index += 1
                    break
                }

                bodyLines.append(lines[index])
                index += 1
            }

            let cueText = cleanText(bodyLines.joined(separator: "\n"))
            if !cueText.isEmpty, end > start {
                cues.append(SubtitleCue(start: start, end: end, text: cueText))
            }
        }

        return cues
    }

    private static func parseSMI(_ text: String) -> [SubtitleCue] {
        let pattern = #"(?is)<sync\s+start\s*=\s*([0-9]+)[^>]*>(.*?)(?=<sync\s+start\s*=|\z)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        var syncEntries: [(start: Double, paragraphs: [(className: String?, text: String)])] = []
        for match in matches where match.numberOfRanges >= 3 {
            let startString = nsText.substring(with: match.range(at: 1))
            let body = nsText.substring(with: match.range(at: 2))
            guard let startMS = Double(startString) else { continue }
            syncEntries.append((startMS / 1000, parseSMIParagraphs(body)))
        }

        let preferredClass = syncEntries
            .lazy
            .flatMap(\.paragraphs)
            .first(where: { !$0.text.isEmpty })?
            .className

        let cues = syncEntries.enumerated().compactMap { index, entry -> SubtitleCue? in
            let selectedText = preferredClass.flatMap { className in
                entry.paragraphs.first { $0.className == className && !$0.text.isEmpty }?.text
            } ?? entry.paragraphs.first { !$0.text.isEmpty }?.text

            guard let selectedText, !selectedText.isEmpty else { return nil }
            let nextStart = index + 1 < syncEntries.count ? syncEntries[index + 1].start : entry.start + 3
            guard nextStart > entry.start else { return nil }
            return SubtitleCue(start: entry.start, end: nextStart, text: selectedText)
        }
        return removingRolledUpLines(from: removingDuplicateCues(cues))
    }

    private static func parseSMIParagraphs(_ body: String) -> [(className: String?, text: String)] {
        let pattern = #"(?is)<p\b([^>]*)>(.*?)(?=<p\b|\z)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsBody = body as NSString
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: nsBody.length))

        if matches.isEmpty {
            return [(nil, cleanText(body))]
        }

        return matches.compactMap { match in
            guard match.numberOfRanges >= 3 else { return nil }
            let attributes = nsBody.substring(with: match.range(at: 1))
            let paragraphBody = nsBody.substring(with: match.range(at: 2))
            return (smiClassName(from: attributes), cleanText(paragraphBody))
        }
    }

    private static func smiClassName(from attributes: String) -> String? {
        let pattern = #"(?i)\bclass\s*=\s*[\"']?([^\s\"'>]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsAttributes = attributes as NSString
        guard let match = regex.firstMatch(
            in: attributes,
            range: NSRange(location: 0, length: nsAttributes.length)
        ), match.numberOfRanges >= 2 else { return nil }
        return nsAttributes.substring(with: match.range(at: 1)).lowercased()
    }

    private static func parseTime(_ value: String) -> Double? {
        let cleaned = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .first?
            .replacingOccurrences(of: ",", with: ".")

        guard let cleaned else { return nil }
        let parts = cleaned.split(separator: ":").map(String.init)
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else { return nil }

        return hours * 3600 + minutes * 60 + seconds
    }

    private static func cleanText(_ value: String) -> String {
        let lines = value
            .replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var previousLine: String?
        let uniqueLines = lines.filter { line in
            defer { previousLine = line }
            return line != previousLine
        }
        return uniqueLines.joined(separator: "\n")
    }

    private static func removingDuplicateCues(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        var previousCue: SubtitleCue?
        return cues.filter { cue in
            defer { previousCue = cue }
            guard let previousCue else { return true }
            return abs(cue.start - previousCue.start) >= 0.01
                || abs(cue.end - previousCue.end) >= 0.01
                || cue.text != previousCue.text
        }
    }

    private static func removingRolledUpLines(from cues: [SubtitleCue]) -> [SubtitleCue] {
        var previousLines: [String] = []

        return cues.compactMap { cue in
            let currentLines = cue.text
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            let overlapCount = maximumSuffixPrefixOverlap(previousLines, currentLines)
            let visibleLines = overlapCount > 0 && overlapCount < currentLines.count
                ? Array(currentLines.dropFirst(overlapCount))
                : currentLines
            previousLines = currentLines

            guard !visibleLines.isEmpty else { return nil }
            return SubtitleCue(start: cue.start, end: cue.end, text: visibleLines.joined(separator: "\n"))
        }
    }

    private static func maximumSuffixPrefixOverlap(_ previous: [String], _ current: [String]) -> Int {
        let maximumCount = min(previous.count, current.count - 1)
        guard maximumCount > 0 else { return 0 }

        for count in stride(from: maximumCount, through: 1, by: -1) {
            if Array(previous.suffix(count)) == Array(current.prefix(count)) {
                return count
            }
        }
        return 0
    }
}
