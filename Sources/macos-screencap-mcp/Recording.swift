import AVFoundation
import ScreenCaptureKit

/// One in-progress screen recording, written to disk by SCRecordingOutput.
final class Recording: NSObject, SCStreamOutput {
    let id: String
    let url: URL
    let target: JSON
    let pixelSize: CGSize
    let codec: String
    private(set) var startedAt = Date()

    private let stream: SCStream
    private let recordingOutput: SCRecordingOutput
    private let delegate = CaptureDelegate()
    private let lock = NSLock()
    private var finished = false
    private var streamError: Error?
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private let sampleQueue = DispatchQueue(label: "macos-screencap-mcp.samples")

    init(id: String, url: URL, target: JSON, filter: SCContentFilter, size: CGSize,
         fps: Int, showCursor: Bool, systemAudio: Bool, microphone: Bool) throws {
        self.id = id
        self.url = url
        self.target = target

        let scale = CGFloat(filter.pointPixelScale)
        // Video encoders require even dimensions.
        let w = max(2, Int((size.width * scale).rounded()) & ~1)
        let h = max(2, Int((size.height * scale).rounded()) & ~1)
        pixelSize = CGSize(width: w, height: h)

        let config = SCStreamConfiguration()
        config.width = w
        config.height = h
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, min(fps, 120))))
        config.showsCursor = showCursor
        config.capturesAudio = systemAudio
        config.captureMicrophone = microphone
        config.queueDepth = 6

        let recConfig = SCRecordingOutputConfiguration()
        recConfig.outputURL = url
        recConfig.outputFileType = url.pathExtension.lowercased() == "mov" ? .mov : .mp4
        // H.264 hardware encoders top out around 4096 px wide; fall back to HEVC for big retina displays.
        let wantsHEVC = w > 4096 || h > 4096
        let preferred: AVVideoCodecType = wantsHEVC ? .hevc : .h264
        recConfig.videoCodecType = recConfig.availableVideoCodecTypes.contains(preferred)
            ? preferred : (recConfig.availableVideoCodecTypes.first ?? .h264)
        codec = recConfig.videoCodecType.rawValue

        stream = SCStream(filter: filter, configuration: config, delegate: delegate)
        recordingOutput = SCRecordingOutput(configuration: recConfig, delegate: delegate)
        super.init()

        delegate.onFinish = { [weak self] error in self?.markFinished(error: error) }
        delegate.onStreamError = { [weak self] error in self?.streamStopped(error) }
        try stream.addRecordingOutput(recordingOutput)
        // A screen output keeps the stream delivering frames; we discard them.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
    }

    func start() async throws {
        do {
            try await stream.startCapture()
        } catch {
            throw ToolError("Failed to start recording: \(error.localizedDescription)")
        }
        startedAt = Date()
    }

    /// Stops capture and waits for the file to be finalized.
    func stop() async -> JSON {
        do { try await stream.stopCapture() } catch { markFinished(error: error) }

        // Wait for recordingOutputDidFinishRecording, with a safety timeout.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.waitForFinish() }
            group.addTask { try? await Task.sleep(for: .seconds(10)) }
            await group.next()
            group.cancelAll()
        }
        markFinished(error: nil)
        return summary(active: false)
    }

    func summary(active: Bool) -> JSON {
        var out: JSON = [
            "recording_id": id,
            "output_path": url.path,
            "target": target,
            "pixel_width": Int(pixelSize.width),
            "pixel_height": Int(pixelSize.height),
            "codec": codec,
            // NSDecimalNumber so JSON shows e.g. 3.2 rather than 3.2000000000000002.
            "elapsed_seconds": NSDecimalNumber(string: String(format: "%.1f", Date().timeIntervalSince(startedAt))),
            "active": active,
        ]
        if !active {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
            out["file_bytes"] = size ?? 0
        }
        lock.lock()
        if let streamError { out["error"] = streamError.localizedDescription }
        lock.unlock()
        return out
    }

    private func waitForFinish() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if finished {
                lock.unlock()
                cont.resume()
            } else {
                finishWaiters.append(cont)
                lock.unlock()
            }
        }
    }

    private func markFinished(error: Error?) {
        lock.lock()
        if let error, streamError == nil { streamError = error }
        let waiters = finished ? [] : finishWaiters
        finished = true
        finishWaiters = []
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}

    private func streamStopped(_ error: Error) {
        log("recording \(id) stream stopped: \(error.localizedDescription)")
        lock.lock()
        if streamError == nil { streamError = error }
        lock.unlock()
    }
}

/// SCStream and SCRecordingOutput take their delegates before the owning Recording exists, so callbacks go through this.
private final class CaptureDelegate: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    var onFinish: ((Error?) -> Void)?
    var onStreamError: ((Error) -> Void)?

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStreamError?(error)
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        log("recording output failed: \(error.localizedDescription)")
        onFinish?(error)
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        onFinish?(nil)
    }
}

/// Tracks active recordings by id.
actor RecordingStore {
    private var active: [String: Recording] = [:]
    private var counter = 0

    func nextID() -> String {
        counter += 1
        return "rec-\(counter)"
    }

    func add(_ r: Recording) { active[r.id] = r }

    func remove(_ id: String?) throws -> Recording {
        if let id {
            guard let r = active.removeValue(forKey: id) else {
                throw ToolError("No active recording with id \(id). Active: \(active.keys.sorted())")
            }
            return r
        }
        guard active.count == 1, let (key, r) = active.first else {
            throw ToolError(active.isEmpty
                ? "No active recordings."
                : "Multiple recordings active; pass recording_id. Active: \(active.keys.sorted())")
        }
        active[key] = nil
        return r
    }

    func list() -> [Recording] { active.values.sorted { $0.id < $1.id } }

    func removeAll() -> [Recording] {
        defer { active.removeAll() }
        return Array(active.values)
    }
}
