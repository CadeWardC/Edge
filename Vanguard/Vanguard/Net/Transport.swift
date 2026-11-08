import Foundation

/// One seat in a multiplayer lobby. The host owns the lobby and sends it to everyone after each change.
struct LobbyState: Codable, Equatable {
    var hostId: String
    var map: MapID
    var players: [PlayerSetup]
}

/// Everything peers say to each other. Sent as JSON text; the relay server just forwards it to the room.
enum NetMessage: Codable, Equatable {
    case hello(clientId: String, name: String, version: Int)
    case lobby(LobbyState)
    case start(MatchSetup)
    case turn(TurnPacket)
    case chat(from: String, text: String)
    case leave(clientId: String)

    func encoded() -> Data? { try? JSONEncoder().encode(self) }
    static func decode(_ d: Data) -> NetMessage? { try? JSONDecoder().decode(NetMessage.self, from: d) }
}

enum TransportStatus: Equatable {
    case connecting
    case connected
    case disconnected(String)
}

/// Anything that moves NetMessages between the players of one room: the WebSocket relay below, an in-process
/// loopback (tests), or later Game Center / MultipeerConnectivity / a hosted service.
protocol NetTransport: AnyObject {
    var onMessage: ((NetMessage) -> Void)? { get set }
    var onStatus: ((TransportStatus) -> Void)? { get set }
    func send(_ m: NetMessage)
    func close()
}

// MARK: in-process loopback

/// Connects several endpoints in the same process. Messages wait in a queue until `pump()` (or are delivered at once
/// with `autoPump`), so tests can add latency and reorder turns.
final class LoopbackHub {
    private var endpoints: [LoopbackTransport] = []
    var autoPump = false

    func makeEndpoint() -> LoopbackTransport {
        let e = LoopbackTransport(hub: self)
        endpoints.append(e)
        return e
    }

    fileprivate func broadcast(from: LoopbackTransport, _ m: NetMessage) {
        for e in endpoints where e !== from { e.pending.append(m) }
        if autoPump { pump() }
    }

    /// Delivers everything queued. `keepNewest` messages per endpoint stay queued (simulated latency).
    func pump(keepNewest: Int = 0) {
        for e in endpoints {
            let n = max(0, e.pending.count - keepNewest)
            guard n > 0 else { continue }
            let batch = Array(e.pending.prefix(n))
            e.pending.removeFirst(n)
            for m in batch { e.onMessage?(m) }
        }
    }
}

final class LoopbackTransport: NetTransport {
    var onMessage: ((NetMessage) -> Void)?
    var onStatus: ((TransportStatus) -> Void)?
    fileprivate var pending: [NetMessage] = []
    private weak var hub: LoopbackHub?

    fileprivate init(hub: LoopbackHub) { self.hub = hub }

    func send(_ m: NetMessage) {
        // round-trip through JSON so tests cover the wire format too
        guard let d = m.encoded(), let back = NetMessage.decode(d) else { return }
        hub?.broadcast(from: self, back)
    }

    func close() { hub = nil }
}

// MARK: WebSocket relay

/// Talks to the relay in `Vanguard/Server/relay.py` (or anything that speaks the same protocol): connect to
/// `ws://host:port/<room>`, every text frame you send is forwarded to the other sockets in the room.
final class WebSocketTransport: NSObject, NetTransport, URLSessionWebSocketDelegate {
    var onMessage: ((NetMessage) -> Void)?
    var onStatus: ((TransportStatus) -> Void)?
    private let url: URL
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var closed = false

    init(server: String, room: String) throws {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.hasPrefix("ws://") && !s.hasPrefix("wss://") { s = "ws://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        let safeRoom = room.uppercased().filter { $0.isLetter || $0.isNumber }
        guard !safeRoom.isEmpty, let u = URL(string: s + "/" + safeRoom) else { throw URLError(.badURL) }
        url = u
        super.init()
    }

    func connect() {
        onStatus?(.connecting)
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receive()
    }

    private func receive() {
        task?.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                switch result {
                case let .success(msg):
                    let data: Data?
                    switch msg {
                    case let .string(s): data = s.data(using: .utf8)
                    case let .data(d): data = d
                    @unknown default: data = nil
                    }
                    if let data, let m = NetMessage.decode(data) { self.onMessage?(m) }
                    self.receive()
                case let .failure(err):
                    self.onStatus?(.disconnected(err.localizedDescription))
                }
            }
        }
    }

    func send(_ m: NetMessage) {
        guard let d = m.encoded(), let s = String(data: d, encoding: .utf8) else { return }
        task?.send(.string(s)) { [weak self] err in
            if let err {
                DispatchQueue.main.async { self?.onStatus?(.disconnected(err.localizedDescription)) }
            }
        }
    }

    func close() {
        closed = true
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onStatus?(.connected)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        if !closed { onStatus?(.disconnected("Connection closed")) }
    }
}
