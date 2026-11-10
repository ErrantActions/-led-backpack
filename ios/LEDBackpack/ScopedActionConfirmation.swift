import Foundation

/// Approval belongs to one reviewed scope and is consumed before attempting an action.
struct ScopedActionConfirmation<Scope: Equatable> {
    private var approvedScope: Scope?

    func isConfirmed(for scope: Scope) -> Bool { approvedScope == scope }
    mutating func setConfirmed(_ confirmed: Bool, for scope: Scope) {
        approvedScope = confirmed ? scope : nil
    }
    mutating func reset() { approvedScope = nil }
    mutating func consume(for scope: Scope) -> Bool {
        let authorized = isConfirmed(for: scope)
        reset()
        return authorized
    }
}
