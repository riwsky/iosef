import SwiftUI

struct ContentView: View {
    @State private var state = TapState()

    var body: some View {
        VStack(spacing: 0) {
            StatusBar(state: state)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            GridSection(state: state)
                .padding(6)

            Divider()

            ControlsSection(state: state)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Spacer(minLength: 0)
        }
        .accessibilityLabel("MCP Test Playground")
        .accessibilityIdentifier("root_view")
    }
}
