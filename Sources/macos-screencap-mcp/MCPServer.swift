import Foundation

/// Error whose message is returned to the client as a tool error (isError: true).
struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

typealias JSON = [String: Any]

struct Tool {
    let name: String
    let description: String
    let inputSchema: JSON
    /// Returns MCP content blocks (text / image).
    let handler: (JSON) async throws -> [JSON]
}

/// Minimal MCP server over stdio: newline-delimited JSON-RPC 2.0.
/// State is immutable after init or guarded (outLock, DispatchGroup), so sharing across tasks is safe.
final class MCPServer: @unchecked Sendable {
    static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    let name: String
    let version: String
    let tools: [String: Tool]
    private let toolOrder: [String]
    private let outLock = NSLock()
    private let onShutdown: () async -> Void

    init(name: String, version: String, tools: [Tool], onShutdown: @escaping () async -> Void) {
        self.name = name
        self.version = version
        self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        self.toolOrder = tools.map(\.name)
        self.onShutdown = onShutdown
    }

    func run() -> Never {
        // Finalize any in-progress recordings before exiting so files aren't left corrupt.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [self] in shutdown() }
            source.resume()
            signalSources.append(source)
        }

        Thread.detachNewThread { [self] in
            while let line = readLine(strippingNewline: true) {
                guard !line.isEmpty,
                      let data = line.data(using: .utf8),
                      let msg = try? JSONSerialization.jsonObject(with: data) as? JSON
                else { continue }
                inFlight.enter()
                Task {
                    await self.handle(msg)
                    self.inFlight.leave()
                }
            }
            shutdown()
        }
        dispatchMain()
    }

    private var signalSources: [DispatchSourceSignal] = []
    private let inFlight = DispatchGroup()

    private func shutdown() {
        Task {
            await onShutdown()
            // Let requests that arrived before EOF finish and reply, but don't hang forever
            // (e.g. a start_recording call still sleeping out its duration).
            DispatchQueue.global().async { [self] in
                _ = inFlight.wait(timeout: .now() + 10)
                exit(0)
            }
        }
    }

    private func handle(_ msg: JSON) async {
        let id = msg["id"]
        // Messages without a method are responses to requests we never send; ignore them.
        guard let method = msg["method"] as? String else { return }
        let params = msg["params"] as? JSON ?? [:]

        let result: JSON
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            result = [
                "protocolVersion": Self.supportedProtocolVersions.contains(requested)
                    ? requested : Self.supportedProtocolVersions[0],
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": name, "version": version],
            ]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": toolOrder.map { name -> JSON in
                let t = tools[name]!
                return ["name": t.name, "description": t.description, "inputSchema": t.inputSchema]
            }]
        case "tools/call":
            guard let toolName = params["name"] as? String, let tool = tools[toolName] else {
                if let id { sendError(id: id, code: -32602, message: "Unknown tool: \(params["name"] ?? "nil")") }
                return
            }
            let args = params["arguments"] as? JSON ?? [:]
            do {
                result = ["content": try await tool.handler(args)]
            } catch {
                log("tool \(toolName) failed: \(error)")
                result = ["content": [["type": "text", "text": "\(error)"]], "isError": true]
            }
        default:
            // Notifications (no id) such as notifications/initialized need no reply.
            if let id { sendError(id: id, code: -32601, message: "Method not found: \(method)") }
            return
        }
        if let id { send(["jsonrpc": "2.0", "id": id, "result": result]) }
    }

    private func sendError(id: Any, code: Int, message: String) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func send(_ obj: JSON) {
        guard var data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else {
            log("failed to encode response")
            return
        }
        data.append(0x0A)
        outLock.lock()
        FileHandle.standardOutput.write(data)
        outLock.unlock()
    }
}

/// stdout is reserved for protocol messages; all diagnostics go to stderr.
func log(_ message: String) {
    FileHandle.standardError.write(Data("[macos-screencap-mcp] \(message)\n".utf8))
}

extension Dictionary where Key == String, Value == Any {
    func int(_ key: String) -> Int? {
        guard let n = self[key] as? NSNumber else { return nil }
        return n.intValue
    }

    func double(_ key: String) -> Double? {
        (self[key] as? NSNumber)?.doubleValue
    }

    func bool(_ key: String) -> Bool? {
        (self[key] as? NSNumber)?.boolValue
    }

    func string(_ key: String) -> String? {
        guard let s = self[key] as? String, !s.isEmpty else { return nil }
        return s
    }
}
