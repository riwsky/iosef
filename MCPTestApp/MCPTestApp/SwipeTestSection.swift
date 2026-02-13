import SwiftUI

struct SwipeTestSection: View {
    let state: TapState

    @GestureState private var isDragging = false

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Swipe Test")
                    .font(.subheadline.bold())
                Spacer()
                Text(statusText)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(statusText)
                    .accessibilityIdentifier("swipe_status_label")
            }

            RoundedRectangle(cornerRadius: 8)
                .fill(isDragging ? Color.blue.opacity(0.3) : Color(.systemGray5))
                .overlay(
                    Text(directionArrow)
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                )
                .frame(maxWidth: .infinity)
                .accessibilityElement()
                .accessibilityIdentifier("swipe_area")
                .accessibilityLabel("Swipe area")
                .accessibilityValue(accessibilityValueString)
                .gesture(
                    DragGesture(minimumDistance: 10)
                        .updating($isDragging) { _, isDragging, _ in
                            isDragging = true
                        }
                        .onEnded { value in
                            state.recordSwipe(translation: value.translation)
                        }
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("swipe_section")
    }

    private var statusText: String {
        guard let dir = state.lastSwipeDirection,
              let dist = state.lastSwipeDistance else {
            return "No swipes"
        }
        let arrow: String
        switch dir {
        case "right": arrow = "\u{2192}"
        case "left": arrow = "\u{2190}"
        case "up": arrow = "\u{2191}"
        case "down": arrow = "\u{2193}"
        default: arrow = "?"
        }
        return "Swipe: \(arrow) \(String(format: "%.0f", dist))pt"
    }

    private var directionArrow: String {
        guard let dir = state.lastSwipeDirection else { return "\u{2194}" }
        switch dir {
        case "right": return "\u{2192}"
        case "left": return "\u{2190}"
        case "up": return "\u{2191}"
        case "down": return "\u{2193}"
        default: return "\u{2194}"
        }
    }

    private var accessibilityValueString: String {
        guard let dir = state.lastSwipeDirection,
              let dist = state.lastSwipeDistance else {
            return "none"
        }
        return "\(dir),\(String(format: "%.0f", dist))"
    }
}
