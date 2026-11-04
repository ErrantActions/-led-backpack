import SwiftUI

@MainActor
struct CreateView: View {
    @EnvironmentObject private var app: AppModel
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Make something\nworth looking at.")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold)).tracking(-1)
                    Text("Pick a tool. Your artwork stays local until you choose to upload.")
                        .foregroundStyle(.secondary)
                    NavigationLink {
                        Form { TextArtworkStudio() }.modernScene().navigationTitle("Text artwork")
                    } label: {
                        tool("Text to GIF", detail: "Crisp letters, exact LED sizing and scrolling.", symbol: "textformat", color: .cyan)
                    }.buttonStyle(.plain)
                    NavigationLink { StudioView() } label: {
                        tool("Pixel drawing", detail: "Draw, erase and save your own style.", symbol: "paintbrush.pointed", color: .pink)
                    }.buttonStyle(.plain)
                    Button { app.selectedTab = .library } label: {
                        tool("Images and video", detail: "Open Library, then + to import or convert.", symbol: "film", color: .purple)
                    }.buttonStyle(.plain)
                    NavigationLink { LEDAlphabetView() } label: {
                        tool("LED font inspector", detail: "Every letter. Every whole-pixel size.", symbol: "character.textbox", color: .mint)
                    }.buttonStyle(.plain)
                }.padding(24)
            }.modernScene().navigationTitle("Create")
        }
    }
    private func tool(_ title: String, detail: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 18) {
            Image(systemName: symbol).font(.title).foregroundStyle(color).frame(width: 42)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.secondary)
        }.padding(22).glassPanel()
    }
}
