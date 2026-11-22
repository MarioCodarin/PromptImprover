import Foundation
import ServiceManagement

/// "Open at login" via SMAppService (macOS 13+). No helper app or LaunchAgent plist needed.
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published var lastError: String?

    var isEnabled: Bool { status == .enabled }
    var needsApproval: Bool { status == .requiresApproval }

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func refresh() { status = SMAppService.mainApp.status }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// Turns it on once, the first time the bundled app runs. Never re-enables it if the user switched it off.
    static func enableOnFirstLaunch() {
        let key = "loginItem.didSetup"
        guard Bundle.main.bundlePath.hasSuffix(".app"),
              !UserDefaults.standard.bool(forKey: key) else { return }
        try? SMAppService.mainApp.register()
        UserDefaults.standard.set(true, forKey: key)
    }
}
