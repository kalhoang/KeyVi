// SPDX-License-Identifier: MPL-2.0

extension StringProtocol {
    /// Character-wise substring test. Without Foundation, `contains(_:)` with a string argument resolves to the
    /// `_StringProcessing` overload, which needs macOS 13; the app's floor is macOS 12 (PLT-R106).
    func containsText(_ needle: some StringProtocol) -> Bool {
        guard !needle.isEmpty else { return true }
        var index = startIndex
        while index != endIndex {
            if self[index...].starts(with: needle) { return true }
            index = self.index(after: index)
        }
        return false
    }
}
