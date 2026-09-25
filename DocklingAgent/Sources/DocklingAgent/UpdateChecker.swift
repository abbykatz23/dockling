import Foundation

/// Checks GitHub for a newer release than the one currently running, and if
/// there is one, shows a notification pointing at it — "notify and link,"
/// not a silent background install (that's Sparkle territory, a much
/// bigger dependency this app doesn't have). Lives on the dispatcher, the
/// one long-lived process, so this doesn't repeat once per session/subagent
/// the way something on SessionChild would.
enum UpdateChecker {
    static let repo = "abbykatz23/dockling"
    /// The stable, always-latest release asset name (see notarize_release.sh)
    /// — never versioned in its filename, so this URL always resolves to
    /// whatever the newest release is.
    static let latestDMGURL = URL(string: "https://github.com/\(repo)/releases/latest/download/Dockling.dmg")!
    private static let checkInterval: TimeInterval = 24 * 60 * 60
    private static let urlSession = URLSession(configuration: .ephemeral)

    /// docklingVersion (GeneratedVersion.swift) — compiled directly into
    /// the binary by tools/notarize_release.sh for a real release build.
    /// Not read from Info.plist: the dispatcher that's actually running
    /// long-term is a bare copy at ~/.dockling/bin/DocklingAgent (see
    /// install.sh / LaunchdRegistration.swift), never launched from inside
    /// the .app bundle, so it has no Info.plist to read at runtime even
    /// though one exists in Dockling.app's Contents/. A from-source dev
    /// build has this at its default of nil, which is exactly when this
    /// (and the settings window's own Update button) should quietly stay
    /// disabled rather than offering an "update" for a build that was never
    /// versioned in the first place.
    static var currentVersion: String? { docklingVersion }

    static func startPeriodicCheck() {
        guard currentVersion != nil else { return }
        checkOnce()
    }

    private static func checkOnce() {
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + checkInterval) { checkOnce() }
        }
        guard let currentVersion else { return }

        fetchLatestVersion { result in
            guard case .success(let latestVersion) = result, latestVersion > currentVersion else { return }
            fputs("[dockling] update available: \(currentVersion) -> \(latestVersion)\n", stderr)
            notifyUpdateAvailable(version: latestVersion)
        }
    }

    /// Shared by the periodic background check above and the settings
    /// window's "Check for Updates" button — both just want "what's the
    /// newest tag_name on GitHub," they differ only in what they do with it.
    static func fetchLatestVersion(completion: @escaping (Result<String, Error>) -> Void) {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        urlSession.dataTask(with: request) { data, _, error in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                completion(.failure(error ?? UpdateCheckError(description: "malformed response from GitHub")))
                return
            }
            // Tags are "v" + the exact same timestamp string baked into
            // docklingVersion (see notarize_release.sh) — plain string
            // comparison sorts these correctly since the format is a
            // fixed-width, zero-padded Y.m.d.HM, same reasoning as an
            // ISO-8601 timestamp sorting correctly as text.
            let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            completion(.success(latestVersion))
        }.resume()
    }

    // LocalizedError too — see UpdateInstaller.UpdateError's doc comment for
    // why CustomStringConvertible alone isn't enough for `.localizedDescription`.
    struct UpdateCheckError: Error, CustomStringConvertible, LocalizedError {
        let description: String
        var errorDescription: String? { description }
    }

    /// Shells out to osascript rather than using UNUserNotificationCenter
    /// directly — confirmed by actually hitting it, that framework hard
    /// crashes the whole process ("bundleProxyForCurrentProcess is nil")
    /// when called from a bare executable with no real running .app
    /// context, which is exactly what the installed dispatcher is (see
    /// docklingVersion's comment above). osascript's notification isn't
    /// clickable through to a URL the way a real app's own notification
    /// can be, so the download link goes in the message text instead of
    /// behind a click action.
    private static func notifyUpdateAvailable(version: String) {
        let title = "Dockling \(version) is available"
        let message = "Download the latest at github.com/\(repo)/releases/latest"
        let script = "display notification \"\(escapeForAppleScript(message))\" with title \"\(escapeForAppleScript(title))\""

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        do {
            try process.run()
        } catch {
            fputs("[dockling] could not show update notification: \(error.localizedDescription)\n", stderr)
        }
    }

    /// `version` is network-supplied (GitHub's tag_name), and gets
    /// interpolated straight into a shelled-out AppleScript string literal
    /// — escaping its quotes/backslashes here is what keeps a stray
    /// character in a tag name from breaking out of that literal, not just
    /// defensive-for-its-own-sake.
    private static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
