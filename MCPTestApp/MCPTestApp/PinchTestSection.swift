import SwiftUI

/// A pushed screen with room for two fingers: reports the last pinch scale and rotation so
/// multi-touch input can be asserted with `iosef text --identifier pinch_scale`, the way
/// swipes are with `swipe_status_label`.
struct PinchTestSection: View {
    @State private var liveScale = 1.0
    @State private var liveDegrees = 0.0
    @State private var lastScale: Double?
    @State private var lastDegrees: Double?
    @State private var gestureCount = 0

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                readout(title: "Scale", text: scaleText, identifier: "pinch_scale")
                Spacer()
                readout(title: "Rotation", text: degreesText, identifier: "rotation_degrees")
                Spacer()
                readout(title: "Gestures", text: "\(gestureCount)", identifier: "gesture_count")
            }
            .padding(.horizontal, 12)

            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemGray5))
                .overlay(
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                        .scaleEffect(liveScale)
                        .rotationEffect(.degrees(liveDegrees))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
                .accessibilityElement()
                .accessibilityIdentifier("pinch_area")
                .accessibilityLabel("Pinch area")
                .overlay(
                    TwoFingerGestureView(
                        onChanged: { scale, degrees in
                            liveScale = scale
                            liveDegrees = degrees
                        },
                        onEnded: { scale, degrees in
                            lastScale = scale
                            lastDegrees = degrees
                            liveScale = 1
                            liveDegrees = 0
                            gestureCount += 1
                            print("[MCPTest] Gesture: scale \(scaleText) rotation \(degreesText) (gesture #\(gestureCount))")
                        }
                    )
                    .padding(12)
                )
        }
        .navigationTitle("Gestures")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pinch_section")
    }

    private var scaleText: String { lastScale.map { String(format: "%.2f", $0) } ?? "none" }
    private var degreesText: String { lastDegrees.map { String(format: "%.0f", $0) } ?? "none" }

    private func readout(title: String, text: String, identifier: String) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(text)
                .font(.system(.subheadline, design: .monospaced))
                .accessibilityLabel(text)
                .accessibilityIdentifier(identifier)
        }
    }
}

/// Pinch and rotation via UIKit's recognizers, running simultaneously. These are what apps
/// with zoomable content overwhelmingly use, and they report one cumulative scale and
/// rotation per gesture, which is what the readouts want.
private struct TwoFingerGestureView: UIViewRepresentable {
    let onChanged: (Double, Double) -> Void
    let onEnded: (Double, Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChanged: onChanged, onEnded: onEnded) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isMultipleTouchEnabled = true
        view.isAccessibilityElement = false
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        let rotation = UIRotationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        for recognizer in [pinch, rotation] {
            recognizer.delegate = context.coordinator
            view.addGestureRecognizer(recognizer)
        }
        context.coordinator.pinch = pinch
        context.coordinator.rotation = rotation
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let onChanged: (Double, Double) -> Void
        let onEnded: (Double, Double) -> Void
        weak var pinch: UIPinchGestureRecognizer?
        weak var rotation: UIRotationGestureRecognizer?
        private var scale = 1.0
        private var degrees = 0.0
        private var reportedEnd = false

        init(onChanged: @escaping (Double, Double) -> Void, onEnded: @escaping (Double, Double) -> Void) {
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        @objc func changed(_ recognizer: UIGestureRecognizer) {
            switch recognizer.state {
            case .began:
                reportedEnd = false
                fallthrough
            case .changed:
                if let pinch, pinch.state == .began || pinch.state == .changed { scale = pinch.scale }
                if let rotation, rotation.state == .began || rotation.state == .changed {
                    degrees = rotation.rotation * 180 / .pi
                }
                onChanged(scale, degrees)
            case .ended, .cancelled:
                // Both recognizers end on the same lift; report the gesture once.
                guard !reportedEnd else { return }
                reportedEnd = true
                onEnded(scale, degrees)
                scale = 1
                degrees = 0
            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }
}
