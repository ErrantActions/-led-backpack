import SwiftUI

@MainActor
struct CreateView: View {
    @EnvironmentObject private var app: AppModel
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Make a GIF").font(.title2.bold())
                    Text("Choose a tool. Save locally.").font(.subheadline).foregroundStyle(.secondary)
                    NavigationLink {
                        Form { TextArtworkStudio() }.modernScene().navigationTitle("Text artwork")
                    } label: {
                        tool("Text to GIF", detail: "Type & animate", symbol: "textformat", color: Aurora.mint)
                    }.buttonStyle(.plain)
                    NavigationLink { PixelAnimationStudio() } label: {
                        tool("Pixel drawing", detail: "Draw & animate", symbol: "paintbrush.pointed", color: Aurora.rose)
                    }.buttonStyle(.plain)
                    Button { app.selectedTab = .library } label: {
                        tool("Images and video", detail: "Import with + in Library", symbol: "film", color: Aurora.lavender)
                    }.buttonStyle(.plain)
                    DisclosureGroup("More tools") {
                        NavigationLink { LEDAlphabetView() } label: {
                            FeatureRowLabel(title: "LED font inspector", symbol: "character.textbox")
                        }
                        #if DEBUG
                        if CommandLine.arguments.contains("--library-ui-fixture") {
                            NavigationLink("Action isolation fixture") { FeatureActionIsolationFixture() }
                            NavigationLink("Erase review fixture") { BackpackEraseReviewFixture() }
                        }
                        #endif
                    }
                }.padding(24).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
            }.modernScene().navigationTitle("Create").navigationBarTitleDisplayMode(.inline)
        }
    }
    private func tool(_ title: String, detail: String, symbol: String, color: Color) -> some View {
        FeatureRowLabel(title: title, symbol: symbol, subtitle: detail, tint: color)
            .padding(16).glassPanel(radius: 20)
    }
}
