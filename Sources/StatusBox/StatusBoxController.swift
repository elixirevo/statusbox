import AppKit
import CoreGraphics

private enum StatusItemLength {
    static let shown = NSStatusItem.squareLength
    static let hidden: CGFloat = 10_000
}

final class StatusBoxController: NSObject {
    private let store = SettingsStore()
    private lazy var overlayManager = OverlayManager(store: store)

    // Kept for the dormant Box UI feature. The current build does not route user actions here.
    private lazy var boxWindowController = BoxWindowController(settingsStore: store)
    private var settingsWindowController: SettingsWindowController?

    private var statusItem: NSStatusItem?
    private var tapeItem: NSStatusItem?
    private var autoHideTimer: Timer?
    private var captureTask: Task<Void, Never>?
    private var isHidden = false

    func start() {
        configureMainStatusItem()
        configureTapeStatusItem()

        DispatchQueue.main.async { [weak self] in
            self?.revealHiddenIcons()
        }

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    private func configureMainStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: StatusItemLength.shown)
        item.autosaveName = "com.elixirevo.StatusBox.main"
        item.length = StatusItemLength.shown
        if let button = item.button {
            button.image = StatusIconFactory.boxIcon()
            button.title = ""
            button.toolTip = "Status Box: 숨김/보임 전환"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    private func configureTapeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: StatusItemLength.shown)
        item.autosaveName = "com.elixirevo.StatusBox.tape"
        item.length = StatusItemLength.shown
        if let button = item.button {
            button.image = StatusIconFactory.tapeIcon()
            button.title = ""
            button.imagePosition = .imageOnly
            button.toolTip = "Status Box 기준선: Command-드래그로 숨길 아이콘들의 오른쪽에 놓으세요."
            button.target = nil
            button.action = nil
        }
        tapeItem = item
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            toggleHiddenIcons()
            return
        }

        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu(from: sender)
        } else {
            toggleHiddenIcons()
        }
    }

    private func toggleHiddenIcons() {
        if isHidden {
            showHiddenIcons()
        } else {
            hideHiddenIcons()
        }
    }

    private func showHiddenIcons() {
        revealHiddenIcons()
    }

    private func revealHiddenIcons() {
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        captureTask?.cancel()
        captureTask = nil
        boxWindowController.close()

        tapeItem?.length = StatusItemLength.shown
        isHidden = false
    }

    private func hideHiddenIcons() {
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        captureTask?.cancel()
        captureTask = nil
        boxWindowController.close()

        tapeItem?.length = StatusItemLength.hidden
        isHidden = true
    }

    private func scheduleAutoHideIfNeeded() {
        guard store.settings.autoHideEnabled else { return }

        autoHideTimer = Timer.scheduledTimer(withTimeInterval: store.settings.autoHideDelaySeconds, repeats: false) { [weak self] _ in
            self?.hideHiddenIcons()
        }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "숨긴 아이콘 보기", action: #selector(showHiddenIconsMenuAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "다시 숨기기", action: #selector(hideHiddenIconsMenuAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "현재 테이프 위치로 다시 숨기기", action: #selector(refreshRangeMenuAction), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "설정 열기", action: #selector(openSettingsMenuAction), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Status Box 종료", action: #selector(quitMenuAction), keyEquivalent: "q"))

        for item in menu.items where item.target == nil {
            item.target = self
        }

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 4), in: button)
    }

    @objc private func showHiddenIconsMenuAction() {
        showHiddenIcons()
    }

    @objc private func hideHiddenIconsMenuAction() {
        hideHiddenIcons()
    }

    @objc private func refreshRangeMenuAction() {
        hideHiddenIcons()
    }

    @objc private func openSettingsMenuAction() {
        openSettings()
    }

    @objc private func quitMenuAction() {
        NSApplication.shared.terminate(nil)
    }

    private func openSettings() {
        if settingsWindowController == nil {
            let actions = SettingsActions(
                refreshHiddenRange: { [weak self] in
                    self?.hideHiddenIcons()
                },
                showHiddenIcons: { [weak self] in self?.showHiddenIcons() },
                hideHiddenIcons: { [weak self] in self?.hideHiddenIcons() },
                setLaunchAtLogin: { enabled in LaunchAtLoginManager.setEnabled(enabled) }
            )
            settingsWindowController = SettingsWindowController(store: store, actions: actions)
        }
        settingsWindowController?.show()
    }

    // Dormant Box UI path. Left in place intentionally, but not called in this build.
    private func showBox(anchorFrame: NSRect, screen: NSScreen) {
        guard store.settings.boxFeatureEnabled,
              let range = store.range(for: screen),
              let display = ScreenCapture.descriptor(for: screen) else {
            return
        }

        let rangeRect = MenuBarGeometry.rect(for: range, on: screen)
        let displayId = screen.statusBoxDisplayId

        captureTask?.cancel()
        overlayManager.orderOutAll()
        captureTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }

            let captureResult = await ScreenCapture.capture(rect: rangeRect, display: display)

            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                guard let screen = MenuBarGeometry.screen(displayId: displayId) else { return }
                self.overlayManager.hideConfiguredRanges()
                self.boxWindowController.show(
                    anchorFrame: anchorFrame,
                    rangeRect: rangeRect,
                    screen: screen,
                    captureResult: captureResult
                )
                self.scheduleAutoHideIfNeeded()
            }
        }
    }

    private func forwardClickToMenuBar(point: NSPoint, button: CGMouseButton) {
        overlayManager.revealConfiguredRanges()
        ClickForwarder.postClick(at: point, button: button)
        scheduleAutoHideIfNeeded()
    }

    @objc private func screenParametersChanged() {
        store.refreshDisplays()
        if isHidden {
            hideHiddenIcons()
        }
    }

    @objc private func activeSpaceChanged() {
        if isHidden {
            hideHiddenIcons()
        }
    }
}
