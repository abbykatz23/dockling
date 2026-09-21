import AppKit

/// What runs when the shipped app is double-clicked in Finder — as opposed
/// to `--dispatcher` (launchd's own launch of the real background process)
/// or `--session` (a spawned per-session child). Without this, double-
/// clicking Dockling.app would just silently become another headless
/// dispatcher with nothing on screen to tell you it did anything at all.
/// A minimal native install flow instead, so setup needs no Terminal.
final class FirstRunDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if LaunchdRegistration.isInstalled {
            showAlreadyInstalled()
        } else {
            showWelcome()
        }
    }

    private func showWelcome() {
        let alert = NSAlert()
        alert.messageText = "Welcome to Dockling"
        alert.informativeText = "This sets up a live duck in your Dock for every Claude Code session on this Mac, and registers it to start automatically at login."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            NSApp.terminate(nil)
            return
        }
        install()
    }

    private func showAlreadyInstalled() {
        let alert = NSAlert()
        alert.messageText = "Dockling is already installed"
        alert.informativeText = "It's running in the background and starts automatically at login."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Reinstall")
        if alert.runModal() == .alertSecondButtonReturn {
            install()
        } else {
            NSApp.terminate(nil)
        }
    }

    private func install() {
        Installer.run()
        do {
            try LaunchdRegistration.install()
        } catch {
            showError("Dockling's hooks are set up, but starting it automatically failed: \(error.localizedDescription)")
            return
        }
        let done = NSAlert()
        done.messageText = "You're all set!"
        done.informativeText = "Start or continue any Claude Code session to see your duck."
        done.addButton(withTitle: "OK")
        done.runModal()
        NSApp.terminate(nil)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Something went wrong"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        NSApp.terminate(nil)
    }
}

func runFirstRunApp() -> Never {
    let delegate = FirstRunDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.run()
    exit(0)
}
