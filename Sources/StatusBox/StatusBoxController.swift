import AppKit
import Carbon
import Combine
import CoreGraphics

private enum StatusItemLength {
    static let shown = NSStatusItem.squareLength
    static let hidden: CGFloat = 10_000
}

private enum HiddenBoxLayout {
    static let maxCaptureWidth: CGFloat = 520
    static let captureDelayNanoseconds: UInt64 = 120_000_000
    static let clickForwardInitialDelayNanoseconds: UInt64 = 280_000_000
    static let clickForwardRetryDelayNanoseconds: UInt64 = 100_000_000
    static let clickForwardMaxAttempts = 12
}

private enum StatusBoxHotKey {
    static let signature: OSType = 0x53544258
    static let menuBarIconID: UInt32 = 1
    static let boxUIID: UInt32 = 2
}

private func statusBoxHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ eventRef: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let eventRef, let userData else { return noErr }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        eventRef,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == StatusBoxHotKey.signature else {
        return status
    }

    let controller = Unmanaged<StatusBoxController>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async {
        controller.handleKeyboardShortcut(id: hotKeyID.id)
    }
    return noErr
}

final class StatusBoxController: NSObject {
    private let store = SettingsStore()
    private lazy var overlayManager = OverlayManager(store: store)

    private lazy var boxWindowController = BoxWindowController(settingsStore: store)
    private var settingsWindowController: SettingsWindowController?

    private var statusItem: NSStatusItem?
    private var tapeItem: NSStatusItem?
    private var autoHideTimer: Timer?
    private var captureTask: Task<Void, Never>?
    private var isHidden = false
    private var settingsCancellable: AnyCancellable?
    private var hotKeyEventHandler: EventHandlerRef?
    private var menuBarIconHotKey: EventHotKeyRef?
    private var boxUIHotKey: EventHotKeyRef?
    private var isRecordingShortcut = false
    private var proxyTargetScanTask: Task<Void, Never>?
    private var cachedProxyTargets: [MenuBarProxyTarget] = []
    private var cachedProxyTargetsLoadedAt: Date?

    deinit {
        proxyTargetScanTask?.cancel()
        uninstallKeyboardShortcuts()
    }

    func start() {
        boxWindowController.onForwardedClick = { [weak self] click, button in
            self?.forwardClickToMenuBar(click: click, button: button)
        }

        configureMainStatusItem()
        configureTapeStatusItem()
        installKeyboardShortcuts()

        settingsCancellable = store.$settings
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshKeyboardShortcuts()
            }

        DispatchQueue.main.async { [weak self] in
            self?.hideHiddenIcons()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.refreshProxyTargetCache(updateVisibleBox: false)
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
            button.toolTip = "Status Box"
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
            button.toolTip = "Status Box marker: Command-drag to move, right-click to open menu"
            button.target = self
            button.action = #selector(tapeItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        tapeItem = item
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            performBoxIconAction(store.settings.boxIconLeftClickAction)
            return
        }

        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            performBoxIconAction(store.settings.boxIconRightClickAction)
        } else if event.modifierFlags.contains(.option) {
            performBoxIconAction(.showBoxUI)
        } else {
            performBoxIconAction(store.settings.boxIconLeftClickAction)
        }
    }

    @objc private func tapeItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            return
        }

        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu(from: sender)
        }
    }

    private func toggleHiddenIcons() {
        if isHidden {
            showHiddenIcons()
        } else {
            hideHiddenIcons()
        }
    }

    private func performBoxIconAction(_ action: BoxIconAction) {
        switch action {
        case .toggleHiddenIcons:
            toggleHiddenIcons()
        case .showBoxUI:
            showHiddenIconsBox()
        case .showHiddenIcons:
            showHiddenIcons()
        case .hideHiddenIcons:
            hideHiddenIcons()
        case .openSettings:
            openSettings()
        case .none:
            break
        }
    }

    fileprivate func handleKeyboardShortcut(id: UInt32) {
        switch id {
        case StatusBoxHotKey.menuBarIconID:
            toggleHiddenIcons()
        case StatusBoxHotKey.boxUIID:
            toggleHiddenIconsBox()
        default:
            break
        }
    }

    private func toggleHiddenIconsBox() {
        if boxWindowController.isShowing {
            boxWindowController.close()
        } else {
            showHiddenIconsBox()
        }
    }

    private func showHiddenIcons() {
        revealHiddenIcons()
        scheduleAutoHideIfNeeded()
    }

    private func revealHiddenIcons() {
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        captureTask?.cancel()
        captureTask = nil
        boxWindowController.close()

        revealMenuBarIcons()
    }

    private func revealMenuBarIcons() {
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

    private func scheduleAutoHideIfNeeded(minimumDelay: TimeInterval = 0) {
        autoHideTimer?.invalidate()
        autoHideTimer = nil

        guard store.settings.autoHideEnabled else { return }

        let delay = max(store.settings.autoHideDelaySeconds, minimumDelay)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.hideHiddenIcons()
        }
        autoHideTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func installKeyboardShortcuts() {
        guard hotKeyEventHandler == nil else {
            refreshKeyboardShortcuts()
            return
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            statusBoxHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyEventHandler
        )
        if status != noErr {
            NSLog("[StatusBox] Failed to install hotkey handler: %d", status)
        }
        refreshKeyboardShortcuts()
    }

    private func refreshKeyboardShortcuts() {
        unregisterKeyboardShortcuts()
        guard hotKeyEventHandler != nil, !isRecordingShortcut else { return }

        let menuBarShortcut = store.settings.menuBarIconShortcut
        let boxUIShortcut = store.settings.boxUIShortcut

        menuBarIconHotKey = registerKeyboardShortcut(
            menuBarShortcut,
            id: StatusBoxHotKey.menuBarIconID
        )

        if boxUIShortcut == menuBarShortcut {
            NSLog("[StatusBox] Box UI shortcut matches menu bar shortcut; skipping duplicate registration")
        } else {
            boxUIHotKey = registerKeyboardShortcut(
                boxUIShortcut,
                id: StatusBoxHotKey.boxUIID
            )
        }
    }

    private func setShortcutRecordingActive(_ active: Bool) {
        isRecordingShortcut = active
        if active {
            unregisterKeyboardShortcuts()
        } else {
            refreshKeyboardShortcuts()
        }
    }

    private func registerKeyboardShortcut(
        _ shortcut: KeyboardShortcutSetting,
        id: UInt32
    ) -> EventHotKeyRef? {
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: StatusBoxHotKey.signature, id: id)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            carbonModifierFlags(for: shortcut.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            NSLog("[StatusBox] Failed to register shortcut %@: %d", shortcut.displayTitle, status)
            return nil
        }
        return hotKeyRef
    }

    private func unregisterKeyboardShortcuts() {
        if let hotKey = menuBarIconHotKey {
            UnregisterEventHotKey(hotKey)
            menuBarIconHotKey = nil
        }
        if let hotKey = boxUIHotKey {
            UnregisterEventHotKey(hotKey)
            boxUIHotKey = nil
        }
    }

    private func uninstallKeyboardShortcuts() {
        unregisterKeyboardShortcuts()
        if let handler = hotKeyEventHandler {
            RemoveEventHandler(handler)
            hotKeyEventHandler = nil
        }
    }

    private func carbonModifierFlags(for modifiers: ShortcutModifiers) -> UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) {
            flags |= UInt32(cmdKey)
        }
        if modifiers.contains(.option) {
            flags |= UInt32(optionKey)
        }
        if modifiers.contains(.control) {
            flags |= UInt32(controlKey)
        }
        if modifiers.contains(.shift) {
            flags |= UInt32(shiftKey)
        }
        return flags
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Settings", action: #selector(openSettingsMenuAction), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Status Box", action: #selector(quitMenuAction), keyEquivalent: "q"))

        for item in menu.items where item.target == nil {
            item.target = self
        }

        menu.popUp(positioning: nil, at: contextMenuAnchorPoint(for: button), in: button)
    }

    private func contextMenuAnchorPoint(for button: NSStatusBarButton) -> NSPoint {
        guard let window = button.window else {
            return NSPoint(x: button.bounds.midX, y: button.bounds.minY - 4)
        }

        let windowFrame = window.frame
        let windowCenter = NSPoint(x: windowFrame.midX, y: windowFrame.midY)
        let screen = MenuBarGeometry.screen(containing: windowCenter)
        let menuBarBottom = screen.map { MenuBarGeometry.menuBarRect(for: $0).minY } ?? windowFrame.minY
        let screenPoint = NSPoint(x: windowFrame.midX, y: menuBarBottom - 3)
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let buttonPoint = button.convert(windowPoint, from: nil)

        return NSPoint(
            x: max(button.bounds.minX, min(button.bounds.maxX, buttonPoint.x)),
            y: buttonPoint.y
        )
    }

    @objc private func showHiddenIconsMenuAction() {
        showHiddenIcons()
    }

    @objc private func hideHiddenIconsMenuAction() {
        hideHiddenIcons()
    }

    @objc private func showHiddenIconsBoxMenuAction() {
        showHiddenIconsBox()
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
                requestAccessibility: { ClickForwarder.requestAccessibilityAccess() },
                requestScreenRecording: { ScreenCapture.requestScreenCaptureAccess() },
                setShortcutRecordingActive: { [weak self] active in
                    self?.setShortcutRecordingActive(active)
                },
                setLaunchAtLogin: { enabled in LaunchAtLoginManager.setEnabled(enabled) }
            )
            settingsWindowController = SettingsWindowController(store: store, actions: actions)
        }
        settingsWindowController?.show()
    }

    private func showHiddenIconsBox() {
        guard store.settings.boxUIEnabled else {
            return
        }

        guard ClickForwarder.accessibilityTrusted else {
            ClickForwarder.requestAccessibilityAccess()
            return
        }

        guard let anchorFrame = statusItem?.button?.window?.frame,
              let tapeFrame = tapeItem?.button?.window?.frame,
              let screen = MenuBarGeometry.screen(containing: NSPoint(x: anchorFrame.midX, y: anchorFrame.midY)) else {
            return
        }

        autoHideTimer?.invalidate()
        autoHideTimer = nil
        captureTask?.cancel()

        let cachedTargets = cachedProxyTargets(before: tapeFrame)
        let hasLoadedCache = cachedProxyTargetsLoadedAt != nil
        boxWindowController.showProxyTargets(
            anchorFrame: anchorFrame,
            screen: screen,
            proxyTargets: cachedTargets,
            statusText: hasLoadedCache ? nil : "Loading"
        )
        scheduleAutoHideIfNeeded()
        refreshProxyTargetCache(
            anchorFrame: anchorFrame,
            tapeFrame: tapeFrame,
            updateVisibleBox: !hasLoadedCache || cachedTargets.isEmpty
        )
    }

    private func refreshProxyTargetCache(
        anchorFrame: NSRect? = nil,
        tapeFrame: NSRect? = nil,
        updateVisibleBox: Bool
    ) {
        guard ClickForwarder.accessibilityTrusted else {
            return
        }

        let resolvedAnchorFrame = anchorFrame ?? statusItem?.button?.window?.frame
        guard let resolvedTapeFrame = tapeFrame ?? tapeItem?.button?.window?.frame else {
            return
        }

        proxyTargetScanTask?.cancel()
        let excludedPID = ProcessInfo.processInfo.processIdentifier
        let runningApplications = MenuBarProxyScanner.runningApplicationInfo(
            excludingProcessIdentifier: excludedPID
        )
        let startedAt = Date()

        proxyTargetScanTask = Task { [weak self] in
            let targets = await Task.detached(priority: updateVisibleBox ? .userInitiated : .utility) {
                MenuBarProxyScanner.targetsBeforeMarker(
                    tapeFrame: resolvedTapeFrame,
                    runningApplications: runningApplications
                )
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self else { return }

                self.cachedProxyTargets = targets
                self.cachedProxyTargetsLoadedAt = Date()
                NSLog(
                    "[StatusBox] Proxy target cache refreshed %ld targets in %.1fms",
                    targets.count,
                    Date().timeIntervalSince(startedAt) * 1000
                )

                guard updateVisibleBox,
                      self.boxWindowController.isShowing,
                      let resolvedAnchorFrame,
                      let resolvedScreen = MenuBarGeometry.screen(
                        containing: NSPoint(x: resolvedAnchorFrame.midX, y: resolvedAnchorFrame.midY)
                      ) else {
                    return
                }

                self.boxWindowController.showProxyTargets(
                    anchorFrame: resolvedAnchorFrame,
                    screen: resolvedScreen,
                    proxyTargets: self.cachedProxyTargets(before: resolvedTapeFrame)
                )
                self.scheduleAutoHideIfNeeded()
            }
        }
    }

    private func cachedProxyTargets(before tapeFrame: NSRect) -> [MenuBarProxyTarget] {
        cachedProxyTargets
            .filter { $0.appKitFrame.maxX <= tapeFrame.minX + 1 }
            .sorted { $0.appKitFrame.minX < $1.appKitFrame.minX }
    }

    private func hiddenIconsCaptureRect(tapeFrame: NSRect, screen: NSScreen) -> NSRect {
        let menu = MenuBarGeometry.menuBarRect(for: screen)
        let right = max(menu.minX, min(menu.maxX, tapeFrame.minX - 2))
        let left = max(menu.minX, right - HiddenBoxLayout.maxCaptureWidth)
        return NSRect(x: left, y: menu.minY, width: max(1, right - left), height: menu.height)
    }

    private func forwardClickToMenuBar(click: MenuBarProxyClick, button: CGMouseButton) {
        guard ClickForwarder.accessibilityTrusted else {
            ClickForwarder.requestAccessibilityAccess()
            return
        }

        autoHideTimer?.invalidate()
        autoHideTimer = nil

        if !click.revealBeforeForwarding {
            guard let target = click.target else {
                boxWindowController.showStatus("Failed: No target")
                return
            }

            let liveTarget = MenuBarProxyScanner.refreshedTarget(from: target) ?? target
            let immediateItems = MenuBarProxyScanner.immediateProxyMenuItems(for: liveTarget)
            if showProxyMenuIfAvailable(
                for: liveTarget,
                items: immediateItems,
                anchorPoint: click.menuAnchorPoint
            ) {
                return
            }

            boxWindowController.showStatus("Unsupported app: \(liveTarget.displayName)")
            scheduleAutoHideIfNeeded(minimumDelay: 15)
            return
        }

        revealMenuBarIcons()

        captureTask?.cancel()
        captureTask = Task { [weak self] in
            guard let self else { return }
            var target: MenuBarProxyTarget?

            for attempt in 0..<HiddenBoxLayout.clickForwardMaxAttempts {
                let delay = attempt == 0
                    ? HiddenBoxLayout.clickForwardInitialDelayNanoseconds
                    : HiddenBoxLayout.clickForwardRetryDelayNanoseconds
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }

                target = await MainActor.run {
                    self.liveTarget(for: click)
                }

                if target != nil {
                    break
                }
            }

            let resolvedTarget = target
            let forwardResult = await MainActor.run {
                let targetForClick = resolvedTarget ?? self.visibleFallbackTarget(for: click)
                let point = targetForClick?.appKitClickPoint ?? click.appKitPoint
                guard self.isVisibleMenuBarPoint(point) else {
                    NSLog("[StatusBox] Proxy click target is not visible after reveal point=%@", NSStringFromPoint(point))
                    self.boxWindowController.showStatus("Failed: Target not found")
                    return ClickForwarder.ForwardResult.failed
                }

                if let targetForClick {
                    NSLog("[StatusBox] Forwarding native proxy click to target role=%@ title=%@ description=%@ point=%@", targetForClick.role, targetForClick.title, targetForClick.description, NSStringFromPoint(point))
                } else {
                    NSLog("[StatusBox] Forwarding native proxy click without AX target point=%@", NSStringFromPoint(point))
                }

                let result = ClickForwarder.postClick(at: point, button: button, target: targetForClick)
                let targetName = targetForClick?.displayName ?? "Point"
                self.boxWindowController.showStatus("\(result.title): \(targetName)")
                return result
            }

            await MainActor.run {
                if forwardResult.didForward {
                    self.scheduleAutoHideIfNeeded(minimumDelay: 10)
                } else {
                    self.scheduleAutoHideIfNeeded(minimumDelay: 30)
                }
            }
        }
    }

    private func showProxyMenuIfAvailable(
        for target: MenuBarProxyTarget,
        items: [MenuBarProxyMenuItem],
        anchorPoint: NSPoint?
    ) -> Bool {
        guard items.contains(where: { !$0.isSeparator }) else {
            return false
        }

        boxWindowController.showProxyMenu(
            for: target,
            items: items,
            anchorPoint: anchorPoint
        ) { [weak self] selection in
            guard let self else { return }
            let result = ClickForwarder.performProxyMenuSelection(selection, target: target)
            self.boxWindowController.showStatus("\(result.title): \(selection.item.title)")
            if result.didForward {
                self.scheduleAutoHideIfNeeded(minimumDelay: 10)
            } else {
                self.scheduleAutoHideIfNeeded(minimumDelay: 30)
            }
        }
        scheduleAutoHideIfNeeded(minimumDelay: 10)
        return true
    }

    private func liveTarget(for click: MenuBarProxyClick) -> MenuBarProxyTarget? {
        if let original = click.target,
           let refreshed = MenuBarProxyScanner.refreshedTarget(from: original),
           isVisibleMenuBarPoint(refreshed.appKitClickPoint) {
            return refreshed
        }

        if let original = click.target,
           let searchRect = currentVisibleHiddenIconsSearchRect(),
           let matched = MenuBarProxyScanner.matchingTarget(for: original, in: searchRect),
           isVisibleMenuBarPoint(matched.appKitClickPoint) {
            return matched
        }

        if click.searchRect.width > 0,
           click.searchRect.height > 0,
           let nearby = MenuBarProxyScanner.bestTarget(near: click.appKitPoint, in: click.searchRect),
           isVisibleMenuBarPoint(nearby.appKitClickPoint) {
            return nearby
        }

        return nil
    }

    private func visibleFallbackTarget(for click: MenuBarProxyClick) -> MenuBarProxyTarget? {
        guard let target = click.target,
              isVisibleMenuBarPoint(target.appKitClickPoint) else {
            return nil
        }
        return target
    }

    private func currentVisibleHiddenIconsSearchRect() -> NSRect? {
        guard let tapeFrame = tapeItem?.button?.window?.frame,
              let screen = MenuBarGeometry.screen(containing: NSPoint(x: tapeFrame.midX, y: tapeFrame.midY)) else {
            return nil
        }

        return hiddenIconsCaptureRect(tapeFrame: tapeFrame, screen: screen).insetBy(dx: -12, dy: -6)
    }

    private func isVisibleMenuBarPoint(_ point: NSPoint) -> Bool {
        NSScreen.screens.contains { screen in
            MenuBarGeometry.menuBarRect(for: screen)
                .insetBy(dx: -2, dy: -8)
                .contains(point)
        }
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
