import SwiftUI
import AppKit
import QuartzCore

struct OscilloscopeView: View {
    let samples: [Float]
    
    var body: some View {
        Canvas { context, size in
            guard samples.count > 1 else { return }
            
            // Black background
            context.fill(
                Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6),
                with: .color(.black)
            )
            
            // Center line (dim green grid line)
            let midY = size.height / 2
            var centerLine = Path()
            centerLine.move(to: CGPoint(x: 0, y: midY))
            centerLine.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(centerLine, with: .color(.green.opacity(0.15)), lineWidth: 0.5)
            
            // Waveform
            let stepX = size.width / CGFloat(samples.count - 1)
            
            var path = Path()
            path.move(to: CGPoint(x: 0, y: midY - CGFloat(samples[0]) * midY))
            
            for i in 1..<samples.count {
                let x = CGFloat(i) * stepX
                let y = midY - CGFloat(samples[i]) * midY
                path.addLine(to: CGPoint(x: x, y: y))
            }
            
            // Green phosphor glow effect
            context.stroke(path, with: .color(Color(red: 0, green: 1, blue: 0, opacity: 0.25)), lineWidth: 5)
            context.stroke(path, with: .color(Color(red: 0, green: 1, blue: 0, opacity: 0.5)), lineWidth: 2.5)
            context.stroke(path, with: .color(Color(red: 0.6, green: 1, blue: 0.6)), lineWidth: 1)
        }
        .drawingGroup()
    }
}

/// Green phosphor oscilloscope drawn with Core Animation (popover, floating window).
///
/// Each frame builds one 256-point path and hands it to three stroke layers
/// (glow, halo, core); the render server rasterizes them. `OscilloscopeView`
/// (SwiftUI Canvas) is kept for the disco overlay, which re-renders anyway.
final class OscilloscopeLayerView: NSView, VisualizationListener {
    private let centerLine = CAShapeLayer()
    private let strokes: [CAShapeLayer]
    private var samples: [Float] = []

    override init(frame frameRect: NSRect) {
        let styles: [(width: CGFloat, color: NSColor)] = [
            (5, NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 0.25)),
            (2.5, NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 0.5)),
            (1, NSColor(srgbRed: 0.6, green: 1, blue: 0.6, alpha: 1)),
        ]
        strokes = styles.map { style in
            let layer = CAShapeLayer()
            layer.fillColor = nil
            layer.strokeColor = style.color.cgColor
            layer.lineWidth = style.width
            layer.lineJoin = .round
            return layer
        }
        super.init(frame: frameRect)
        wantsLayer = true
        let root = CALayer()
        root.cornerRadius = 6
        root.masksToBounds = true
        root.backgroundColor = NSColor.black.cgColor
        layer = root

        centerLine.fillColor = nil
        centerLine.strokeColor = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 0.15).cgColor
        centerLine.lineWidth = 0.5
        root.addSublayer(centerLine)
        strokes.forEach { root.addSublayer($0) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func visualizationFrame(bands: [Float], scope: [Float]) {
        samples = scope
        updateWaveform()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let midY = bounds.midY
        let line = CGMutablePath()
        line.move(to: CGPoint(x: 0, y: midY))
        line.addLine(to: CGPoint(x: bounds.width, y: midY))
        centerLine.frame = bounds
        centerLine.path = line
        strokes.forEach { $0.frame = bounds }
        CATransaction.commit()
        updateWaveform()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        ([centerLine] + strokes).forEach { $0.contentsScale = scale }
    }

    private func updateWaveform() {
        guard samples.count > 1, bounds.width > 0 else { return }
        // Non-flipped view: positive samples go up, as in the Canvas version
        let midY = bounds.midY
        let stepX = bounds.width / CGFloat(samples.count - 1)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: midY + CGFloat(samples[0]) * midY))
        for i in 1..<samples.count {
            path.addLine(to: CGPoint(x: CGFloat(i) * stepX, y: midY + CGFloat(samples[i]) * midY))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strokes.forEach { $0.path = path }
        CATransaction.commit()
    }
}

/// SwiftUI wrapper. It does not observe `VisualizationData`: frames go straight
/// to the layer view, so the surrounding SwiftUI views are never re-rendered.
struct OscilloscopeContainerView: NSViewRepresentable {
    let visualizationData: VisualizationData

    func makeNSView(context: Context) -> OscilloscopeLayerView {
        let view = OscilloscopeLayerView()
        view.visualizationFrame(bands: visualizationData.spectrumBands, scope: visualizationData.oscilloscopeSamples)
        visualizationData.addListener(view)
        return view
    }

    func updateNSView(_ nsView: OscilloscopeLayerView, context: Context) {}
}
