import SwiftUI
import AppKit

// MARK: - Floating Spectrum Window Controller

class SpectrumWindowController: NSObject, ObservableObject {
    static let shared = SpectrumWindowController()
    
    private var window: NSWindow?
    @Published var isActive = false
    
    func toggle() {
        if isActive {
            stop()
        } else {
            start()
        }
    }
    
    func start() {
        guard window == nil else { return }
        
        let size = NSSize(width: 300, height: 280)
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let origin = NSPoint(x: screenFrame.maxX - size.width - 20, y: screenFrame.maxY - size.height - 40)
        
        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        
        let content = SpectrumFloatingView()
        window.contentView = NSHostingView(rootView: content)
        window.makeKeyAndOrderFront(nil)
        
        self.window = window
        isActive = true
        AudioManager.shared.visualizationActive = true
    }
    
    func stop() {
        window?.close()
        window = nil
        isActive = false
    }
}

// MARK: - Spectrum Floating View

struct SpectrumFloatingView: View {
    @ObservedObject private var audioManager = AudioManager.shared
    @ObservedObject private var vizData = AudioManager.shared.visualizationData
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
            
            VStack(spacing: 6) {
                SpectrumAnalyzerView(bands: vizData.spectrumBands)
                    .frame(height: 50)
                
                OscilloscopeView(samples: vizData.oscilloscopeSamples)
                    .frame(height: 40)

                GeometryReader { geometry in
                    let sliderCount: CGFloat = 8
                    let spacing: CGFloat = 4
                    let totalSpacing = (sliderCount - 1) * spacing
                    let sliderWidth = (geometry.size.width - totalSpacing) / sliderCount
                    
                    HStack(alignment: .bottom, spacing: spacing) {
                        ForEach(0..<8, id: \.self) { index in
                            VStack(spacing: 2) {
                                VerticalSliderView(
                                    value: Binding(
                                        get: { Double(audioManager.eqBands[index]) },
                                        set: { audioManager.eqBands[index] = Float($0) }
                                    ),
                                    range: -12...12,
                                    height: 120,
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
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            
            // Custom close button inside the display
            Button {
                SpectrumWindowController.shared.stop()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.white.opacity(0.7))
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .padding(6)
        }
        .frame(width: 300, height: 280)
    }
}