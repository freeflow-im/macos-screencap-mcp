import AppKit
import ScreenCaptureKit

// Connect to the window server so ScreenCaptureKit works from a command-line process.
_ = NSApplication.shared

let recordings = RecordingStore()

func schema(_ properties: JSON, required: [String] = []) -> JSON {
    ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
}

let windowSelector: JSON = [
    "window_id": ["type": "integer", "description": "Window id from list_windows."],
    "app": ["type": "string", "description": "Case-insensitive substring of the app name or bundle id. Used when window_id is omitted; the frontmost match wins."],
    "title": ["type": "string", "description": "Case-insensitive substring of the window title. Used when window_id is omitted."],
]
let nameProp: JSON = ["type": "string", "description": """
    Please provide this. A short kebab-case name for what is being captured, written so someone browsing the \
    folder later knows what the file shows, e.g. "teams-tab-my-trips", "checkout-error-dialog", \
    "login-flow-demo". The server adds a timestamp and chooses the folder, so leave out dates, \
    extensions and paths. If omitted, the name is built from the app and window title.
    """]
let outputPathProp: JSON = ["type": "string", "description": "Exact file path to write (~ is expanded). Rarely needed: prefer `name` and let the server choose the folder (~/Desktop, or SCREENCAP_OUTPUT_DIR)."]
let namingHint = "Pass `name` with a short description of the content so the saved file is easy to find later."

func requestedExt(_ args: JSON, _ allowed: [String], default def: String) -> String {
    guard let ext = args.string("output_path").map({ ($0 as NSString).pathExtension.lowercased() }) else { return def }
    if ext == "jpeg" { return "jpg" }
    return allowed.contains(ext) ? ext : def
}
let includeImageProp: JSON = ["type": "boolean", "description": "Return a downscaled preview of the image inline. Default true."]
let showCursorProp: JSON = ["type": "boolean", "description": "Include the mouse cursor."]

func screenshotResult(_ image: CGImage, url: URL, extra: JSON, includeImage: Bool) -> [JSON] {
    var info = extra
    info["output_path"] = url.path
    info["pixel_width"] = image.width
    info["pixel_height"] = image.height
    var content = [textContent(info)]
    if includeImage, let preview = Capture.previewContent(image) { content.append(preview) }
    return content
}

func startRecording(_ args: JSON) async throws -> Recording {
    guard let targetKind = args.string("target"), ["display", "window"].contains(targetKind) else {
        throw ToolError("target must be \"display\" or \"window\".")
    }
    let content = try await Capture.shareableContent()
    let filter: SCContentFilter
    let size: CGSize
    let target: JSON
    let fallbackName: [String?]
    if targetKind == "window" {
        let window = try Capture.findWindow(args, in: content)
        filter = SCContentFilter(desktopIndependentWindow: window)
        size = filter.contentRect.size
        target = ["type": "window"].merging(Capture.describe(window)) { a, _ in a }
        fallbackName = [window.owningApplication?.applicationName, window.title]
    } else {
        let display = try Capture.display(id: args.int("display_id"), in: content)
        filter = SCContentFilter(display: display, excludingWindows: [])
        size = display.frame.size
        target = ["type": "display", "display_id": Int(display.displayID)]
        fallbackName = ["display-\(display.displayID)"]
    }

    let url = try outputURL(args.string("output_path"), name: args.string("name"), fallback: fallbackName,
                            ext: requestedExt(args, ["mov", "mp4"], default: "mp4"))
    if FileManager.default.fileExists(atPath: url.path) {
        throw ToolError("\(url.path) already exists; choose another output_path.")
    }

    let recording = try Recording(
        id: await recordings.nextID(), url: url, target: target, filter: filter, size: size,
        fps: args.int("fps") ?? 30,
        showCursor: args.bool("show_cursor") ?? true,
        systemAudio: args.bool("system_audio") ?? false,
        microphone: args.bool("microphone") ?? false)
    try await recording.start()
    await recordings.add(recording)
    log("started \(recording.id) -> \(url.path)")
    return recording
}

let tools: [Tool] = [
    Tool(
        name: "list_displays",
        description: "List connected displays with their ids, frames (in global points, origin at top-left of the main display), and pixel scale.",
        inputSchema: schema([:])
    ) { _ in
        let content = try await Capture.shareableContent()
        return [textContent(content.displays.map(Capture.describe))]
    },

    Tool(
        name: "list_windows",
        description: "List on-screen application windows, frontmost first, with window ids, app names, titles and frames (global points).",
        inputSchema: schema([
            "app": ["type": "string", "description": "Only include windows whose app name or bundle id contains this (case-insensitive)."],
        ])
    ) { args in
        let content = try await Capture.shareableContent()
        var windows = Capture.appWindows(in: content)
        if let app = args.string("app")?.lowercased() {
            windows = windows.filter {
                [$0.owningApplication?.applicationName, $0.owningApplication?.bundleIdentifier]
                    .contains { $0?.lowercased().contains(app) == true }
            }
        }
        return [textContent(windows.map(Capture.describe))]
    },

    Tool(
        name: "screenshot_region",
        description: """
            Capture a rectangle of the screen. x/y/width/height are in global points (same space as list_displays and \
            list_windows frames). Omit the rectangle to capture an entire display. Set interactive=true to let the user \
            drag-select a region on screen instead. Saves PNG (or JPEG if output_path ends in .jpg). \(namingHint)
            """,
        inputSchema: schema([
            "name": nameProp,
            "x": ["type": "number"],
            "y": ["type": "number"],
            "width": ["type": "number"],
            "height": ["type": "number"],
            "display_id": ["type": "integer", "description": "Display to capture from. Defaults to the display containing the rectangle, or the main display."],
            "interactive": ["type": "boolean", "description": "Let the user select the region with the macOS crosshair (blocks until they finish or press Esc)."],
            "show_cursor": showCursorProp,
            "include_image": includeImageProp,
            "output_path": outputPathProp,
        ])
    ) { args in
        let ext = requestedExt(args, ["png", "jpg"], default: "png")
        let includeImage = args.bool("include_image") ?? true

        if args.bool("interactive") == true {
            let url = try outputURL(args.string("output_path"), name: args.string("name"), fallback: ["selection"],
                                    ext: ext)
            try await Capture.interactiveScreenshot(to: url)
            return screenshotResult(try Capture.loadImage(url), url: url, extra: ["mode": "interactive"], includeImage: includeImage)
        }

        let content = try await Capture.shareableContent()
        let rectKeys = ["x", "y", "width", "height"]
        let given = rectKeys.compactMap { args.double($0) }
        guard given.isEmpty || given.count == 4 else {
            throw ToolError("Provide all of x, y, width, height, or none to capture the whole display.")
        }
        let rect = given.count == 4 ? CGRect(x: given[0], y: given[1], width: given[2], height: given[3]) : nil

        let display: SCDisplay
        if let id = args.int("display_id") {
            display = try Capture.display(id: id, in: content)
        } else if let rect {
            let center = CGPoint(x: rect.midX, y: rect.midY)
            display = try content.displays.first { $0.frame.contains(center) }
                ?? content.displays.max { $0.frame.intersection(rect).area < $1.frame.intersection(rect).area }
                ?? Capture.display(id: nil, in: content)
        } else {
            display = try Capture.display(id: nil, in: content)
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        var captureRect = display.frame
        if let rect {
            captureRect = rect.intersection(display.frame)
            guard !captureRect.isNull, captureRect.width >= 1, captureRect.height >= 1 else {
                throw ToolError("Rectangle \(rect) does not overlap display \(display.displayID) at \(display.frame).")
            }
        }
        // sourceRect is relative to the display's own origin.
        let local = captureRect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        let image = try await Capture.screenshot(filter: filter, sourceRect: local, size: captureRect.size,
                                                 showCursor: args.bool("show_cursor") ?? false)

        // Without a caller-supplied name, name the file after the frontmost window under the region.
        let fallbackName: [String?]
        if rect != nil, let w = Capture.appWindows(in: content).first(where: {
            $0.frame.contains(CGPoint(x: captureRect.midX, y: captureRect.midY))
        }) {
            fallbackName = [w.owningApplication?.applicationName, w.title]
        } else {
            fallbackName = ["display-\(display.displayID)"]
        }
        let url = try outputURL(args.string("output_path"), name: args.string("name"), fallback: fallbackName,
                                ext: ext)
        try Capture.save(image, to: url)
        return screenshotResult(image, url: url,
                                extra: ["display_id": Int(display.displayID), "rect": rectJSON(captureRect)],
                                includeImage: includeImage)
    },

    Tool(
        name: "screenshot_window",
        description: "Capture a single window (even if partially covered by other windows). Identify it by window_id, or by app and/or title substring. \(namingHint)",
        inputSchema: schema(windowSelector.merging([
            "name": nameProp,
            "include_image": includeImageProp,
            "output_path": outputPathProp,
        ]) { a, _ in a })
    ) { args in
        let content = try await Capture.shareableContent()
        let window = try Capture.findWindow(args, in: content)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await Capture.screenshot(filter: filter, size: filter.contentRect.size, showCursor: false)
        let url = try outputURL(args.string("output_path"), name: args.string("name"),
                                fallback: [window.owningApplication?.applicationName, window.title],
                                ext: requestedExt(args, ["png", "jpg"], default: "png"))
        try Capture.save(image, to: url)
        return screenshotResult(image, url: url, extra: ["window": Capture.describe(window)],
                                includeImage: args.bool("include_image") ?? true)
    },

    Tool(
        name: "start_recording",
        description: """
            Record a full display or a single window to MP4 (or MOV if output_path ends in .mov). \
            If duration_seconds is given, this call blocks until the recording finishes and returns the file. \
            Otherwise it returns a recording_id immediately; call stop_recording to finish. \(namingHint)
            """,
        inputSchema: schema(windowSelector.merging([
            "name": nameProp,
            "target": ["type": "string", "enum": ["display", "window"], "description": "Record a whole display or one window."],
            "display_id": ["type": "integer", "description": "For target=display. Defaults to the main display."],
            "duration_seconds": ["type": "number", "description": "Record for this long, then stop and return the file."],
            "fps": ["type": "integer", "description": "Frames per second (1-120). Default 30."],
            "show_cursor": ["type": "boolean", "description": "Include the mouse cursor. Default true."],
            "system_audio": ["type": "boolean", "description": "Record system audio output. Default false."],
            "microphone": ["type": "boolean", "description": "Record the default microphone. Default false."],
            "output_path": outputPathProp,
        ]) { a, _ in a }, required: ["target"])
    ) { args in
        let recording = try await startRecording(args)
        guard let duration = args.double("duration_seconds") else {
            return [textContent(recording.summary(active: true))]
        }
        try? await Task.sleep(for: .seconds(max(0.5, duration)))
        // It may already have been stopped by stop_recording or shutdown.
        guard (try? await recordings.remove(recording.id)) != nil else {
            return [textContent(recording.summary(active: false))]
        }
        return [textContent(await recording.stop())]
    },

    Tool(
        name: "stop_recording",
        description: "Stop an active recording and finalize the video file. recording_id may be omitted when only one recording is active.",
        inputSchema: schema(["recording_id": ["type": "string"]])
    ) { args in
        let recording = try await recordings.remove(args.string("recording_id"))
        return [textContent(await recording.stop())]
    },

    Tool(
        name: "list_recordings",
        description: "List recordings that are currently in progress.",
        inputSchema: schema([:])
    ) { _ in
        [textContent(await recordings.list().map { $0.summary(active: true) })]
    },
]

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

MCPServer(name: "macos-screencap-mcp", version: "0.1.0", tools: tools) {
    for r in await recordings.removeAll() {
        _ = await r.stop()
        log("finalized \(r.id) on shutdown")
    }
}.run()
