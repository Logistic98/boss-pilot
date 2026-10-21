import Foundation

struct StableListSelectionContext: Equatable {
    let scopeID: UUID?
    let mode: String
    let visibleIDs: [String]
    let preferredID: String?
}

enum StableListSelectionPolicy {
    static func reconciledSelection(
        current: String?,
        preferred: String?,
        visibleIDs: [String]
    ) -> String? {
        let visibleIDSet = Set(visibleIDs)
        if let current, visibleIDSet.contains(current) {
            return current
        }
        if let preferred, visibleIDSet.contains(preferred) {
            return preferred
        }
        return visibleIDs.first
    }
}
