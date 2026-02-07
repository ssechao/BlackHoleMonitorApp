import SwiftUI
import ServiceManagement

struct MenuBarView: View {
    @ObservedObject var audioManager = AudioManager.shared
    @ObservedObject var discoController = DiscoWindowController.shared
    @ObservedObject var spectrumWindowController = SpectrumWindowController.shared
    @AppStorage("autoStart") var autoStart = true
    @State private var compressorExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: audioManager.isRunning ? "speaker.wave.3.fill" : "speaker.slash.fill")
                    .foregroundColor(audioManager.isRunning ? .green : .gray)
                Text("BlackHole Monitor")
                    .font(.headline)
                Spacer()
            }
            .padding(.bottom, 4)
            
            // Spectrum Analyzer - isolated in its own observed view
            // so updates don't trigger full MenuBarView re-render
            if audioManager.isRunning {
                SpectrumContainerView(visualizationData: audioManager.visualizationData)
                    .frame(height: 70)
                OscilloscopeContainerView(visualizationData: audioManager.visualizationData)
                    .frame(height: 40)
            }

            Divider()

            // Input Device
            VStack(alignment: .leading, spacing: 4) {
                Text("Input")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("", selection: $audioManager.selectedInputID) {
                    ForEach(audioManager.inputDevices, id: \.id) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()
            }

            // Output Device
            VStack(alignment: .leading, spacing: 4) {
                Text("Output")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("", selection: $audioManager.selectedOutputID) {
                    ForEach(audioManager.outputDevices, id: \.id) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()
            }

            // Volume
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Volume")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(audioManager.volume * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Slider(value: $audioManager.volume, in: 0...1)
            }

            Divider()

            // Compressor Section
            DisclosureGroup(
                isExpanded: $compressorExpanded,
                content: {
                    VStack(alignment: .leading, spacing: 8) {
                        // Threshold
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Threshold")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(Int(audioManager.compressorThreshold)) dB")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(value: $audioManager.compressorThreshold, in: -60...0)
                        }

                        // Ratio
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Ratio")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(audioManager.compressorRatio >= 20 ? "∞:1" : "\(String(format: "%.1f", audioManager.compressorRatio)):1")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(value: $audioManager.compressorRatio, in: 1...20)
                        }

                        // Attack
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Attack")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(String(format: "%.1f", audioManager.compressorAttack)) ms")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(value: $audioManager.compressorAttack, in: 0.1...100)
                        }

                        // Release
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Release")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(Int(audioManager.compressorRelease)) ms")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(value: $audioManager.compressorRelease, in: 10...1000)
                        }

                        // Makeup Gain
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Makeup Gain")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(audioManager.compressorMakeupGain >= 0 ? "+" : "")\(String(format: "%.1f", audioManager.compressorMakeupGain)) dB")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(value: $audioManager.compressorMakeupGain, in: -12...24)
                        }
                        
                        Divider()
                            .padding(.vertical, 4)
                        
                        // Drift Correction Toggle
                        Toggle(isOn: $audioManager.driftCorrectionEnabled) {
                            HStack {
                                Image(systemName: "clock.arrow.2.circlepath")
                                Text("Drift Correction")
                                    .font(.caption2)
                            }
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                    .padding(.top, 4)
                },
                label: {
                    Toggle(isOn: $audioManager.compressorEnabled) {
                        HStack {
                            Image(systemName: "waveform.path")
                            Text("Compressor")
                                .font(.caption)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            )

            // Karaoke Section
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $audioManager.karaokeEnabled) {
                    HStack {
                        Image(systemName: "mic.slash.fill")
                        Text("Karaoke Mode")
                            .font(.caption)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                
                if audioManager.karaokeEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        // AI Toggle
                        Toggle(isOn: $audioManager.karaokeUseAI) {
                            HStack(spacing: 4) {
                                Image(systemName: "brain")
                                    .foregroundColor(audioManager.karaokeUseAI ? .purple : .secondary)
                                Text("Demucs AI")
                                    .font(.caption2)
                                if audioManager.karaokeUseAI {
                                    if audioManager.karaokeAIAvailable {
                                        Text("(~3s latency)")
                                            .font(.caption2)
                                            .foregroundColor(.orange)
                                    } else {
                                        Text("connecting...")
                                            .font(.caption2)
                                            .foregroundColor(.yellow)
                                    }
                                }
                            }
                        }
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        
                        if !audioManager.karaokeUseAI {
                            Text("Mid-Side mode (instant, basic)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Vocal Removal")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(Int(audioManager.karaokeIntensity * 100))%")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(value: $audioManager.karaokeIntensity, in: 0...1)
                        }
                    }
                }
            }

            // EQ Section
            VStack(alignment: .leading, spacing: 6) {
                Text("Equalizer")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                GeometryReader { geometry in
                    let sliderCount: CGFloat = 8
                    let totalSpacing = (sliderCount - 1) * 4
                    let sliderWidth = (geometry.size.width - totalSpacing) / sliderCount
                    
                    HStack(alignment: .bottom, spacing: 4) {
                        ForEach(0..<8, id: \.self) { index in
                            VStack(spacing: 2) {
                                VerticalSliderView(
                                    value: Binding(
                                        get: { Double(audioManager.eqBands[index]) },
                                        set: { audioManager.eqBands[index] = Float($0) }
                                    ),
                                    range: -12...12,
                                    height: 70,
                                    width: sliderWidth
                                )
                                .frame(width: sliderWidth, alignment: .center)

                                Text("\(Int(audioManager.eqBands[index]))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 110)

            Divider()

            // Status
            if audioManager.isRunning {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                        Text("\(audioManager.inputSampleRateDisplay)Hz → \(audioManager.outputSampleRateDisplay)Hz")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    // Warning if sample rates don't match
                    if audioManager.sampleRateMismatch {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.caption2)
                            Text("Resampling actif - qualité réduite")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    }
                }
            }

            // Start/Stop Button
            Button {
                toggleAudio()
            } label: {
                HStack {
                    Image(systemName: audioManager.isRunning ? "stop.fill" : "play.fill")
                    Text(audioManager.isRunning ? "Stop" : "Start")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(audioManager.isRunning ? .red : .green)
            
            // Disco Mode Button
            if audioManager.isRunning {
                Button {
                    discoController.toggle()
                } label: {
                    HStack {
                        Image(systemName: discoController.isActive ? "sparkles" : "party.popper")
                        Text(discoController.isActive ? "Stop Disco" : "Disco Mode")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(discoController.isActive ? .orange : .purple)

                Button {
                    spectrumWindowController.toggle()
                } label: {
                    HStack {
                        Image(systemName: spectrumWindowController.isActive ? "waveform.circle.fill" : "waveform.circle")
                        Text(spectrumWindowController.isActive ? "Hide Spectrum" : "Show Spectrum")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Divider()

            // Auto-start toggle
            Toggle("Launch at login", isOn: $autoStart)
                .onChange(of: autoStart) { newValue in
                    setAutoStart(newValue)
                }

            // Quit button
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .foregroundColor(.red)
        }
        .padding()
        .frame(width: 280)
        .onAppear {
            audioManager.refreshDevices()
            if autoStart && !audioManager.isRunning {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    audioManager.start()
                }
            }
        }
    }

    func setAutoStart(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to set auto-start: \(error)")
        }
    }
    
    func toggleAudio() {
        if audioManager.isRunning {
            audioManager.stop()
        } else {
            audioManager.start()
        }
    }
}
