import ServiceManagement
import SwiftUI

/// Settings pane: launch at login via SMAppService (off until the user turns it on).
/// Registration only works from the `.app` bundle; elsewhere the error is shown.
struct SettingsView: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled
    @State private var error: String?

    var body: some View {
        Form {
            Toggle("로그인 시 열기", isOn: Binding(get: { enabled }, set: { setLoginItem($0) }))
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
    }

    private func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch let e {
            error = e.localizedDescription
        }
        enabled = SMAppService.mainApp.status == .enabled
    }
}
