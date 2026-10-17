import SwiftUI
import AppKit
import QuartzCore

/// 16-bar LED spectrum drawn with Core Animation.
///
/// The segment grid (unlit and lit colors) is built once per size; each frame
/// only changes the heights of 16 mask layers. The render server composites
/// it, so a frame costs almost nothing on the main thread and SwiftUI is not
/// involved at all (no view graph update per frame).
final class SpectrumLayerView: NSView, VisualizationListener {
    private static let barCount = VisualizationTap.bandCount
    private static let segmentCount = 12
    private static let padding: CGFloat = 4
    private static let barSpacing: CGFloat = 2
    private static let segmentSpacing: CGFloat = 1
    private static let segmentHeight: CGFloat = 4

    private let unlitLayer = CAShapeLayer()
    private let litContainer = CALayer()
    private let colorLayers = (0..<4).map { _ in CAShapeLayer() }  // green, yellow, orange, red
    private let maskLayer = CALayer()
    private let barMasks = (0..<SpectrumLayerView.barCount).map { _ in CALayer() }
    private var levels = [Float](repeating: 0, count: SpectrumLayerView.barCount)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let root = CALayer()
        root.cornerRadius = 6
        root.masksToBounds = true
        layer = root

        unlitLayer.fillColor = NSColor.gray.withAlphaComponent(0.2).cgColor
        root.addSublayer(unlitLayer)
        colorLayers.forEach { litContainer.addSublayer($0) }
        barMasks.forEach {
            $0.backgroundColor = NSColor.white.cgColor
            maskLayer.addSublayer($0)
        }
        litContainer.mask = maskLayer
        root.addSublayer(litContainer)
        updateColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { false }  // y grows upward, bars grow from the bottom

    func visualizationFrame(bands: [Float], scope: [Float]) {
        levels = bands
        updateBars()
    }

    override func layout() {
        super.layout()
        rebuildGrid()
        updateBars()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        ([unlitLayer] + colorLayers).forEach { $0.contentsScale = scale }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        let colors: [NSColor] = [.systemGreen, .systemYellow, .systemOrange, .systemRed]
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
            for (layer, color) in zip(colorLayers, colors) {
                layer.fillColor = color.cgColor
            }
        }
    }

    /// Same thresholds as the former Canvas version.
    private static func colorIndex(segment: Int) -> Int {
        let ratio = Float(segment) / Float(segmentCount)
        if ratio > 0.85 { return 3 }
        if ratio > 0.65 { return 2 }
        if ratio > 0.45 { return 1 }
        return 0
    }

    private var barWidth: CGFloat {
        let available = bounds.width - Self.padding * 2 - CGFloat(Self.barCount - 1) * Self.barSpacing
        return max(available / CGFloat(Self.barCount), 1)
    }

    private func segmentY(_ segment: Int) -> CGFloat {
        Self.padding + Self.segmentSpacing + CGFloat(segment) * (Self.segmentHeight + Self.segmentSpacing)
    }

    private func rebuildGrid() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let unlit = CGMutablePath()
        let lit = (0..<4).map { _ in CGMutablePath() }
        for bar in 0..<Self.barCount {
            let x = Self.padding + CGFloat(bar) * (barWidth + Self.barSpacing)
            for segment in 0..<Self.segmentCount {
                let rect = CGRect(x: x, y: segmentY(segment), width: barWidth, height: Self.segmentHeight)
                unlit.addRect(rect)
                lit[Self.colorIndex(segment: segment)].addRect(rect)
            }
        }
        unlitLayer.frame = bounds
        unlitLayer.path = unlit
        litContainer.frame = bounds
        maskLayer.frame = bounds
        for (layer, path) in zip(colorLayers, lit) {
            layer.frame = bounds
            layer.path = path
        }
    }

    private func updateBars() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width = barWidth
        for bar in 0..<Self.barCount {
            let level = levels.indices.contains(bar) ? CGFloat(levels[bar]) : 0
            // Segment s is lit when s / segmentCount < level
            let litSegments = min(Self.segmentCount, max(0, Int((level * CGFloat(Self.segmentCount)).rounded(.up))))
            let x = Self.padding + CGFloat(bar) * (width + Self.barSpacing)
            let top = litSegments == 0 ? 0 : segmentY(litSegments - 1) + Self.segmentHeight
            barMasks[bar].frame = CGRect(x: x, y: 0, width: width, height: top)
        }
        CATransaction.commit()
    }
}

/// SwiftUI wrapper. It does not observe `VisualizationData`: frames go straight
/// to the layer view, so the surrounding SwiftUI views are never re-rendered.
struct SpectrumContainerView: NSViewRepresentable {
    let visualizationData: VisualizationData

    func makeNSView(context: Context) -> SpectrumLayerView {
        let view = SpectrumLayerView()
        view.visualizationFrame(bands: visualizationData.spectrumBands, scope: visualizationData.oscilloscopeSamples)
        visualizationData.addListener(view)
        return view
    }

    func updateNSView(_ nsView: SpectrumLayerView, context: Context) {}
}
