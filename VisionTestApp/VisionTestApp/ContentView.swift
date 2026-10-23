import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 24) {
            StatusBar()
            TapGrid()
            HStack(alignment: .top, spacing: 40) {
                TextEntry()
                DragTarget()
            }
            HStack(spacing: 40) {
                VolumeToggle()
                ImmersionToggle()
            }
            SpatialStatus()
        }
        .padding(40)
        .onAppear { log.notice("[VisionTest] Window ready") }
    }
}

private struct StatusBar: View {
    @Environment(VisionTestState.self) private var state

    var body: some View {
        HStack {
            Text("Vision Test")
                .font(.title)
                .accessibilityIdentifier("title_label")
            Spacer()
            Text("Taps: \(state.tapCount)")
                .accessibilityLabel("Tap count \(state.tapCount)")
                .accessibilityIdentifier("tap_count_label")
            Text(state.lastTap.map { "Last: \($0)" } ?? "Last: none")
                .accessibilityLabel(state.lastTap.map { "Last tapped \($0)" } ?? "No taps yet")
                .accessibilityIdentifier("last_tap_label")
            Text("Orb taps: \(state.orbTapCount)")
                .accessibilityLabel("Orb tap count \(state.orbTapCount)")
                .accessibilityIdentifier("orb_tap_count_label")
        }
        .font(.headline)
    }
}

/// Buttons spread to the window's corners and edges, so taps far from the centre (where
/// the gaze ray is most sensitive to the camera model) are exercised too.
private struct TapGrid: View {
    @Environment(VisionTestState.self) private var state
    private let rows = 3
    private let cols = 5

    var body: some View {
        Grid(horizontalSpacing: 16, verticalSpacing: 16) {
            ForEach(0..<rows, id: \.self) { row in
                GridRow {
                    ForEach(0..<cols, id: \.self) { col in
                        let name = "R\(row)C\(col)"
                        Button(name) { state.tap(name) }
                            .frame(maxWidth: .infinity)
                            .tint(state.lastTap == name ? .green : nil)
                            .accessibilityLabel("Row \(row) Column \(col)")
                            .accessibilityIdentifier("grid_\(row)_\(col)")
                    }
                }
            }
        }
    }
}

private struct TextEntry: View {
    @Environment(VisionTestState.self) private var state

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading) {
            TextField("Type here", text: $state.textFieldValue)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(width: 360)
                .accessibilityIdentifier("text_field")
                .onChange(of: state.textFieldValue) { _, new in
                    log.notice("[VisionTest] Text changed: \(new, privacy: .public)")
                }
            Text("Text: \(state.textFieldValue)")
                .accessibilityIdentifier("text_value_label")
        }
    }
}

/// A token that follows a pinch-drag. Its offset is reported in points, rounded to 10, so
/// a drag can be asserted on without pixel-perfect gestures.
private struct DragTarget: View {
    @Environment(VisionTestState.self) private var state
    @GestureState private var live: CGSize = .zero

    var body: some View {
        VStack {
            Circle()
                .fill(.orange)
                .frame(width: 60, height: 60)
                .offset(x: state.dragOffset.width + live.width, y: state.dragOffset.height + live.height)
                .gesture(
                    DragGesture()
                        .updating($live) { value, live, _ in live = value.translation }
                        .onEnded { value in
                            state.dragOffset.width += value.translation.width
                            state.dragOffset.height += value.translation.height
                            state.dragCount += 1
                            log.notice("[VisionTest] Drag ended: \(Int(value.translation.width)), \(Int(value.translation.height))")
                        }
                )
                .accessibilityIdentifier("drag_token")
                .frame(width: 360, height: 120)
            Text("Drags: \(state.dragCount) offset: \(rounded(state.dragOffset.width)), \(rounded(state.dragOffset.height))")
                .accessibilityIdentifier("drag_label")
        }
    }

    private func rounded(_ v: CGFloat) -> Int { Int((v / 10).rounded()) * 10 }
}

private struct ImmersionToggle: View {
    @Environment(VisionTestState.self) private var state
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        Button(state.isImmersed ? "Leave Space" : "Enter Space") {
            Task {
                if state.isImmersed {
                    await dismissImmersiveSpace()
                    state.isImmersed = false
                } else {
                    state.isImmersed = await openImmersiveSpace(id: ImmersiveView.id) == .opened
                }
                log.notice("[VisionTest] Immersed: \(state.isImmersed)")
            }
        }
        .accessibilityIdentifier("immersion_toggle")
    }
}

private struct VolumeToggle: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Volume") {
            openWindow(id: VolumeView.id)
            log.notice("[VisionTest] Volume opened")
        }
        .accessibilityIdentifier("volume_toggle")
    }
}

/// Where the 3D content is, so moves in the volume and immersive space can be asserted on
/// from the window.
private struct SpatialStatus: View {
    @Environment(VisionTestState.self) private var state

    var body: some View {
        VStack(alignment: .leading) {
            Text("Volume cube taps: \(state.volumeCubeTapCount) at \(state.volumeCubePosition.centimetres) cm")
                .accessibilityIdentifier("volume_cube_label")
            Text("Immersive cube at \(state.immersiveCubePosition.centimetres) cm")
                .accessibilityIdentifier("immersive_cube_label")
        }
        .font(.callout)
    }
}
