import Foundation

/// Which folder under Application Support this copy of baia owns.
///
/// Two copies are meant to run at once: the one in `/Applications` that gets used
/// and the one `make run` builds to test the next change. They must not share
/// `session.json`, `control.sock` or `recent-projects.tsv`, because the second
/// instance to bind the socket runs with no channel at all and the second to write
/// the session takes the first one's windows with it.
///
/// The name comes from `BAIASupportDirectory` in the app's own Info.plist, set per
/// configuration in `project.yml`: `baia` for Release, `baia-dev` for Debug. Read
/// from the bundle rather than compiled in with `#if DEBUG`, because the value has
/// to be the same one the build settings produced, and a preprocessor branch is a
/// second place for that to be decided.
///
/// Settings are deliberately not covered by this. `~/.config/baia/config.json` is
/// shared, because a test build reading settings that are not the ones in daily
/// use is testing the wrong thing.
enum SupportDirectory {
    /// The fallback is the installed copy's name rather than a crash or a unique
    /// one. A bundle with no key is an older build or an unusual packaging, and
    /// putting it where it has always been is the behaviour that build had.
    static let name: String = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "BAIASupportDirectory") as? String,
              !value.isEmpty,
              // An unexpanded build setting means the Info.plist was processed
              // without the setting defined. Treating the literal as a directory
              // name would make a folder called `$(BAIA_SUPPORT_DIRECTORY)`.
              !value.hasPrefix("$(")
        else { return "baia" }
        return value
    }()
}
