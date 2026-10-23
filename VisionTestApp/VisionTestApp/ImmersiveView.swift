import RealityKit
import SwiftUI

/// The immersive space: an orb up and to the left of the window (tap target) and a cube to
/// its right (drag target), both clear of the window so they aren't hidden behind it.
struct ImmersiveView: View {
    static let id = "ImmersiveSpace"
    nonisolated static let cubeStart: SIMD3<Float> = [1.0, 1.6, -2.0]
    @Environment(VisionTestState.self) private var state

    var body: some View {
        RealityView { content in
            let orb = ModelEntity(
                mesh: .generateSphere(radius: 0.15),
                materials: [UnlitMaterial(color: .systemPink)]
            )
            orb.name = "orb"
            orb.position = [-1.0, 1.6, -2.0]
            orb.makeInteractive(radius: 0.15, label: "Orb")
            content.add(orb)

            let cube = ModelEntity(
                mesh: .generateBox(size: 0.2, cornerRadius: 0.02),
                materials: [UnlitMaterial(color: .systemPurple)]
            )
            cube.name = "immersive_cube"
            cube.position = Self.cubeStart
            cube.makeInteractive(radius: 0.14, label: "Immersive cube")
            content.add(cube)
            log.notice("[VisionTest] Immersive space ready")
        }
        .gesture(
            SpatialTapGesture()
                .targetedToAnyEntity()
                .onEnded { value in
                    if value.entity.name == "orb" { state.tapOrb() }
                }
        )
        .gesture(entityDrag { entity in
            if entity.name == "immersive_cube" { state.movedImmersiveCube(to: entity.position) }
        })
    }
}
