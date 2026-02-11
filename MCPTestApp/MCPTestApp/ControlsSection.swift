import SwiftUI

struct ControlsSection: View {
    @Bindable var state: TapState

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Text:")
                    .font(.subheadline)
                TextField("Enter text here", text: $state.textFieldValue)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Text input field")
                    .accessibilityIdentifier("text_field")
                    .accessibilityHint("Enter text to test ui_type")
                    .onChange(of: state.textFieldValue) { _, newValue in
                        print("[MCPTest] Text changed: \"\(newValue)\"")
                    }
            }

            HStack(spacing: 16) {
                Toggle("Toggle 1", isOn: $state.toggle1)
                    .toggleStyle(.switch)
                    .accessibilityLabel("Toggle 1")
                    .accessibilityIdentifier("toggle_1")
                    .accessibilityHint("Switch toggle 1 on or off")
                    .onChange(of: state.toggle1) { _, newValue in
                        print("[MCPTest] Toggle changed: toggle_1 = \(newValue)")
                    }

                Toggle("Toggle 2", isOn: $state.toggle2)
                    .toggleStyle(.switch)
                    .accessibilityLabel("Toggle 2")
                    .accessibilityIdentifier("toggle_2")
                    .accessibilityHint("Switch toggle 2 on or off")
                    .onChange(of: state.toggle2) { _, newValue in
                        print("[MCPTest] Toggle changed: toggle_2 = \(newValue)")
                    }
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                Toggle("Toggle 3", isOn: $state.toggle3)
                    .toggleStyle(.switch)
                    .accessibilityLabel("Toggle 3")
                    .accessibilityIdentifier("toggle_3")
                    .accessibilityHint("Switch toggle 3 on or off")
                    .onChange(of: state.toggle3) { _, newValue in
                        print("[MCPTest] Toggle changed: toggle_3 = \(newValue)")
                    }
                Spacer()
            }

            VStack(spacing: 4) {
                HStack {
                    Text("Slider:")
                        .font(.subheadline)
                    Text(String(format: "%.2f", state.sliderValue))
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("slider_value_label")
                    Spacer()
                }
                Slider(value: $state.sliderValue, in: 0...1)
                    .accessibilityLabel("Value slider")
                    .accessibilityIdentifier("slider")
                    .accessibilityHint("Adjust slider value between 0 and 1")
                    .accessibilityValue(String(format: "%.2f", state.sliderValue))
                    .onChange(of: state.sliderValue) { _, newValue in
                        print("[MCPTest] Slider value: \(String(format: "%.2f", newValue))")
                    }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("controls_section")
    }
}
