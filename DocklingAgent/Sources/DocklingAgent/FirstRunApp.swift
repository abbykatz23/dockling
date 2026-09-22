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

        let rowWidth: CGFloat = 400
        let checkboxFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        var rowHeights: [CGFloat] = []

        // NSButton's own intrinsic size assumes a single line unless told
        // otherwise — without wraps=true plus an explicit, measured height,
        // a title longer than the row fits just gets truncated ("Asks for
        // accessibility a…", confirmed happening) rather than wrapping.
        func makeCheckbox(_ title: String, isOn: Bool) -> NSButton {
            let checkbox = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            checkbox.state = isOn ? .on : .off
            (checkbox.cell as? NSButtonCell)?.wraps = true
            checkbox.translatesAutoresizingMaskIntoConstraints = false
            checkbox.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
            let textWidth = rowWidth - 22 // checkbox glyph + its own leading gap
            let textHeight = ceil((title as NSString).boundingRect(
                with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: checkboxFont]
            ).height)
            let rowHeight = max(18, textHeight + 2)
            checkbox.heightAnchor.constraint(greaterThanOrEqualToConstant: rowHeight).isActive = true
            rowHeights.append(rowHeight)
            return checkbox
        }

        let subagentDucksCheckbox = makeCheckbox("Show a baby duck for each subagent", isOn: config.subagentDucks)
        let focusVSCodeCheckbox = makeCheckbox("Focus Claude session when clicking duck (asks for Accessibility access)", isOn: config.focusVSCodeOnClick)

        let stackSpacing: CGFloat = 12
        let stack = NSStackView(views: [subagentDucksCheckbox, focusVSCodeCheckbox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = stackSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        // NSAlert sizes its accessory area off the view's own `frame`, not
        // off NSStackView's constraint-derived intrinsic size — without an
        // explicitly framed container, the accessory area collapses to
        // near-zero height and its content overlaps the alert's own text
        // instead of sitting in its own space below it (confirmed
        // happening: exactly this overlap, in the shipped customize step).
        let totalHeight = rowHeights.reduce(0, +) + stackSpacing * CGFloat(rowHeights.count - 1)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: totalHeight))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        alert.accessoryView = container

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        return DocklingConfig(
            subagentDucks: subagentDucksCheckbox.state == .on,
            focusVSCodeOnClick: focusVSCodeCheckbox.state == .on
        )
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
