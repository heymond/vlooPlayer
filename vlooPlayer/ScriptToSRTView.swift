import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ScriptToSRTView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var youtubeAddress = ""
    @State private var statusMessage: String?
    @State private var isConverting = false
    @State private var exportDocument = SRTDocument(text: "")
    @State private var exportFilename = "youtube-subtitles.srt"
    @State private var isExporting = false
    @State private var loadedResult: YouTubeSubtitleConverter.Result?

    var body: some View {
        NavigationStack {
            Form {
                Section("YouTube address") {
                    TextField("https://www.youtube.com/watch?v=...", text: $youtubeAddress)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .onChange(of: youtubeAddress) { _, _ in
                            loadedResult = nil
                            statusMessage = nil
                        }
                }

                Section {
                    Button {
                        loadScript()
                    } label: {
                        HStack {
                            Spacer()
                            if isConverting {
                                ProgressView().padding(.trailing, 6)
                            }
                            Text(isConverting ? "Loading..." : "Load Script")
                            Spacer()
                        }
                    }
                    .disabled(isConverting || youtubeAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let statusMessage {
                    Section("Status") {
                        Text(statusMessage)
                            .foregroundStyle(statusMessage == "Script loaded." ? Color.green : Color.red)
                    }
                }

                if let loadedResult {
                    Section("Script preview") {
                        ScrollView([.horizontal, .vertical]) {
                            Text(loadedResult.script)
                                .font(.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                        }
                        .frame(minHeight: 220, maxHeight: 360)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))

                        Button("Convert to SRT") {
                            convertToSRT(loadedResult)
                        }
                    }
                }

                Section {
                    Text("Only subtitles made available by the video owner or YouTube can be converted.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Script to SRT")
            .onAppear {
                pasteYouTubeAddressFromClipboard()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .fileExporter(
                isPresented: $isExporting,
                document: exportDocument,
                contentType: .srtSubtitle,
                defaultFilename: exportFilename
            ) { result in
                if case .failure(let error) = result {
                    statusMessage = "Could not save the SRT file: \(error.localizedDescription)"
                }
            }
        }
    }

    private func loadScript() {
        isConverting = true
        statusMessage = nil
        loadedResult = nil

        Task {
            do {
                let result = try await YouTubeSubtitleConverter.convert(address: youtubeAddress)
                loadedResult = result
                statusMessage = "Script loaded."
            } catch YouTubeSubtitleError.noScript {
                statusMessage = "No script found for this video."
            } catch YouTubeSubtitleError.invalidAddress {
                statusMessage = "Enter a valid YouTube address."
            } catch {
                statusMessage = "Could not convert this video: \(error.localizedDescription)"
            }
            isConverting = false
        }
    }

    private func convertToSRT(_ result: YouTubeSubtitleConverter.Result) {
        exportDocument = SRTDocument(text: result.srt)
        exportFilename = "\(result.videoID).srt"
        isExporting = true
    }

    private func pasteYouTubeAddressFromClipboard() {
        guard youtubeAddress.isEmpty,
              UIPasteboard.general.hasStrings,
              let clipboardText = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              let host = URLComponents(string: clipboardText)?.host?.lowercased(),
              host == "youtu.be" || host.hasSuffix(".youtu.be") || host == "youtube.com" || host.hasSuffix(".youtube.com") else { return }

        youtubeAddress = clipboardText
    }
}

private struct SRTDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.srtSubtitle] }
    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

private extension UTType {
    static let srtSubtitle = UTType(filenameExtension: "srt") ?? .plainText
}

private enum YouTubeSubtitleError: Error {
    case invalidAddress
    case noScript
    case invalidResponse
}

private enum YouTubeSubtitleConverter {
    struct Result {
        let videoID: String
        let script: String
        let srt: String
    }

    static func convert(address: String) async throws -> Result {
        guard let videoID = videoID(from: address) else {
            throw YouTubeSubtitleError.invalidAddress
        }

        var request = URLRequest(url: URL(string: "https://www.youtube.com/watch?v=\(videoID)&hl=en")!)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148", forHTTPHeaderField: "User-Agent")
        let (pageData, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let page = String(data: pageData, encoding: .utf8),
              let tracks = captionTracks(from: page),
              let trackURLString = preferredTrackURL(from: tracks),
              var components = URLComponents(string: trackURLString) else {
            throw YouTubeSubtitleError.noScript
        }

        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "fmt" }
        queryItems.append(URLQueryItem(name: "fmt", value: "json3"))
        components.queryItems = queryItems
        guard let transcriptURL = components.url else { throw YouTubeSubtitleError.invalidResponse }

        let (transcriptData, transcriptResponse) = try await URLSession.shared.data(from: transcriptURL)
        guard (transcriptResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw YouTubeSubtitleError.noScript
        }

        let cues = try parseCues(from: transcriptData)
        guard !cues.isEmpty else { throw YouTubeSubtitleError.noScript }
        return Result(
            videoID: videoID,
            script: cues.map(\.text).joined(separator: "\n"),
            srt: makeSRT(cues)
        )
    }

    private static func videoID(from address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let host = components.host?.lowercased() else { return nil }

        if host == "youtu.be" || host.hasSuffix(".youtu.be") {
            return components.path.split(separator: "/").first.map(String.init)
        }
        if host == "youtube.com" || host.hasSuffix(".youtube.com") {
            if components.path == "/watch" {
                return components.queryItems?.first(where: { $0.name == "v" })?.value
            }
            let parts = components.path.split(separator: "/")
            if let marker = parts.firstIndex(where: { ["shorts", "embed", "live"].contains($0.lowercased()) }), marker + 1 < parts.count {
                return String(parts[marker + 1])
            }
        }
        return nil
    }

    private static func captionTracks(from page: String) -> [[String: Any]]? {
        guard let markerRange = page.range(of: #"\"captionTracks\":"#),
              let start = page[markerRange.upperBound...].firstIndex(of: "[") else { return nil }
        guard let json = balancedJSON(in: page, from: start, opening: "[", closing: "]"),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    }

    private static func preferredTrackURL(from tracks: [[String: Any]]) -> String? {
        let preferred = tracks.first(where: { ($0["kind"] as? String) != "asr" }) ?? tracks.first
        return preferred?["baseUrl"] as? String
    }

    private static func balancedJSON(in text: String, from start: String.Index, opening: Character, closing: Character) -> String? {
        var depth = 0
        var isInsideString = false
        var isEscaped = false
        var index = start

        while index < text.endIndex {
            let character = text[index]
            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInsideString = false
                }
            } else if character == "\"" {
                isInsideString = true
            } else if character == opening {
                depth += 1
            } else if character == closing {
                depth -= 1
                if depth == 0 {
                    return String(text[start...index])
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func parseCues(from data: Data) throws -> [(start: Int, end: Int, text: String)] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = root["events"] as? [[String: Any]] else {
            throw YouTubeSubtitleError.invalidResponse
        }

        return events.compactMap { event in
            guard let start = event["tStartMs"] as? NSNumber,
                  let segments = event["segs"] as? [[String: Any]] else { return nil }
            let text = segments.compactMap { $0["utf8"] as? String }.joined()
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let duration = (event["dDurationMs"] as? NSNumber)?.intValue ?? 2_000
            return (start.intValue, start.intValue + max(duration, 500), text)
        }
    }

    private static func makeSRT(_ cues: [(start: Int, end: Int, text: String)]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.start)) --> \(timestamp(cue.end))\n\(cue.text)"
        }.joined(separator: "\n\n") + "\n"
    }

    private static func timestamp(_ milliseconds: Int) -> String {
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let seconds = (milliseconds / 1_000) % 60
        let millis = milliseconds % 1_000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, millis)
    }
}
