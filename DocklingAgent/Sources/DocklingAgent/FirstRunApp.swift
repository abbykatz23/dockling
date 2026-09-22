import AppKit

/// What runs when the shipped app is double-clicked in Finder — as opposed
/// to `--dispatcher` (launchd's own launch of the real background process)
/// or `--session` (a spawned per-session child). Without this, double-
/// clicking Dockling.app would just silently become another headless
/// dispatcher with nothing on screen to tell you it did anything at all.
/// A minimal native install flow instead, so setup needs no Terminal.
final class FirstRunDelegate: NSObject, NSApplicationDelegate {
    // Retained here, not just handed to showWindow(nil): NSWindowController
    // isn't kept alive by its own window (isReleasedWhenClosed=false keeps
    // the *window* around, not the controller), and this delegate is the
    // only other thing around to hold a strong reference to it.
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if LaunchdRegistration.isInstalled {
            openSettingsWindow(welcomeMessage: nil)
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

    private func openSettingsWindow(welcomeMessage: String?) {
        let controller = SettingsWindowController(
            welcomeMessage: welcomeMessage,
            onUninstall: { [weak self] in self?.confirmUninstall() },
            onReinstall: { [weak self] in self?.repairInstallation() }
        )
        settingsWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Cancel is the default button (first added, responds to Return) rather
    /// than Uninstall — this is destructive and can't be undone, so an
    /// accidental Return keypress shouldn't be able to trigger it. Declining
    /// just returns to the still-open settings window rather than quitting
    /// the whole app — this is reached from a button in that window now,
    /// not from a one-shot "what do you want to do" alert with nothing else
    /// left to show afterward.
    private func confirmUninstall() {
        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = "Uninstall Dockling?"
        confirm.informativeText = "This removes Dockling's hooks from ~/.claude/settings.json, stops the background process, and deletes ~/.dockling — including your saved preferences and per-project duck colors. This can't be undone."
        confirm.addButton(withTitle: "Cancel")
        confirm.addButton(withTitle: "Uninstall")
        guard confirm.runModal() == .alertSecondButtonReturn else { return }
        Installer.uninstall()
        let done = NSAlert()
        done.messageText = "Dockling has been uninstalled"
        done.informativeText = "Its hooks, background process, and saved settings have all been removed."
        done.addButton(withTitle: "OK")
        done.runModal()
        NSApp.terminate(nil)
    }

    /// Re-runs the same hook/launchd registration `install()` does, without
    /// its customize step or final window — settings are already editable
    /// live in the settings window this is reached from, so there's nothing
    /// left to ask. For repairing a broken hook entry or launchd
    /// registration without touching saved preferences.
    private func repairInstallation() {
        do {
            try Installer.run()
            try LaunchdRegistration.install()
        } catch {
            showError("Reinstall failed: \(error.localizedDescription)", terminate: false)
            return
        }
        let done = NSAlert()
        done.messageText = "Hooks reinstalled"
        done.informativeText = "Dockling's hooks and background process have been refreshed."
        done.addButton(withTitle: "OK")
        done.runModal()
    }

    // No separate "customize your settings" step before this: it used to
    // ask via its own dialog, then immediately open the settings window
    // (which shows those exact same two checkboxes) right after — asking
    // once and then appearing to ask again read as broken, not thorough.
    // Installs with whatever's already on disk (DocklingConfig.load()
    // falls back to .default on a genuinely fresh install), and the
    // settings window that opens right after is where those get changed,
    // same as any other time it's opened.
    private func install() {
        do {
            try Installer.run()
        } catch {
            showError("Setup failed: \(error)")
            return
        }
        do {
            try LaunchdRegistration.install()
        } catch {
            showError("Dockling's hooks are set up, but starting it automatically failed: \(error.localizedDescription)")
            return
        }
        openSettingsWindow(welcomeMessage: "You're all set! Start or continue any Claude Code session to see your duck. Here's what each pose means:")
    }

    private func showError(_ message: String, terminate: Bool = true) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Something went wrong"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        if terminate { NSApp.terminate(nil) }
    }
}

func runFirstRunApp() -> Never {
    let delegate = FirstRunDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.run()
    exit(0)
}
