import SwiftUI
import AVFoundation
import CoreTransferable
import UniformTypeIdentifiers
import BackpackProtocol

struct ImportedVideo: Transferable, Identifiable {
    let url: URL
    var id: URL { url }
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            try copy(received.file)
        }
    }
    static func copy(_ source: URL) throws -> ImportedVideo {
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let bytes = values.fileSize, (1...256_000_000).contains(bytes) else {
            throw BackpackError.invalid("Choose a video file up to 256 MB.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LEDBackpackVideo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let ext = ["mov", "mp4", "m4v"].contains(source.pathExtension.lowercased()) ? source.pathExtension.lowercased() : "mov"
        let target = directory.appendingPathComponent("input.\(ext)")
        do {
            try FileManager.default.copyItem(at: source, to: target)
            let copied = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard (1...256_000_000).contains(copied) else { throw BackpackError.invalid("Copied video exceeds the size limit.") }
            return ImportedVideo(url: target)
        } catch {
            do { try FileManager.default.removeItem(at: directory) }
            catch { throw BackpackError.invalid("Video import and temporary cleanup failed: \(error.localizedDescription)") }
            throw error
        }
    }
    func remove() throws {
        let directory = url.deletingLastPathComponent()
        guard directory.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL,
              directory.lastPathComponent.hasPrefix("LEDBackpackVideo-") else {
            throw BackpackError.invalid("Refusing to remove an unmanaged video path.")
        }
        try FileManager.default.removeItem(at: directory)
    }
}

struct VideoGIFPlan {
    let start: Double
    let duration: Double
    let frameCount: Int
    var delay: Double { duration / Double(frameCount) }
    var times: [Double] { (0..<frameCount).map { start + Double($0) * delay } }
    init(assetDuration: Double, start: Double, duration: Double, fps: Int) throws {
        guard assetDuration.isFinite, assetDuration > 0, assetDuration <= 86400,
              start.isFinite, duration.isFinite, start >= 0, duration >= 0.1, duration <= 12,
              start + duration <= assetDuration + 0.000001, (2...20).contains(fps) else {
            throw BackpackError.invalid("Choose a clip within the video, at most 12 seconds, at 2-20 FPS.")
        }
        let count = Int(ceil(duration * Double(fps)))
        guard (2...120).contains(count) else {
            throw BackpackError.invalid("Choose 2-120 frames. Shorten the clip or reduce FPS.")
        }
        self.start = start; self.duration = duration; frameCount = count
    }
}

@MainActor
enum VideoGIFCodec {
    static func inspect(_ url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration >= 0.1, duration <= 86400 else {
            throw BackpackError.invalid("Choose a video between 0.1 seconds and 24 hours.")
        }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw BackpackError.invalid("This file has no video track.") }
        let size = try await track.load(.naturalSize)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              size.width <= 8192, size.height <= 8192 else {
            throw BackpackError.invalid("Video source dimensions must be at most 8192 x 8192.")
        }
        try Task.checkCancellation()
        return duration
    }

    static func convert(_ url: URL, plan: VideoGIFPlan, size: PanelSize, fit: MediaCodec.Fit,
        progress: (Double) -> Void) async throws -> Data {
        guard MediaCodec.renderSizes.contains(size) else { throw BackpackError.invalid("Choose a supported GIF canvas size.") }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        defer { generator.cancelAllCGImageGeneration() }
        var frames: [PixelFrame] = []
        for (index, seconds) in plan.times.enumerated() {
            try Task.checkCancellation()
            let result = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
            try Task.checkCancellation()
            let frame = try autoreleasepool {
                try MediaCodec.transform(UIImage(cgImage: result.image), size: size, fit: fit, turns: 0, brightness: 1)
            }
            frames.append(frame)
            progress(Double(index + 1) / Double(plan.frameCount))
            await Task.yield()
        }
        try Task.checkCancellation()
        return try MediaCodec.encode(frames, delays: Array(repeating: plan.delay, count: plan.frameCount))
    }
}

@MainActor
struct VideoGIFEditor: View {
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var panel: PanelController
    @Environment(\.dismiss) private var dismiss
    let video: ImportedVideo
    @State private var duration: Double?
    @State private var start = 0.0
    @State private var length = 3.0
    @State private var fps = 10
    @State private var sizeIndex = 1
    @State private var fit = MediaCodec.Fit.fit
    @State private var name = "My video GIF"
    @State private var category = ""
    @State private var output: Data?
    @State private var failure: String?
    @State private var status: String?
    @State private var progress = 0.0
    @State private var busy = false
    @State private var task: Task<Void, Never>?
    private struct Options: Equatable {
        let start: Double
        let length: Double
        let fps: Int
        let size: Int
        let fit: MediaCodec.Fit
    }
    private var options: Options { Options(start: start, length: length, fps: fps, size: sizeIndex, fit: fit) }
    var body: some View {
        NavigationStack {
            Form {
                if let duration {
                    conversionOptions(duration)
                    Section {
                        if output == nil {
                            Button("Create GIF preview") { convert(duration) }
                                .buttonStyle(AuroraPrimaryButton()).disabled(busy)
                        }
                        if busy {
                            ProgressView("Extracting video frames...", value: progress)
                            Button("Cancel conversion", role: .cancel) { task?.cancel() }
                        }
                        FeatureDetails("Conversion details") {
                            Text("Conversion stays on this iPhone. Audio is omitted; video rotation is respected. The source video is never uploaded. Maximum 120 frames / 5 MB.")
                        }
                    }
                } else if failure == nil { ProgressView("Reading video...") }
                if let output { savedOutput(output) }
                if let failure { Text(failure).foregroundStyle(.orange) }
                if let status { Text(status).font(.caption) }
            }
            .modernScene().navigationTitle("Video to GIF")
            .toolbar { Button("Done") { task?.cancel(); dismiss() } }
            .safeAreaInset(edge: .bottom) {
                Button("Cancel") { task?.cancel(); dismiss() }
                    .frame(maxWidth: .infinity, minHeight: 44).padding(8).background(.regularMaterial)
            }
            .interactiveDismissDisabled(busy)
            .task {
                do {
                    let value = try await VideoGIFCodec.inspect(video.url)
                    duration = value; length = min(3, value); failure = nil
                    if let size = panel.size, let index = MediaCodec.renderSizes.firstIndex(of: size) { sizeIndex = index }
                } catch {
                    if !Task.isCancelled { failure = error.localizedDescription }
                }
            }
            .onChange(of: options) { _, _ in output = nil; status = nil }
            .onDisappear { task?.cancel() }
        }
    }
    private func conversionOptions(_ duration: Double) -> some View {
        Section("Clip and canvas") {
            Text("Source duration: \(duration, specifier: "%.2f") seconds").font(.caption)
            TextField("Start (seconds)", value: $start, format: .number).keyboardType(.decimalPad)
            TextField("Length (seconds, up to 12)", value: $length, format: .number).keyboardType(.decimalPad)
            DisclosureGroup("Canvas & frame rate") {
                Stepper("\(fps) frames per second", value: $fps, in: 2...20)
                Picker("GIF canvas", selection: $sizeIndex) {
                    ForEach(MediaCodec.renderSizes.indices, id: \.self) { index in
                        let size = MediaCodec.renderSizes[index]
                        Text("\(size.width) x \(size.height)").tag(index)
                    }
                }
                Picker("Framing", selection: $fit) {
                    ForEach(MediaCodec.Fit.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
            }
        }.disabled(busy)
    }
    private func savedOutput(_ data: Data) -> some View {
        Section("Preview and save") {
            AnimatedPreview(data: data).frame(height: 240)
            Text(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)).font(.caption)
            DisclosureGroup("Library category") { TextField("Category (optional)", text: $category) }
            Button("Save GIF to library") {
                do {
                    try library.add(name: name, data: data, category: category)
                    status = "Saved. Use Library > Actions to send to the backpack or share to the community."
                    failure = nil
                } catch { failure = error.localizedDescription }
            }.buttonStyle(AuroraPrimaryButton())
        }
    }
    private func convert(_ duration: Double) {
        guard !busy else { return }
        do {
            let plan = try VideoGIFPlan(assetDuration: duration, start: start, duration: length, fps: fps)
            let size = MediaCodec.renderSizes[sizeIndex], fit = fit
            busy = true; progress = 0; failure = nil; output = nil; status = nil
            task = Task {
                defer { busy = false; task = nil }
                do {
                    let data = try await VideoGIFCodec.convert(video.url, plan: plan, size: size, fit: fit) { progress = $0 }
                    try Task.checkCancellation()
                    output = data
                } catch {
                    if Task.isCancelled { status = "Conversion cancelled." }
                    else { failure = error.localizedDescription }
                }
            }
        } catch { failure = error.localizedDescription }
    }
}
