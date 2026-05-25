import AppKit
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

    func start() {
        boxWindowController.onForwardedClick = { [weak self] click, button in
            self?.forwardClickToMenuBar(click: click, button: button)
        }

        configureMainStatusItem()
        configureTapeStatusItem()

        DispatchQueue.main.async { [weak self] in
            self?.hideHiddenIcons()
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
        } else if event.modifierFlags.contains(.option) {
            showHiddenIconsBox()
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

    private func showContextMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "숨긴 아이콘 보기", action: #selector(showHiddenIconsMenuAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "다시 숨기기", action: #selector(hideHiddenIconsMenuAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "박스에서 보기", action: #selector(showHiddenIconsBoxMenuAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "현재 테이프 위치로 다시 숨기기", action: #selector(refreshRangeMenuAction), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "설정 열기", action: #selector(openSettingsMenuAction), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Status Box 종료", action: #selector(quitMenuAction), keyEquivalent: "q"))

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
                setLaunchAtLogin: { enabled in LaunchAtLoginManager.setEnabled(enabled) }
            )
            settingsWindowController = SettingsWindowController(store: store, actions: actions)
        }
        settingsWindowController?.show()
    }

    private func showHiddenIconsBox() {
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

        let proxyTargets = MenuBarProxyScanner.targetsBeforeMarker(
            tapeFrame: tapeFrame,
            excludingProcessIdentifier: ProcessInfo.processInfo.processIdentifier
        )
        NSLog("[StatusBox] Loaded %ld proxy targets before tape frame %@", proxyTargets.count, NSStringFromRect(tapeFrame))

        boxWindowController.showProxyTargets(
            anchorFrame: anchorFrame,
            screen: screen,
            proxyTargets: proxyTargets
        )
        scheduleAutoHideIfNeeded()
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
                boxWindowController.showStatus("Failed: 타겟 없음")
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

            let result = ClickForwarder.performHiddenStatusItemAccessibilityAction(
                on: liveTarget,
                button: button
            )
            if result.didForward {
                boxWindowController.showStatus("앱 UI 열림: \(liveTarget.displayName)")
                scheduleAutoHideIfNeeded(minimumDelay: 10)
            } else {
                boxWindowController.showStatus("지원하지 않는 앱: \(liveTarget.displayName)")
                scheduleAutoHideIfNeeded(minimumDelay: 15)
            }
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
                    self.boxWindowController.showStatus("Failed: 타겟 찾기 실패")
                    return ClickForwarder.ForwardResult.failed
                }

                if let targetForClick {
                    NSLog("[StatusBox] Forwarding native proxy click to target role=%@ title=%@ description=%@ point=%@", targetForClick.role, targetForClick.title, targetForClick.description, NSStringFromPoint(point))
                } else {
                    NSLog("[StatusBox] Forwarding native proxy click without AX target point=%@", NSStringFromPoint(point))
                }

                let result = ClickForwarder.postClick(at: point, button: button, target: targetForClick)
                let targetName = targetForClick?.displayName ?? "좌표"
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
