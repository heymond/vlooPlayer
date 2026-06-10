import SwiftUI
import UniformTypeIdentifiers

struct VideoDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL, URL?) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let subtitleTypes = [
            UTType(filenameExtension: "srt"),
            UTType(filenameExtension: "smi"),
            UTType(filenameExtension: "vtt"),
            .plainText
        ].compactMap { $0 }

        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.mpeg4Movie, .quickTimeMovie, .movie, .video] + subtitleTypes,
            asCopy: false
        )
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL, URL?) -> Void

        init(onPick: @escaping (URL, URL?) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let videoURL = urls.first(where: { Self.isVideo($0) }) else { return }
            let subtitleURL = urls.first { Self.isSubtitle($0) && Self.matches(videoURL: videoURL, subtitleURL: $0) }
                ?? urls.first(where: Self.isSubtitle(_:))
            onPick(videoURL, subtitleURL)
        }

        private static func isVideo(_ url: URL) -> Bool {
            ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
        }

        private static func isSubtitle(_ url: URL) -> Bool {
            ["srt", "smi", "vtt"].contains(url.pathExtension.lowercased())
        }

        private static func matches(videoURL: URL, subtitleURL: URL) -> Bool {
            videoURL.deletingPathExtension().lastPathComponent == subtitleURL.deletingPathExtension().lastPathComponent
        }
    }
}
