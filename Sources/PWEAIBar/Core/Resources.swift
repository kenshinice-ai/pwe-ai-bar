import Foundation

extension Bundle {
    /// The app's resources — fonts, string tables, the price list, the hook script — found where
    /// an assembled .app actually keeps them.
    ///
    /// SwiftPM's generated `Bundle.module` was never written for a shipped executable. It looks
    /// beside `Bundle.main.bundleURL` — the .app *root* — and then at the absolute path the bundle
    /// was built into. `build-app.sh` puts the bundle in `Contents/Resources`, where an app keeps
    /// its resources, so the first lookup fails on every machine and the second succeeds on exactly
    /// one: the Mac with the source checkout on it. Everywhere else the app called `fatalError`
    /// before the status item existed — it installed, it launched, and it showed nothing at all.
    /// 1.0.0 through 1.0.12 shipped that way, and the build machine could never notice, because
    /// the fallback path was always there.
    ///
    /// `.module` stays last so `swift run` and `swift test`, which have no .app, keep working.
    static let resources: Bundle = {
        let name = "PWEAIBar_PWEAIBar.bundle"
        for base in [Bundle.main.resourceURL, Bundle.main.bundleURL] {
            if let url = base?.appendingPathComponent(name), let found = Bundle(url: url) { return found }
        }
        return .module
    }()

    /// Whether `resources` came from inside the running .app — the only answer that matters for
    /// a copy on someone else's Mac, and the one `build-app.sh` refuses to ship without.
    static var resourcesAreInsideApp: Bool {
        resources.bundleURL.standardizedFileURL.path
            .hasPrefix(Bundle.main.bundleURL.standardizedFileURL.path + "/")
    }
}
