import Foundation

/// The one place the product version lives. `Scripts/build-installer.sh` reads
/// `current` out of this file to stamp the installer, so the binary and the
/// package can never disagree about what version they are.
public enum TrolleyVersion {
    public static let current = "0.1.0"

    /// The Developer ID team every update is pinned to. A download that is not
    /// signed by this team is refused, whatever the server said.
    public static let teamIdentifier = "46LU76SNUA"

    public static let releaseFeed = URL(
        string: "https://api.github.com/repos/minsuRob/trolley/releases/latest"
    )!

    /// Stable asset name carried by every release -- the signed universal binary.
    /// Stable on purpose: the updater looks it up by name, not by guessing.
    public static let updateAssetName = "trolley-universal"

    /// GitHub rejects API requests without one.
    public static var userAgent: String { "trolley/\(current)" }
}
