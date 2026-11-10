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
            FeatureDetails("Details") { Text(details) }
        }
    }
}
