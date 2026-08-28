import Foundation

/// What the folder widget's numeric count badge shows, given a raw count.
///
/// Split out for the same reason as `WikiButtonCopy`: the hide/cap rule can be asserted
/// without a window server.
enum CountBadgeCopy {
    /// - Parameter count: nil or non-positive hides the badge -- a badge reading "0" is
    ///   not a thing anyone expects to see, unlike the button's title, which keeps its
    ///   zero. Anything past 99 collapses to "+99" rather than widening the circle.
    static func text(for count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        return count > 99 ? "+99" : "\(count)"
    }
}
