import SwiftUI

struct GridSection: View {
    let state: TapState

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 6)
    private let rows = 8

    var body: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(0..<rows, id: \.self) { row in
                ForEach(0..<6, id: \.self) { col in
                    Button(action: { state.tapButton(row: row, col: col) }) {
                        Text("R\(row)C\(col)")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(state.textColor(row: row, col: col))
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background(state.buttonColor(row: row, col: col))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Row \(row) Column \(col)")
                    .accessibilityIdentifier("grid_\(row)_\(col)")
                    .accessibilityHint("Tap to select grid cell at row \(row), column \(col)")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("button_grid")
    }
}
