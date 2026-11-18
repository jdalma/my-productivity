import ServiceManagement
import SwiftUI
import TowerCore

/// The Settings window (⌘,): launch at login via SMAppService (off until the user turns it on), appearance, and
/// the diff layout the 보기 menu also switches.
/// Registration only works from the `.app` bundle; elsewhere the error is shown.
struct SettingsView: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled
    @State private var error: String?
    @AppStorage(AppearanceChoice.storageKey) private var appearance = AppearanceChoice.system.rawValue
    @AppStorage(DiffLayout.storageKey) private var diffLayout = DiffLayout.unified.rawValue
    @AppStorage(UsageAdvisor.autoKey) private var adviceAuto = true

    var body: some View {
        Form {
            Section("일반") {
                Toggle("로그인 시 열기", isOn: Binding(get: { enabled }, set: { setLoginItem($0) }))
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Picker("화면", selection: $appearance) {
                    ForEach(AppearanceChoice.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                }
                Picker("diff 기본 보기", selection: $diffLayout) {
                    ForEach(DiffLayout.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                }
                EditorPicker()
            }
            Section {
                Toggle("하루 한 번 사용량 분석", isOn: $adviceAuto)
            } header: {
                Text("대시보드")
            } footer: {
                Text("그날 대시보드를 처음 열 때 claude를 한 번 실행해 새는 곳의 분석과 조언을 받습니다. 집계 숫자와 프로젝트 폴더 이름만 넘기고 대화 내용은 넘기지 않습니다. 꺼도 새는 곳의 \"분석과 조언\" 버튼으로 실행할 수 있습니다.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .background(TestWindowPlacement())
    }

    private func setLoginItem(_ on: Bool) {
        do {
            try switchLoginItem(on, register: { try SMAppService.mainApp.register() },
                                unregister: { try SMAppService.mainApp.unregister() })
            error = nil
        } catch let e {
            error = e.localizedDescription
        }
        enabled = towerDryRun != nil ? on : SMAppService.mainApp.status == .enabled
    }
}

/// Under `TOWER_DRY_RUN` the switch is a line in that file and the system's login items are left alone (T96).
func switchLoginItem(_ on: Bool, dryRun: String? = towerDryRun,
                     register: () throws -> Void, unregister: () throws -> Void) throws {
    if let dryRun { return recordDryRun("login-item \(on ? "register" : "unregister")", to: dryRun) }
    try on ? register() : unregister()
}
