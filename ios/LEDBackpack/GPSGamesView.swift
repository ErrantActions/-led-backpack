import SwiftUI

@MainActor
struct GPSGamesView: View {
    @EnvironmentObject private var community: CommunityController
    @State private var failure: String?
    var body: some View {
        List {
            Section("GPS adventures and checkpoint games") {
                NavigationLink("My local places / adventure / distance milestones") { SoloScenesView() }
                Text("Account-free, foreground GPS and private local progress. No route/encounter history or automatic public check-ins. Start sensing and any PHONE automation separately.").font(.caption)
                if community.signedIn && community.config?.eventsEnabled == true {
                    NavigationLink("Event GPS hunts / ride checkpoints") { CommunityEventsView() }
                    Text("Open an event → Play GPS checkpoint hunt, or Foreground local checkpoint hint for route progress. Private collection and progress sharing are separate explicit choices.").font(.caption)
                } else {
                    NavigationLink("Sign in / check event availability") { CommunityAccountView() }
                }
            }
            Section("Nearby games — separate Bluetooth consent") {
                NavigationLink("Automatic PHONE GIF exchange game") { PhoneSwapGameView() }
                NavigationLink("Locally paired calm colors / optional NI") { LocalPairedGameView() }
                if community.signedIn && community.config?.socialEnabled == true {
                    NavigationLink("Accepted-friend greetings / duet / pass") { CommunitySocialView() }
                }
                Text("GPS cannot precisely tag another player. BLE needs an actually observed short-lived token plus authenticated key/session consent. RSSI is rough, not reliable meters. NI measures supported phones, not backpacks; uncertain/unsupported needs an explicit manual choice.").font(.caption)
            }
            Section("Safety and real availability") {
                Text("Stationary/noncontact play only; no chasing or traffic interaction. Stop/background/account/OS permission loss stops local work; no silent restart. PHONE originals must be durably saved before automatic replacement; hardware originals remain unknown.").font(.caption)
                Text("Source and simulator tests are not physical GPS/BLE/UWB proof. Event/player/provider capabilities remain governed by the current service and device permissions.").font(.caption)
                Button("Refresh actual backend capabilities") {
                    Task { do { try await community.loadConfig(); failure = nil } catch { failure = error.localizedDescription } }
                }
                if let failure { Text(failure).foregroundStyle(.orange) }
            }
        }.navigationTitle("GPS & nearby games").modernScene()
    }
}
