import SwiftUI
import MapKit
import BackpackProtocol

@MainActor
struct ChatFixedPinPicker: View {
    @Environment(\.dismiss) private var dismiss
    let selected: (ChatPin) -> Void
    @State private var consent = false
    @State private var label = ""
    @State private var point: CLLocationCoordinate2D?
    @State private var camera = MapCameraPosition.automatic
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if consent {
                    MapReader { proxy in
                        Map(position: $camera) {
                            if let point { Annotation("Selected fixed place", coordinate: point) { Image(systemName: "mappin.circle.fill").font(.largeTitle).foregroundStyle(Aurora.mint) } }
                        }
                        .onTapGesture { position in point = proxy.convert(position, from: .local) }
                    }.clipShape(RoundedRectangle(cornerRadius: 24))
                    TextField("Name this fixed place", text: $label).textFieldStyle(.roundedBorder)
                    Button("Use this fixed place") {
                        do {
                            guard let point else { throw BackpackError.invalid("Deliberately tap a fixed place on the map first.") }
                            selected(try ChatPin(label: label, latitude: point.latitude, longitude: point.longitude).normalized())
                            dismiss()
                        } catch { failure = error.localizedDescription }
                    }.buttonStyle(.borderedProminent)
                } else {
                    Image(systemName: "mappin.and.ellipse").font(.system(size: 52)).foregroundStyle(Aurora.mint)
                    Text("Share a place, not your location").font(.title2.bold())
                    Text("Opening this page contacts Apple Maps. You manually place a fixed pin; no GPS, location tracking, directions or automatic sharing. The selected pin is sent only after the chat's Send action.")
                    Button("Allow Apple Maps on this page") { consent = true }.buttonStyle(.borderedProminent)
                }
                if let failure { Text(failure).foregroundStyle(.orange) }
            }.padding(20).modernScene().navigationTitle("Fixed place")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
@MainActor
struct ChatFixedPinCard: View {
    @Environment(\.openURL) private var openURL
    let pin: ChatPin
    @State private var confirming = false
    @State private var failure: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(pin.label, systemImage: "mappin.and.ellipse").font(.headline)
            Text("Fixed shared place. No map imagery is fetched automatically.").font(.caption)
            Button("Open Apple Maps...") { confirming = true }
            if let failure { Text(failure).foregroundStyle(.orange) }
        }
        .confirmationDialog("Disclose this fixed place to Apple Maps?", isPresented: $confirming) {
            Button("Open fixed place") {
                do {
                    let value = try pin.normalized()
                    var parts = URLComponents(string: "https://maps.apple.com")!
                    parts.queryItems = [URLQueryItem(name: "ll", value: "\(value.latitude),\(value.longitude)"),
                        URLQueryItem(name: "q", value: value.label)]
                    guard let url = parts.url else { throw BackpackError.invalid("Could not create the fixed place link.") }
                    openURL(url) { accepted in if !accepted { failure = "Apple Maps did not open the fixed place." } }
                } catch { failure = error.localizedDescription }
            }
        } message: { Text("This deliberately opens the fixed coordinates/label in Apple Maps. It does not request GPS or promise safe navigation.") }
    }
}
