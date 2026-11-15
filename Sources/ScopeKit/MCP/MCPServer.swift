import Foundation
import Network
import Observation

/// What a tool call returns: MCP content blocks (text, image) and whether it failed.
public struct MCPToolResult {
    public var content: [[String: Any]]
    public var isError: Bool

    public init(content: [[String: Any]], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public static func text(_ s: String, isError: Bool = false) -> MCPToolResult {
        MCPToolResult(content: [["type": "text", "text": s]], isError: isError)
    }

    /// Adds an image block (e.g. a PNG of the screen) after the text.
    public func adding(image data: Data, mimeType: String = "image/png") -> MCPToolResult {
        var r = self
        r.content.append(["type": "image", "data": data.base64EncodedString(), "mimeType": mimeType])
        return r
    }
}

/// The tools an `MCPServer` serves.
@MainActor
public protocol MCPToolProvider: AnyObject {
    /// Shown to the agent when it connects.
    var instructions: String { get }
    /// `tools/list` entries: name, description, inputSchema, annotations.
    var definitions: [[String: Any]] { get }
    func call(_ name: String, _ arguments: [String: Any]) async -> MCPToolResult
}

/// A Model Context Protocol server, so AI agents can read and drive the app.
///
/// Streamable HTTP transport with JSON responses (no SSE), bound to 127.0.0.1 only. The
/// same layout as MDP Bench's server, so one agent can drive both:
///   claude mcp add --transport http owonscope http://127.0.0.1:8908/mcp
@MainActor
@Observable
public final class MCPServer {
    public let name: String
    public let title: String
    public let version: String

    public private(set) var running = false
    public private(set) var status = "Off"
    /// The port asked for; 0 picks a free one (tests). `port` is the one in use once running.
    public private(set) var port: UInt16
    public private(set) var requests = 0
    public private(set) var lastClient: String?
    public var url: String { "http://127.0.0.1:\(port)/mcp" }

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private let provider: MCPToolProvider
    @ObservationIgnored private let queue: DispatchQueue
    @ObservationIgnored private var readyWaiters: [CheckedContinuation<Void, Never>] = []

    public init(name: String, title: String, version: String, port: UInt16, provider: MCPToolProvider) {
        self.name = name
        self.title = title
        self.version = version
        self.port = port
        self.provider = provider
        queue = DispatchQueue(label: "\(name).mcp")
    }

    public func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
            let l = try NWListener(using: params)
            let weakSelf = WeakBox(self)
            l.stateUpdateHandler = { state in
                DispatchQueue.main.async { MainActor.assumeIsolated { weakSelf.value?.listenerState(state) } }
            }
            let queue = self.queue
            l.newConnectionHandler = { conn in
                let c = MCPHTTPConnection(conn) { req in
                    await weakSelf.value?.handle(req) ?? .text(503, "Unavailable")
                }
                c.start(on: queue)
            }
            listener = l
            status = "Starting"
            l.start(queue: queue)
        } catch {
            status = "Couldn't start: \(error.localizedDescription)"
            resumeWaiters()
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        running = false
        status = "Off"
    }

    /// Waits until the listener is ready (or has failed).
    public func waitUntilReady() async {
        if running || listener == nil { return }
        await withCheckedContinuation { readyWaiters.append($0) }
    }

    private func resumeWaiters() {
        let w = readyWaiters
        readyWaiters = []
        w.forEach { $0.resume() }
    }

    private func listenerState(_ s: NWListener.State) {
        switch s {
        case .ready:
            if let p = listener?.port?.rawValue { port = p }
            running = true
            status = "Listening on \(url)"
            print("MCP server listening on \(url)")
            resumeWaiters()
        case .failed(let e):
            running = false
            status = "Failed: \(e.localizedDescription)"
            listener?.cancel()
            listener = nil
            resumeWaiters()
        case .cancelled:
            running = false
            resumeWaiters()
        default: break
        }
    }

    // MARK: HTTP -> JSON-RPC

    func handle(_ req: MCPHTTPRequest) async -> MCPHTTPResponse {
        // DNS-rebinding guard: browsers send Origin; only local pages may talk to us.
        if let origin = req.headers["origin"], let host = URL(string: origin)?.host,
           !["localhost", "127.0.0.1", "::1"].contains(host) {
            return .text(403, "Forbidden origin")
        }
        guard req.path.split(separator: "?").first == "/mcp" else { return .text(404, "Not found. The MCP endpoint is /mcp") }
        guard req.method == "POST" else { return .text(405, "Method not allowed", headers: ["Allow": "POST"]) }
        requests += 1
        guard let json = try? JSONSerialization.jsonObject(with: req.body) else {
            return .json(Self.rpcError(nil, -32700, "Parse error"))
        }
        if let batch = json as? [[String: Any]] {
            var out: [[String: Any]] = []
            for m in batch { if let r = await rpc(m) { out.append(r) } }
            return out.isEmpty ? MCPHTTPResponse(status: 202) : .json(out)
        }
        guard let msg = json as? [String: Any] else { return .json(Self.rpcError(nil, -32600, "Invalid request")) }
        guard let reply = await rpc(msg) else { return MCPHTTPResponse(status: 202) }
        return .json(reply)
    }

    /// One JSON-RPC message; nil for notifications and responses (nothing to send back).
    private func rpc(_ m: [String: Any]) async -> [String: Any]? {
        guard let method = m["method"] as? String, let id = m["id"], !(id is NSNull) else { return nil }
        let params = m["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            if let info = params["clientInfo"] as? [String: Any] { lastClient = info["name"] as? String }
            let version = params["protocolVersion"] as? String ?? "2025-06-18"
            return Self.result(id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": name, "title": title, "version": self.version],
                "instructions": provider.instructions,
            ])
        case "ping":
            return Self.result(id, [:])
        case "tools/list":
            return Self.result(id, ["tools": provider.definitions])
        case "tools/call":
            guard let tool = params["name"] as? String else { return Self.rpcError(id, -32602, "Missing tool name") }
            guard provider.definitions.contains(where: { $0["name"] as? String == tool }) else {
                return Self.rpcError(id, -32602, "Unknown tool \(tool)")
            }
            let r = await provider.call(tool, params["arguments"] as? [String: Any] ?? [:])
            return Self.result(id, ["content": r.content, "isError": r.isError])
        case "resources/list": return Self.result(id, ["resources": []])
        case "resources/templates/list": return Self.result(id, ["resourceTemplates": []])
        case "prompts/list": return Self.result(id, ["prompts": []])
        default:
            return Self.rpcError(id, -32601, "Method not found: \(method)")
        }
    }

    private static func result(_ id: Any?, _ r: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": r]
    }

    private static func rpcError(_ id: Any?, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }
}

private final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ v: T) { value = v }
}

// MARK: - Minimal HTTP/1.1

struct MCPHTTPRequest: Sendable {
    var method: String
    var path: String
    /// Lower-cased names.
    var headers: [String: String]
    var body: Data
}

struct MCPHTTPResponse: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()

    static func text(_ status: Int, _ s: String, headers: [String: String] = [:]) -> MCPHTTPResponse {
        MCPHTTPResponse(status: status, headers: headers.merging(["Content-Type": "text/plain; charset=utf-8"]) { a, _ in a }, body: Data(s.utf8))
    }

    static func json(_ obj: Any) -> MCPHTTPResponse {
        let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return MCPHTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: d)
    }

    static let reasons = [200: "OK", 202: "Accepted", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
                          405: "Method Not Allowed", 413: "Payload Too Large", 503: "Service Unavailable"]
}

/// Reads requests off one TCP connection (keep-alive) and answers each in turn.
final class MCPHTTPConnection: @unchecked Sendable {
    private let conn: NWConnection
    private let handler: @Sendable (MCPHTTPRequest) async -> MCPHTTPResponse
    private var buffer = Data()
    private static let maxBody = 4 << 20

    init(_ conn: NWConnection, handler: @escaping @Sendable (MCPHTTPRequest) async -> MCPHTTPResponse) {
        self.conn = conn
        self.handler = handler
    }

    func start(on queue: DispatchQueue) {
        conn.start(queue: queue)
        receive()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [self] data, _, done, error in
            if let data { buffer.append(data) }
            if error != nil { conn.cancel(); return }
            if !parseAndServe() {
                if done { conn.cancel() } else { receive() }
            }
        }
    }

    /// Serves one complete request from the buffer; false if more bytes are needed.
    private func parseAndServe() -> Bool {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ").map(String.init)
        guard start.count >= 2 else { respond(.text(400, "Bad request"), close: true); return true }
        var headers: [String: String] = [:]
        for l in lines {
            guard let c = l.firstIndex(of: ":") else { continue }
            headers[l[..<c].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length <= Self.maxBody else { respond(.text(413, "Too large"), close: true); return true }
        let bodyStart = end.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return false }
        let bodyEnd = buffer.index(bodyStart, offsetBy: length)
        let body = Data(buffer[bodyStart..<bodyEnd])
        buffer = Data(buffer[bodyEnd...])
        let req = MCPHTTPRequest(method: start[0].uppercased(), path: start[1], headers: headers, body: body)
        let close = headers["connection"]?.lowercased() == "close"
        Task {
            let r = await handler(req)
            respond(r, close: close)
        }
        return true
    }

    private func respond(_ r: MCPHTTPResponse, close: Bool) {
        var head = "HTTP/1.1 \(r.status) \(MCPHTTPResponse.reasons[r.status] ?? "Status")\r\n"
        var h = r.headers
        h["Content-Length"] = "\(r.body.count)"
        h["Connection"] = close ? "close" : "keep-alive"
        h["Cache-Control"] = "no-store"
        for (k, v) in h { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        conn.send(content: Data(head.utf8) + r.body, completion: .contentProcessed { [self] _ in
            if close { conn.cancel() } else if !parseAndServe() { receive() }
        })
    }
}
