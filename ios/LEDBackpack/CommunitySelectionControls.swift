import SwiftUI

@MainActor
struct CommunitySelectionControls: View {
    @ObservedObject var store: CommunitySelectionStore
    let favorite, send, openQueue: () -> Void
    var body: some View {
        if !store.selection.ids.isEmpty || store.message != nil || store.failure != nil || store.queueReady {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(store.selection.ids.count) selected").font(.headline)
                    Spacer()
                    Button("Clear") { store.clear() }.disabled(store.busy)
                }
                HStack {
                    Button(action: favorite) { Label("Favorite", systemImage: "heart.fill") }
                        .accessibilityIdentifier("community-favorite-selection")
                    Button(action: send) { Label("Send to LED", systemImage: "backpack") }
                        .accessibilityIdentifier("community-send-selection")
                }.buttonStyle(.borderedProminent).disabled(store.busy || store.selection.ids.isEmpty)
                if store.busy { ProgressView(); Button("Cancel remaining") { store.cancel() } }
                if let message = store.message { Text(message).font(.caption) }
                if let failure = store.failure { Text(failure).font(.caption).foregroundStyle(.orange) }
                if store.queueReady { Button("Open Send queue / review LED slots", action: openQueue).disabled(store.busy) }
                Text("Favorite saves a local copy in Library → Favorites. Send saves and queues originals; no backpack write until explicit slot review/confirmation.").font(.caption2)
            }.padding(16).background(.regularMaterial)
        }
    }
}
