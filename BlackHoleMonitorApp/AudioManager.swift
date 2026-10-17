import Foundation
import CoreAudio

// MARK: - CoreAudio Device Change Callback (C function)

private func deviceChangeCallback(
    objectID: AudioObjectID,
    numberAddresses: UInt32,
    addresses: UnsafePointer<AudioObjectPropertyAddress>,
    clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData = clientData else { return noErr }
    let audioManager = Unmanaged<AudioManager>.fromOpaque(clientData).takeUnretainedValue()
    DispatchQueue.main.async {
        audioManager.handleDeviceChange()
    }
    return noErr
}

/// Receives visualization frames on the main thread, outside of SwiftUI.
protocol VisualizationListener: AnyObject {
    func visualizationFrame(bands: [Float], scope: [Float])
}

/// Latest visualization frame, delivered two ways:
/// - directly to registered `VisualizationListener`s (Core Animation views of the
///   popover and floating window): no SwiftUI update per frame;
/// - through `@Published` for SwiftUI views that animate anyway (disco mode).
final class VisualizationData: ObservableObject {
    @Published private(set) var spectrumBands: [Float] = Array(repeating: 0.0, count: VisualizationTap.bandCount)
    @Published private(set) var oscilloscopeSamples: [Float] = Array(repeating: 0.0, count: VisualizationTap.scopeCount)
    private let listeners = NSHashTable<AnyObject>.weakObjects()

    func addListener(_ listener: VisualizationListener) {
        listeners.add(listener)
    }

    func deliver(bands: [Float], scope: [Float]) {
        for case let listener as VisualizationListener in listeners.allObjects {
            listener.visualizationFrame(bands: bands, scope: scope)
        }
        spectrumBands = bands
        oscilloscopeSamples = scope
    }
}

/// Settings, device management and session lifecycle. Main thread only.
///
/// The real-time work happens in `AudioSession`; every setting change is
/// forwarded to it through mailboxes (`pushRenderParameters`, `pushEqualizer`,
/// `pushCompressor`), never by sharing mutable state with the audio threads.
final class AudioManager: ObservableObject {
    static let shared = AudioManager()

    @Published var inputDevices: [AudioDevice] = []
    @Published var outputDevices: [AudioDevice] = []
    @Published var selectedInputID: AudioDeviceID = 0 {
        didSet { scheduleSave() }
    }
    @Published var selectedOutputID: AudioDeviceID = 0 {
        didSet { scheduleSave() }
    }
    @Published var volume: Float = 1.0 {
        didSet { pushRenderParameters(); scheduleSave() }
    }
    var previousVolume: Float = 1.0  // For mute toggle
    @Published private(set) var isRunning = false
    @Published private(set) var inputSampleRateDisplay: Int = 0
    @Published private(set) var outputSampleRateDisplay: Int = 0
    @Published private(set) var sampleRateMismatch: Bool = false  // Warning when resampling is needed

    // Visualization data is in a SEPARATE ObservableObject to avoid
    // triggering full MenuBarView re-renders on every frame update.
    let visualizationData = VisualizationData()
    private let visualizationTap = VisualizationTap()
    private var visualizationTimer: Timer?
    private var visualizationVersion: UInt64 = 0

    /// Whether visualization is computed (any visualization UI visible)
    var visualizationActive: Bool = false {
        didSet {
            guard visualizationActive != oldValue else { return }
            pushRenderParameters()
            updateVisualizationTimer()
        }
    }

    // Equalizer (8 bands, -12dB to +12dB)
    @Published var eqBands: [Float] = Array(repeating: 0.0, count: Equalizer.bandCount) {
        didSet { pushEqualizer(); scheduleSave() }
    }

    // Compressor settings
    @Published var compressorEnabled: Bool = false {
        didSet { pushRenderParameters(); scheduleSave() }
    }
    @Published var compressorThreshold: Float = -20.0 {  // dB
        didSet { pushCompressor(); scheduleSave() }
    }
    @Published var compressorRatio: Float = 4.0 {  // ratio :1
        didSet { pushCompressor(); scheduleSave() }
    }
    @Published var compressorAttack: Float = 10.0 {  // ms
        didSet { pushCompressor(); scheduleSave() }
    }
    @Published var compressorRelease: Float = 100.0 {  // ms
        didSet { pushCompressor(); scheduleSave() }
    }
    @Published var compressorMakeupGain: Float = 0.0 {  // dB
        didSet { pushCompressor(); scheduleSave() }
    }

    // Drift correction via resampling (when input and output rates differ)
    @Published var driftCorrectionEnabled: Bool = true {
        didSet {
            session?.setDriftCorrectionEnabled(driftCorrectionEnabled)
            pushRenderParameters()
            scheduleSave()
        }
    }

    // Karaoke mode
    @Published var karaokeEnabled: Bool = false {
        didSet { updateAIActivation(); pushRenderParameters(); scheduleSave() }
    }
    @Published var karaokeIntensity: Float = 1.0 {  // 0.0 = normal, 1.0 = full vocal removal
        didSet { pushRenderParameters(); scheduleSave() }
    }
    @Published var karaokeUseAI: Bool = false {  // Use Demucs instead of Mid-Side
        didSet { updateAIActivation(); pushRenderParameters(); scheduleSave() }
    }

    // AI Vocal Separator
    private let vocalSeparatorAI = VocalSeparatorAI()
    @Published private(set) var karaokeAIStatus: VocalSeparatorAI.Status = .off
    var karaokeAIAvailable: Bool { karaokeAIStatus == .ready }

    private var session: AudioSession?
    private let channels = 2
    private let log = Log.audio

    // Settings persistence (debounced: sliders fire many changes per second)
    private var isLoadingSettings = false
    private var saveWork: DispatchWorkItem?

    // Device change monitoring
    private var deviceChangeListenerAdded = false
    private var wasRunningBeforeDeviceLoss = false
    private var lastSelectedOutputName: String = ""  // Match by name since USB ID changes on reconnect

    private init() {
        vocalSeparatorAI.onStatusChanged = { [weak self] status in
            guard let self else { return }
            self.karaokeAIStatus = status
            self.pushRenderParameters()
        }
        refreshDevices()
        loadSavedSettings()
        setupDeviceChangeListener()
    }

    // MARK: - Device Change Monitoring

    private func setupDeviceChangeListener() {
        guard !deviceChangeListenerAdded else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            deviceChangeCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )

        if status == noErr {
            deviceChangeListenerAdded = true
            log.info("Device change listener installed")
        } else {
            log.error("Failed to install device change listener: \(status)")
        }
    }

    func handleDeviceChange() {
        log.info("Audio device change detected")

        let previousOutputID = selectedOutputID
        let previousOutputName = outputDevices.first { $0.id == previousOutputID }?.name ?? lastSelectedOutputName

        refreshDevices()

        let outputStillAvailable = outputDevices.contains { $0.id == previousOutputID }

        if isRunning && !outputStillAvailable {
            log.info("Output device '\(previousOutputName)' (ID:\(previousOutputID)) disconnected - stopping audio")
            wasRunningBeforeDeviceLoss = true
            lastSelectedOutputName = previousOutputName
            stop()
        } else if !isRunning && wasRunningBeforeDeviceLoss && !lastSelectedOutputName.isEmpty {
            // Match by NAME since USB ID changes on reconnect
            if let reconnectedDevice = outputDevices.first(where: { $0.name == lastSelectedOutputName }) {
                log.info("Output device '\(lastSelectedOutputName)' reconnected with new ID:\(reconnectedDevice.id) - restarting audio")
                selectedOutputID = reconnectedDevice.id
                wasRunningBeforeDeviceLoss = false
                lastSelectedOutputName = ""

                // Delay restart to let the device fully initialize
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.start()
                }
            }
        }
    }

    func refreshDevices() {
        let devices = AudioDevices.all()
        inputDevices = devices.filter { $0.isInput }
        outputDevices = devices.filter { $0.isOutput }

        if selectedInputID == 0, let blackhole = inputDevices.first(where: { $0.name.lowercased().contains("blackhole") }) {
            selectedInputID = blackhole.id
        } else if selectedInputID == 0, let first = inputDevices.first {
            selectedInputID = first.id
        }

        if selectedOutputID == 0, let first = outputDevices.first(where: { !$0.name.lowercased().contains("blackhole") }) {
            selectedOutputID = first.id
        } else if selectedOutputID == 0, let first = outputDevices.first {
            selectedOutputID = first.id
        }
    }

    // MARK: - Start / Stop

    func start() {
        guard !isRunning else {
            log.info("start(): already running")
            return
        }
        log.info("Starting... Input ID: \(selectedInputID), Output ID: \(selectedOutputID)")

        guard let inRate = AudioDevices.nominalSampleRate(of: selectedInputID),
              let outRate = AudioDevices.nominalSampleRate(of: selectedOutputID) else {
            log.error("Failed to get sample rates for input:\(selectedInputID) output:\(selectedOutputID)")
            return
        }
        log.info("Sample rates: \(inRate) -> \(outRate)")

        do {
            let newSession = try AudioSession(
                inputDevice: selectedInputID,
                outputDevice: selectedOutputID,
                inputSampleRate: inRate,
                outputSampleRate: outRate,
                channels: channels,
                visualizationTap: visualizationTap
            )
            session = newSession
            newSession.setDriftCorrectionEnabled(driftCorrectionEnabled)
            pushEqualizer()
            pushCompressor()
            pushRenderParameters()
            try newSession.start()
        } catch {
            log.error("Failed to start: \(error.localizedDescription)")
            session?.stop()
            session = nil
            return
        }

        vocalSeparatorAI.attach(bridge: session?.demucsBridge)
        inputSampleRateDisplay = Int(inRate)
        outputSampleRateDisplay = Int(outRate)
        sampleRateMismatch = inRate != outRate
        isRunning = true
        updateVisualizationTimer()
        log.info("Audio routing started successfully")
    }

    func stop() {
        guard let current = session else { return }
        vocalSeparatorAI.attach(bridge: nil)
        current.stop()
        if current.underrunCount > 0 {
            log.info("Session stopped after \(current.underrunCount) underrun(s), final latency \(Int(current.currentLatencyMs)) ms")
        }
        session = nil
        isRunning = false
        updateVisualizationTimer()
    }

    /// Called when the app terminates.
    func shutdown() {
        stop()
        vocalSeparatorAI.shutdown()
        saveWork?.cancel()
        saveSettings()
    }

    // MARK: - Parameter forwarding

    private func pushRenderParameters() {
        guard let session else { return }
        let clamped = max(0.0, min(volume, 1.0))
        session.parameters.publish(RenderParameters(
            // x^3 curve to match loudness perception: 50% -> 0.125 (-18 dB)
            gain: clamped * clamped * clamped,
            compressorEnabled: compressorEnabled,
            karaokeEnabled: karaokeEnabled,
            karaokeIntensity: karaokeIntensity,
            karaokeUseAI: karaokeUseAI && karaokeAIAvailable,
            driftCorrectionEnabled: driftCorrectionEnabled,
            visualizationActive: visualizationActive
        ))
    }

    private func pushEqualizer() {
        session?.equalizer.setGains(eqBands)
    }

    private func pushCompressor() {
        session?.compressor.setParameters(
            threshold: compressorThreshold,
            ratio: compressorRatio,
            attack: compressorAttack,
            release: compressorRelease,
            makeupGain: compressorMakeupGain
        )
    }

    private func updateAIActivation() {
        vocalSeparatorAI.setActive(karaokeEnabled && karaokeUseAI)
    }

    // MARK: - Visualization polling

    /// Pulls frames published by the audio thread, only while something is visible.
    /// Polls at twice the frame rate so a frame is never shown late by a whole
    /// period; views are only invalidated when a new frame arrived.
    private func updateVisualizationTimer() {
        let shouldRun = visualizationActive && isRunning
        if shouldRun, visualizationTimer == nil {
            let timer = Timer(timeInterval: 0.5 / AudioVisualizer.frameRate, repeats: true) { [weak self] _ in
                self?.pollVisualization()
            }
            RunLoop.main.add(timer, forMode: .common)
            visualizationTimer = timer
        } else if !shouldRun {
            visualizationTimer?.invalidate()
            visualizationTimer = nil
        }
    }

    private func pollVisualization() {
        guard let frame = visualizationTap.readFrame(lastVersion: &visualizationVersion) else { return }
        visualizationData.deliver(bands: frame.bands, scope: frame.scope)
    }

    // MARK: - Settings Persistence

    private func scheduleSave() {
        guard !isLoadingSettings else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveSettings() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(Int(selectedInputID), forKey: "selectedInputID")
        defaults.set(Int(selectedOutputID), forKey: "selectedOutputID")
        defaults.set(volume, forKey: "volume")
        defaults.set(eqBands, forKey: "eqBands")

        defaults.set(compressorEnabled, forKey: "compressorEnabled")
        defaults.set(compressorThreshold, forKey: "compressorThreshold")
        defaults.set(compressorRatio, forKey: "compressorRatio")
        defaults.set(compressorAttack, forKey: "compressorAttack")
        defaults.set(compressorRelease, forKey: "compressorRelease")
        defaults.set(compressorMakeupGain, forKey: "compressorMakeupGain")
        defaults.set(driftCorrectionEnabled, forKey: "driftCorrectionEnabled")

        defaults.set(karaokeEnabled, forKey: "karaokeEnabled")
        defaults.set(karaokeIntensity, forKey: "karaokeIntensity")
        defaults.set(karaokeUseAI, forKey: "karaokeUseAI")
    }

    private func loadSavedSettings() {
        isLoadingSettings = true
        defer { isLoadingSettings = false }
        let defaults = UserDefaults.standard

        if let savedInput = defaults.object(forKey: "selectedInputID") as? Int, savedInput > 0 {
            selectedInputID = AudioDeviceID(savedInput)
        }
        if let savedOutput = defaults.object(forKey: "selectedOutputID") as? Int, savedOutput > 0 {
            selectedOutputID = AudioDeviceID(savedOutput)
        }
        if let savedVolume = defaults.object(forKey: "volume") as? Float {
            volume = savedVolume
        }
        if let savedBands = defaults.array(forKey: "eqBands") as? [Float], savedBands.count == Equalizer.bandCount {
            eqBands = savedBands
        }

        compressorEnabled = defaults.bool(forKey: "compressorEnabled")
        if let threshold = defaults.object(forKey: "compressorThreshold") as? Float {
            compressorThreshold = threshold
        }
        if let ratio = defaults.object(forKey: "compressorRatio") as? Float {
            compressorRatio = ratio
        }
        if let attack = defaults.object(forKey: "compressorAttack") as? Float {
            compressorAttack = attack
        }
        if let release = defaults.object(forKey: "compressorRelease") as? Float {
            compressorRelease = release
        }
        if let makeupGain = defaults.object(forKey: "compressorMakeupGain") as? Float {
            compressorMakeupGain = makeupGain
        }
        // Default to true if not set
        driftCorrectionEnabled = defaults.object(forKey: "driftCorrectionEnabled") as? Bool ?? true

        karaokeEnabled = defaults.bool(forKey: "karaokeEnabled")
        if let intensity = defaults.object(forKey: "karaokeIntensity") as? Float {
            karaokeIntensity = intensity
        }
        karaokeUseAI = defaults.bool(forKey: "karaokeUseAI")
    }
}
