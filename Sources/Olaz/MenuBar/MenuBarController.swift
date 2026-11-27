import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The Olaz item in the menu bar: an icon with the unread count of the pinned conversations, opening a glass panel to read
/// and answer them (`MenuBarPopover`). ⌥⌘Z toggles it from anywhere. Both can be turned off in Settings ▸ Chung.
///
/// The panel is a non-activating `NSPanel`, not an `NSPopover`: it takes the keyboard without activating Olaz, so opening it
/// never pulls the main window in front of the app the user is in (as Spotlight does).
@MainActor
final class MenuBarController: NSObject {
    private static var shared: MenuBarController?

    /// Called once at launch; the item appears as soon as the app finished launching.
    static func install(engine: ZaloEngine, shell: ShellModel) {
        guard shared == nil else { return }
        shared = MenuBarController(engine: engine, shell: shell)
    }

    static let panelSize = NSSize(width: 360, height: 540)
    private static let cornerRadius: CGFloat = 22

    private let model: MenuBarModel
    private let panel: QuickPanel
    private var item: NSStatusItem?
    private var hotKey: GlobalHotKey?
    private var outsideClickMonitor: Any?
    private var viewerCloseObserver: NSObjectProtocol?
    private var lastUnread = 0

    private init(engine: ZaloEngine, shell: ShellModel) {
        model = MenuBarModel(engine: engine, shell: shell)
        panel = QuickPanel(size: Self.panelSize, cornerRadius: Self.cornerRadius)
        super.init()
        model.closePanel = { [weak self] in self?.hide() }

        let hosting = NSHostingView(rootView: MenuBarPopover(model: model).olazAppearance(engine: engine, shell: shell))
        hosting.sizingOptions = []
        let glass = NSGlassEffectView()
        glass.cornerRadius = Self.cornerRadius
        glass.contentView = hosting
        // The window itself is rectangular: clipping its content to the glass's corners keeps the clear corners (and the
        // shadow computed from them) from showing as a frame around the rounded panel.
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = Self.cornerRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        glass.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            glass.topAnchor.constraint(equalTo: container.topAnchor),
            glass.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        panel.contentView = container

        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelResignedKey() }
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPreferences() }
        }
        // App.init runs before NSApplication finished launching: the status bar is set up on the first run-loop turn.
        Task { @MainActor [weak self] in
            self?.applyPreferences()
            self?.trackBadge()
        }
    }

    // MARK: Preferences

    private func applyPreferences() {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: OlazPrefs.menuBarEnabled) as? Bool ?? true
        let wantsHotKey = enabled && (defaults.object(forKey: OlazPrefs.menuBarHotKey) as? Bool ?? true)

        if enabled, item == nil {
            installItem()
        } else if !enabled, let item {
            hide()
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }

        if wantsHotKey, hotKey == nil {
            hotKey = GlobalHotKey(keyCode: kVK_ANSI_Z, modifiers: cmdKey | optionKey, id: 1) { [weak self] in self?.toggle() }
            if hotKey == nil { EngineLog.shared.write("menu bar hotkey ⌥⌘Z unavailable (held by another app)") }
        } else if !wantsHotKey, let hotKey {
            hotKey.unregister()
            self.hotKey = nil
        }
    }

    private func installItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Keeps the place the user ⌘-dragged it to across launches.
        item.autosaveName = "olaz.pinnedChats"
        if let button = item.button {
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(buttonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Olaz — chat đã ghim (⌥⌘Z)"
        }
        self.item = item
        updateButton()
    }

    // MARK: Badge

    /// Re-renders the button whenever the pinned list or its unread counts change.
    private func trackBadge() {
        withObservationTracking { updateButton() } onChange: { [weak self] in
            Task { @MainActor in self?.trackBadge() }
        }
    }

    private func updateButton() {
        let unread = model.isSignedIn ? model.unreadTotal : 0
        let drafts = model.isSignedIn ? model.pendingDrafts : 0
        guard let button = item?.button else { lastUnread = unread + drafts; return }
        let symbol = unread > 0 ? "bubble.left.and.text.bubble.right.fill" : "bubble.left.and.bubble.right"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Olaz")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        image?.isTemplate = true
        button.image = image
        // "3" unread, "✎2" drafts waiting for review.
        var parts: [String] = []
        if unread > 0 { parts.append(unread > 99 ? "99+" : String(unread)) }
        if drafts > 0 { parts.append("✎" + String(drafts)) }
        button.attributedTitle = parts.isEmpty
            ? NSAttributedString(string: "")
            : NSAttributedString(string: " " + parts.joined(separator: " "),
                                 attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)])
        var label = ["Olaz"]
        if unread > 0 { label.append("\(unread) tin chưa đọc") }
        if drafts > 0 { label.append("\(drafts) nháp chờ duyệt") }
        button.setAccessibilityLabel(label.joined(separator: ", "))
        if unread + drafts > lastUnread, !panel.isVisible { bounce(button) }
        lastUnread = unread + drafts
    }

    /// A short spring on a new message; skipped with Reduce Motion.
    private func bounce(_ button: NSStatusBarButton) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        button.wantsLayer = true
        guard let layer = button.layer else { return }
        let animation = CASpringAnimation(keyPath: "transform.translation.y")
        animation.fromValue = -3
        animation.toValue = 0
        animation.damping = 7
        animation.initialVelocity = 6
        animation.duration = animation.settlingDuration
        layer.add(animation, forKey: "olaz.bounce")
    }

    // MARK: Panel

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu(from: sender)
        } else {
            toggle()
        }
    }

    private func toggle() {
        panel.isVisible ? hide() : show()
    }

    private func show() {
        guard let button = item?.button, let buttonWindow = button.window else { return }
        model.willShow()
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let size = Self.panelSize
        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let y = anchor.minY - size.height - 6
        let target = NSRect(x: x, y: y, width: size.width, height: size.height)

        button.highlight(true)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.setFrame(reduceMotion ? target : target.offsetBy(dx: 0, dy: 8), display: false)
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.level = .popUpMenu
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(target, display: true)
            }
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    /// Losing the keyboard closes the panel, except to the media viewer opened from it (photo / video tapped in the chat):
    /// the panel then waits behind the viewer and takes the keyboard back when the viewer closes.
    private func panelResignedKey() {
        // The key window changes after this notification; the viewer is ordered front right after the app activates.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, self.panel.isVisible, !self.panel.isKeyWindow else { return }
            if let viewer = NSApp.windows.first(where: { $0 is MediaViewerWindow && $0.isVisible }) {
                self.wait(behind: viewer)
            } else {
                self.hide()
            }
        }
    }

    private func wait(behind viewer: NSWindow) {
        guard viewerCloseObserver == nil else { return }
        panel.level = .normal
        panel.order(.below, relativeTo: viewer.windowNumber)
        viewerCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: viewer, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dropViewerObserver()
                guard self.panel.isVisible else { return }
                self.panel.level = .popUpMenu
                self.panel.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func dropViewerObserver() {
        if let viewerCloseObserver { NotificationCenter.default.removeObserver(viewerCloseObserver) }
        viewerCloseObserver = nil
    }

    private func hide() {
        dropViewerObserver()
        guard panel.isVisible else { return }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        item?.button?.highlight(false)
        panel.orderOut(nil)
        model.didClose()
    }

    private func showMenu(from button: NSStatusBarButton) {
        hide()
        let menu = NSMenu()
        menu.addItem(withTitle: "Mở cửa sổ Olaz", action: #selector(openMain), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Cài đặt…", action: #selector(openSettings), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Ẩn biểu tượng trên menu bar", action: #selector(hideItem), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Thoát Olaz", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        item?.menu = menu
        button.performClick(nil)
        item?.menu = nil
    }

    @objc private func openMain() { model.openMainWindow() }
    @objc private func openSettings() { model.openSettings() }
    @objc private func hideItem() { UserDefaults.standard.set(false, forKey: OlazPrefs.menuBarEnabled) }
}

/// Borderless floating panel that can take the keyboard without activating the app.
private final class QuickPanel: NSPanel {
    init(size: NSSize, cornerRadius: CGFloat) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
