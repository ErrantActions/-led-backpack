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
    enum Action { case preview, edit, send, share, export, organize, delete }
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: LocalLibrary
    let item: SavedMedia
    var cloudStatus: String? = nil
    let action: (Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button { action(.preview) } label: {
                GIFThumbnail(key: "local:\(item.id.uuidString)") { try library.data(item) }
                    .frame(maxWidth: .infinity).frame(height: 160)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 19))
                    .clipShape(RoundedRectangle(cornerRadius: 19))
            }.buttonStyle(.plain).accessibilityLabel("Preview \(item.name)")
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.name).font(.headline).lineLimit(2)
                    Label(item.categoryName, systemImage: "folder").font(.caption).foregroundStyle(.secondary)
                    Label(cloudStatus == nil ? "On this iPhone" : "On iPhone + Cloud", systemImage: cloudStatus == nil ? "iphone" : "icloud.fill")
                        .font(.caption2).foregroundStyle(cloudStatus == nil ? Color.secondary : Color.cyan)
                    if let credit = item.attribution {
                        Text(credit.author.isEmpty ? (credit.license == "unreviewed" ? "Rights not reviewed" : credit.license)
                            : "\(credit.author) / \(credit.license)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    app.run { try library.organize(item.id, category: item.category, favorite: !item.isFavorite) }
                } label: {
                    Image(systemName: item.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(item.isFavorite ? Color.yellow : Color.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                }.buttonStyle(.plain)
                    .accessibilityLabel(item.isFavorite ? "Remove favorite" : "Add favorite")
            }
            HStack {
                Button("Preview") { action(.preview) }
                Spacer()
                Menu("Actions", systemImage: "ellipsis.circle") {
                    Button("Edit a copy") { action(.edit) }
                    Button("Send to backpack") { action(.send) }
                    Button(cloudStatus == nil ? "Save a private cloud copy" : "Cloud copy options") { action(.share) }
                    Button("Organize") { action(.organize) }
                    Button("Export GIF") { action(.export) }
                    Button("Delete local copy", role: .destructive) { action(.delete) }
                }
            }.font(.subheadline.weight(.semibold)).buttonStyle(.borderless)
            if let credit = item.attribution, let url = URL(string: credit.source), url.scheme == "https" {
                Link("Source and license", destination: url).font(.caption)
            }
        }.padding(16).glassPanel()
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
