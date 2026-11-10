import SwiftUI

@MainActor
struct InteractionExplanation: View {
    let summary: String
    let details: String
    init(_ summary: String, details: String) {
        self.summary = summary
        self.details = details
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summary)
            FeatureDetails("Why this matters") {
                Text(details).foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
struct NativeFlowCancelFooter: View {
    var title = "Cancel"
    var busy = false
    let cancel: () -> Void
    var body: some View {
        Button(title, role: .cancel, action: cancel)
            .frame(maxWidth: .infinity, minHeight: 44)
            .disabled(busy)
            .padding(.horizontal, 20).padding(.vertical, 8)
            .background(Aurora.surface)
    }
}
