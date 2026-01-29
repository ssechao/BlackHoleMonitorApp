import SwiftUI
import AppKit

// MARK: - Disco Window Controller

class DiscoWindowController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = DiscoWindowController()
    
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
        
        // Get main screen
        guard let screen = NSScreen.main else { return }
        
        // Create window at desktop level
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        // Desktop level: above wallpaper, below icons
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true  // Click through to desktop icons
        window.acceptsMouseMovedEvents = false
        window.isReleasedWhenClosed = false
        window.delegate = self
        
        // Set SwiftUI content
        let discoView = DiscoView(audioManager: AudioManager.shared)
        window.contentView = NSHostingView(rootView: discoView)
        
        window.orderFront(nil)
        self.window = window
        isActive = true
    }
    
    func stop() {
        guard let window = window else { return }
        window.orderOut(nil)
        window.contentView = nil
        window.delegate = nil
        window.close()
        self.window = nil
        isActive = false
    }
    
    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        window = nil
        isActive = false
    }
}

// MARK: - Disco View (60fps animated)

struct DiscoView: View {
    @ObservedObject var audioManager: AudioManager
    @State private var time: Double = 0
    @State private var strobeOn = false
    @State private var lastBassHit: Double = 0
    
    let timer = Timer.publish(every: 1.0/60.0, on: .main, in: .common).autoconnect()
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background - deep dark with subtle pulse
                backgroundLayer(size: geometry.size)
                
                // Aurora waves
                auroraLayer(size: geometry.size)
                
                // Laser beams
                laserLayer(size: geometry.size)

                // Oscilloscope overlay
                oscilloscopeLayer(size: geometry.size)

                // Center disco ball glow
                discoBallLayer(size: geometry.size)

                // Strobe flash
                if strobeOn {
                    Color.white.opacity(0.8)
                }

                // Particles
                particleLayer(size: geometry.size)
            }
        }
        .ignoresSafeArea()
        .onReceive(timer) { _ in
            time += 1.0/60.0
            updateEffects()
        }
    }
    
    // MARK: - Background
    
    private func backgroundLayer(size: CGSize) -> some View {
        let bass = Double(bassLevel)
        return Rectangle()
            .fill(
                RadialGradient(
                    colors: [
                        Color(hue: 0.75 + bass * 0.1, saturation: 0.8, brightness: 0.15),
                        Color.black
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: size.width * 0.8
                )
            )
    }
    
    // MARK: - Aurora Waves
    
    private func auroraLayer(size: CGSize) -> some View {
        let mids = midLevel
        return Canvas { context, canvasSize in
            for i in 0..<5 {
                let phase = time * (0.3 + Double(i) * 0.1) + Double(i) * 0.5
                let hue = (0.5 + Double(i) * 0.1 + time * 0.05).truncatingRemainder(dividingBy: 1.0)
                let amplitude = 50.0 + Double(mids) * 100.0
                
                var path = Path()
                path.move(to: CGPoint(x: 0, y: canvasSize.height * 0.5))
                
                for x in stride(from: 0, to: canvasSize.width, by: 5) {
                    let y = canvasSize.height * 0.5 +
                        sin(x * 0.01 + phase) * amplitude +
                        sin(x * 0.02 + phase * 1.5) * amplitude * 0.5
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                
                path.addLine(to: CGPoint(x: canvasSize.width, y: canvasSize.height))
                path.addLine(to: CGPoint(x: 0, y: canvasSize.height))
                path.closeSubpath()
                
                context.fill(
                    path,
                    with: .color(Color(hue: hue, saturation: 0.8, brightness: 0.6).opacity(0.2))
                )
            }
        }
    }
    
    // MARK: - Laser Beams
    
    private func laserLayer(size: CGSize) -> some View {
        let bass = bassLevel
        let treble = trebleLevel
        
        return Canvas { context, canvasSize in
            let centerX = canvasSize.width / 2
            let centerY = canvasSize.height * 0.3
            let laserCount = 12
            
            for i in 0..<laserCount {
                let baseAngle = Double(i) * (2 * .pi / Double(laserCount))
                let wobble = sin(time * 3 + Double(i)) * 0.3 * Double(bass)
                let angle = baseAngle + time * 0.5 + wobble
                
                let length = canvasSize.width * (0.6 + Double(treble) * 0.4)
                let endX = centerX + cos(angle) * length
                let endY = centerY + sin(angle) * length
                
                var path = Path()
                path.move(to: CGPoint(x: centerX, y: centerY))
                path.addLine(to: CGPoint(x: endX, y: endY))
                
                let hue = (Double(i) / Double(laserCount) + time * 0.1).truncatingRemainder(dividingBy: 1.0)
                let brightness = 0.8 + Double(bass) * 0.2
                
                context.stroke(
                    path,
                    with: .color(Color(hue: hue, saturation: 1.0, brightness: brightness)),
                    lineWidth: 2 + CGFloat(bass) * 3
                )
                
                // Laser glow
                context.stroke(
                    path,
                    with: .color(Color(hue: hue, saturation: 0.5, brightness: 1.0).opacity(0.3)),
                    lineWidth: 8 + CGFloat(bass) * 10
                )
            }
        }
    }
    
    // MARK: - Disco Ball
    
    private func discoBallLayer(size: CGSize) -> some View {
        let bass = Double(bassLevel)
        let overall = Double(overallLevel)
        let radius = 50 + CGFloat(overall) * 30
        
        // Dance movement - bounce on bass, sway side to side
        let bounceY = sin(time * 8) * 20 * bass + bass * 40  // Vertical bounce on beat
        let swayX = sin(time * 2) * 30 * (0.3 + bass * 0.7)  // Side to side sway
        let rotation = time * 50  // Spinning
        let scale = 1.0 + bass * 0.3  // Pulse bigger on bass
        let glowOpacity = 0.5 + bass * 0.3
        
        let glowGradient = RadialGradient(
            colors: [
                Color.white.opacity(glowOpacity),
                Color.white.opacity(0.2),
                Color.clear
            ],
            center: .center,
            startRadius: radius * 0.5,
            endRadius: radius * 2
        )
        
        let ballGradient = RadialGradient(
            colors: [
                Color.white,
                Color(white: 0.7)
            ],
            center: UnitPoint(x: 0.3, y: 0.3),
            startRadius: 0,
            endRadius: radius
        )
        
        return ZStack {
            // Glow
            Circle()
                .fill(glowGradient)
                .frame(width: radius * 4, height: radius * 4)
            
            // Disco ball with facets
            ZStack {
                // Base ball
                Circle()
                    .fill(ballGradient)
                
                // Mirror facets
                ForEach(0..<12, id: \.self) { i in
                    let angle = Double(i) * (360.0 / 12.0) + rotation
                    let radians = angle * .pi / 180
                    let facetX = cos(radians) * Double(radius) * 0.3
                    let facetY = sin(radians) * Double(radius) * 0.3
                    
                    Circle()
                        .fill(Color.white.opacity(0.8))
                        .frame(width: radius * 0.2, height: radius * 0.2)
                        .offset(x: facetX, y: facetY)
                }
                
                // Inner ring of facets
                ForEach(0..<8, id: \.self) { i in
                    let angle = Double(i) * (360.0 / 8.0) + rotation * 1.5 + 22.5
                    let radians = angle * .pi / 180
                    let facetX = cos(radians) * Double(radius) * 0.15
                    let facetY = sin(radians) * Double(radius) * 0.15
                    
                    Circle()
                        .fill(Color.white.opacity(0.6))
                        .frame(width: radius * 0.15, height: radius * 0.15)
                        .offset(x: facetX, y: facetY)
                }
            }
            .frame(width: radius, height: radius)
            .scaleEffect(scale)
        }
        .position(x: size.width / 2 + swayX, y: size.height * 0.3 - bounceY)
    }
    
    // MARK: - Particles
    
    private func particleLayer(size: CGSize) -> some View {
        let treble = trebleLevel
        
        return Canvas { context, canvasSize in
            let particleCount = 50
            
            for i in 0..<particleCount {
                let seed = Double(i) * 1.618
                let particleTime = (time + seed).truncatingRemainder(dividingBy: 5.0)
                let progress = particleTime / 5.0
                
                let startX = canvasSize.width / 2
                let startY = canvasSize.height * 0.3
                
                let angle = seed * 2 * .pi
                let speed = 200 + seed.truncatingRemainder(dividingBy: 1.0) * 300
                let x = startX + cos(angle) * speed * progress * (1 + Double(treble))
                let y = startY + sin(angle) * speed * progress * (1 + Double(treble)) + progress * progress * 200
                
                let alpha = (1 - progress) * Double(treble + 0.3)
                let particleSize = (1 - progress) * 4 * (1 + Double(treble))
                
                let rect = CGRect(x: x - particleSize/2, y: y - particleSize/2, width: particleSize, height: particleSize)
                let hue = (seed + time * 0.2).truncatingRemainder(dividingBy: 1.0)
                
                context.fill(
                    Path(ellipseIn: rect),
                    with: .color(Color(hue: hue, saturation: 1.0, brightness: 1.0).opacity(alpha))
                )
            }
        }
    }
    
    // MARK: - Oscilloscope
    
    private func oscilloscopeLayer(size: CGSize) -> some View {
        OscilloscopeView(samples: audioManager.oscilloscopeSamples)
            .frame(width: size.width * 0.8, height: 120)
            .position(x: size.width / 2, y: size.height * 0.75)
            .opacity(0.85)
    }
    
    // MARK: - Audio Reactivity
    
    private var bassLevel: Float {
        // Bands 0-3: bass (32-125Hz)
        let bands = audioManager.spectrumBands
        guard bands.count >= 4 else { return 0 }
        return (bands[0] + bands[1] + bands[2] + bands[3]) / 4
    }
    
    private var midLevel: Float {
        // Bands 4-11: mids (125Hz-2kHz)
        let bands = audioManager.spectrumBands
        guard bands.count >= 12 else { return 0 }
        var sum: Float = 0
        for i in 4..<12 { sum += bands[i] }
        return sum / 8
    }
    
    private var trebleLevel: Float {
        // Bands 12-15: treble (2-16kHz)
        let bands = audioManager.spectrumBands
        guard bands.count >= 16 else { return 0 }
        return (bands[12] + bands[13] + bands[14] + bands[15]) / 4
    }
    
    private var overallLevel: Float {
        let bands = audioManager.spectrumBands
        guard !bands.isEmpty else { return 0 }
        return bands.reduce(0, +) / Float(bands.count)
    }
    
    private func updateEffects() {
        // Strobe on bass hits
        let bass = bassLevel
        if bass > 0.7 && (time - lastBassHit) > 0.1 {
            strobeOn = true
            lastBassHit = time
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                strobeOn = false
            }
        }
    }
}
