import Foundation
import Network

/// Acquisition backend for a scope shared by a `ScopeServer` on another computer.
///
/// The engine drives it like local hardware: `apply` sends settings, `poll` hands back the
/// newest acquisition streamed by the server, `keepAlive` (called while stopped) tells the
/// server this client has stopped. Connection state, settings changed by other clients and
/// the server's log come back through `events`.
public final class RemoteBackend: AcquisitionBackend, @unchecked Sendable {
    public enum Event {
        case connection(ConnectionState)
        /// Settings changed elsewhere (another client, or the server's autoset).
        case settings(ScopeSettings)
        case log(String)
    }

    public private(set) var info: DeviceInfo
    public let target: RemoteTarget

    private let queue = DispatchQueue(label: "OwonScope.remote", qos: .userInteractive)
    private let link: FramedConnection
    private let events: (Event) -> Void
    private let lock = NSLock()

    // guarded by `lock`
    private var closedReason: String?
    private var latest: Acquisition?
    private var lastSequence = -1
    private var serverSettings: ScopeSettings?
    private var remoteConnected = false
    private var singleArmed = false
    private var autosetWaiter: (id: Int, sema: DispatchSemaphore, result: ScopeSettings?)?

    // engine thread only
    private var runRequested = false
    private var sentSettings: ScopeSettings?
    private var adoptServerSettings = false
    private var lastPing = Date()
    private var autosetID = 0

    /// Connects and waits for the server's welcome (up to `timeout` seconds).
    /// - Parameter localSettings: this client's settings. They are pushed to the scope if no
    ///   other client is connected; otherwise this client adopts the shared settings.
    public init(target: RemoteTarget, clientName: String, localSettings: ScopeSettings,
                timeout: Double = 6, events: @escaping (Event) -> Void) throws {
        self.target = target
        self.events = events
        info = DeviceInfo(model: "Remote scope", serial: "", hardwareVersion: "", fpgaVersion: 0,
                          isSimulated: false, host: target.name)
        link = FramedConnection(to: target.endpoint, queue: queue)

        let welcomed = DispatchSemaphore(value: 0)
        var welcome: ControlMessage?
        link.onReady = { [link] in
            link.send(.control(ControlMessage(.hello, version: RemoteProtocol.version, text: clientName)))
        }
        link.onMessage = { [weak self] m in
            if welcome == nil, case .control(let c) = m, c.kind == .welcome {
                welcome = c
                welcomed.signal()
                return
            }
            self?.receive(m)
        }
        link.onClose = { [weak self] reason in
            self?.lock.lock()
            self?.closedReason = reason
            let waiter = self?.autosetWaiter
            self?.lock.unlock()
            waiter?.sema.signal()
            if welcome == nil { welcomed.signal() }
        }
        link.start()

        if welcomed.wait(timeout: .now() + timeout) == .timedOut {
            link.cancel()
            throw RemoteError.timeout("“\(target.name)” didn't answer. Check that it is sharing its scope and is on the same network.")
        }
        lock.lock(); let reason = closedReason; lock.unlock()
        guard let w = welcome else {
            throw RemoteError.closed(reason ?? "Couldn't connect to “\(target.name)”.")
        }
        guard w.version == RemoteProtocol.version else {
            link.cancel()
            throw RemoteError.incompatible(w.version ?? 0)
        }
        // Another client is already using the scope: join its session rather than
        // overwriting its settings with ours.
        if (w.count ?? 0) > 0, let s = w.settings {
            serverSettings = s
            sentSettings = s
            adoptServerSettings = true
            events(.settings(s))
        }
        _ = localSettings
        setRemote(w.connection?.state ?? .searching)
    }

    private func setRemote(_ state: ConnectionState) {
        var s = state
        if case .connected(var i) = state {
            i.host = target.name
            info = i
            s = .connected(i)
        }
        lock.lock(); remoteConnected = s.isConnected; lock.unlock()
        events(.connection(s))
    }

    private func receive(_ m: RemoteMessage) {
        switch m {
        case .acquisition(let a):
            lock.lock()
            // While a single capture is armed, skip frames still in flight from before it.
            if !singleArmed || a.settings.trigger.sweep == .single { latest = a }
            lock.unlock()
        case .control(let c):
            switch c.kind {
            case .settings:
                guard let s = c.settings else { return }
                lock.lock(); serverSettings = s; lock.unlock()
                events(.settings(s))
            case .connection:
                if let w = c.connection { setRemote(w.state) }
            case .running:
                // The server stopped after a single capture: ask again when we next poll.
                if c.flag == false { lock.lock(); serverStopped = true; lock.unlock() }
            case .armed:
                break
            case .autosetDone:
                lock.lock()
                if let w = autosetWaiter, w.id == c.id {
                    autosetWaiter?.result = c.settings
                    serverSettings = c.settings
                    w.sema.signal()
                }
                lock.unlock()
            case .log:
                if let t = c.text { events(.log("[\(target.name)] \(t)")) }
            case .hello, .welcome, .run, .single, .force, .autoset, .ping:
                break
            }
        }
    }

    private var serverStopped = false

    private func checkOpen() throws {
        lock.lock(); let reason = closedReason; lock.unlock()
        if let reason { throw RemoteError.closed("Lost “\(target.name)”: \(reason)") }
    }

    private func send(_ m: ControlMessage) { link.send(.control(m)) }

    // MARK: AcquisitionBackend

    public func apply(_ settings: ScopeSettings, force: Bool) throws {
        try checkOpen()
        if adoptServerSettings {
            // The engine's first (forced) apply after connecting carries our stale settings.
            adoptServerSettings = false
            return
        }
        lock.lock(); let server = serverSettings; lock.unlock()
        guard force || settings != sentSettings, settings != server || force else { return }
        sentSettings = settings
        lock.lock(); serverSettings = settings; lock.unlock()
        send(ControlMessage(.settings, settings: settings))
    }

    public func arm(_ settings: ScopeSettings) throws {
        try apply(settings, force: false)
        lock.lock(); singleArmed = true; latest = nil; serverStopped = false; lock.unlock()
        runRequested = true
        send(ControlMessage(.single))
    }

    public func poll(_ settings: ScopeSettings) throws -> Acquisition? {
        try checkOpen()
        lock.lock()
        let stopped = serverStopped
        serverStopped = false
        let a = latest
        latest = nil
        let connected = remoteConnected
        lock.unlock()
        if stopped && settings.trigger.sweep != .single { runRequested = false }
        if !runRequested {
            runRequested = true
            send(ControlMessage(.run, flag: true))
        }
        pingIfIdle()
        guard connected, let a, a.sequence != lastSequence else { return nil }
        lastSequence = a.sequence
        if a.settings.trigger.sweep == .single { lock.lock(); singleArmed = false; lock.unlock() }
        return a
    }

    public func forceTrigger() throws {
        try checkOpen()
        send(ControlMessage(.force))
    }

    public func keepAlive() throws {
        try checkOpen()
        if runRequested {
            runRequested = false
            send(ControlMessage(.run, flag: false))
        }
        pingIfIdle()
    }

    private func pingIfIdle() {
        guard Date().timeIntervalSince(lastPing) > 2 else { return }
        lastPing = Date()
        send(ControlMessage(.ping))
    }

    public func autoset(from settings: ScopeSettings) throws -> ScopeSettings? {
        try apply(settings, force: false)
        autosetID += 1
        let sema = DispatchSemaphore(value: 0)
        lock.lock(); autosetWaiter = (autosetID, sema, nil); lock.unlock()
        runRequested = true
        send(ControlMessage(.autoset, id: autosetID))
        let timedOut = sema.wait(timeout: .now() + 30) == .timedOut
        lock.lock()
        let result = autosetWaiter?.result
        autosetWaiter = nil
        lock.unlock()
        try checkOpen()
        if timedOut { throw RemoteError.timeout("Autoset on “\(target.name)” timed out.") }
        if let result { sentSettings = result }
        return result ?? settings
    }

    public func close() { link.cancel() }
}

/// Finds scopes shared on the local network.
public final class RemoteBrowser: @unchecked Sendable {
    private let queue = DispatchQueue(label: "OwonScope.browser")
    private var browser: NWBrowser?
    /// Called on the main queue with the service names found, sorted.
    public var onChange: (([String]) -> Void)?
    /// Called on the main queue when browsing fails (for example, local network access denied).
    public var onError: ((String) -> Void)?

    public init() {}

    public func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjour(type: RemoteProtocol.serviceType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let names = results.compactMap { r -> String? in
                if case .service(let name, _, _, _) = r.endpoint { return name }
                return nil
            }
            let sorted = Array(Set(names)).sorted()
            DispatchQueue.main.async { self?.onChange?(sorted) }
        }
        b.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let e), .waiting(let e):
                DispatchQueue.main.async { self?.onError?(e.localizedDescription) }
            default: break
            }
        }
        browser = b
        b.start(queue: queue)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }
}
