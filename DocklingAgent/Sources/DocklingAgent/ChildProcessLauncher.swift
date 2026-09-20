import Foundation

/// Spawns a `DocklingAgent --session ... --port ... --color ... --name ...`
/// child process, through a synthesized per-name `.app` bundle so its Dock
/// hover tooltip shows something real rather than the raw binary name.
/// Shared by the Dispatcher (spawning one child per Claude Code session) and
/// by a session child itself (spawning a "baby" duck per subagent, and
/// relaunching its own replacement — see SessionChild.swift's ordering
/// trick), since both need the exact same launch mechanism.
enum ChildProcessLauncher {
    @discardableResult
    static func spawn(session: String, port: UInt16, color: String, name: String, agentID: String? = nil, parentPort: UInt16? = nil) -> pid_t? {
        guard let launchedPath = Bundle.main.executablePath else {
            fputs("[dockling] could not resolve own executable path to spawn a child\n", stderr)
            return nil
        }
        // Bundle.main.executablePath reflects however *this* process was
        // launched — for a session child (or a baby, or mama relaunching
        // herself), that's a per-name symlinked bundle path, not the real
        // binary. Resolving symlinks here is what keeps every child pointing
        // at the one real binary instead of, in mama's relaunch case,
        // accidentally symlinking her own bundle to itself.
        let executablePath = (launchedPath as NSString).resolvingSymlinksInPath
        let launchPath = appBundleExecutable(realPath: executablePath, displayName: name)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        var arguments = ["--session", session, "--port", "\(port)", "--color", color, "--name", name]
        if let agentID {
            arguments += ["--agent", agentID]
        }
        if let parentPort {
            arguments += ["--parent-port", "\(parentPort)"]
        }
        process.arguments = arguments

        do {
            try process.run()
        } catch {
            fputs("[dockling] failed to spawn child for session \(session): \(error)\n", stderr)
            return nil
        }
        return process.processIdentifier
    }

    /// Dock/Launch Services identity (the hover tooltip, in particular) is
    /// driven by real bundle metadata (Info.plist's CFBundleName), read at
    /// launch — renaming the process after the fact (via a symlink, or via
    /// ProcessInfo.processName) doesn't reach it; both were tried and
    /// confirmed not to change the tooltip. So this synthesizes a minimal,
    /// throwaway .app bundle per display name, with the executable inside it
    /// just a symlink to the real binary, and launches that instead.
    private static func appBundleExecutable(realPath: String, displayName: String) -> String {
        let bundlesDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("dockling-agent-bundles")
        let bundlePath = (bundlesDir as NSString).appendingPathComponent("\(displayName).app")
        let contentsDir = (bundlePath as NSString).appendingPathComponent("Contents")
        let macOSDir = (contentsDir as NSString).appendingPathComponent("MacOS")
        let executablePath = (macOSDir as NSString).appendingPathComponent("DocklingAgent")
        let infoPlistPath = (contentsDir as NSString).appendingPathComponent("Info.plist")

        let fileManager = FileManager.default
        try? fileManager.createDirectory(atPath: macOSDir, withIntermediateDirectories: true)

        if let existingTarget = try? fileManager.destinationOfSymbolicLink(atPath: executablePath), existingTarget != realPath {
            try? fileManager.removeItem(atPath: executablePath) // stale, e.g. from a rebuilt binary
        }
        if !fileManager.fileExists(atPath: executablePath) {
            do {
                try fileManager.createSymbolicLink(atPath: executablePath, withDestinationPath: realPath)
            } catch {
                fputs("[dockling] could not create app bundle for \(displayName), falling back to real path: \(error)\n", stderr)
                return realPath
            }
        }

        let bundleID = "com.dockling.session." + displayName.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { $0.append($1) }
        let info: [String: Any] = [
            "CFBundleName": displayName,
            "CFBundleDisplayName": displayName,
            "CFBundleExecutable": "DocklingAgent",
            "CFBundleIdentifier": bundleID,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
        ]
        if let plistData = try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0) {
            try? plistData.write(to: URL(fileURLWithPath: infoPlistPath))
        }

        return executablePath
    }
}
