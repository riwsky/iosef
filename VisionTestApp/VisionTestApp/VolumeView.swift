import RealityKit
import SwiftUI

/// A volumetric window holding one cube that can be tapped and dragged around inside it.
struct VolumeView: View {
    static let id = "Volume"
    @Environment(VisionTestState.self) private var state

    var body: some View {
        RealityView { content in
            let cube = ModelEntity(
                mesh: .generateBox(size: 0.1, cornerRadius: 0.01),
                materials: [SimpleMaterial(color: .systemTeal, isMetallic: false)]
            )
            cube.name = "volume_cube"
            cube.makeInteractive(radius: 0.07, label: "Volume cube")
            content.add(cube)
            log.notice("[VisionTest] Volume ready")
        }
        .gesture(
            SpatialTapGesture()
                .targetedToAnyEntity()
                .onEnded { _ in state.tapVolumeCube() }
        )
        .gesture(entityDrag { state.movedVolumeCube(to: $0.position) })
    }
}
