import SwiftUI
import BackpackProtocol

@MainActor
struct CommunityFavoritesView: View {
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var community: CommunityController
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var selection = CommunitySelection()
    @State private var failure: String?
    @State private var showQueue = false
    @State private var directSend: BackpackSendRequest?
    private var favorites: [SavedMedia] { library.state.media.filter(\.isFavorite) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if favorites.isEmpty { ContentUnavailableView("No favorite GIFs yet", systemImage: "heart", description: Text("Select GIFs in Community and tap Favorite to keep local copies here.")) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                    ForEach(favorites) { item in
                        let selected = selection.ids.contains(item.id)
                        let animate = community.user?.mediaPreferences?.permitsAnimation(reducedMotion: reducedMotion, manual: false) ?? !reducedMotion
                        Button {
                            do { try selection.toggle(item.id); failure = nil } catch { failure = error.localizedDescription }
                        } label: {
                            GIFThumbnail(key: "\(item.previewKey):\(animate)", cache: false, animationAllowed: animate) {
                                let url = try library.phoneOriginalURL(item)
                                return try await Task.detached { try PhoneDisplayFileReader.read(url) }.value
                            }.aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay { RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.cyan : .clear, lineWidth: 3) }
                                .overlay(alignment: .topTrailing) {
                                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .cyan).font(.title2).padding(8) }
                                }
                        }.buttonStyle(.plain).accessibilityLabel("Select favorite GIF")
                            .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                if let failure { Text(failure).foregroundStyle(.orange) }
            }.padding(20)
        }.navigationTitle("Favorites").modernScene()
            .safeAreaInset(edge: .bottom) {
                if !selection.ids.isEmpty {
                    VStack {
                        Text("\(selection.ids.count) selected")
                        HStack {
                            Button("Send to LED") {
                                do {
                                    guard selection.ids.allSatisfy({ id in favorites.contains { $0.id == id } }) else { throw BackpackError.invalid("Favorites changed; select again.") }
                                    let chosen = try selection.ids.map { id -> SavedMedia in
                                        guard let item = favorites.first(where: { $0.id == id }) else { throw BackpackError.invalid("Favorites changed; select again.") }
                                        return item
                                    }
                                    directSend = BackpackSendRequest(sources: chosen.map { .local($0) }); failure = nil
                                } catch { failure = error.localizedDescription }
                            }
                            Button("Remove favorite", role: .destructive) {
                                do {
                                    for id in selection.ids {
                                        guard let item = favorites.first(where: { $0.id == id }) else { throw BackpackError.invalid("A favorite was removed. Reload before changing the rest.") }
                                        try library.organize(id, category: item.category, favorite: false)
                                    }
                                    selection.clear(); failure = nil
                                } catch { failure = error.localizedDescription }
                            }
                            Button("Clear") { selection.clear() }
                        }.buttonStyle(.bordered)
                        Text("Local originals and credits stay intact. Send opens timing and automatic empty-slot preparation; removing a favorite does not delete artwork.").font(.caption)
                    }.padding(16).background(.regularMaterial)
                }
            }
            .navigationDestination(isPresented: $showQueue) { BatchTransferView() }
            .sheet(item: $directSend) { request in BackpackDirectSendView(request: request) }
            .onChange(of: favorites.map(\.id)) { _, ids in
                for id in selection.ids where !ids.contains(id) { selection.remove(id) }
            }
    }
}
