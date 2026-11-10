import SwiftUI

@MainActor
struct CreateView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dynamicTypeSize) private var typeSize
    private var columns: [GridItem] {
        typeSize.isAccessibilitySize ?
            [GridItem(.flexible(), alignment: .top)] :
            [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .top)]
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AuroraHeading(eyebrow: "Your next idea", title: "Make something", accent: "expressive.")
                        .auroraEntrance()
                    Text("Choose a tool. Save locally. No community account needed.")
                        .font(.subheadline).foregroundStyle(Aurora.supporting)
                    AuroraHeroArtwork(kind: .bloom)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        NavigationLink {
                            Form { TextArtworkStudio() }.modernScene().navigationTitle("Text artwork")
                        } label: {
                            tool("Text to GIF", detail: "Type & animate", symbol: "textformat", color: Aurora.mint)
                        }
                        NavigationLink { PixelAnimationStudio() } label: {
                            tool("Pixel drawing", detail: "Draw & animate", symbol: "paintbrush.pointed", color: Aurora.rose)
                        }
                        Button { app.selectedTab = .library } label: {
                            tool("Images and video", detail: "Import with + in Library", symbol: "film", color: Aurora.lavender)
                        }
                    }.buttonStyle(AuroraTileButton())
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
                }.padding(20).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
            }.modernScene().navigationTitle("Create").navigationBarTitleDisplayMode(.inline)
        }
    }
    private func tool(_ title: String, detail: String, symbol: String, color: Color) -> some View {
        FeatureCardLabel(title: title, subtitle: detail, symbol: symbol, tint: color)
    }
}
