import SwiftUI

@MainActor
struct CreateView: View {
    @EnvironmentObject private var app: AppModel
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AuroraHeading(eyebrow: "The creative studio", title: "Make something", accent: "worth looking at.")
                    Text("Pick a tool. Your artwork stays local until you choose to upload.")
                        .foregroundStyle(.secondary)
                    NavigationLink {
                        Form { TextArtworkStudio() }.modernScene().navigationTitle("Text artwork")
                    } label: {
                        tool("Text to GIF", detail: "Crisp letters, exact LED sizing and scrolling.", symbol: "textformat", color: Aurora.mint)
                    }.buttonStyle(.plain)
                    NavigationLink { StudioView() } label: {
                        tool("Pixel drawing", detail: "Draw, erase and save your own style.", symbol: "paintbrush.pointed", color: Aurora.rose)
                    }.buttonStyle(.plain)
                    Button { app.selectedTab = .library } label: {
                        tool("Images and video", detail: "Open Library, then + to import or convert.", symbol: "film", color: Aurora.lavender)
                    }.buttonStyle(.plain)
                    NavigationLink { LEDAlphabetView() } label: {
                        tool("LED font inspector", detail: "Every letter. Every whole-pixel size.", symbol: "character.textbox", color: .mint)
                    }.buttonStyle(.plain)
                }.padding(24).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
            }.modernScene().navigationTitle("Create").navigationBarTitleDisplayMode(.inline)
        }
    }
    private func tool(_ title: String, detail: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 18) {
            Image(systemName: symbol).font(.title2).foregroundStyle(color)
                .frame(width: 52, height: 60)
                .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.secondary)
        }.padding(20).glassPanel()
    }
}
