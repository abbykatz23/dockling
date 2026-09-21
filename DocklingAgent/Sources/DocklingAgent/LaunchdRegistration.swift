import Foundation

/// Registers the dispatcher as a per-user launchd agent, so it starts at
/// login and restarts if it ever crashes. A Swift-native equivalent of
/// install_launchd.sh, for FirstRunApp's double-click install path — that
/// script stays as-is for the from-source dev flow (`./install/install.sh`
/// + `./install/install_launchd.sh`), since it already works and there's no
/// reason to touch it; this exists so the shipped app's install button
/// doesn't need any script files bundled alongside it to do the same job.
enum LaunchdRegistration {
    private static let label = "com.dockling.dispatcher"
    private static let plistPath = ((NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/LaunchAgents") as NSString)
        .appendingPathComponent("\(label).plist")

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    static func install() throws {
        let home = NSHomeDirectory()
        let launchAgentsDir = (home as NSString).appendingPathComponent("Library/LaunchAgents")
        let logDir = (home as NSString).appendingPathComponent(".dockling/logs")
        try FileManager.default.createDirectory(atPath: launchAgentsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)

        // --dispatcher distinguishes a launchd-managed launch (the real,
        // headless, long-running background process) from a plain
        // double-click in Finder (which shows FirstRunApp's UI instead) —
        // both otherwise call the same binary with no other arguments.
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(Installer.installedBinaryPath)</string>
                <string>--dispatcher</string>
            </array>
            <key>EnvironmentVariables</key>
            <dict>
                <key>PATH</key>
                <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
            </dict>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(logDir)/dispatcher.log</string>
            <key>StandardErrorPath</key>
            <string>\(logDir)/dispatcher.log</string>
        </dict>
        </plist>
        """
        try plist.write(toFile: plistPath, atomically: true, encoding: .utf8)

        let uid = getuid()
        // Ignoring failure here on purpose, same as install_launchd.sh: on a
        // fresh install there's nothing to bootout yet, and that's not an
        // error.
        _ = try? run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])

        // launchd can take a moment to fully release the label after
        // bootout — bootstrapping immediately after occasionally fails with
        // a transient error. Retry rather than surfacing that to the user.
        var lastError: Error?
        for attempt in 1...5 {
            do {
                try run("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistPath])
                return
            } catch {
                lastError = error
                if attempt < 5 { Thread.sleep(forTimeInterval: 0.5) }
            }
        }
        throw lastError ?? NSError(domain: "Dockling", code: 1, userInfo: [NSLocalizedDescriptionKey: "launchctl bootstrap failed"])
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "Dockling", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: message?.isEmpty == false ? message! : "\(path) exited with status \(process.terminationStatus)",
            ])
        }
        return ""
    }
}
