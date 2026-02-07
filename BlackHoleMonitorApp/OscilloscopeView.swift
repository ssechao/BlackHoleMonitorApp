import SwiftUI

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

/// Container that observes VisualizationData separately
/// so oscilloscope updates don't trigger full MenuBarView re-render.
struct OscilloscopeContainerView: View {
    @ObservedObject var visualizationData: VisualizationData
    
    var body: some View {
        OscilloscopeView(samples: visualizationData.oscilloscopeSamples)
    }
}
