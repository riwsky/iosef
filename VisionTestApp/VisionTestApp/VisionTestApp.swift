import SwiftUI

@main
struct VisionTestApp: App {
    @State private var state = VisionTestState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(state)
        }
        .defaultSize(width: 1280, height: 720)

        WindowGroup(id: VolumeView.id) {
            VolumeView()
                .environment(state)
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 0.6, height: 0.4, depth: 0.4, in: .meters)

        ImmersiveSpace(id: ImmersiveView.id) {
            ImmersiveView()
                .environment(state)
        }
    }
}
