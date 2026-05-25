import AppKit
import ServiceManagement
import SwiftUI

final class SettingsWindowController: NSWindowController {
    private let store: SettingsStore
    private let actions: SettingsActions

    init(store: SettingsStore, actions: SettingsActions) {
        self.store = store
        self.actions = actions

        let view = SettingsView(store: store, actions: actions)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Status Box 설정"
        window.setContentSize(NSSize(width: 620, height: 520))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        store.refreshDisplays()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

struct SettingsActions {
    var refreshHiddenRange: () -> Void
    var showHiddenIcons: () -> Void
    var hideHiddenIcons: () -> Void
    var requestAccessibility: () -> Void
    var requestScreenRecording: () -> Void
    var setLaunchAtLogin: (Bool) -> Void
}

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    let actions: SettingsActions

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("일반", systemImage: "gearshape") }
            displayTab
                .tabItem { Label("표시", systemImage: "menubar.rectangle") }
            monitorTab
                .tabItem { Label("모니터", systemImage: "display.2") }
            permissionTab
                .tabItem { Label("권한", systemImage: "lock.shield") }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 460)
    }

    private var generalTab: some View {
        Form {
            Toggle("로그인 시 자동 실행", isOn: Binding(
                get: { store.settings.launchAtLogin },
                set: { enabled in
                    store.update { $0.launchAtLogin = enabled }
                    actions.setLaunchAtLogin(enabled)
                }
            ))

            Picker("기본 표시 방식", selection: Binding(
                get: { store.settings.defaultDisplayMode },
                set: { mode in store.update { $0.defaultDisplayMode = mode } }
            )) {
                ForEach(DisplayMode.enabledCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            Toggle("자동 재숨김", isOn: Binding(
                get: { store.settings.autoHideEnabled },
                set: { enabled in store.update { $0.autoHideEnabled = enabled } }
            ))

            HStack {
                Text("자동 재숨김 시간")
                Slider(value: Binding(
                    get: { store.settings.autoHideDelaySeconds },
                    set: { value in store.update { $0.autoHideDelaySeconds = value } }
                ), in: 1...30, step: 1)
                Text("\(Int(store.settings.autoHideDelaySeconds))초")
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .formStyle(.grouped)
    }

    private var displayTab: some View {
        Form {
            Button("현재 테이프 기준으로 다시 숨기기") {
                actions.refreshHiddenRange()
            }

            HStack {
                Button("숨긴 아이콘 보기") {
                    actions.showHiddenIcons()
                }
                Button("다시 숨기기") {
                    actions.hideHiddenIcons()
                }
            }
        }
        .formStyle(.grouped)
    }

    private var monitorTab: some View {
        Form {
            ForEach(Array(store.settings.displayPolicies.values).sorted(by: { $0.displayName < $1.displayName })) { policy in
                Picker(policy.displayName, selection: Binding(
                    get: { policy.mode },
                set: { mode in store.setPolicy(displayId: policy.displayId, mode: mode) }
            )) {
                    ForEach(DisplayMode.enabledCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }

            Button("모니터 목록 새로고침") {
                store.refreshDisplays()
            }
        }
        .formStyle(.grouped)
    }

    private var permissionTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            PermissionRow(
                title: "손쉬운 사용",
                description: "박스 UI에서 보이지 않는 상태 아이콘을 찾고 해당 아이콘의 메뉴를 열 때 필요합니다.",
                granted: ClickForwarder.accessibilityTrusted,
                actionTitle: "권한 요청",
                action: actions.requestAccessibility
            )

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PermissionRow: View {
    let title: String
    let description: String
    let granted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(granted ? .green : .orange)
                Spacer()
                Button(actionTitle, action: action)
            }
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

enum LaunchAtLoginManager {
    static func setEnabled(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }

        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("StatusBox launch-at-login update failed: \(error.localizedDescription)")
        }
    }
}
