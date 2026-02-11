import SwiftUI
import Observation

@Observable
class TapState {
    var tapCount = 0
    var lastTapRow: Int? = nil
    var lastTapCol: Int? = nil
    var tappedButtons: Set<String> = []
    var currentButton: String? = nil
    var flashingButton: String? = nil

    var textFieldValue = ""
    var toggle1 = false
    var toggle2 = false
    var toggle3 = false
    var sliderValue: Double = 0.5

    func tapButton(row: Int, col: Int) {
        let key = "\(row)_\(col)"
        tapCount += 1
        lastTapRow = row
        lastTapCol = col

        if let current = currentButton, current != key {
            tappedButtons.insert(current)
        }

        flashingButton = key
        currentButton = key

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if self.flashingButton == key {
                self.flashingButton = nil
            }
        }

        print("[MCPTest] Button tapped: R\(row) C\(col) (tap #\(tapCount))")
    }

    func buttonColor(row: Int, col: Int) -> Color {
        let key = "\(row)_\(col)"
        if flashingButton == key { return .green }
        if currentButton == key { return .blue }
        if tappedButtons.contains(key) { return .yellow }
        return Color(.systemGray5)
    }

    func textColor(row: Int, col: Int) -> Color {
        let key = "\(row)_\(col)"
        if flashingButton == key || currentButton == key { return .white }
        return .primary
    }
}
