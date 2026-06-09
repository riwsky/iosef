import SwiftUI

struct ContentView: View {
    @State private var state = TapState()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                StatusBar(state: state)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                Divider()

                GridSection(state: state)
                    .padding(6)
                    .frame(maxHeight: .infinity)

                Divider()

                SwipeTestSection(state: state)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(height: 80)

                Divider()

                // Pushes a NavigationStack detail screen whose nav-bar (Back button,
                // title, toolbar "More" item) regressed the tree-walk in issue #2.
                NavigationLink(value: "item") {
                    Text("Open detail")
                }
                .accessibilityIdentifier("open_detail")
                .padding(.vertical, 6)

                Divider()

                ControlsSection(state: state)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .accessibilityIdentifier("root_view")
            .navigationDestination(for: String.self) { _ in
                DetailView()
            }
        }
    }
}

/// A pushed detail screen exercising the navigation-bar elements (Back / title /
/// toolbar item) that `describe` tree-walk skipped before the issue #2 fix.
struct DetailView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Detail content")
                .accessibilityIdentifier("detail_content")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Item")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("More") { }
                    .accessibilityLabel("More")
                    .accessibilityIdentifier("itemDetailMoreMenu")
            }
        }
    }
}
