import SwiftUI
import BackpackProtocol

enum EventCreationReadiness {
    static func issue(input: CatalogEventInput?, startChosen: Bool, endChosen: Bool,
        venueConfirmed: Bool, existingVisibility: String? = nil) -> String? {
        guard startChosen && endChosen else { return "Choose and confirm a start and end time." }
        guard let input else { return "Choose a venue." }
        do { try input.validate() }
        catch { return error.localizedDescription }
        guard venueConfirmed else { return "Confirm the venue." }
        if input.visibility == "unlisted", existingVisibility != "unlisted", input.unlistedLinkConsent != true {
            return "Agree to link-readable details and venue." }
        return nil
    }
}
