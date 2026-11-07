import SwiftUI

@MainActor
struct LibraryScopeControl: View {
    @Binding var selection: LibraryScope
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(spacing: 4) { choices }
            } else {
                HStack(spacing: 4) { choices }
            }
        }
        .padding(5).glassPanel(radius: 22)
        .accessibilityElement(children: .contain).accessibilityLabel("Library location")
    }
    @ViewBuilder private var choices: some View {
        ForEach(LibraryScope.allCases) { value in
            Button { selection = value } label: {
                Text(value.rawValue).font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(selection == value ? Aurora.mint : Color.secondary)
                    .background(selection == value ? Aurora.mint.opacity(0.1) : .clear,
                        in: RoundedRectangle(cornerRadius: 17))
                    .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(selection == value ? Aurora.mint.opacity(0.2) : .clear))
            }.buttonStyle(.plain)
                .accessibilityAddTraits(selection == value ? .isSelected : [])
        }
    }
}

@MainActor
struct LibraryMediaRow: View {
    enum Action { case preview, edit, phone, send, enqueue, share, cloud, export, organize, delete }
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: LocalLibrary
    let item: SavedMedia
    let action: (Action) -> Void
    @State private var directSend: BackpackSendRequest?
    @State private var editingTiming = false

    var body: some View {
        Button { action(.preview) } label: {
            GIFThumbnail(key: "local:\(item.id.uuidString)") { try library.data(item) }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 19))
        }.buttonStyle(.plain)
        .accessibilityLabel("Preview \(item.name)")
        .accessibilityHint("Opens artwork. Touch and hold for actions.")
        .contextMenu {
            Button("Edit a copy") { action(.edit) }
            Button("Display on phone") { action(.phone) }
            Button("Send & Play on backpack") { directSend = BackpackSendRequest(sources: [.local(item)]) }
            Button("Adjust GIF timing / loops") { editingTiming = true }
            Button("Add to send queue") { action(.enqueue) }
            Button("Back up to private cloud") { action(.cloud) }
            Button("Submit to community review") { action(.share) }
            Button(item.isFavorite ? "Remove favorite" : "Add favorite") {
                app.run { try library.organize(item.id, category: item.category, favorite: !item.isFavorite) }
            }
            Button("Organize") { action(.organize) }
            Button("Export GIF") { action(.export) }
            if let credit = item.attribution, let url = URL(string: credit.source), url.scheme == "https" {
                Link("Source and license", destination: url)
            }
            Button("Delete local copy", role: .destructive) { action(.delete) }
        }
        .sheet(item: $directSend) { request in BackpackDirectSendView(request: request) }
        .sheet(isPresented: $editingTiming) { GIFTimingEditorView(item: item) }
    }
}

@MainActor
struct MediaOrganizer: View {
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var link: BluetoothLink
    @Environment(\.dismiss) private var dismiss
    let item: SavedMedia
    @State private var category: String
    @State private var favorite: Bool
    @State private var failure: String?

    init(item: SavedMedia) {
        self.item = item
        _category = State(initialValue: item.category ?? "")
        _favorite = State(initialValue: item.isFavorite)
    }

    private var suggestions: [String] {
        Array(Set(GIFTopic.allCases.compactMap(\.libraryCategory) + library.mediaCategories))
            .filter { $0 != "Uncategorized" }.sorted()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(item.name) {
                    TextField("Category, or leave empty", text: $category)
                    Menu("Choose a category") {
                        Button("Uncategorized") { category = "" }
                        ForEach(suggestions, id: \.self) { value in Button(value) { category = value } }
                    }
                    Toggle("Favorite", isOn: $favorite)
                }
                Text("Create your own category names, up to 40 characters. Organization stays on this iPhone and is included in library backups.")
                    .font(.caption).foregroundStyle(.secondary)
                if let failure { Text(failure).foregroundStyle(.orange) }
                Button("Save organization") {
                    do {
                        try library.organize(item.id, category: category, favorite: favorite)
                        dismiss()
                    } catch {
                        failure = error.localizedDescription
                        link.note("Media organization failed: \(error.localizedDescription)")
                    }
                }.buttonStyle(.borderedProminent)
            }
            .modernScene().navigationTitle("Organize artwork")
            .toolbar { Button("Cancel") { dismiss() } }
        }
    }
}
