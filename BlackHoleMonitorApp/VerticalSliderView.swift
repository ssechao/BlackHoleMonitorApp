import SwiftUI
import AppKit

struct VerticalSliderView: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let height: CGFloat
    let width: CGFloat

    init(value: Binding<Double>, range: ClosedRange<Double>, height: CGFloat, width: CGFloat = 16) {
        self._value = value
        self.range = range
        self.height = height
        self.width = width
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: context.coordinator, action: #selector(Coordinator.valueChanged(_:)))
        slider.isContinuous = true
        slider.controlSize = .small
        slider.frame = NSRect(x: 0, y: 0, width: width, height: height)
        slider.isVertical = true
        return slider
    }

    func updateNSView(_ nsView: NSSlider, context: Context) {
        if nsView.doubleValue != value {
            nsView.doubleValue = value
        }
        if nsView.minValue != range.lowerBound || nsView.maxValue != range.upperBound {
            nsView.minValue = range.lowerBound
            nsView.maxValue = range.upperBound
        }
        if nsView.frame.size.height != height || nsView.frame.size.width != width {
            nsView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        }
    }

    class Coordinator: NSObject {
        @Binding var value: Double

        init(value: Binding<Double>) {
            self._value = value
        }

        @objc func valueChanged(_ sender: NSSlider) {
            value = sender.doubleValue
        }
    }
}
