#if DEBUG
import SwiftUI
import BackpackProtocol

@MainActor
struct BackpackEraseReviewFixture: View {
    @State private var plan: BackpackErasePlan?
    @State private var failure: String?
    var body: some View {
        Group {
            if let plan { EraseBackpackView(plan: plan) }
            else if let failure { Text(failure).foregroundStyle(.orange) }
            else { ProgressView() }
        }
        .task {
            do {
                var bytes: [UInt8] = []
                for id in 0..<60 {
                    bytes += [UInt8(id)] + Array(repeating: UInt8(id == 2 ? 2 : 0), count: 20)
                }
                guard case .slots(let records) = try Wire.reply([0x81, 0x83, 0x35] + Wire.length(bytes.count) + bytes) else {
                    throw BackpackError.invalid("Erase review fixture could not construct slot metadata.")
                }
                plan = try BackpackErasePlan(deviceID: UUID(), serial: "UI fixture", records: records)
            } catch { failure = error.localizedDescription }
        }
    }
}
#endif
