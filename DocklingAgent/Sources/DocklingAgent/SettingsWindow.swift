import AppKit

/// Shown whenever Dockling.app is opened while already installed, and once
/// automatically right after a fresh install finishes (via `welcomeMessage`)
/// so the pose key is seen without any extra click — most people install
/// Dockling once and never open the .app again afterward, so this first
/// showing may be their only look at it. Settings save immediately on
/// toggle rather than needing an explicit Save button, since this is a
/// persistent window a user can just close whenever, not a modal dialog
/// with a clear "commit" moment.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private var config: DocklingConfig
    private var subagentDucksCheckbox: NSButton!
    private let onUninstall: () -> Void
    private let onReinstall: () -> Void
    // Reused across double-clicks rather than a new window each time, so
    // clicking several ducks in a row doesn't pile up orphaned windows.
    private var previewWindowController: NSWindowController?

    private static let windowWidth: CGFloat = 460

    // (assetNames, label) rather than keying off DockState directly: every
    // other state has exactly one asset, but .committing has two —
    // bride and groom, picked randomly per process (see
    // DockIconController) — and the key shows both side by side rather
    // than picking just one to stand in for the pair.
    private static let legend: [(assetNames: [String], label: String)] = [
        (["idle"], "Idle"),
        (["bash"], "Running a shell command"),
        (["edit"], "Editing a file"),
        (["search"], "Searching or reading"),
        (["other"], "Using a tool"),
        (["awaiting-input"], "Waiting on you"),
        (["error"], "Error"),
        (["eureka"], "Task complete"),
        (["committing-bride", "committing-groom"], "Committing"),
        (["pulling"], "Pulling"),
        (["pushing"], "Pushing"),
        (["testing"], "Running tests"),
        (["compressing"], "Compressing files"),
        (["sleepy"], "Idle 5+ minutes"),
        (["butt"], "Session ending"),
    ]

    init(welcomeMessage: String?, onUninstall: @escaping () -> Void, onReinstall: @escaping () -> Void) {
        self.config = DocklingConfig.load()
        self.onUninstall = onUninstall
        self.onReinstall = onReinstall

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Dockling"
        window.minSize = NSSize(width: Self.windowWidth, height: 420)
        window.center()
        // Nothing else re-shows this window if AppKit deallocs it on close
        // (this app has no menu, no other windows) — keeping it alive until
        // windowWillClose explicitly terminates avoids that mattering.
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
        buildContent(welcomeMessage: welcomeMessage)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    // The only way this window closes is the user clicking its own close
    // button or the bottom-bar Close button — there's no other UI once
    // it's open, so treat that the same as quitting the app, matching
    // every other flow in FirstRunApp.
    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    private func buildContent(welcomeMessage: String?) {
        guard let contentView = window?.contentView else { return }
        let rowWidth = Self.windowWidth - 40

        let documentStack = NSStackView()
        documentStack.orientation = .vertical
        documentStack.alignment = .leading
        documentStack.spacing = 14
        documentStack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        documentStack.translatesAutoresizingMaskIntoConstraints = false

        if let welcomeMessage {
            documentStack.addArrangedSubview(makeLabel(welcomeMessage, wrapWidth: rowWidth))
        }

        documentStack.addArrangedSubview(makeLabel("Settings", bold: true))
        let subagentDucksCheckbox = makeCheckbox("Show a baby duck for each subagent", isOn: config.subagentDucks, rowWidth: rowWidth)
        self.subagentDucksCheckbox = subagentDucksCheckbox
        documentStack.addArrangedSubview(subagentDucksCheckbox)
        documentStack.addArrangedSubview(makeLabel("Changes here save immediately. You can also edit ~/.dockling/config.json directly.", wrapWidth: rowWidth, small: true))

        documentStack.addArrangedSubview(makeSeparator(width: rowWidth))

        documentStack.addArrangedSubview(makeLabel("Duck Key", bold: true))
        for (assetNames, label) in Self.legend {
            documentStack.addArrangedSubview(makeLegendRow(assetNames: assetNames, label: label))
        }

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = documentStack

        let uninstallButton = NSButton(title: "Uninstall…", target: self, action: #selector(uninstallClicked))
        let reinstallButton = NSButton(title: "Reinstall", target: self, action: #selector(reinstallClicked))
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        closeButton.keyEquivalent = "\r"
        for button in [uninstallButton, reinstallButton, closeButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.bezelStyle = .rounded
        }

        contentView.addSubview(scrollView)
        contentView.addSubview(uninstallButton)
        contentView.addSubview(reinstallButton)
        contentView.addSubview(closeButton)

        // Direct constraints per button rather than an NSStackView with a
        // hugging-priority spacer to push uninstall left and the rest
        // right — fewer moving parts to get an ambiguous-layout warning
        // out of, for a bar that's just three fixed buttons.
        NSLayoutConstraint.activate([
            documentStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: uninstallButton.topAnchor, constant: -12),

            uninstallButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            uninstallButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),

            closeButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            closeButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),

            reinstallButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -10),
            reinstallButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])
    }

    private func makeLabel(_ text: String, bold: Bool = false, wrapWidth: CGFloat? = nil, small: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        let size = small ? NSFont.smallSystemFontSize : NSFont.systemFontSize
        label.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        if small { label.textColor = .secondaryLabelColor }
        label.translatesAutoresizingMaskIntoConstraints = false
        if let wrapWidth {
            label.preferredMaxLayoutWidth = wrapWidth
            label.lineBreakMode = .byWordWrapping
        }
        return label
    }

    // Same measured-height recipe as FirstRunApp's customize step: NSButton's
    // own intrinsic size assumes a single line unless told otherwise, so a
    // title longer than the row just gets truncated instead of wrapping
    // without an explicit, measured height (confirmed happening before this
    // fix landed there).
    private func makeCheckbox(_ title: String, isOn: Bool, rowWidth: CGFloat) -> NSButton {
        let checkbox = NSButton(checkboxWithTitle: title, target: self, action: #selector(checkboxChanged(_:)))
        checkbox.state = isOn ? .on : .off
        (checkbox.cell as? NSButtonCell)?.wraps = true
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
        let textWidth = rowWidth - 22 // checkbox glyph + its own leading gap
        let textHeight = ceil((title as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        ).height)
        checkbox.heightAnchor.constraint(greaterThanOrEqualToConstant: max(18, textHeight + 2)).isActive = true
        return checkbox
    }

    private func makeSeparator(width: CGFloat) -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: width).isActive = true
        return box
    }

    // A plain NSView with every edge pinned explicitly, not nested
    // NSStackViews — a horizontal stack-of-stacks here (icon-pair stack
    // inside a row stack, inside the vertical document stack) left some
    // rows' labels with an underdetermined position, and different rows
    // resolved that ambiguity differently: some left-aligned, some pinned
    // to the far trailing edge instead (confirmed happening — a real,
    // reported-back regression, not a hypothetical). Every anchor below is
    // either a fixed constant or tied straight back to `row`'s own edges,
    // so there's exactly one valid layout, not several AppKit could pick
    // between.
    //
    // Two icon slots on every row, not just however many assets this
    // particular row has, so every label — including committing's, the
    // only row with two real icons — starts at the same x position. An
    // unfilled slot is an empty, image-less NSImageView the same size as
    // a real one, invisible but still occupying its spot.
    private func makeLegendRow(assetNames: [String], label text: String) -> NSView {
        let iconSize: CGFloat = 28
        let iconGap: CGFloat = 4
        let labelGap: CGFloat = 6

        let slots = (0..<2).map { index -> LegendImageView in
            let assetName = index < assetNames.count ? assetNames[index] : nil
            let imageView = LegendImageView(assetName: assetName)
            imageView.image = assetName.flatMap(Self.duckImage)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            if assetName != nil {
                imageView.toolTip = "Double-click to enlarge"
                let click = NSClickGestureRecognizer(target: self, action: #selector(self.legendImageDoubleClicked(_:)))
                click.numberOfClicksRequired = 2
                imageView.addGestureRecognizer(click)
            }
            return imageView
        }
        let label = makeLabel(text)

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(slots[0])
        row.addSubview(slots[1])
        row.addSubview(label)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: iconSize),

            slots[0].leadingAnchor.constraint(equalTo: row.leadingAnchor),
            slots[0].centerYAnchor.constraint(equalTo: row.centerYAnchor),
            slots[0].widthAnchor.constraint(equalToConstant: iconSize),
            slots[0].heightAnchor.constraint(equalToConstant: iconSize),

            slots[1].leadingAnchor.constraint(equalTo: slots[0].trailingAnchor, constant: iconGap),
            slots[1].centerYAnchor.constraint(equalTo: row.centerYAnchor),
            slots[1].widthAnchor.constraint(equalToConstant: iconSize),
            slots[1].heightAnchor.constraint(equalToConstant: iconSize),

            label.leadingAnchor.constraint(equalTo: slots[1].trailingAnchor, constant: labelGap),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            // Ties row's own width to its content (leading pinned above,
            // trailing pinned here) rather than leaving it derived from
            // nothing — the exact gap this whole rewrite exists to close.
            label.trailingAnchor.constraint(equalTo: row.trailingAnchor),
        ])
        return row
    }

    // Yellow specifically: not any user's actual duck color (that's
    // per-project, see DockIconController), just a fixed, representative
    // pick so the key always renders something regardless of which colors
    // are or aren't currently in use. Same choice main.swift's dev-mode
    // default and Installer's sanity check already make.
    private static func duckImage(_ assetName: String) -> NSImage? {
        AssetResolver.resolveURL(name: assetName, ext: "png", subdir: "yellow").flatMap(NSImage.init(contentsOf:))
    }

    @objc private func checkboxChanged(_ sender: NSButton) {
        config.subagentDucks = subagentDucksCheckbox.state == .on
        config.save()
    }

    @objc private func uninstallClicked() {
        onUninstall()
    }

    @objc private func reinstallClicked() {
        onReinstall()
    }

    @objc private func closeClicked() {
        window?.close()
    }

    @objc private func legendImageDoubleClicked(_ sender: NSClickGestureRecognizer) {
        guard let imageView = sender.view as? LegendImageView,
              let assetName = imageView.assetName,
              let image = Self.duckImage(assetName) else { return }
        showPreview(image)
    }

    private func showPreview(_ image: NSImage) {
        let size: CGFloat = 220
        if previewWindowController == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                styleMask: [.titled, .closable, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            panel.title = ""
            panel.isReleasedWhenClosed = false
            let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: size, height: size))
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.autoresizingMask = [.width, .height]
            panel.contentView = imageView
            previewWindowController = NSWindowController(window: panel)
        }
        (previewWindowController?.window?.contentView as? NSImageView)?.image = image
        previewWindowController?.window?.center()
        previewWindowController?.showWindow(nil)
    }
}

// Tags an icon slot with which pose asset it shows, if any, so a double-
// click handler shared by every slot can tell which image to enlarge
// without needing a separate closure/selector per row.
private final class LegendImageView: NSImageView {
    let assetName: String?

    init(assetName: String?) {
        self.assetName = assetName
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }
}
