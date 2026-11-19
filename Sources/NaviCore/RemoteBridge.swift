import Foundation
import Combine

// MARK: - Protocols

/// Where the bridge delivers what remote relays report. `EventMonitor`
/// conforms; tests use a recording fake. Called on the bridge's queue.
public protocol RemoteEventSink: AnyObject {
    func ingestRemoteEvent(_ dict: [String: Any], origin: String)
    func ingestRemoteResolve(_ dict: [String: Any], origin: String)
    func ingestRemoteWorking(sessionID: String, origin: String)
    /// `live` is nil when the relay couldn't read its sessions dir (unknown).
    func applyRemoteHeartbeat(origin: String, sessions: [DiscoveredSession], live: Set<String>?)
    func setLiveness(origin: String, _ state: OriginLiveness)
    func removeOrigin(_ origin: String)
}

/// Delivers approve/deny for a remote permission card.
public protocol RemoteResponder: AnyObject {
    /// Returns false if the host isn't connected or the input is invalid.
    func respond(origin: String, id: String, decision: String) -> Bool
}

/// How a relay process is started for a host.
public protocol RemoteTransport {
    func launchSpec(for host: RemoteHostConfig, features: [String]) -> RemoteLaunchSpec
}

public struct RemoteLaunchSpec: Equatable {
    public var executable: URL
    public var arguments: [String]
    public init(executable: URL, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

/// Production transport: `ssh -T -o BatchMode=yes ... -- <alias> python3 -c ...`.
public struct SSHTransport: RemoteTransport {
    public var sshPath: String
    public init(sshPath: String = "/usr/bin/ssh") { self.sshPath = sshPath }

    public func launchSpec(for host: RemoteHostConfig, features: [String]) -> RemoteLaunchSpec {
        RemoteLaunchSpec(
            executable: URL(fileURLWithPath: sshPath),
            arguments: RelayCommand.sshArguments(
                alias: host.alias,
                remoteCommand: RelayCommand.remoteShellCommand(features: features)))
    }
}

/// Runs a relay script directly with a local python3, no SSH. For tests and
/// local development; `root` must not be the live /tmp/navi or the relay
/// would steal events from this Mac's own pipeline.
public struct LocalRelayTransport: RemoteTransport {
    public var relayPath: String
    public var root: String
    public var sessionsDir: String
    public var heartbeat: Double

    public init(relayPath: String, root: String, sessionsDir: String, heartbeat: Double = 3) {
        self.relayPath = relayPath
        self.root = root
        self.sessionsDir = sessionsDir
        self.heartbeat = heartbeat
    }

    public func launchSpec(for host: RemoteHostConfig, features: [String]) -> RemoteLaunchSpec {
        var args = ["python3", relayPath, "--root", root, "--sessions-dir", sessionsDir,
                    "--heartbeat", String(heartbeat)]
        let flags = features.filter { RelayCommand.mirrorableFeatures.contains($0) }
        if !flags.isEmpty { args += ["--features", flags.joined(separator: ",")] }
        return RemoteLaunchSpec(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: args)
    }
}

/// Runs a fixed command for every host. For tests (canned JSONL).
public struct CommandTransport: RemoteTransport {
    public var spec: RemoteLaunchSpec
    public init(executable: String, arguments: [String]) {
        spec = RemoteLaunchSpec(executable: URL(fileURLWithPath: executable), arguments: arguments)
    }
    public func launchSpec(for host: RemoteHostConfig, features: [String]) -> RemoteLaunchSpec { spec }
}

// MARK: - Wire format

/// One line from a relay's stdout. See hooks/relay.py for the protocol.
public enum RemoteMessage {
    case hello(version: Int, user: String, host: String)
    case event([String: Any])
    case resolve([String: Any])
    case working(sessionID: String)
    case heartbeat(live: Set<String>?, sessions: [DiscoveredSession], user: String, host: String)
    case error(String)

    public static func parse(_ line: Data) -> RemoteMessage? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let kind = obj["kind"] as? String else { return nil }
        switch kind {
        case "hello":
            return .hello(version: obj["version"] as? Int ?? 0,
                          user: obj["user"] as? String ?? "",
                          host: obj["host"] as? String ?? "")
        case "event":
            return (obj["event"] as? [String: Any]).map { .event($0) }
        case "resolve":
            return (obj["resolve"] as? [String: Any]).map { .resolve($0) }
        case "working":
            guard let sid = obj["session_id"] as? String, isValidSessionID(sid) else { return nil }
            return .working(sessionID: sid)
        case "heartbeat":
            let live = (obj["live"] as? [Any]).map { Set($0.compactMap { $0 as? String }.filter(isValidSessionID)) }
            let raw = obj["sessions"] as? [[String: Any]] ?? []
            let sessions = raw.compactMap { dict -> DiscoveredSession? in
                guard let d = DiscoveredSession.parse(dict, isAlive: { _ in true }),
                      isValidSessionID(d.sessionID) else { return nil }
                // The relay only lists live sessions; trust `live` as the authority.
                return DiscoveredSession(
                    sessionID: d.sessionID, pid: d.pid,
                    alive: live?.contains(d.sessionID) ?? false,
                    cwd: d.cwd, name: d.name, claudeStatus: d.claudeStatus,
                    statusUpdatedAt: d.statusUpdatedAt, title: d.title)
            }
            return .heartbeat(live: live, sessions: sessions,
                              user: obj["user"] as? String ?? "",
                              host: obj["host"] as? String ?? "")
        case "error":
            return .error(obj["message"] as? String ?? "relay error")
        default:
            return nil
        }
    }

    public static func isValidSessionID(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 256 && s.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    }

    /// Permission event IDs as produced by parse_event.py: `<epoch>-<32 hex>`.
    public static func isValidEventID(_ s: String) -> Bool {
        s.range(of: #"^[0-9]{1,20}-[0-9a-f]{32}$"#, options: .regularExpression) != nil
    }

    /// The control-channel line for a decision, or nil if the input is invalid.
    public static func responseLine(id: String, decision: String) -> Data? {
        guard isValidEventID(id), decision == "approve" || decision == "deny" else { return nil }
        let obj: [String: String] = ["kind": "response", "id": id, "decision": decision]
        guard var data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return nil }
        data.append(0x0A)
        return data
    }
}

// MARK: - Bridge

/// Maintains one relay process per enabled remote host, feeds what they report
/// into a `RemoteEventSink`, and writes approve/deny back over the relay's stdin.
public final class RemoteBridge: ObservableObject, RemoteResponder {
    public enum Status: Equatable { case connecting, connected, disconnected }

    public struct HostState: Equatable {
        public var status: Status = .connecting
        public var lastError: String?
        public var remoteUser: String?
        public var remoteHostname: String?
        public var lastHeartbeat: Date?
        public var nextRetry: Date?
    }

    /// Per-alias connection state, published on the main queue.
    @Published public private(set) var states: [String: HostState] = [:]

    private let queue = DispatchQueue(label: "navi.remote-bridge")
    private let transport: RemoteTransport
    private let backoffTemplate: Backoff
    private weak var sink: RemoteEventSink?
    // Queue-confined:
    private var connections: [String: Connection] = [:]
    private var features: [String] = []

    public init(transport: RemoteTransport = SSHTransport(), backoff: Backoff = Backoff()) {
        self.transport = transport
        self.backoffTemplate = backoff
        // Writing to a relay whose process just died must not kill Navi.
        signal(SIGPIPE, SIG_IGN)
    }

    public func attach(sink: RemoteEventSink) {
        queue.sync { self.sink = sink }
    }

    /// Reconcile running connections with the configured hosts. Hosts that are
    /// removed or disabled are stopped and their sessions dropped. Pass an
    /// empty list to stop everything (feature off).
    public func configure(hosts: [RemoteHostConfig], features: [String]) {
        let wanted = hosts.filter { $0.enabled && RemoteHostConfig.isValidAlias($0.alias) }
        queue.async {
            let featuresChanged = self.features != features
            self.features = features
            let wantedAliases = Set(wanted.map(\.alias))
            for (alias, conn) in self.connections where !wantedAliases.contains(alias) || featuresChanged {
                conn.stop()
                self.connections.removeValue(forKey: alias)
                if !wantedAliases.contains(alias) {
                    self.sink?.removeOrigin(alias)
                    self.publish(alias, nil)
                }
            }
            for host in wanted where self.connections[host.alias] == nil {
                let conn = Connection(host: host, bridge: self, backoff: self.backoffTemplate)
                self.connections[host.alias] = conn
                conn.start()
            }
        }
    }

    /// Retry a disconnected host now instead of waiting for the backoff.
    public func reconnectNow(_ alias: String) {
        queue.async { self.connections[alias]?.restartNow() }
    }

    public func stopAll() {
        configure(hosts: [], features: [])
    }

    public func respond(origin: String, id: String, decision: String) -> Bool {
        guard let line = RemoteMessage.responseLine(id: id, decision: decision) else { return false }
        return queue.sync { connections[origin]?.send(line) ?? false }
    }

    // MARK: Connection callbacks (on queue)

    fileprivate func handle(_ message: RemoteMessage, from alias: String) {
        switch message {
        case let .hello(_, user, host):
            update(alias) { $0.remoteUser = user; $0.remoteHostname = host }
        case let .event(dict):
            sink?.ingestRemoteEvent(dict, origin: alias)
        case let .resolve(dict):
            sink?.ingestRemoteResolve(dict, origin: alias)
        case let .working(sid):
            sink?.ingestRemoteWorking(sessionID: sid, origin: alias)
        case let .heartbeat(live, sessions, user, host):
            connections[alias]?.markConnected()
            sink?.applyRemoteHeartbeat(origin: alias, sessions: sessions, live: live)
            update(alias) {
                $0.status = .connected
                $0.lastError = nil
                $0.nextRetry = nil
                $0.lastHeartbeat = Date()
                if !user.isEmpty { $0.remoteUser = user }
                if !host.isEmpty { $0.remoteHostname = host }
            }
        case let .error(message):
            connections[alias]?.relayError = message
            update(alias) { $0.lastError = message }
        }
    }

    fileprivate func connectionStarted(_ alias: String) {
        update(alias) { $0.status = .connecting; $0.nextRetry = nil }
    }

    fileprivate func connectionEnded(_ alias: String, error: String?, retryIn delay: TimeInterval?) {
        sink?.setLiveness(origin: alias, .disconnected)
        update(alias) {
            $0.status = .disconnected
            if let error { $0.lastError = error }
            $0.nextRetry = delay.map { Date().addingTimeInterval($0) }
        }
    }

    private var pendingStates: [String: HostState] = [:]

    private func update(_ alias: String, _ change: (inout HostState) -> Void) {
        var state = pendingStates[alias] ?? HostState()
        change(&state)
        publish(alias, state)
    }

    private func publish(_ alias: String, _ state: HostState?) {
        pendingStates[alias] = state
        DispatchQueue.main.async { self.states[alias] = state }
    }

    /// For tests: current state as seen on the bridge queue.
    public func stateSnapshot(_ alias: String) -> HostState? {
        queue.sync { pendingStates[alias] }
    }

    // MARK: - Connection

    /// One relay process plus its reconnect loop. All state is confined to the
    /// bridge queue; pipe callbacks hop onto it and are tagged with a
    /// generation so callbacks from a previous process are ignored.
    fileprivate final class Connection {
        let host: RemoteHostConfig
        unowned let bridge: RemoteBridge
        var backoff: Backoff
        private var process: Process?
        private var stdin: FileHandle?
        private var stdoutBuffer = Data()
        private var stderrTail = Data()
        private var generation = 0
        private var stopped = false
        private var retry: DispatchWorkItem?
        /// Fatal message the relay reported on stdout before exiting.
        var relayError: String?
        private static let maxLine = 4 * 1024 * 1024
        private static let maxStderr = 4 * 1024

        init(host: RemoteHostConfig, bridge: RemoteBridge, backoff: Backoff) {
            self.host = host
            self.bridge = bridge
            self.backoff = backoff
        }

        func start() {
            guard !stopped else { return }
            retry = nil
            generation += 1
            let gen = generation
            stdoutBuffer.removeAll()
            stderrTail.removeAll()
            relayError = nil

            let spec = bridge.transport.launchSpec(for: host, features: bridge.features)
            let proc = Process()
            proc.executableURL = spec.executable
            proc.arguments = spec.arguments
            let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
            proc.standardInput = inPipe
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            let queue = bridge.queue
            outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
                let data = h.availableData
                if data.isEmpty { h.readabilityHandler = nil; return }
                queue.async { self?.receiveStdout(data, gen: gen) }
            }
            errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
                let data = h.availableData
                if data.isEmpty { h.readabilityHandler = nil; return }
                queue.async { self?.receiveStderr(data, gen: gen) }
            }
            proc.terminationHandler = { [weak self] p in
                let code = p.terminationStatus
                // Let the pipe handlers drain the last output first.
                queue.asyncAfter(deadline: .now() + 0.1) { self?.exited(code: code, gen: gen) }
            }

            bridge.connectionStarted(host.alias)
            do {
                try proc.run()
                process = proc
                stdin = inPipe.fileHandleForWriting
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                scheduleRetry(error: "Couldn't start \(spec.executable.path): \(error.localizedDescription)")
            }
        }

        func stop() {
            stopped = true
            retry?.cancel()
            retry = nil
            generation += 1  // ignore anything the old process still says
            // Closing stdin is the relay's clean shutdown signal (over SSH it
            // becomes EOF on the remote side). Only terminate if it lingers.
            closeStdin()
            if let p = process, p.isRunning {
                bridge.queue.asyncAfter(deadline: .now() + 3) {
                    if p.isRunning { p.terminate() }
                }
            }
            process = nil
        }

        func restartNow() {
            guard !stopped, process == nil else { return }
            retry?.cancel()
            start()
        }

        func markConnected() { backoff.reset() }

        func send(_ line: Data) -> Bool {
            guard let stdin, let p = process, p.isRunning else { return false }
            do {
                try stdin.write(contentsOf: line)
                return true
            } catch {
                return false
            }
        }

        private func closeStdin() {
            try? stdin?.close()
            stdin = nil
        }

        private func receiveStdout(_ data: Data, gen: Int) {
            guard gen == generation else { return }
            stdoutBuffer.append(data)
            while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
                let line = stdoutBuffer[stdoutBuffer.startIndex..<nl]
                stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
                if let msg = RemoteMessage.parse(Data(line)) {
                    bridge.handle(msg, from: host.alias)
                }
            }
            if stdoutBuffer.count > Self.maxLine { stdoutBuffer.removeAll() }
        }

        private func receiveStderr(_ data: Data, gen: Int) {
            guard gen == generation else { return }
            stderrTail.append(data)
            if stderrTail.count > Self.maxStderr {
                stderrTail = stderrTail.suffix(Self.maxStderr)
            }
        }

        private func exited(code: Int32, gen: Int) {
            guard gen == generation else { return }
            process = nil
            closeStdin()
            let stderr = String(decoding: stderrTail, as: UTF8.self)
            let error: String?
            if stderr.isEmpty, let relayError {
                error = relayError
            } else if code == 0 && stderr.isEmpty {
                error = nil
            } else {
                error = RemoteErrorHint.describe(alias: host.alias, exitCode: code, stderr: stderr)
            }
            scheduleRetry(error: error)
        }

        private func scheduleRetry(error: String?) {
            guard !stopped else { return }
            let delay = backoff.next()
            bridge.connectionEnded(host.alias, error: error, retryIn: delay)
            let work = DispatchWorkItem { [weak self] in self?.start() }
            retry = work
            bridge.queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }
}
