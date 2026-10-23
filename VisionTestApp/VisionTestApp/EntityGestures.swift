import RealityKit
import SwiftUI

extension Entity {
    /// Makes an entity hit-testable for gaze + pinch, and an accessibility element named
    /// `label`, so iosef can find it with `--name`.
    func makeInteractive(radius: Float, label: String) {
        components.set(InputTargetComponent())
        components.set(CollisionComponent(shapes: [.generateSphere(radius: radius)]))
        components.set(HoverEffectComponent())
        var accessibility = AccessibilityComponent()
        accessibility.isAccessibilityElement = true
        accessibility.label = LocalizedStringResource(stringLiteral: label)
        accessibility.traits = .button
        components.set(accessibility)
    }
}

extension SIMD3<Float> {
    /// Position in whole centimetres, for labels an agent can assert on.
    var centimetres: String {
        func cm(_ metres: Float) -> Int { Int((metres * 100).rounded()) }
        return "\(cm(x)), \(cm(y)), \(cm(z))"
    }
}

/// Drags whichever entity the pinch started on, keeping it under the hand, and reports
/// where it ended up (in its parent's space) once released.
@MainActor
func entityDrag(onEnded: @escaping @MainActor (Entity) -> Void) -> some Gesture {
    DragGesture()
        .targetedToAnyEntity()
        .onChanged { value in
            guard let parent = value.entity.parent else { return }
            value.entity.position = value.convert(value.location3D, from: .local, to: parent)
        }
        .onEnded { value in onEnded(value.entity) }
}
