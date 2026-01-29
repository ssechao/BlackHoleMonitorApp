import SwiftUI

struct SpectrumAnalyzerView: View {
    let bands: [Float]
    let barCount = 16
    let segmentCount = 12  // Like Alpine car stereos
    
    // Alpine-style colors: green at bottom, yellow in middle, red at top
    private func colorForSegment(_ segment: Int) -> Color {
        let ratio = Float(segment) / Float(segmentCount)
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
    
    var body: some View {
        GeometryReader { geometry in
            let totalSpacing = CGFloat(barCount - 1) * 2
            let barWidth = (geometry.size.width - 8 - totalSpacing) / CGFloat(barCount)
            
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { bandIndex in
                    SpectrumBar(
                        value: CGFloat(bands.indices.contains(bandIndex) ? bands[bandIndex] : 0),
                        segmentCount: segmentCount,
                        colorForSegment: colorForSegment,
                        barWidth: barWidth
                    )
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
        .background(Color.black.opacity(0.8))
        .cornerRadius(6)
    }
}

struct SpectrumBar: View {
    let value: CGFloat  // 0.0 to 1.0
    let segmentCount: Int
    let colorForSegment: (Int) -> Color
    var barWidth: CGFloat = 12
    
    private let segmentHeight: CGFloat = 4
    private let segmentSpacing: CGFloat = 1
    
    var body: some View {
        VStack(spacing: segmentSpacing) {
            ForEach((0..<segmentCount).reversed(), id: \.self) { segment in
                let isLit = CGFloat(segment) / CGFloat(segmentCount) < value
                Rectangle()
                    .fill(isLit ? colorForSegment(segment) : Color.gray.opacity(0.2))
                    .frame(height: segmentHeight)
            }
        }
        .frame(width: barWidth)
    }
}

// Preview
struct SpectrumAnalyzerView_Previews: PreviewProvider {
    static var previews: some View {
        SpectrumAnalyzerView(bands: [
            0.8, 0.9, 0.7, 0.85, 0.6, 0.75, 0.5, 0.65,
            0.4, 0.55, 0.3, 0.45, 0.2, 0.35, 0.1, 0.25
        ])
        .frame(width: 280)
    }
}
