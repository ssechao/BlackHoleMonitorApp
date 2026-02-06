import SwiftUI

/// High-performance spectrum analyzer using Canvas instead of individual views
/// Reduces CPU usage by drawing all bars in a single render pass
struct SpectrumAnalyzerView: View {
    let bands: [Float]
    private let barCount = 16
    private let segmentCount = 12
    
    // Pre-computed colors for each segment level
    private static let segmentColors: [Color] = {
        (0..<12).map { segment in
            let ratio = Float(segment) / 12.0
            if ratio > 0.85 {
                return .red
            } else if ratio > 0.65 {
                return .orange
            } else if ratio > 0.45 {
                return .yellow
            } else {
                return .green
            }
        }
    }()
    
    var body: some View {
        Canvas { context, size in
            let padding: CGFloat = 4
            let barSpacing: CGFloat = 2
            let segmentSpacing: CGFloat = 1
            let segmentHeight: CGFloat = 4
            
            let availableWidth = size.width - padding * 2 - CGFloat(barCount - 1) * barSpacing
            let barWidth = availableWidth / CGFloat(barCount)
            let availableHeight = size.height - padding * 2
            
            // Draw background
            context.fill(
                Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6),
                with: .color(.black.opacity(0.8))
            )
            
            // Draw each bar
            for barIndex in 0..<barCount {
                let value = bands.indices.contains(barIndex) ? CGFloat(bands[barIndex]) : 0
                let barX = padding + CGFloat(barIndex) * (barWidth + barSpacing)
                
                // Draw segments from bottom to top
                for segment in 0..<segmentCount {
                    let segmentY = padding + availableHeight - CGFloat(segment + 1) * (segmentHeight + segmentSpacing)
                    let isLit = CGFloat(segment) / CGFloat(segmentCount) < value
                    
                    let rect = CGRect(x: barX, y: segmentY, width: barWidth, height: segmentHeight)
                    let color = isLit ? Self.segmentColors[segment] : Color.gray.opacity(0.2)
                    
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
        .drawingGroup() // Rasterize for better performance
    }
}

// Preview
struct SpectrumAnalyzerView_Previews: PreviewProvider {
    static var previews: some View {
        SpectrumAnalyzerView(bands: [
            0.8, 0.9, 0.7, 0.85, 0.6, 0.75, 0.5, 0.65,
            0.4, 0.55, 0.3, 0.45, 0.2, 0.35, 0.1, 0.25
        ])
        .frame(width: 280, height: 80)
    }
}
