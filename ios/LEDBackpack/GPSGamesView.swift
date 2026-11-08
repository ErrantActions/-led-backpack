import SwiftUI

@MainActor
struct GPSGamesView: View {
    @EnvironmentObject private var community: CommunityController
    @State private var failure: String?
    var body: some View {
        List {
            Section {
                Text("Choose your next game").font(.title2.bold())
                Text("Stationary, noncontact play. You choose when GPS or Bluetooth starts.").font(.subheadline).foregroundStyle(.secondary)
            }
            Section("Explore") {
                NavigationLink { SoloScenesView() } label: {
                    FeatureCardLabel(title: "My adventures", subtitle: "Private places & milestones", symbol: "location.circle", tint: Aurora.lavender)
                }.accessibilityLabel("My local places / adventure / distance milestones")
                if community.signedIn && community.config?.eventsEnabled == true {
                    NavigationLink { CommunityEventsView() } label: {
                        FeatureCardLabel(title: "Event hunts", subtitle: "Checkpoints & cooperative goals", symbol: "flag.checkered")
                    }.accessibilityLabel("Event GPS hunts / ride checkpoints")
                } else {
                    NavigationLink { CommunityAccountView() } label: {
                        FeatureRowLabel(title: "Event hunts", symbol: "flag.checkered", subtitle: "Sign in to check availability")
                    }
                }
            }
            Section("Play nearby") {
                NavigationLink { PhoneSwapGameView() } label: {
                    FeatureCardLabel(title: "GIF swap", subtitle: "Trade what's playing. Both players opt in.", symbol: "arrow.triangle.2.circlepath")
                }.accessibilityLabel("Automatic PHONE GIF exchange game")
                NavigationLink { LocalPairedGameView() } label: {
                    FeatureCardLabel(title: "Pair & play", subtitle: "Offline calm colors", symbol: "qrcode", tint: Aurora.rose)
                }.accessibilityLabel("Locally paired calm colors / optional NI")
                if community.signedIn && community.config?.socialEnabled == true {
                    NavigationLink { CommunitySocialView() } label: {
                        FeatureRowLabel(title: "Friend play", symbol: "person.2", subtitle: "Greetings, duet & pass")
                    }.accessibilityLabel("Accepted-friend greetings / duet / pass")
                }
            }
            Section {
                FeatureDetails("Privacy & device support") {
                    Text("GPS gives broad fixed-target hints, not precise peer tagging. Bluetooth needs observed tokens and authenticated consent; signal strength is not reliable meters.")
                    Text("Optional NI measures supported phones, not backpacks. Uncertain ranging needs an explicit manual choice.")
                    Text("Background or permission loss stops play. Automatic phone changes retain your original; unknown backpack originals cannot be restored automatically.")
                    Text("Device and service availability are checked at use. Software tests are not physical GPS/Bluetooth/UWB proof.")
                    Button("Refresh availability") {
                        Task { do { try await community.loadConfig(); failure = nil } catch { failure = error.localizedDescription } }
                    }
                }
                if let failure { Text(failure).foregroundStyle(.orange) }
            }
        }.navigationTitle("GPS & nearby games").modernScene().buttonStyle(.plain)
    }
}
