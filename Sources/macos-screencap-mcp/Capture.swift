import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

enum Capture {
    static func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw ToolError("""
                Could not read screen content: \(error.localizedDescription)
                Grant Screen Recording permission to the app that launches this server \
                (System Settings → Privacy & Security → Screen & System Audio Recording), then restart that app.
                """)
        }
    }

    // MARK: Displays

    static func display(id: Int?, in content: SCShareableContent) throws -> SCDisplay {
        let wanted = id.map { CGDirectDisplayID($0) } ?? CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == wanted }) else {
            throw ToolError("No display with id \(wanted). Use list_displays to see available displays.")
        }
        return display
    }

    static func describe(_ d: SCDisplay) -> JSON {
        let scale = SCContentFilter(display: d, excludingWindows: []).pointPixelScale
        return [
            "display_id": Int(d.displayID),
            "is_main": d.displayID == CGMainDisplayID(),
            "frame": rectJSON(d.frame),
            "scale": Double(scale),
            "pixel_width": Int(CGFloat(d.width) * CGFloat(scale)),
            "pixel_height": Int(CGFloat(d.height) * CGFloat(scale)),
        ]
    }

    // MARK: Windows

    /// Normal (layer 0) app windows, ordered front-to-back.
    static func appWindows(in content: SCShareableContent) -> [SCWindow] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [JSON] ?? []
        var rank: [CGWindowID: Int] = [:]
        for (i, w) in info.enumerated() {
            if let n = w[kCGWindowNumber as String] as? NSNumber, rank[n.uint32Value] == nil {
                rank[n.uint32Value] = i
            }
        }
        return content.windows
            .filter { $0.windowLayer == 0 && $0.owningApplication != nil && $0.frame.width >= 40 && $0.frame.height >= 40 }
            .sorted { (rank[$0.windowID] ?? .max) < (rank[$1.windowID] ?? .max) }
    }

    /// Resolve a window from `window_id`, or the frontmost window matching `app` and/or `title` substrings.
    static func findWindow(_ args: JSON, in content: SCShareableContent) throws -> SCWindow {
        if let id = args.int("window_id") {
            guard let w = content.windows.first(where: { $0.windowID == CGWindowID(id) }) else {
                throw ToolError("No on-screen window with id \(id). Use list_windows to see available windows.")
            }
            return w
        }
        let app = args.string("app")?.lowercased()
        let title = args.string("title")?.lowercased()
        guard app != nil || title != nil else {
            throw ToolError("Provide window_id, or app and/or title to match a window.")
        }
        let match = appWindows(in: content).first { w in
            let appOK = app.map { a in
                [w.owningApplication?.applicationName, w.owningApplication?.bundleIdentifier]
                    .contains { $0?.lowercased().contains(a) == true }
            } ?? true
            let titleOK = title.map { t in w.title?.lowercased().contains(t) == true } ?? true
            return appOK && titleOK
        }
        guard let match else {
            throw ToolError("No on-screen window matched app=\(app ?? "*") title=\(title ?? "*"). Use list_windows.")
        }
        return match
    }

    static func describe(_ w: SCWindow) -> JSON {
        [
            "window_id": Int(w.windowID),
            "app": w.owningApplication?.applicationName ?? "",
            "bundle_id": w.owningApplication?.bundleIdentifier ?? "",
            "pid": Int(w.owningApplication?.processID ?? 0),
            "title": w.title ?? "",
            "frame": rectJSON(w.frame),
            "is_active": w.isActive,
        ]
    }

    // MARK: Screenshots

    static func screenshot(filter: SCContentFilter, sourceRect: CGRect? = nil, size: CGSize, showCursor: Bool) async throws -> CGImage {
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = max(1, Int((size.width * scale).rounded()))
        config.height = max(1, Int((size.height * scale).rounded()))
        if let sourceRect { config.sourceRect = sourceRect }
        config.showsCursor = showCursor
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Lets the user drag a rectangle (or press space to pick a window) with the system UI.
    static func interactiveScreenshot(to url: URL) async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-i", "-x", "-t", url.pathExtension.lowercased() == "jpg" ? "jpg" : "png", url.path]
        try proc.run()
        await withCheckedContinuation { cont in
            proc.terminationHandler = { _ in cont.resume() }
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError("Interactive capture was cancelled.")
        }
    }

    static func save(_ image: CGImage, to url: URL) throws {
        let type: UTType = ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? .jpeg : .png
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ToolError("Cannot write image to \(url.path)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ToolError("Failed to write image to \(url.path)") }
    }

    static func loadImage(_ url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { throw ToolError("Cannot read image at \(url.path)") }
        return img
    }

    /// Downscaled JPEG for returning inline to the model; the full-resolution file stays on disk.
    static func previewContent(_ image: CGImage, maxDimension: Int = 1568) -> JSON? {
        let longest = max(image.width, image.height)
        let factor = longest > maxDimension ? Double(maxDimension) / Double(longest) : 1
        let w = max(1, Int(Double(image.width) * factor)), h = max(1, Int(Double(image.height) * factor))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return ["type": "image", "mimeType": "image/jpeg", "data": (data as Data).base64EncodedString()]
    }
}

// MARK: Helpers

func rectJSON(_ r: CGRect) -> JSON {
    ["x": Double(r.origin.x), "y": Double(r.origin.y), "width": Double(r.width), "height": Double(r.height)]
}

func textContent(_ obj: Any) -> JSON {
    let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    return ["type": "text", "text": String(decoding: data, as: UTF8.self)]
}

/// Where generated file names are saved: SCREENCAP_OUTPUT_DIR if set, otherwise ~/Desktop
/// (matching where macOS's own screenshots and screen recordings land).
var outputDirectory: URL {
    if let custom = ProcessInfo.processInfo.environment["SCREENCAP_OUTPUT_DIR"], !custom.isEmpty {
        return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
}

/// Resolves where to save a capture, creating parent directories. Precedence: an explicit `output_path`
/// (tilde-expanded, used as-is), then the caller's `name`, then `fallback` parts describing what was captured
/// (e.g. app name and window title). Generated names get a timestamp and never overwrite an existing file.
func outputURL(_ requested: String?, name: String?, fallback: [String?], ext: String) throws -> URL {
    let fm = FileManager.default
    if let requested {
        let url = URL(fileURLWithPath: (requested as NSString).expandingTildeInPath)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    // Agents sometimes include an extension ("dialog.png"); the server picks the extension itself.
    var name = name?.trimmingCharacters(in: .whitespaces) ?? ""
    if ["png", "jpg", "jpeg", "mp4", "mov"].contains((name as NSString).pathExtension.lowercased()) {
        name = (name as NSString).deletingPathExtension
    }
    let fromName = slug(name)
    let fromContext = fallback.compactMap { $0.map { slug($0) } }.filter { !$0.isEmpty }.joined(separator: "_")
    let base = !fromName.isEmpty ? fromName : (!fromContext.isEmpty ? fromContext : "capture")

    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    let stem = "\(base)_\(f.string(from: Date()))"
    let dir = outputDirectory
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    var url = dir.appendingPathComponent("\(stem).\(ext)")
    var n = 2
    while fm.fileExists(atPath: url.path) {
        url = dir.appendingPathComponent("\(stem)-\(n).\(ext)")
        n += 1
    }
    return url
}

/// Filename-safe form of `s`: letters and digits (any script) kept with their case, every other run of
/// characters collapsed to one hyphen, trimmed to `maxLength`. "MCP Docs" -> "MCP-Docs".
func slug(_ s: String, maxLength: Int = 60) -> String {
    var out = ""
    var pendingHyphen = false
    for ch in s {
        if ch.isLetter || ch.isNumber {
            if pendingHyphen && !out.isEmpty { out.append("-") }
            out.append(ch)
            pendingHyphen = false
        } else {
            pendingHyphen = true
        }
    }
    var trimmed = String(out.prefix(maxLength))
    while trimmed.hasSuffix("-") { trimmed.removeLast() }
    return trimmed
}
