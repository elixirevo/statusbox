import AppKit
import CoreGraphics
import ScreenCaptureKit

enum ScreenCapture {
    struct DisplayDescriptor {
        let displayId: CGDirectDisplayID
        let frame: CGRect
        let scale: CGFloat
    }

    enum CaptureResult {
        case image(CGImage)
        case permissionDenied
        case failed(String)

        var image: CGImage? {
            if case let .image(image) = self {
                return image
            }
            return nil
        }

        var placeholderText: String {
            switch self {
            case .image:
                return ""
            case .permissionDenied:
                return "화면 기록 권한을 허용한 뒤 앱을 다시 실행하세요"
            case .failed:
                return "메뉴 막대 이미지를 가져올 수 없습니다"
            }
        }
    }

    static func descriptor(for screen: NSScreen) -> DisplayDescriptor? {
        guard let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return DisplayDescriptor(
            displayId: CGDirectDisplayID(displayNumber.uint32Value),
            frame: screen.frame,
            scale: screen.backingScaleFactor
        )
    }

    static func capture(rect: NSRect, display: DisplayDescriptor) async -> CaptureResult {
        if #available(macOS 15.2, *) {
            do {
                let image = try await SCScreenshotManager.captureImage(in: screenCaptureRect(fromAppKitRect: rect))
                return .image(image)
            } catch {
                if !hasScreenCaptureAccess {
                    return .permissionDenied
                }
                return .failed(error.localizedDescription)
            }
        }

        if let image = legacyCapture(rect: rect, display: display) {
            return .image(image)
        }

        if !hasScreenCaptureAccess {
            return .permissionDenied
        }
        return .failed("Legacy CoreGraphics capture returned nil.")
    }

    static var hasScreenCaptureAccess: Bool {
        if #available(macOS 10.15, *) {
            return CGPreflightScreenCaptureAccess()
        }
        return true
    }

    static func requestScreenCaptureAccess() {
        if #available(macOS 10.15, *) {
            _ = CGRequestScreenCaptureAccess()
        }
    }

    private static func screenCaptureRect(fromAppKitRect rect: NSRect) -> CGRect {
        let desktopTop = NSScreen.screens.map(\.frame.maxY).max() ?? rect.maxY
        return CGRect(
            x: rect.minX,
            y: desktopTop - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private static func legacyCapture(rect: NSRect, display: DisplayDescriptor) -> CGImage? {
        let displayRect = CGRect(
            x: (rect.minX - display.frame.minX) * display.scale,
            y: (display.frame.maxY - rect.maxY) * display.scale,
            width: rect.width * display.scale,
            height: rect.height * display.scale
        )
        return CGDisplayCreateImage(display.displayId, rect: displayRect)
    }
}
