import Foundation

/// Backs the settings window's "Update" button: downloads the latest signed,
/// notarized release DMG, verifies it, and installs it in place — the same
/// end state as the manual "download → drag to Applications → open → click
/// Reinstall" flow, minus every manual step and without the first-run
/// welcome dialog (that only ever shows when LaunchdRegistration.isInstalled
/// is false, which stays true the whole way through this).
enum UpdateInstaller {
    // Also LocalizedError, not just CustomStringConvertible: plain Error's
    // own `localizedDescription` bridges to NSError and ignores
    // CustomStringConvertible entirely, which would otherwise surface a
    // generic "The operation couldn't be completed" in the settings
    // window's alert instead of this message.
    struct UpdateError: Error, CustomStringConvertible, LocalizedError {
        let description: String
        var errorDescription: String? { description }
    }

    /// Runs entirely off the main thread — network, disk I/O, and shelling
    /// out to hdiutil/spctl/codesign are all slow enough to matter — and
    /// always calls back on the main queue. `progress` fires with a short
    /// human-readable status the settings window can show next to its
    /// button. On success, the newly installed app's own bundle path is
    /// handed back so the caller can offer to relaunch into it.
    static func run(progress: @escaping (String) -> Void, completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let installedAppPath = try performUpdate(progress: progress)
                DispatchQueue.main.async { completion(.success(installedAppPath)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private static func report(_ message: String, _ progress: @escaping (String) -> Void) {
        DispatchQueue.main.async { progress(message) }
    }

    private static func performUpdate(progress: @escaping (String) -> Void) throws -> String {
        let fileManager = FileManager.default
        let workDir = fileManager.temporaryDirectory.appendingPathComponent("dockling-update-\(UUID().uuidString)")
        try fileManager.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDir) }

        report("Downloading update…", progress)
        let dmgPath = workDir.appendingPathComponent("Dockling.dmg").path
        try download(from: UpdateChecker.latestDMGURL, to: dmgPath)

        report("Verifying download…", progress)
        try verifyAppleSignature(atPath: dmgPath)

        report("Installing…", progress)
        let mountPoint = workDir.appendingPathComponent("mount").path
        try mount(dmgAt: dmgPath, to: mountPoint)
        defer { try? unmount(mountPoint) }

        let sourceApp = (mountPoint as NSString).appendingPathComponent("Dockling.app")
        guard fileManager.fileExists(atPath: sourceApp) else {
            throw UpdateError(description: "the downloaded disk image doesn't contain Dockling.app")
        }
        // Belt-and-suspenders on top of verifyAppleSignature's own Gatekeeper
        // check just above: pins the downloaded app to the same signing
        // team as *this* currently-running, already-trusted copy, so a
        // release built/signed under a different Apple developer account —
        // compromised credentials, a misconfigured CI, anything — can't
        // silently get installed just because it happens to also carry
        // *some* valid Apple signature.
        if Installer.isRealAppBundle {
            try verifySameSigningTeam(candidateAppPath: sourceApp, knownGoodAppPath: Bundle.main.bundlePath)
        }

        try Installer.installDownloadedUpdate(sourceAppPath: sourceApp)
        try LaunchdRegistration.install()

        // Also refresh the on-disk bundle this very process was launched
        // from (typically /Applications/Dockling.app) — otherwise the next
        // time someone opens Dockling to reach Settings, they'd still see
        // whichever UI they originally downloaded, even though the
        // background dispatcher (just replaced above) has already moved on.
        // Safe to replace out from under a running process on macOS: this
        // only rewrites directory entries/file contents, and the already-
        // running executable stays mapped from its old inode until this
        // process actually exits.
        if Installer.isRealAppBundle {
            try replaceRunningAppBundle(withAppAt: sourceApp)
            return Bundle.main.bundlePath
        }
        return sourceApp
    }

    // MARK: - Download

    private static func download(from url: URL, to destinationPath: String) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var downloadError: Error?

        let task = URLSession(configuration: .ephemeral).downloadTask(with: url) { location, response, error in
            defer { semaphore.signal() }
            if let error {
                downloadError = error
                return
            }
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                downloadError = UpdateError(description: "download failed (server returned \((response as? HTTPURLResponse)?.statusCode ?? -1))")
                return
            }
            guard let location else {
                downloadError = UpdateError(description: "download did not produce a file")
                return
            }
            // `location` is deleted the moment this completion handler
            // returns — move it out synchronously, before signaling, rather
            // than handing back a path that's already gone by the time the
            // waiting thread wakes up.
            do {
                try FileManager.default.moveItem(at: location, to: URL(fileURLWithPath: destinationPath))
            } catch {
                downloadError = error
            }
        }
        task.resume()
        semaphore.wait()

        if let downloadError { throw downloadError }
        guard FileManager.default.fileExists(atPath: destinationPath) else {
            throw UpdateError(description: "download did not produce a file")
        }
    }

    // MARK: - Verification

    /// Same check notarize_release.sh itself runs right after stapling —
    /// validates the full chain (Developer ID signature + notarization
    /// ticket) exactly as Gatekeeper would for a manually-downloaded-and-
    /// opened DMG, which this flow otherwise entirely bypasses.
    private static func verifyAppleSignature(atPath path: String) throws {
        let output = try run("/usr/sbin/spctl", ["-a", "-t", "open", "--context", "context:primary-signature", "-v", path])
        guard output.contains("accepted") else {
            throw UpdateError(description: "downloaded update failed Apple's Gatekeeper verification")
        }
    }

    private static func verifySameSigningTeam(candidateAppPath: String, knownGoodAppPath: String) throws {
        let candidateTeam = try signingTeamID(ofAppAt: candidateAppPath)
        let knownGoodTeam = try signingTeamID(ofAppAt: knownGoodAppPath)
        guard let candidateTeam, let knownGoodTeam, candidateTeam == knownGoodTeam else {
            throw UpdateError(description: "downloaded update is signed by a different developer than the currently installed copy — refusing to install")
        }
    }

    private static func signingTeamID(ofAppAt path: String) throws -> String? {
        // codesign exits non-zero for an unsigned bundle, which run() would
        // normally surface as a thrown error — caught here instead of
        // propagated, since "unsigned" should read as "no team ID found"
        // (and therefore fail the equality check above) rather than a
        // separate hard error with its own message.
        guard let output = try? run("/usr/bin/codesign", ["-dv", "--verbose=4", path]) else { return nil }
        for line in output.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
            let value = line.dropFirst("TeamIdentifier=".count)
            return value == "not set" ? nil : String(value)
        }
        return nil
    }

    // MARK: - Disk image mounting

    private static func mount(dmgAt dmgPath: String, to mountPoint: String) throws {
        try FileManager.default.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)
        _ = try run("/usr/bin/hdiutil", ["attach", dmgPath, "-nobrowse", "-noautoopen", "-mountpoint", mountPoint])
    }

    private static func unmount(_ mountPoint: String) throws {
        _ = try run("/usr/bin/hdiutil", ["detach", mountPoint, "-quiet"])
    }

    // MARK: - Self-replacement

    /// Swaps `knownGoodAppPath` (this process's own running bundle, e.g.
    /// /Applications/Dockling.app) for `sourceApp`, preserving the old copy
    /// as a `.old` sibling until the new one is fully in place — a crash or
    /// error partway through leaves the original recoverable rather than
    /// gone, rather than deleting first and copying second.
    private static func replaceRunningAppBundle(withAppAt sourceApp: String) throws {
        let fileManager = FileManager.default
        let bundlePath = Bundle.main.bundlePath
        let backupPath = bundlePath + ".old"

        if fileManager.fileExists(atPath: backupPath) {
            try? fileManager.removeItem(atPath: backupPath)
        }
        try fileManager.moveItem(atPath: bundlePath, toPath: backupPath)

        do {
            try fileManager.copyItem(atPath: sourceApp, toPath: bundlePath)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: (bundlePath as NSString).appendingPathComponent("Contents/MacOS/DocklingAgent"))
            let clearQuarantine = Process()
            clearQuarantine.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            clearQuarantine.arguments = ["-cr", bundlePath]
            try? clearQuarantine.run()
            clearQuarantine.waitUntilExit()
            try? fileManager.removeItem(atPath: backupPath)
        } catch {
            try? fileManager.removeItem(atPath: bundlePath)
            try? fileManager.moveItem(atPath: backupPath, toPath: bundlePath)
            throw error
        }
    }

    // MARK: - Process helper

    @discardableResult
    private static func run(_ path: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let combined = (String(data: outputData, encoding: .utf8) ?? "") + (String(data: errorData, encoding: .utf8) ?? "")

        if process.terminationStatus != 0 {
            let message = combined.trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError(description: message.isEmpty ? "\(path) exited with status \(process.terminationStatus)" : message)
        }
        return combined
    }
}
