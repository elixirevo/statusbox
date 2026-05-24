import AppKit
import ApplicationServices
import CoreGraphics

enum ClickForwarder {
    static var accessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibilityAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func postClick(at appKitPoint: NSPoint, button: CGMouseButton) {
        let quartzPoint = MenuBarGeometry.quartzPoint(fromAppKitPoint: appKitPoint)
        let downType: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp

        guard let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: quartzPoint, mouseButton: button),
              let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: quartzPoint, mouseButton: button) else {
            return
        }

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    static func openAccessibilitySettings() {
        openSystemSettings(path: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openScreenRecordingSettings() {
        openSystemSettings(path: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private static func openSystemSettings(path: String) {
        guard let url = URL(string: path) else { return }
        NSWorkspace.shared.open(url)
    }
}
