import SwiftUI

@MainActor
struct LibraryMediaRow: View {
    enum Action { case preview, edit, send, export, organize, delete }
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: LocalLibrary
    let item: SavedMedia
    let action: (Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Button { action(.preview) } label: {
                    GIFThumbnail(key: "local:\(item.id.uuidString)") { try library.data(item) }
                        .frame(width: 92, height: 92).clipShape(RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.borderless).accessibilityLabel("Preview \(item.name)")
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.name).font(.headline)
                    Label(item.categoryName, systemImage: "folder").font(.caption).foregroundStyle(.secondary)
                    if let credit = item.attribution {
                        Text("\(credit.author) / \(credit.license)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    app.run { try library.organize(item.id, category: item.category, favorite: !item.isFavorite) }
                } label: {
                    Image(systemName: item.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(item.isFavorite ? Color.yellow : Color.secondary)
                }.buttonStyle(.borderless)
                    .accessibilityLabel(item.isFavorite ? "Remove favorite" : "Add favorite")
            }
            HStack {
                Button("Preview") { action(.preview) }
                Spacer()
                Menu("Actions", systemImage: "ellipsis.circle") {
                    Button("Edit a copy") { action(.edit) }
                    Button("Send to backpack") { action(.send) }
                    Button("Organize") { action(.organize) }
                    Button("Export GIF") { action(.export) }
                    Button("Delete local copy", role: .destructive) { action(.delete) }
                }
            }.buttonStyle(.borderless)
            if let credit = item.attribution, let url = URL(string: credit.source), url.scheme == "https" {
                Link("Source and license", destination: url).font(.caption)
            }
        }.padding(.vertical, 4)
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
