import Foundation
import Network

/// Client of the Demucs server (`ML/demucs_server.py`), see `DemucsProtocol`.
///
/// - The Python server is launched only while AI karaoke is requested, and
///   terminated when it is turned off or the app quits (the server also exits
///   by itself if the app dies, via `--parent-pid`).
/// - All network and process state is confined to `queue`. The audio thread
///   only touches the current `DemucsBridge` FIFOs.
final class VocalSeparatorAI {
    enum Status: Equatable {
        case off
        case starting
        case ready
        case failed(String)
    }

    /// Called on the main thread.
    var onStatusChanged: ((Status) -> Void)?

    static let port: UInt16 = 19845
    private static let sendChunkFrames = 4096
    private static let handshakeTimeout: TimeInterval = 10

    private let queue = DispatchQueue(label: "com.blackhole.monitor.demucs", qos: .userInitiated)
    private let log = Log.demucs

    // Queue-confined state
    private var active = false
    private var status: Status = .off
    private var bridge: DemucsBridge?
    private var process: Process?
    private var connection: NWConnection?
    private var handshakeDone = false
    private var sendTimer: DispatchSourceTimer?
    private var retryWork: DispatchWorkItem?
    private var timeoutWork: DispatchWorkItem?
    private let sendScratch: UnsafeMutablePointer<Float>

    init() {
        let count = Self.sendChunkFrames * DemucsProtocol.inputChannels
        sendScratch = UnsafeMutablePointer<Float>.allocate(capacity: count)
        sendScratch.initialize(repeating: 0, count: count)
    }

    deinit {
        sendScratch.deallocate()
    }

    // MARK: - Public API (main thread)

    func setActive(_ active: Bool) {
        queue.async { active ? self.activate() : self.deactivate() }
    }

    /// Bridge of the running audio session (nil when stopped).
    func attach(bridge: DemucsBridge?) {
        queue.async {
            self.bridge = bridge
            self.handshakeDone = false
            if bridge != nil, self.connection?.state == .ready {
                self.sendHello()
            }
        }
    }

    /// Synchronous: terminates the server before the app exits.
    func shutdown() {
        queue.sync {
            active = false
            tearDown()
        }
    }

    // MARK: - Lifecycle

    private func activate() {
        guard !active else { return }
        active = true
        setStatus(.starting)
        launchServer()
        scheduleConnect(after: 1.0)
    }

    private func deactivate() {
        guard active else { return }
        active = false
        tearDown()
        setStatus(.off)
    }

    private func fail(_ message: String) {
        log.error(message)
        active = false
        tearDown()
        setStatus(.failed(message))
    }

    private func tearDown() {
        retryWork?.cancel()
        retryWork = nil
        timeoutWork?.cancel()
        timeoutWork = nil
        sendTimer?.cancel()
        sendTimer = nil
        connection?.cancel()
        connection = nil
        handshakeDone = false
        if let process, process.isRunning {
            process.terminate()
            log.info("Server stopped")
        }
        process = nil
    }

    private func setStatus(_ newStatus: Status) {
        guard newStatus != status else { return }
        status = newStatus
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChanged?(newStatus)
        }
    }

    // MARK: - Server process

    private func launchServer() {
        guard let script = Self.findScript() else {
            fail("demucs_server.py not found")
            return
        }
        guard let python = Self.findPython() else {
            fail("No python3 with demucs found (pip install demucs, or set the demucsPythonPath default)")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [script, "--port", "\(Self.port)", "--parent-pid", "\(getpid())"]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let log = self.log
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // EOF: detach, otherwise the handler is called in a loop
                handle.readabilityHandler = nil
                return
            }
            String(decoding: data, as: UTF8.self).split(separator: "\n").forEach { log.info("server: \($0)") }
        }
        process.terminationHandler = { [weak self] terminated in
            self?.queue.async { self?.serverTerminated(terminated) }
        }

        do {
            try process.run()
            self.process = process
            log.info("Server started with \(python) \(script) (pid \(process.processIdentifier))")
        } catch {
            fail("Cannot start Demucs server: \(error.localizedDescription)")
        }
    }

    private func serverTerminated(_ terminated: Process) {
        guard terminated === process else { return }
        process = nil
        guard active else { return }
        switch terminated.terminationStatus {
        case 2: fail("Demucs model could not be loaded (see logs)")
        case 3: fail("Port \(Self.port) is already in use")
        default: fail("Demucs server exited (code \(terminated.terminationStatus), see logs)")
        }
    }

    private static func findScript() -> String? {
        var candidates: [String] = []
        if let resources = Bundle.main.resourcePath {
            candidates.append("\(resources)/demucs_server.py")
        }
        // Development: build/BlackHoleMonitorApp.app -> <repo>/ML
        candidates.append(Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ML/demucs_server.py").path)
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// GUI apps get a minimal PATH, so look in the usual install locations and
    /// keep the first interpreter that can actually import demucs and torch.
    /// An explicit override (`demucsPythonPath` default or `BHM_PYTHON`) is used as is.
    private static func findPython() -> String? {
        let overrides = [UserDefaults.standard.string(forKey: "demucsPythonPath"),
                         ProcessInfo.processInfo.environment["BHM_PYTHON"]].compactMap { $0 }
        if let custom = overrides.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return custom
        }
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
            "/usr/bin/python3",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) && hasDemucs($0) }
    }

    /// Checks the modules without importing them (fast), with the same
    /// user site-packages fallback as the server.
    private static func hasDemucs(_ python: String) -> Bool {
        let probe = """
        import importlib.util, os, sys
        v = f"{sys.version_info.major}.{sys.version_info.minor}"
        sys.path.append(os.path.expanduser(f"~/Library/Python/{v}/lib/python{v}/site-packages"))
        sys.exit(0 if all(importlib.util.find_spec(m) for m in ("demucs", "torch", "torchaudio")) else 1)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-c", probe]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: - Connection

    private func scheduleConnect(after delay: TimeInterval) {
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        retryWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func connect() {
        guard active, connection == nil, process != nil else { return }
        let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!, using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn, conn === self.connection else { return }
            switch state {
            case .ready:
                self.log.info("Connected to server")
                self.receiveMessage(on: conn)
                if self.bridge != nil { self.sendHello() }
            case .waiting, .failed:
                // Typically "connection refused" while the model is loading
                self.connectionLost()
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func connectionLost() {
        connection?.cancel()
        connection = nil
        handshakeDone = false
        sendTimer?.cancel()
        sendTimer = nil
        timeoutWork?.cancel()
        guard active else { return }
        if status == .ready { setStatus(.starting) }
        scheduleConnect(after: 1.0)
    }

    private func sendHello() {
        guard let conn = connection, let bridge else { return }
        handshakeDone = false
        bridge.resetStreams()
        conn.send(content: DemucsProtocol.encodeHeader(.hello, value: UInt32(bridge.sampleRate)),
                  completion: .contentProcessed { _ in })

        timeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.fail("No answer from Demucs server (port \(VocalSeparatorAI.port) used by another program?)")
        }
        timeoutWork = work
        queue.asyncAfter(deadline: .now() + Self.handshakeTimeout, execute: work)
    }

    // MARK: - Receiving (exact framing)

    private func receiveMessage(on conn: NWConnection) {
        let headerSize = DemucsProtocol.headerSize
        conn.receive(minimumIncompleteLength: headerSize, maximumLength: headerSize) { [weak self] data, _, isComplete, error in
            guard let self, conn === self.connection else { return }
            guard error == nil, let data, data.count == headerSize else {
                if error != nil || isComplete { self.connectionLost() }
                return
            }
            let header: DemucsProtocol.Header
            do {
                header = try DemucsProtocol.decodeHeader(data)
            } catch {
                self.log.error("Protocol error: \(error)")
                self.connectionLost()
                return
            }
            let payloadSize = DemucsProtocol.payloadSize(of: header)
            if payloadSize == 0 {
                self.handle(header, payload: Data())
                self.receiveMessage(on: conn)
                return
            }
            conn.receive(minimumIncompleteLength: payloadSize, maximumLength: payloadSize) { [weak self] payload, _, _, error in
                guard let self, conn === self.connection else { return }
                guard error == nil, let payload, payload.count == payloadSize else {
                    self.connectionLost()
                    return
                }
                self.handle(header, payload: payload)
                self.receiveMessage(on: conn)
            }
        }
    }

    private func handle(_ header: DemucsProtocol.Header, payload: Data) {
        switch header.type {
        case .helloAck:
            timeoutWork?.cancel()
            guard header.value == DemucsProtocol.version else {
                fail("Incompatible Demucs server (protocol v\(header.value), expected v\(DemucsProtocol.version))")
                return
            }
            handshakeDone = true
            startSendTimer()
            setStatus(.ready)
        case .result:
            guard handshakeDone, let bridge else { return }
            let floats = DemucsProtocol.decodeFloats(payload)
            floats.withUnsafeBufferPointer {
                bridge.receiveResult($0.baseAddress!, frames: Int(header.value))
            }
        case .hello, .audio:
            log.error("Unexpected message from server: \(header.type)")
            connectionLost()
        }
    }

    // MARK: - Sending

    private func startSendTimer() {
        sendTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.flushInput() }
        timer.resume()
        sendTimer = timer
    }

    private func flushInput() {
        guard handshakeDone, let conn = connection, let bridge else { return }
        while true {
            let frames = bridge.toServer.readAvailable(into: sendScratch, maxFrames: Self.sendChunkFrames)
            if frames == 0 { break }
            conn.send(content: DemucsProtocol.encodeAudio(sendScratch, frames: frames),
                      completion: .contentProcessed { [log] error in
                          if let error { log.error("Send error: \(error)") }
                      })
        }
    }
}
