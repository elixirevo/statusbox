import AppKit
import Foundation

enum DisplayMode: String, Codable, CaseIterable, Identifiable {
    case menuBar
    case box
    case disabled

    var id: String { rawValue }

    static let enabledCases: [DisplayMode] = [.menuBar, .disabled]

    var title: String {
        switch self {
        case .menuBar:
            return "메뉴 막대에서 보기"
        case .box:
            return "박스 UI에서 보기"
        case .disabled:
            return "이 모니터에서는 표시하지 않기"
        }
    }
}

struct HiddenRange: Codable, Equatable {
    var displayId: String
    var leftX: CGFloat
    var rightX: CGFloat
    var updatedAt: Date

    var normalized: HiddenRange {
        HiddenRange(
            displayId: displayId,
            leftX: min(leftX, rightX),
            rightX: max(leftX, rightX),
            updatedAt: updatedAt
        )
    }
}

struct DisplayPolicy: Codable, Equatable, Identifiable {
    var displayId: String
    var displayName: String
    var mode: DisplayMode
    var lastSeenAt: Date

    var id: String { displayId }
}

struct AppSettings: Codable, Equatable {
    var launchAtLogin: Bool
    var defaultDisplayMode: DisplayMode
    var autoHideEnabled: Bool
    var autoHideDelaySeconds: Double
    var boxIconSize: Double
    var boxMaxRows: Int
    var calibrationModeEnabled: Bool
    var boxFeatureEnabled: Bool
    var displayPolicies: [String: DisplayPolicy]
    var hiddenRanges: [String: HiddenRange]

    static let defaults = AppSettings(
        launchAtLogin: false,
        defaultDisplayMode: .menuBar,
        autoHideEnabled: true,
        autoHideDelaySeconds: 5,
        boxIconSize: 22,
        boxMaxRows: 2,
        calibrationModeEnabled: false,
        boxFeatureEnabled: false,
        displayPolicies: [:],
        hiddenRanges: [:]
    )
}

extension NSScreen {
    var statusBoxDisplayId: String {
        if let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return number.stringValue
        }
        return localizedName
    }
}
