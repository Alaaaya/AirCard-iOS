import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

/// PHPicker grants access to only the selected video, not the whole library.
struct WallpaperVideoPicker: UIViewControllerRepresentable {
    var completion: (Result<URL, Error>?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .videos
        config.selectionLimit = 1
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(completion) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let completion: (Result<URL, Error>?) -> Void
        init(_ completion: @escaping (Result<URL, Error>?) -> Void) { self.completion = completion }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider else { completion(nil); return }
            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
                let result: Result<URL, Error>
                do {
                    guard let url = url else { throw error ?? CocoaError(.fileReadUnknown) }
                    let copy = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
                    // Provider URL is valid only inside this callback.
                    try FileManager.default.copyItem(at: url, to: copy)
                    result = .success(copy)
                } catch { result = .failure(error) }
                DispatchQueue.main.async { self.completion(result) }
            }
        }
    }
}

enum VideoWallpaper {
    static func makeArchive(from source: URL, screenAspect: CGFloat,
                            progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("video-wallpaper-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0,
              let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let seconds = min(duration, 10)
        let size = try await track.load(.naturalSize)
        let rotation = try await track.load(.preferredTransform)
        let oriented = CGRect(origin: .zero, size: size).applying(rotation)
        guard oriented.width > 0, oriented.height > 0 else { throw CocoaError(.fileReadCorruptFile) }
        // Moderate resolution and 24 fps bound decoding, disk use and PosterBoard memory.
        let width: CGFloat = 540
        let height = (width / screenAspect / 2).rounded() * 2
        let target = CGSize(width: width, height: height)
        let scale = max(target.width / oriented.width, target.height / oriented.height)
        let transform = rotation
            .concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(
                translationX: (target.width - oriented.width * scale) / 2,
                y: (target.height - oriented.height * scale) / 2))
        let composition = AVMutableVideoComposition()
        composition.renderSize = target
        composition.frameDuration = CMTime(value: 1, timescale: 24)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHEVCHighestQuality)
            ?? AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw CocoaError(.featureUnsupported)
        }
        let movie = work.appendingPathComponent("normalized.mov")
        exporter.outputURL = movie
        exporter.outputFileType = .mov
        exporter.timeRange = instruction.timeRange
        exporter.videoComposition = composition
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            exporter.exportAsynchronously { continuation.resume() }
        }
        guard exporter.status == .completed else {
            throw exporter.error ?? CocoaError(.fileWriteUnknown)
        }
        try Task.checkCancellation()
        progress(0.15)
        guard let template = Bundle.main.url(forResource: "VideoCAML", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let root = work.appendingPathComponent("package")
        let descriptor = root.appendingPathComponent("Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors").appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: descriptor.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: template, to: descriptor)
        let wallpaper = descriptor.appendingPathComponent("versions/1/contents/9183.Custom-810w-1080h@2x~ipad.wallpaper")
        let ca = wallpaper.appendingPathComponent("9183.Custom_Background-810w-1080h@2x~ipad.ca")
        let assets = ca.appendingPathComponent("assets")
        try fm.createDirectory(at: assets, withIntermediateDirectories: true)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frames = max(1, Int(ceil(seconds * 24)))
        var values = ""
        for frame in 0..<frames {
            try Task.checkCancellation()
            try autoreleasepool {
                let image = try generator.copyCGImage(at: CMTime(seconds: Double(frame) / 24, preferredTimescale: 600), actualTime: nil)
                guard let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.75) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try data.write(to: assets.appendingPathComponent("\(frame).jpg"))
            }
            values += "<CGImage src=\"assets/\(frame).jpg\"/>\n"
            progress(0.15 + 0.8 * Double(frame + 1) / Double(frames))
        }
        let w = Int(width), h = Int(height)
        let caml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <caml xmlns="http://www.apple.com/CoreAnimation/1.0">
        <CALayer bounds="0 0 \(w) \(h)" position="\(w/2) \(h/2)" name="_FLOATING">
          <sublayers><CALayer bounds="0 0 \(w) \(h)" position="\(w/2) \(h/2)">
            <contents type="CGImage" src="assets/0.jpg"/>
            <animations><animation type="CAKeyframeAnimation" keyPath="contents" calculationMode="discrete"
            beginTime="1e-100" duration="\(seconds)" removedOnCompletion="0" repeatCount="inf">
            <values>\(values)</values></animation></animations>
          </CALayer></sublayers>
          <states><LKState name="Locked"><elements/></LKState><LKState name="Unlock"><elements/></LKState><LKState name="Sleep"><elements/></LKState></states>
        </CALayer></caml>
        """
        try Data(caml.utf8).write(to: ca.appendingPathComponent("main.caml"))
        let index: [String: Any] = [
            "rootDocument": "main.caml", "documentWidth": w, "documentHeight": h,
            "documentResizesToView": true, "geometryFlipped": false,
            "scalesToFitInPlayer": true, "unitsInPixelsInPlayer": true
        ]
        try PropertyListSerialization.data(fromPropertyList: index, format: .xml, options: 0)
            .write(to: ca.appendingPathComponent("index.xml"))
        let output = fm.temporaryDirectory.appendingPathComponent("Video-" + UUID().uuidString + ".tendies")
        do { try PasscodeThemePackager.archiveDirectory(root, to: output) }
        catch { try? fm.removeItem(at: output); throw error }
        progress(1)
        return output
    }
}
