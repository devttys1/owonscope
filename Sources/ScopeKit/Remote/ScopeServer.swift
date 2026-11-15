import Foundation
import Network

/// Shares a scope on the local network for OwonScope on an iPhone, iPad or another Mac.
///
/// The server owns its own `ScopeEngine` (the scope, or the simulator). The settings are
/// shared: a change from any client goes to the scope and to the other clients. Run/Stop
/// is per client (a client that stops just freezes its own screen); the scope acquires
/// while any client is running. Single and autoset act on the shared scope.
public final class ScopeServer: @unchecked Sendable {
    public let name: String
    public private(set) var port: UInt16?
    /// Log lines (connections, errors), called on the server queue.
    public var onLog: ((String) -> Void)?
    /// Called with the number of connected clients when it changes, on the server queue.
    public var onClientsChanged: ((Int) -> Void)?

    private let queue = DispatchQueue(label: "OwonScope.server", qos: .userInteractive)
    private let engine: ScopeEngine
    private let requestedPort: UInt16?
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]

    // Engine mirror, touched on `queue` only.
    private var settings: ScopeSettings
    private var connection: ConnectionState = .searching
    private var acquiring = false
    private var autosetRequest: (client: ObjectIdentifier, id: Int)?

    private final class Client {
        let link: FramedConnection
        var name = "client"
        var greeted = false
        var wantsRun = false
        var sending = false
        var pending: Acquisition?
        init(_ link: FramedConnection) { self.link = link }
    }

    /// - Parameters:
    ///   - name: Bonjour name; defaults to the computer's name.
    ///   - port: fixed TCP port; nil picks `RemoteProtocol.defaultPort`, or any free port if that is taken.
    public init(name: String? = nil, port: UInt16? = nil, source: ScopeEngine.Source = .hardware,
                settings: ScopeSettings = ScopeSettings()) {
        self.name = name ?? Self.computerName
        self.requestedPort = port
        self.settings = settings
        engine = ScopeEngine(settings: settings, source: source)
        engine.setRunning(false)
        engine.onEvent = { [weak self] e in self?.queue.async { self?.handle(e) } }
    }

    public static var computerName: String {
        #if os(macOS)
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }

    public func start() throws {
        do {
            try listen(port: requestedPort ?? RemoteProtocol.defaultPort)
        } catch where requestedPort == nil {
            // The default port is taken (another server): any free port; Bonjour advertises it.
            try listen(port: nil)
        }
        engine.start()
        log("Sharing as “\(name)” on port \(port.map(String.init) ?? "?")")
    }

    private func listen(port: UInt16?) throws {
        let l = try makeListener(port: port)
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = l.port?.rawValue
                ready.signal()
            case .failed(let e):
                failure = e
                ready.signal()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        if let failure {
            l.cancel()
            throw failure
        }
        listener = l
    }

    private func makeListener(port: UInt16?) throws -> NWListener {
        let params = FramedConnection.parameters()
        let l = try port.map { try NWListener(using: params, on: NWEndpoint.Port(rawValue: $0)!) } ?? NWListener(using: params)
        l.service = NWListener.Service(name: name, type: RemoteProtocol.serviceType)
        return l
    }

    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for c in clients.values { c.link.cancel() }
            clients.removeAll()
        }
        engine.stop()
    }

    public var clientCount: Int { queue.sync { clients.count } }

    private func log(_ s: String) { onLog?(s) }

    // MARK: Clients

    private func accept(_ nw: NWConnection) {
        let link = FramedConnection(nw, queue: queue)
        let client = Client(link)
        let key = ObjectIdentifier(client)
        clients[key] = client
        link.onMessage = { [weak self] m in self?.receive(m, from: key) }
        link.onClose = { [weak self] reason in
            guard let self, let c = self.clients.removeValue(forKey: key) else { return }
            self.log("\(c.name) disconnected (\(reason))")
            if self.autosetRequest?.client == key { self.autosetRequest = nil }
            self.updateRunning()
            self.onClientsChanged?(self.clients.count)
        }
        link.start()
        onClientsChanged?(clients.count)
    }

    private func receive(_ message: RemoteMessage, from key: ObjectIdentifier) {
        guard let client = clients[key], case .control(let m) = message else { return }
        switch m.kind {
        case .hello:
            client.name = m.text ?? "client"
            guard m.version == RemoteProtocol.version else {
                log("\(client.name) uses protocol \(m.version ?? 0); closing")
                client.link.send(.control(ControlMessage(.welcome, version: RemoteProtocol.version, text: name)))
                client.link.cancel()
                return
            }
            client.greeted = true
            let others = clients.values.filter { $0 !== client && $0.greeted }.count
            client.link.send(.control(ControlMessage(.welcome, version: RemoteProtocol.version, text: name,
                                                     settings: settings, connection: WireConnection(connection),
                                                     flag: acquiring, count: others)))
            log("\(client.name) connected")
        case .settings:
            guard let s = m.settings, s != settings else { return }
            settings = s
            engine.update(s)
            broadcast(.control(ControlMessage(.settings, settings: s)), except: key)
        case .run:
            client.wantsRun = m.flag ?? false
            updateRunning()
        case .single:
            for c in clients.values { c.pending = nil }
            client.wantsRun = true
            acquiring = true
            engine.single()
            client.link.send(.control(.armed))
        case .force:
            engine.forceTrigger()
        case .autoset:
            autosetRequest = (key, m.id ?? 0)
            client.wantsRun = true
            acquiring = true
            engine.autoset()
        case .ping:
            client.link.send(.control(.ping))
        case .welcome, .armed, .autosetDone, .connection, .running, .log:
            break
        }
    }

    /// The scope acquires while any client is running.
    private func updateRunning() {
        let want = clients.values.contains { $0.wantsRun }
        guard want != acquiring else { return }
        acquiring = want
        engine.setRunning(want)
    }

    private func broadcast(_ m: RemoteMessage, except: ObjectIdentifier? = nil) {
        for (k, c) in clients where k != except && c.greeted { c.link.send(m) }
    }

    /// Sends the newest acquisition to each running client, dropping frames a slow
    /// client can't keep up with rather than queueing them.
    private func deliver(_ acq: Acquisition) {
        for c in clients.values where c.greeted && c.wantsRun {
            if c.sending { c.pending = acq; continue }
            send(acq, to: c)
        }
    }

    private func send(_ acq: Acquisition, to c: Client) {
        c.sending = true
        c.link.send(.acquisition(acq)) { [weak self, weak c] in
            self?.queue.async {
                guard let c else { return }
                c.sending = false
                if let next = c.pending, c.wantsRun {
                    c.pending = nil
                    self?.send(next, to: c)
                }
            }
        }
    }

    // MARK: Engine events

    private func handle(_ e: EngineEvent) {
        switch e {
        case .acquisition(let a):
            deliver(a)
        case .connection(let c):
            connection = c
            if case .connected(let i) = c { log("Scope connected: \(i.model) \(i.serial)") }
            broadcast(.control(ControlMessage(.connection, connection: WireConnection(c))))
        case .running(let r, _):
            // A single capture finished (or autoset started acquiring).
            acquiring = r
            if !r { for c in clients.values { c.wantsRun = false } }
            broadcast(.control(ControlMessage(.running, flag: r)))
        case .settings(let s):
            settings = s
            if let req = autosetRequest, let c = clients[req.client] {
                c.link.send(.control(ControlMessage(.autosetDone, settings: s, id: req.id)))
                broadcast(.control(ControlMessage(.settings, settings: s)), except: req.client)
            } else {
                broadcast(.control(ControlMessage(.settings, settings: s)))
            }
            autosetRequest = nil
        case .log(let m):
            log(m)
            broadcast(.control(ControlMessage(.log, text: m)))
        }
    }
}
