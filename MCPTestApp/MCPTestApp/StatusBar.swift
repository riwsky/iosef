import SwiftUI

struct StatusBar: View {
    let state: TapState

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("MCP Test")
                    .font(.headline)
                    .accessibilityIdentifier("title_label")

                Spacer()

                if let row = state.lastTapRow, let col = state.lastTapCol {
                    Text("Last: R\(row)C\(col)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Last tapped Row \(row) Column \(col)")
                        .accessibilityIdentifier("last_tap_label")
                }
            }

            HStack {
                Text("Taps: \(state.tapCount)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Tap count \(state.tapCount)")
                    .accessibilityIdentifier("tap_count_label")
                Spacer()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("status_bar")
    }
}
