# macos-screencap-mcp

A local MCP server (stdio) for macOS that takes screenshots and records the screen. It is a single native Swift
binary built on ScreenCaptureKit and has no runtime dependencies.

With it, an agent such as Claude Code can:

- take a screenshot of a rectangle of the screen, a whole display, or one window (even when other windows cover it)
- let you drag-select an area to capture
- record a whole display or one window to MP4, either for a set time or from start to stop
- see what it captured, because screenshots are also returned inline as an image

Example requests to your agent:

> Take a screenshot of the Safari window and tell me what's wrong with the layout.
>
> Record my main display for 10 seconds.
>
> Start recording the Simulator window. … OK, stop recording.

## Requirements

- macOS 15+
- Xcode / Swift 6 toolchain (to build)
- **Screen Recording permission** for the app that launches the server (Terminal, iTerm, Claude Desktop, etc.):
  System Settings → Privacy & Security → Screen & System Audio Recording. Restart that app after granting it.

## Install

The npm package contains a prebuilt universal binary (Apple Silicon and Intel), so you don't need Swift or Xcode.

Claude Code:

```bash
claude mcp add screencap --scope user -- npx -y macos-screencap-mcp
```

Claude Desktop (`~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "screencap": { "command": "npx", "args": ["-y", "macos-screencap-mcp"] }
  }
}
```

Any other MCP client can run it the same way: the command is `npx -y macos-screencap-mcp`, over stdio. To skip
npx's startup check, install it globally with `npm install -g macos-screencap-mcp` and use the command
`macos-screencap-mcp`.

### Build from source

```bash
git clone https://github.com/freeflow-im/macos-screencap-mcp.git
cd macos-screencap-mcp
swift build -c release
claude mcp add screencap --scope user -- "$PWD/.build/release/macos-screencap-mcp"
```

### Releasing

Bump `version` in `package.json` and `Sources/macos-screencap-mcp/Version.swift` (the build fails if they
differ), then run `npm publish`. The `prepack` script builds the universal binary into `bin/`.

## Tools

| Tool | What it does |
|---|---|
| `list_displays` | Display ids, frames (global points), pixel scale |
| `list_windows` | On-screen app windows, frontmost first: `window_id`, app, title, frame. Optional `app` filter |
| `screenshot_region` | Capture `x, y, width, height` (global points), or a whole display if the rect is omitted, or `interactive: true` to let the user drag-select |
| `screenshot_window` | Capture one window by `window_id`, or by `app` / `title` substring (frontmost match). The window is captured even when other windows cover it |
| `start_recording` | `target: "display"` (with optional `display_id`) or `target: "window"` (`window_id` / `app` / `title`). With `duration_seconds` the call blocks and returns the finished file. Without it, the call returns a `recording_id` |
| `stop_recording` | Finalize a recording. `recording_id` is optional when only one recording is active |
| `list_recordings` | Show the recordings that are in progress |

Screenshot tools save full-resolution PNG files, or JPEG when `output_path` ends in `.jpg`. They also return a
downscaled JPEG preview inline so the model can see the capture; pass `include_image: false` to skip it.

Recordings are H.264 MP4 by default, or MOV when `output_path` ends in `.mov`. Above 4096 px they switch to
HEVC automatically. Recording options: `fps` (default 30), `show_cursor` (default true), `system_audio`,
`microphone`.

### Coordinates

All rectangles use macOS global display coordinates in points. The origin is the top-left of the main display,
and displays to the left or above it have negative coordinates. This is the same space that `list_displays` and
`list_windows` report, so you can pass a window's `frame` straight to `screenshot_region`. A rectangle is clipped
to the display that contains its center.

### File names and location

The capture tools take an optional `name`: a short description of the content, such as `teams-tab-my-trips`.
The tool descriptions ask agents to pass one. The server cleans up the name, adds a timestamp and picks the
folder:

```
teams-tab-my-trips_2026-10-28_16-30-02.png
```

When `name` is omitted, the server builds one from what it captured:

| Capture | Default name |
|---|---|
| Window (screenshot or recording) | `<App>_<window-title>_<timestamp>` |
| Region | The frontmost window under the region's center, as above |
| Whole display | `display-<id>_<timestamp>` |
| Interactive selection | `selection_<timestamp>` |

Names never overwrite an existing file. A collision within the same second gets a `-2`, `-3`, and so on.

Screenshots and recordings go to `~/Desktop`, the same place macOS saves its own captures. Set
`SCREENCAP_OUTPUT_DIR` to use another folder. `output_path` overrides all of this with an exact path.

If the server shuts down while recordings are still running (the client disconnects, SIGTERM, or SIGINT), it
finalizes them first so the files stay playable.

## Troubleshooting

- **"Could not read screen content"**: the app that launched the server lacks Screen Recording permission. Grant it
  under System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen that app.
  Permission belongs to the launching app (e.g. Terminal), not to this binary.
- **A window can't be found**: only on-screen windows are listed, so minimized windows and windows on other Spaces
  don't appear. Call `list_windows` to see what is available.
- **Interactive capture returns "cancelled"**: the user pressed Esc, or no one was at the screen to make a
  selection.

## How it works

The server speaks MCP's newline-delimited JSON-RPC over stdin/stdout. All logging goes to stderr. Screenshots
use `SCScreenshotManager`. Recordings use an `SCStream` with an `SCRecordingOutput`, which writes the video file
directly. Interactive selection hands off to the system `screencapture -i` tool.

| File | Contents |
|---|---|
| `Sources/macos-screencap-mcp/MCPServer.swift` | MCP protocol over stdio |
| `Sources/macos-screencap-mcp/Capture.swift` | Displays, windows, screenshots, file naming |
| `Sources/macos-screencap-mcp/Recording.swift` | Screen and window recording |
| `Sources/macos-screencap-mcp/main.swift` | Tool definitions |

## License

MIT. See [LICENSE](LICENSE).
