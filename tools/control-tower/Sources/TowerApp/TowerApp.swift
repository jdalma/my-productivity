import SwiftUI
import TowerCore

@main
struct TowerApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    private var tower: Tower { delegate.tower }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(tower: tower)
        } label: {
            MenuBarLabel(tower: tower)
        }
        .menuBarExtraStyle(.window)

        Window("Control Tower", id: "board") {
            BoardView(tower: tower)
        }
        .defaultSize(width: 1200, height: 760)

        Settings {
            SettingsView()
        }
    }
}

/// The menu bar icon and waiting count. Always on screen, so it is where a launch or reopen opens the board
/// and where the stored appearance is applied, board window open or not.
private struct MenuBarLabel: View {
    let tower: Tower
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppearanceChoice.storageKey) private var storedAppearance = AppearanceChoice.system.rawValue

    var body: some View {
        let n = tower.myTurn
        Image(systemName: "antenna.radiowaves.left.and.right")
            .onChange(of: tower.boardOpenRequested, initial: true) { _, requested in
                guard requested else { return }
                tower.boardOpenRequested = false
                openWindow(id: "board")
                NSApp.activate()
            }
            .onChange(of: storedAppearance, initial: true) { _, stored in AppearanceChoice(stored: stored).apply() }
        if n > 0 { Text("\(n)") }
    }
}

struct MenuContent: View {
    let tower: Tower
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = tower.myTeamError {
                MyTeamErrorLine(error: error).font(.callout).padding(.bottom, 4)
            }
            if let board = tower.board {
                let menu = menuModel(board, history: tower.history, home: NSHomeDirectory())
                if menu.isEmpty {
                    Text("열린 터미널 없음").foregroundStyle(.secondary).padding(.vertical, 4)
                }
                ForEach(menu.teams, id: \.name) { t in
                    MenuLine(leading: .kind(.team), title: t.name, trailing: waitingText(t.waiting) ?? "",
                             hint: "보드를 열고 이 팀을 선택") {
                        tower.boardSelectRequest = t.select
                        openBoard()
                    }
                }
                ForEach(menu.agents, id: \.agent) { g in
                    HStack(spacing: 6) {
                        KindTag(kind: .agent(g.agent))
                        Spacer(minLength: 8)
                        Text(waitingText(g.waiting) ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 6).padding(.bottom, 2)
                    ForEach(g.rows, id: \.id) { row in
                        MenuLine(leading: .status(row.badge), title: row.title, trailing: row.badge.elapsed,
                                 hint: "이 세션의 터미널로 이동") {
                            tower.focus(row.session.handle)
                        }
                        .help(badgeLabel(row.badge) + "\n" + row.path)
                    }
                }
                Divider().padding(.vertical, 4)
            }
            Button("보드 열기", action: openBoard)
                .keyboardShortcut("b")
            SettingsLink { Text("설정…") }
                .keyboardShortcut(",")
            Divider().padding(.vertical, 4)
            Button("Control Tower 종료") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .padding(10)
        .frame(width: 320, alignment: .leading)
    }

    private func openBoard() {
        openWindow(id: "board")
        NSApp.activate()
    }
}

/// One dropdown line. A team: kind label, name, waiting count; it opens the board on the team.
/// A session: status icon, title, elapsed time; it focuses the session's terminal.
private struct MenuLine: View {
    enum Leading {
        case kind(LineKind)
        case status(RowBadge)
    }

    let leading: Leading
    let title: String
    let trailing: String
    let hint: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                switch leading {
                case .kind(let kind): KindTag(kind: kind)
                case .status(let badge): StatusIconView(badge: badge)
                }
                Text(title).font(.headline).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 8)
                Text(trailing).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .padding(.vertical, 4)
        }
        .accessibilityHint(hint)
    }
}

/// One line saying teams are missing because my-team failed; the full text is in the tooltip.
/// The caller sets the font: fixed in the dropdown, scaled in the board window.
struct MyTeamErrorLine: View {
    let error: String

    var body: some View {
        Label("팀 정보를 읽지 못함: \(error)", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(error)
    }
}
