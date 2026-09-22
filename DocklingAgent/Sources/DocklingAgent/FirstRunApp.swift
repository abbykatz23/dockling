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
        alert.addButton(withTitle: "Uninstall")
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            install()
        case .alertThirdButtonReturn:
            confirmUninstall()
        default:
            NSApp.terminate(nil)
        }
    }

    /// Cancel is the default button (first added, responds to Return) rather
    /// than Uninstall — this is destructive and can't be undone, so an
    /// accidental Return keypress shouldn't be able to trigger it.
    private func confirmUninstall() {
        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = "Uninstall Dockling?"
        confirm.informativeText = "This removes Dockling's hooks from ~/.claude/settings.json, stops the background process, and deletes ~/.dockling — including your saved preferences and per-project duck colors. This can't be undone."
        confirm.addButton(withTitle: "Cancel")
        confirm.addButton(withTitle: "Uninstall")
        guard confirm.runModal() == .alertSecondButtonReturn else {
            NSApp.terminate(nil)
            return
        }
        Installer.uninstall()
        let done = NSAlert()
        done.messageText = "Dockling has been uninstalled"
        done.informativeText = "Its hooks, background process, and saved settings have all been removed."
        done.addButton(withTitle: "OK")
        done.runModal()
        NSApp.terminate(nil)
    }

    private func install() {
        // Pre-filled from whatever's already on disk (DocklingConfig.load()
        // falls back to .default, e.g. everything on, if this is a genuinely
        // fresh install) — so re-running Install/Reinstall doesn't silently
        // reset a returning user's prior choices back to defaults.
        guard let config = showCustomize(startingFrom: DocklingConfig.load()) else {
            NSApp.terminate(nil)
            return
        }
        config.save()

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

    /// Lets the user opt in/out of each feature before anything is actually
    /// installed — in particular, whether to request Accessibility access at
    /// all (see DocklingConfig.focusVSCodeOnClick), since that's a real
    /// system permission prompt with no explanation of its own otherwise.
    /// Returns nil on Cancel. Values live in ~/.dockling/config.json
    /// afterward and can be hand-edited there too — this is just a friendlier
    /// front door for the same file.
    private func showCustomize(startingFrom config: DocklingConfig) -> DocklingConfig? {
        let alert = NSAlert()
        alert.messageText = "Customize Dockling"
        alert.informativeText = "You can change these later by editing ~/.dockling/config.json."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        let subagentDucksCheckbox = NSButton(checkboxWithTitle: "Show a smaller duck for each subagent", target: nil, action: nil)
        subagentDucksCheckbox.state = config.subagentDucks ? .on : .off

        let replyPopoverCheckbox = NSButton(checkboxWithTitle: "Reply to Claude by clicking its Dock icon", target: nil, action: nil)
        replyPopoverCheckbox.state = config.replyPopover ? .on : .off

        let focusVSCodeCheckbox = NSButton(checkboxWithTitle: "Focus VS Code when I click its duck (asks for Accessibility access)", target: nil, action: nil)
        focusVSCodeCheckbox.state = config.focusVSCodeOnClick ? .on : .off

        let commitPoseLabel = NSTextField(labelWithString: "Duck shown for a commit:")
        let commitPosePopup = NSPopUpButton()
        commitPosePopup.addItems(withTitles: ["Random", "Bride", "Groom"])
        switch config.commitPose {
        case .random: commitPosePopup.selectItem(at: 0)
        case .bride: commitPosePopup.selectItem(at: 1)
        case .groom: commitPosePopup.selectItem(at: 2)
        }
        let commitPoseRow = NSStackView(views: [commitPoseLabel, commitPosePopup])
        commitPoseRow.orientation = .horizontal
        commitPoseRow.spacing = 8

        let stack = NSStackView(views: [subagentDucksCheckbox, replyPopoverCheckbox, focusVSCodeCheckbox, commitPoseRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 110))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        alert.accessoryView = container

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let commitPose: DocklingConfig.CommitPose
        switch commitPosePopup.indexOfSelectedItem {
        case 1: commitPose = .bride
        case 2: commitPose = .groom
        default: commitPose = .random
        }
        return DocklingConfig(
            subagentDucks: subagentDucksCheckbox.state == .on,
            replyPopover: replyPopoverCheckbox.state == .on,
            commitPose: commitPose,
            focusVSCodeOnClick: focusVSCodeCheckbox.state == .on
        )
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
