import SwiftUI

@MainActor
struct AppleLinkAccountView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var busy = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Connect Apple to this account") {
                    Text("Verify your current password, then choose your Apple account. Matching email addresses are never silently merged.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    SecureField("Current account password", text: $password)
                    if community.config?.appleSignInEnabled == true {
                        AppleSignInControl(purpose: .link, password: password, enabled: !password.isEmpty,
                            busyChanged: { busy = $0 }, completed: { password = ""; dismiss() })
                    } else { Text("Apple linking is not enabled on this server.").foregroundStyle(.orange) }
                }.disabled(busy)
            }
            .modernScene().navigationTitle("Link Apple account")
            .toolbar { Button("Cancel") { password = ""; dismiss() }.disabled(busy) }
            .safeAreaInset(edge: .bottom) {
                Button("Cancel", role: .cancel) { password = ""; dismiss() }
                    .frame(maxWidth: .infinity).padding().background(.bar).disabled(busy)
            }
            .interactiveDismissDisabled(busy)
            .onDisappear { password = "" }
        }
    }
}
