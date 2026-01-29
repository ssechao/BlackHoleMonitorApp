import Foundation
import Network

/// Demucs-based vocal separator using a Python server
/// Provides high-quality vocal separation with ~3s latency
final class VocalSeparatorAI {
    
    private let host = "127.0.0.1"
    private let port: UInt16 = 19845
    private var connection: NWConnection?
    private var isConnected = false
    private var serverProcess: Process?
    
    private let channels: Int = 2
    private var inputBuffer: [Float] = []
    private var outputBuffer: [Float] = []
    private let bufferLock = NSLock()
    
    // Latency buffer (3 seconds worth of samples)
    private let latencySeconds: Double = 3.0
    private let sampleRate: Double = 44100
    private var latencySamples: Int { Int(latencySeconds * sampleRate) }
    
    private var _isAvailable = false
    
    // Callback when connection state changes
    var onConnectionChanged: ((Bool) -> Void)?
    
    init() {
        startServer()
    }
    
    deinit {
        stopServer()
    }
    
    /// Check if Demucs server is available
    var isAvailable: Bool {
        return _isAvailable && isConnected
    }
    
    // MARK: - Server Management
    
    private func startServer() {
        // Find the demucs_server.py script
        let scriptPaths = [
            Bundle.main.resourcePath.map { "\($0)/demucs_server.py" },
            Bundle.main.bundlePath + "/../ML/demucs_server.py",
            "/Users/sechaosouchiam/Source/github.com/BlackHoleMonitorApp/ML/demucs_server.py"
        ].compactMap { $0 }
        
        var scriptPath: String?
        for path in scriptPaths {
            if FileManager.default.fileExists(atPath: path) {
                scriptPath = path
                break
            }
        }
        
        guard let script = scriptPath else {
            print("[Demucs] Server script not found")
            _isAvailable = false
            return
        }
        
        print("[Demucs] Starting server from: \(script)")
        
        // Start Python server in background
        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.launchServer(script: script)
        }
        
        // Try to connect after a delay (let server start)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.connectToServer()
        }
    }
    
    private func launchServer(script: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script]
        process.environment = ProcessInfo.processInfo.environment
        
        // Redirect output for debugging
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        pipe.fileHandleForReading.readabilityHandler = { handle in
            if let line = String(data: handle.availableData, encoding: .utf8), !line.isEmpty {
                print("[Demucs Server] \(line)", terminator: "")
            }
        }
        
        do {
            try process.run()
            serverProcess = process
            print("[Demucs] Server process started (PID: \(process.processIdentifier))")
        } catch {
            print("[Demucs] Failed to start server: \(error)")
        }
    }
    
    private func stopServer() {
        connection?.cancel()
        connection = nil
        isConnected = false
        
        if let process = serverProcess, process.isRunning {
            process.terminate()
            print("[Demucs] Server stopped")
        }
        serverProcess = nil
    }
    
    // MARK: - Connection
    
    private func connectToServer() {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        connection = NWConnection(to: endpoint, using: .tcp)
        
        connection?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[Demucs] Connected to server")
                self?.isConnected = true
                self?._isAvailable = true
                DispatchQueue.main.async {
                    self?.onConnectionChanged?(true)
                }
                self?.startReceiving()
            case .failed(let error):
                print("[Demucs] Connection failed: \(error)")
                self?.isConnected = false
                self?._isAvailable = false
                DispatchQueue.main.async {
                    self?.onConnectionChanged?(false)
                }
                // Retry after delay
                DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                    self?.connectToServer()
                }
            case .cancelled:
                self?.isConnected = false
                DispatchQueue.main.async {
                    self?.onConnectionChanged?(false)
                }
            default:
                break
            }
        }
        
        connection?.start(queue: .global(qos: .userInteractive))
    }
    
    private func startReceiving() {
        receiveData()
    }
    
    private func receiveData() {
        guard let connection = connection, isConnected else { return }
        
        // Continuously poll for output from server
        connection.receive(minimumIncompleteLength: 4, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            if let data = content {
                self?.handleReceivedData(data)
            }
            
            if isComplete || error != nil {
                self?.isConnected = false
                return
            }
            
            // Continue receiving
            self?.receiveData()
        }
    }
    
    private func handleReceivedData(_ data: Data) {
        // Parse response from server
        guard data.count >= 4 else { return }
        
        let numSamples = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        
        if numSamples > 0 && data.count >= 4 + Int(numSamples) * channels * 4 {
            let audioData = data.subdata(in: 4..<(4 + Int(numSamples) * channels * 4))
            let samples = audioData.withUnsafeBytes { ptr -> [Float] in
                Array(ptr.bindMemory(to: Float.self))
            }
            
            bufferLock.lock()
            outputBuffer.append(contentsOf: samples)
            bufferLock.unlock()
        }
    }
    
    // MARK: - Audio Processing
    
    /// Process audio buffer to remove vocals
    func process(_ data: UnsafeMutablePointer<Float>, frameCount: Int, intensity: Float) {
        guard isConnected, intensity > 0 else { return }
        
        let sampleCount = frameCount * channels
        
        // Store original audio for mixing
        var originalAudio = [Float](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            originalAudio[i] = data[i]
        }
        
        // Send audio to server
        sendAudioToServer(data, frameCount: frameCount)
        
        // Request processed output
        requestOutput()
        
        // Get processed output (with latency)
        bufferLock.lock()
        let availableOutput = min(sampleCount, outputBuffer.count)
        
        if availableOutput > 0 {
            // Mix processed output with original based on intensity
            for i in 0..<availableOutput {
                let processed = outputBuffer[i]
                let original = originalAudio[i]
                data[i] = original * (1.0 - intensity) + processed * intensity
            }
            outputBuffer.removeFirst(availableOutput)
            
            // Fill remaining with original (latency compensation)
            for i in availableOutput..<sampleCount {
                data[i] = originalAudio[i]
            }
        }
        bufferLock.unlock()
    }
    
    private func sendAudioToServer(_ data: UnsafePointer<Float>, frameCount: Int) {
        guard let connection = connection, isConnected else { return }
        
        // Create packet: [num_samples (4 bytes)] [audio data (num_samples * channels * 4 bytes)]
        var packet = Data()
        var numSamples = UInt32(frameCount)
        packet.append(Data(bytes: &numSamples, count: 4))
        packet.append(Data(bytes: data, count: frameCount * channels * MemoryLayout<Float>.size))
        
        connection.send(content: packet, completion: .contentProcessed { error in
            if let error = error {
                print("[Demucs] Send error: \(error)")
            }
        })
    }
    
    private func requestOutput() {
        guard let connection = connection, isConnected else { return }
        
        // Request output: send 0xFFFFFFFF as num_samples
        var request = UInt32(0xFFFFFFFF)
        let packet = Data(bytes: &request, count: 4)
        
        connection.send(content: packet, completion: .contentProcessed { _ in })
    }
    
    /// Reset the processor state
    func reset() {
        bufferLock.lock()
        inputBuffer.removeAll()
        outputBuffer.removeAll()
        bufferLock.unlock()
    }
}
