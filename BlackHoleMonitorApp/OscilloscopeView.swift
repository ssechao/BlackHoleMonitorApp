import SwiftUI

struct OscilloscopeView: View {
    let samples: [Float]
    
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                guard samples.count > 1 else { return }
                
                let midY = size.height / 2
                let stepX = size.width / CGFloat(samples.count - 1)
                
                var path = Path()
                path.move(to: CGPoint(x: 0, y: midY))
                
                for i in 0..<samples.count {
                    let x = CGFloat(i) * stepX
                    let y = midY - CGFloat(samples[i]) * midY
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                
                // Glow effect
                context.stroke(path, with: .color(.cyan.opacity(0.3)), lineWidth: 6)
                context.stroke(path, with: .color(.blue.opacity(0.6)), lineWidth: 3)
                context.stroke(path, with: .color(.white), lineWidth: 1)
            }
            .background(Color.black.opacity(0.7))
            .cornerRadius(6)
        }
    }
}