import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct PhotoVideoPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .videos
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .compatible

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider else { return }

            let identifiers = [
                UTType.mpeg4Movie.identifier,
                UTType.quickTimeMovie.identifier,
                UTType.movie.identifier
            ]

            guard let identifier = identifiers.first(where: provider.hasItemConformingToTypeIdentifier) else { return }

            provider.loadFileRepresentation(forTypeIdentifier: identifier) { sourceURL, _ in
                guard let sourceURL else { return }

                let extensionName = sourceURL.pathExtension.isEmpty ? "mp4" : sourceURL.pathExtension
                let destinationURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(extensionName)

                do {
                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        try FileManager.default.removeItem(at: destinationURL)
                    }
                    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                    DispatchQueue.main.async {
                        self.onPick(destinationURL)
                    }
                } catch {
                    print("Failed to copy picked video: \(error)")
                }
            }
        }
    }
}
