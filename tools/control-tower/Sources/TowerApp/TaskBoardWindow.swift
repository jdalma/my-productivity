import AppKit
import SwiftUI
import TowerCore

/// What a task board window shows: one team's board (T86). One window per team, as a diff window is per workspace.
struct TaskBoardTarget: Codable, Hashable {
    var team: String
}

/// The task each team's task board window has picked. Kept when the window closes, so it opens again as it was.
struct TaskBoardPicks: Equatable {
    private(set) var tasks: [String: String] = [:]

    func task(of team: String) -> String? { tasks[team] }

    /// The window a sidebar line or a worker's task line opens: the team's. A task line also picks its task;
    /// the sidebar line keeps the window's pick.
    mutating func open(_ team: String, task: String? = nil) -> TaskBoardTarget {
        if let task { tasks[team] = task }
        return TaskBoardTarget(team: team)
    }

    mutating func pick(_ task: String?, on team: String) { tasks[team] = task }

    /// The task details to read: the picks of the windows on screen; none without a window. A picked decision is on
    /// the board already, so it reads nothing (T147).
    func reads(open: Set<String>) -> [TaskRef] {
        tasks.filter { open.contains($0.key) && !isDecisionId($0.value) }.map { TaskRef(team: $0.key, task: $0.value) }.sorted { $0.team < $1.team }
    }
}

/// A team's task board in a window of its own: the task list, and the picked task's detail beside it or in its place.
/// Picking a task here is not a step of the board window's back and forward.
struct TaskBoardWindow: View {
    let target: TaskBoardTarget
    let tower: Tower
    @Environment(\.openWindow) private var openWindow
    @AppStorage(FontScale.storageKey) private var storedScale = FontScale.standard.value
    @State private var searchFocus = 0

    var body: some View {
        let picked = tower.taskPicks.task(of: target.team)
        let navigation = WindowNavigation(
            escape: picked == nil ? nil : ("작업 상세 닫기", { tower.taskPicks.pick(nil, on: target.team) }),
            search: { searchFocus += 1 },
            reload: { tower.reloadTaskBoards() })
        Group {
            if let board = tower.board {
                TaskBoardView(team: target.team, state: tower.taskBoards[target.team],
                              model: sidebarModel(board: board, history: [], query: "", filter: .claude, historyLimit: 0,
                                                  home: homeDirectory()),
                              selectedTask: picked,
                              family: picked.flatMap { tower.taskFamilies[TaskRef(team: target.team, task: $0)] },
                              pick: { tower.taskPicks.pick($0, on: target.team) },
                              select: { id in
                                  tower.boardSelectRequest = id
                                  openWindow(id: "board")
                              },
                              openInBoard: { request, row in
                                  tower.ideOpenRequest = request
                                  tower.boardSelectRequest = row
                                  openWindow(id: "board")
                              },
                              reload: { tower.reloadTaskBoards() },
                              navigation: navigation,
                              searchFocus: searchFocus,
                              goalOrder: tower.goalOrders[target.team])
            } else {
                ProgressView("수집 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("\(target.team) 작업판")
        .scaledFont(.body)
        .frame(minWidth: 520, minHeight: 360)
        .environment(\.boardFontScale, FontScale(stored: storedScale).value)
        .background { FontScaleAlias(stored: $storedScale) }
        .background(NotRestorable())
        .background(WindowTab(kind: .taskBoard, title: target.team))
        .background(TestWindowPlacement())
        .focusedSceneValue(\.windowNavigation, navigation)
        .onAppear { tower.windows.taskBoards.insert(target.team) }
        .onDisappear { tower.windows.taskBoards.remove(target.team) }
    }
}
