import SwiftUI
import Observation

@Observable
class TapState {
    var tapCount = 0
    var lastTapRow: Int? = nil
    var lastTapCol: Int? = nil
    var currentButton: String? = nil
    var flashingButton: String? = nil

    func tapButton(row: Int, col: Int) {
        let key = "\(row)_\(col)"
        tapCount += 1
        lastTapRow = row
        lastTapCol = col
        flashingButton = key
        currentButton = key

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if self.flashingButton == key {
                self.flashingButton = nil
            }
        }

        print("[WatchTest] Button tapped: R\(row)C\(col) (tap #\(tapCount))")
    }

    func buttonColor(row: Int, col: Int) -> Color {
        let key = "\(row)_\(col)"
        if flashingButton == key { return .green }
        if currentButton == key { return .blue }
        return Color(.darkGray)
    }
}

struct ContentView: View {
    @State private var state = TapState()

    private let rows = 5
    private let cols = 4

    var body: some View {
        VStack(spacing: 2) {
            if let row = state.lastTapRow, let col = state.lastTapCol {
                Text("Last: R\(row)C\(col)")
                    .font(.system(size: 10, design: .monospaced))
                    .accessibilityIdentifier("last_tap_label")
                    .accessibilityLabel("Last tapped Row \(row) Column \(col)")
            } else {
                Text("Tap a cell")
                    .font(.system(size: 10, design: .monospaced))
                    .accessibilityIdentifier("last_tap_label")
                    .accessibilityLabel("No taps yet")
            }

            Text("Taps: \(state.tapCount)")
                .font(.system(size: 9, design: .monospaced))
                .accessibilityIdentifier("tap_count_label")
                .accessibilityLabel("Tap count \(state.tapCount)")

            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                ForEach(0..<rows, id: \.self) { row in
                    GridRow {
                        ForEach(0..<cols, id: \.self) { col in
                            Button(action: { state.tapButton(row: row, col: col) }) {
                                Text("R\(row)C\(col)")
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(state.buttonColor(row: row, col: col))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Row \(row) Column \(col)")
                            .accessibilityIdentifier("grid_\(row)_\(col)")
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("button_grid")
        }
        .accessibilityIdentifier("root_view")
    }
}
