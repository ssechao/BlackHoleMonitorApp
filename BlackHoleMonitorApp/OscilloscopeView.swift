import SwiftUI

struct OscilloscopeView: View {
    let samples: [Float]
    
    var body: some View {
        Canvas { context, size in
            guard samples.count > 1 else { return }
            
            // Draw background
            context.fill(
                Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6),
                with: .color(.black.opacity(0.7))
            )
            
            let midY = size.height / 2
            let stepX = size.width / CGFloat(samples.count - 1)
            
            var path = Path()
            path.move(to: CGPoint(x: 0, y: midY - CGFloat(samples[0]) * midY))
            
            for i in 1..<samples.count {
                let x = CGFloat(i) * stepX
                let y = midY - CGFloat(samples[i]) * midY
                path.addLine(to: CGPoint(x: x, y: y))
            }
            
            // Simplified glow (2 passes instead of 3)
            context.stroke(path, with: .color(.cyan.opacity(0.4)), lineWidth: 4)
            context.stroke(path, with: .color(.white), lineWidth: 1.5)
        }
        .drawingGroup() // Rasterize for better performance
    }
}