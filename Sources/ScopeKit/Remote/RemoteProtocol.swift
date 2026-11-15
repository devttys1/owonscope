import Foundation
import Network

/// Remote scope protocol: a computer with the VDS1022 attached (`ScopeServer`) shares it
/// with OwonScope on other devices (`RemoteBackend`), typically an iPhone or iPad, which
/// can't reach a vendor-class USB device themselves.
///
/// TCP, advertised with Bonjour as `_owonscope._tcp`. Each frame is a 4-byte big-endian
/// length (of what follows), a 1-byte kind, then the payload:
///  - kind 1: a `ControlMessage` as JSON;
///  - kind 2: an acquisition: 4-byte big-endian header length, `AcquisitionHeader` JSON,
///    then each channel's raw ADC counts (one signed byte per sample). Volts are
///    recomputed from the counts and the channel settings, exactly as on the server.
public enum RemoteProtocol {
    public static let serviceType = "_owonscope._tcp"
    public static let version = 1
    public static let defaultPort: UInt16 = 51022
    static let maxFrame = 16 << 20
}

/// Where to find a shared scope: a Bonjour service name, or a host and port typed in.
public struct RemoteTarget: Hashable, Codable, Sendable {
    public var name: String
    public var host: String?
    public var port: UInt16?

    public init(name: String, host: String? = nil, port: UInt16? = nil) {
        self.name = name
        self.host = host
        self.port = port
    }

    public var endpoint: NWEndpoint {
        if let host, !host.isEmpty {
            return .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port ?? RemoteProtocol.defaultPort)!)
        }
        return .service(name: name, type: RemoteProtocol.serviceType, domain: "local.", interface: nil)
    }
}

/// `ConnectionState` as sent over the wire.
public struct WireConnection: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case searching, connecting, loadingFirmware, connected, failed }
    public var kind: Kind
    public var progress: Double?
    public var message: String?
    public var info: DeviceInfo?

    public init(_ s: ConnectionState) {
        switch s {
        case .searching: kind = .searching
        case .connecting: kind = .connecting
        case .loadingFirmware(let p): kind = .loadingFirmware; progress = p
        case .connected(let i): kind = .connected; info = i
        case .failed(let m): kind = .failed; message = m
        }
    }

    public var state: ConnectionState {
        switch kind {
        case .searching: .searching
        case .connecting: .connecting
        case .loadingFirmware: .loadingFirmware(progress ?? 0)
        case .connected: info.map { .connected($0) } ?? .connecting
        case .failed: .failed(message ?? "Error")
        }
    }
}

/// Everything except acquisitions. One flat struct keeps the JSON simple and lets either
/// side ignore fields it doesn't know.
public struct ControlMessage: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// client → server, first message: `version`, `text` = client name
        case hello
        /// server → client, reply to hello: `version`, `text` = server name, `settings`,
        /// `connection`, `flag` = acquiring, `count` = other clients
        case welcome
        /// both ways: the shared settings changed
        case settings
        /// client → server: `flag` = this client wants acquisitions
        case run
        /// client → server: arm a single capture
        case single
        /// server → client: the single capture is armed
        case armed
        case force
        /// client → server: `id`; server → client: `autosetDone` with `id` and `settings`
        case autoset, autosetDone
        /// server → client
        case connection, running, log
        case ping
    }

    public var kind: Kind
    public var version: Int?
    public var text: String?
    public var settings: ScopeSettings?
    public var connection: WireConnection?
    public var flag: Bool?
    public var id: Int?
    public var count: Int?

    public init(_ kind: Kind, version: Int? = nil, text: String? = nil, settings: ScopeSettings? = nil,
                connection: WireConnection? = nil, flag: Bool? = nil, id: Int? = nil, count: Int? = nil) {
        self.kind = kind
        self.version = version
        self.text = text
        self.settings = settings
        self.connection = connection
        self.flag = flag
        self.id = id
        self.count = count
    }
}

struct AcquisitionHeader: Codable {
    struct Channel: Codable {
        var channel: Int
        var t0: Double
        var dt: Double
        var frequency: Double?
        var count: Int
    }
    var sequence: Int
    var timestamp: Double
    var state: String
    var settings: ScopeSettings
    var channels: [Channel]
}

public enum RemoteMessage: Sendable {
    case control(ControlMessage)
    case acquisition(Acquisition)

    enum Kind: UInt8 { case control = 1, acquisition = 2 }

    public static func control(_ kind: ControlMessage.Kind) -> RemoteMessage { .control(ControlMessage(kind)) }

    /// The complete frame, length prefix included.
    public func encoded() throws -> Data {
        var body = Data()
        switch self {
        case .control(let m):
            body.append(Kind.control.rawValue)
            body.append(try JSONEncoder().encode(m))
        case .acquisition(let a):
            body.append(Kind.acquisition.rawValue)
            let present = a.channels.compactMap { $0 }
            let header = AcquisitionHeader(
                sequence: a.sequence, timestamp: a.timestamp.timeIntervalSince1970, state: a.triggerState.rawValue,
                settings: a.settings,
                channels: present.map { .init(channel: $0.channel, t0: $0.t0, dt: $0.dt, frequency: $0.frequencyMeter, count: $0.counts.count) })
            let json = try JSONEncoder().encode(header)
            body.append(contentsOf: UInt32(json.count).bigEndianBytes)
            body.append(json)
            for w in present { w.counts.withUnsafeBytes { body.append(contentsOf: $0) } }
        }
        var frame = Data(UInt32(body.count).bigEndianBytes)
        frame.append(body)
        return frame
    }

    /// Decodes a frame body (kind byte and payload, without the length prefix).
    public static func decode(_ body: Data) throws -> RemoteMessage {
        let bytes = [UInt8](body)
        guard let first = bytes.first, let kind = Kind(rawValue: first) else { throw RemoteError.malformed("unknown frame") }
        switch kind {
        case .control:
            return .control(try JSONDecoder().decode(ControlMessage.self, from: Data(bytes[1...])))
        case .acquisition:
            guard bytes.count >= 5 else { throw RemoteError.malformed("short acquisition") }
            let hlen = Int(UInt32(bigEndianBytes: bytes[1..<5]))
            guard 5 + hlen <= bytes.count else { throw RemoteError.malformed("acquisition header") }
            let h = try JSONDecoder().decode(AcquisitionHeader.self, from: Data(bytes[5..<(5 + hlen)]))
            var offset = 5 + hlen
            var channels: [ChannelWaveform?] = Array(repeating: nil, count: h.settings.channels.count)
            for c in h.channels {
                guard c.channel >= 0, c.channel < channels.count, c.count >= 0, offset + c.count <= bytes.count else {
                    throw RemoteError.malformed("acquisition channel \(c.channel)")
                }
                let counts = bytes[offset..<(offset + c.count)].map { Int8(bitPattern: $0) }
                offset += c.count
                channels[c.channel] = ChannelWaveform(channel: c.channel, counts: counts, t0: c.t0, dt: c.dt,
                                                      frequencyMeter: c.frequency, settings: h.settings.channels[c.channel])
            }
            return .acquisition(Acquisition(channels: channels, settings: h.settings,
                                            timestamp: Date(timeIntervalSince1970: h.timestamp),
                                            triggerState: TriggerState(rawValue: h.state) ?? .auto, sequence: h.sequence))
        }
    }
}

public enum RemoteError: Error, LocalizedError {
    case malformed(String)
    case closed(String)
    case timeout(String)
    case incompatible(Int)

    public var errorDescription: String? {
        switch self {
        case .malformed(let m): "Bad data from the remote scope (\(m))."
        case .closed(let m): m
        case .timeout(let m): m
        case .incompatible(let v): "The computer sharing the scope runs a different OwonScope version (protocol \(v)). Update both."
        }
    }
}

extension FixedWidthInteger {
    var bigEndianBytes: [UInt8] { withUnsafeBytes(of: self.bigEndian) { Array($0) } }
    init<C: Collection>(bigEndianBytes b: C) where C.Element == UInt8 {
        self = b.reduce(0) { $0 << 8 | Self($1) }
    }
}

/// A TCP connection that sends and receives `RemoteMessage` frames. Callbacks run on `queue`.
public final class FramedConnection: @unchecked Sendable {
    public let connection: NWConnection
    private let queue: DispatchQueue
    public var onMessage: ((RemoteMessage) -> Void)?
    public var onReady: (() -> Void)?
    /// Called once, when the connection fails or closes.
    public var onClose: ((String) -> Void)?
    private var closed = false

    public init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    public convenience init(to endpoint: NWEndpoint, queue: DispatchQueue) {
        self.init(NWConnection(to: endpoint, using: Self.parameters()), queue: queue)
    }

    /// TCP with keepalive and no Nagle delay (frames are latency sensitive).
    public static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        let p = NWParameters(tls: nil, tcp: tcp)
        p.includePeerToPeer = true
        return p
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.onReady?()
            case .failed(let e): self.finish("Connection failed: \(e.localizedDescription)")
            case .waiting(let e): self.finish("Can't reach the remote scope: \(e.localizedDescription)")
            case .cancelled: self.finish("Disconnected")
            default: break
            }
        }
        connection.start(queue: queue)
        receiveFrame()
    }

    public func cancel() { connection.cancel() }

    private func finish(_ reason: String) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?(reason)
    }

    public func send(_ message: RemoteMessage, completion: (() -> Void)? = nil) {
        guard !closed, let frame = try? message.encoded() else { completion?(); return }
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let error { self?.queue.async { self?.finish("Send failed: \(error.localizedDescription)") } }
            completion?()
        })
    }

    private func receiveFrame() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, done, error in
            guard let self else { return }
            guard let data, data.count == 4 else {
                self.finish(error.map { "Receive failed: \($0.localizedDescription)" } ?? (done ? "Disconnected" : "Short read"))
                return
            }
            let length = Int(UInt32(bigEndianBytes: data))
            guard length > 0, length <= RemoteProtocol.maxFrame else { self.finish("Bad frame length \(length)"); return }
            self.connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, error in
                guard let body, body.count == length else {
                    self.finish(error.map { "Receive failed: \($0.localizedDescription)" } ?? "Disconnected")
                    return
                }
                do {
                    self.onMessage?(try RemoteMessage.decode(body))
                } catch {
                    self.finish((error as? LocalizedError)?.errorDescription ?? "\(error)")
                    return
                }
                self.receiveFrame()
            }
        }
    }
}
