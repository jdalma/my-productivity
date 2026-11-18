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
        .menuBarExtraStyle(.menu)

        Window("Control Tower", id: "board") {
            BoardView(tower: tower)
        }
        .defaultSize(width: 1200, height: 760)
        .commands { TowerCommands(tower: tower) }

        // one window per workspace: opening a workspace's diff again brings its window forward
        WindowGroup("변경", id: "diff", for: DiffTarget.self) { $target in
            if let target { DiffWindow(target: target, tower: tower) } else { ClosesItself() }
        }
        .defaultSize(width: 1100, height: 760)

        // one window per team: opening a team's task board again brings its window forward
        WindowGroup("작업판", id: "taskBoard", for: TaskBoardTarget.self) { $target in
            if let target { TaskBoardWindow(target: target, tower: tower) } else { ClosesItself() }
        }
        .defaultSize(width: 1100, height: 760)

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
                OpenWindows.show { openWindow(id: "board") }
            }
            .onChange(of: storedAppearance, initial: true) { _, stored in AppearanceChoice(stored: stored).apply() }
            .onChange(of: tower.taskBoardOpenRequest) { _, target in
                guard let target else { return }
                tower.taskBoardOpenRequest = nil
                OpenWindows.show { openWindow(id: "taskBoard", value: target) }
            }
        if n > 0 { Text("\(n)") }
    }
}

/// The menu bar menu, a system menu (T125, MU7): highlight, arrow keys, Return and the shortcuts are the system's.
struct MenuContent: View {
    let tower: Tower
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let error = tower.myTeamError {
            // one short line; the board window shows the whole error (R48 L1)
            Button(menuErrorTitle(error), action: openBoard)
        }
        if let board = tower.board {
            let sections = menuSections(menuModel(board, history: tower.history, home: homeDirectory(), taskBoards: tower.taskBoardStatuses))
            if sections.isEmpty { Text("열린 터미널 없음") }
            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                        Button { go(line.target) } label: { Label(line.title, systemImage: line.symbol) }
                    }
                }
            }
            Divider()
        }
        Button("보드 열기", action: openBoard).keyboardShortcut("b")
        SettingsLink { Text("설정…") }.keyboardShortcut(",")
        Divider()
        Button("Control Tower 종료") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func go(_ target: MenuItemLine.Target) {
        switch target {
        case .terminal(let handle): tower.focus(handle)
        case .board(let row):
            tower.boardSelectRequest = row
            openBoard()
        case .decision(let team, let id):
            let target = tower.taskPicks.open(team, task: id)
            OpenWindows.show { openWindow(id: "taskBoard", value: target) }
        }
    }

    private func openBoard() { OpenWindows.show { openWindow(id: "board") } }
}

/// The board window's line saying teams are missing because my-team failed; the full text is in the tooltip.
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

/// The menu's line for a my-team failure: its first line, cut to `menuErrorLength` characters, and where the whole
/// error is. A menu item has no line limit and no tooltip, so a long error would be one very wide item (R48 L1).
func menuErrorTitle(_ error: String) -> String {
    let first = error.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    let cut = first.count > menuErrorLength ? String(first.prefix(menuErrorLength - 1)) + "…" : first
    return "팀 정보를 읽지 못함: \(cut) · 보드에서 전체 보기"
}

let menuErrorLength = 60

/// Esc in a search field that holds text clears it, as Esc does in a field. The menu's Esc is a key equivalent, and
/// AppKit offers those to the menu before the field sees the key, so the menu does the field's part first (R3 L3).
/// Deleting through the field editor tells the field's delegate, as typing does.
@MainActor func clearSearchForEscape(in window: NSWindow?) -> Bool {
    guard let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor, editor.delegate is NSSearchField,
          !editor.string.isEmpty else { return false }
    editor.selectAll(nil)
    editor.deleteBackward(nil)
    return true
}

/// What the 이동 and 파일 menus do in the key window; a nil action leaves its item disabled.
struct WindowNavigation {
    /// Esc: the window's own label and step back.
    var escape: (label: String, run: () -> Void)?
    var back: (() -> Void)?
    var forward: (() -> Void)?
    var search: (() -> Void)?
    var reload: (() -> Void)?
    /// The selected session's diff window.
    var openDiff: (() -> Void)?
    /// The task board window of the selected worker's team.
    var openTaskBoard: (() -> Void)?

    /// A back or forward that is there only when the history has somewhere to go, so its menu item is off when the
    /// window's toolbar button is (R3 L1).
    static func step(_ possible: Bool, _ go: @escaping () -> Void) -> (() -> Void)? { possible ? go : nil }
}

extension FocusedValues {
    @Entry var windowNavigation: WindowNavigation?
}

/// The main menu while a window is open (T73). Edit, Window and the full screen item are the system's; the
/// shortcuts are the ones the windows had as hidden buttons.
struct TowerCommands: Commands {
    let tower: Tower
    @FocusedValue(\.windowNavigation) private var nav
    @FocusedValue(\.panelArrange) private var arrange
    @AppStorage(FontScale.storageKey) private var storedScale = FontScale.standard.value
    @AppStorage(DiffLayout.storageKey) private var diffLayout = DiffLayout.unified.rawValue

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("새 팀") { tower.newTeam() }
            Divider()
            Button("다시 읽기") { nav?.reload?() }.keyboardShortcut("r").disabled(nav?.reload == nil)
        }
        CommandGroup(before: .toolbar) {
            let scale = FontScale(stored: storedScale)
            Button("글자 크게") { storedScale = scale.bigger().value }.keyboardShortcut("+")
            Button("글자 작게") { storedScale = scale.smaller().value }.keyboardShortcut("-")
            Button("기본 크기") { storedScale = FontScale.standard.value }.keyboardShortcut("0")
            Divider()
            Picker("diff", selection: $diffLayout) {
                ForEach(DiffLayout.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
            Button("변경 보기") { nav?.openDiff?() }.keyboardShortcut("d").disabled(nav?.openDiff == nil)
            Button("작업판 보기") { nav?.openTaskBoard?() }.keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(nav?.openTaskBoard == nil)
            // a task board's layout (T153; hig §7.4, §8.4): the item names what moves
            Menu("묶음") {
                Button(arrange?.subject.map { "\($0) 위로" } ?? "위로") { arrange?.up?() }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option]).disabled(arrange?.up == nil)
                Button(arrange?.subject.map { "\($0) 아래로" } ?? "아래로") { arrange?.down?() }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option]).disabled(arrange?.down == nil)
                // a panel to the next column (T154; hig §7.4): off for a task line, and where there is no column to go to
                Button(arrange?.subject.map { "\($0) 왼쪽 단으로" } ?? "왼쪽 단으로") { arrange?.left?() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option]).disabled(arrange?.left == nil)
                Button(arrange?.subject.map { "\($0) 오른쪽 단으로" } ?? "오른쪽 단으로") { arrange?.right?() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option]).disabled(arrange?.right == nil)
                Divider()
                Button("기본 배치로 되돌리기") { arrange?.reset?() }.disabled(arrange?.reset == nil)
            }
            .disabled(arrange == nil)
            Divider()
        }
        CommandMenu("이동") {
            Button(nav?.escape?.label ?? "닫기") { if !clearSearchForEscape(in: NSApp.keyWindow) { nav?.escape?.run() } }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(nav?.escape == nil)
            Button("뒤로") { nav?.back?() }.keyboardShortcut("[").disabled(nav?.back == nil)
            Button("앞으로") { nav?.forward?() }.keyboardShortcut("]").disabled(nav?.forward == nil)
            Divider()
            Button("검색") { nav?.search?() }.keyboardShortcut("f").disabled(nav?.search == nil)
        }
    }
}
