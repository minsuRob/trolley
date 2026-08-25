import Foundation

/// Where trolley is installed, which decides what an update has to replace.
///
/// Both shapes exist because the app bundle is what users drag to /Applications
/// while a bare binary is what a scripted install or a development build leaves
/// behind. Detection is a pure function of the executable path so it can be
/// tested without either being present.
public enum InstallLayout: Equatable {
    /// The whole bundle is replaced -- see `TrolleyVersion.updateAssetName`.
    case appBundle(URL)
    case bareBinary(URL)

    /// The path an update writes to.
    public var target: URL {
        switch self {
        case .appBundle(let url), .bareBinary(let url):
            return url
        }
    }

    public static func detect(executablePath: String) -> InstallLayout {
        let executable = URL(fileURLWithPath: executablePath)
        // .../trolley.app/Contents/MacOS/trolley -> .../trolley.app
        let bundle = executable
            .deletingLastPathComponent()   // MacOS
            .deletingLastPathComponent()   // Contents
            .deletingLastPathComponent()   // *.app
        if executable.deletingLastPathComponent().lastPathComponent == "MacOS",
           executable.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Contents",
           bundle.pathExtension == "app" {
            // Rebuilt from `path`: walking up leaves a directory URL with a
            // trailing slash, which compares unequal to the same path written
            // out plainly.
            return .appBundle(URL(fileURLWithPath: bundle.path))
        }
        return .bareBinary(executable)
    }
}
