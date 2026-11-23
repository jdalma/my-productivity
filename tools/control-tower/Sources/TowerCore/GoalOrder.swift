import Foundation

// The order of each goal's tasks (T213; schema: tools/my-team/docs/board.md, goal-order). Read only, through
// `my-team api goal-order --json`: waves from the `## 순서` section of the team's goal files, with each node's board
// state. Fields this app does not know are ignored. Two files with one G number: my-team since T230 gives one goal
// with an error per file and no line; an older one gave both with the same `id`, so `path` tells goals apart.

/// One goal file: `waves` is empty when it has no `## 순서`, a cycle (`cycle` set) or syntax errors (`errors` set).
public struct GoalOrder: Decodable, Hashable, Sendable {
    public var id: String
    /// The file's `# G<n> …` heading without the id; nil for a file without a heading.
    public var title: String?
    public var path: String
    /// Each wave's nodes; a wave starts once every wave before it is complete.
    public var waves: [[GoalNode]]
    /// Refs of the nodes whose predecessors are all complete and that are not done, under way ones too.
    public var readyNow: [String]
    /// Task ids the order names that are not on the board.
    public var unregistered: [String]
    /// The refs around a cycle, first one repeated at the end (`["A","B","A"]`); nil without one.
    public var cycle: [String]?
    public var errors: [GoalOrderError]
}

/// A node of the order: a task (`T177`), or a range of its items (`T177:4-7`).
public struct GoalNode: Decodable, Hashable, Sendable {
    public var ref: String
    public var task: String
    /// The items of a range node; nil for the whole task.
    public var items: [Int]?
    /// Every predecessor, complete or not.
    public var after: [GoalRef]
    /// The board's title and state of `task`; nil when it is not on the board.
    public var title: String?
    public var state: String?
    /// done, ready_now, waiting, cancelled or unregistered.
    public var status: String
    /// The predecessors not complete yet, with their task's state (`unregistered` when not on the board).
    public var blockedBy: [GoalBlock]
}

public struct GoalRef: Decodable, Hashable, Sendable {
    public var ref: String
    public var task: String
    public var items: [Int]?
}

public struct GoalBlock: Decodable, Hashable, Sendable {
    public var ref: String
    public var state: String
}

/// A line of `## 순서` that does not read, or (`line` nil) a problem with the file itself: `text` is then its path.
public struct GoalOrderError: Decodable, Hashable, Sendable {
    public var line: Int?
    public var text: String
    public var reason: String
}

private struct GoalOrderAnswer: Decodable { var goals: [GoalOrder] }

public enum GoalOrderRead: Hashable, Sendable {
    case ok([GoalOrder])
    /// The my-team the app runs has no `goal-order` (before T212): the order view hides, the board works as before.
    case unsupported
    case failed(TaskBoardFailure)
}

func parseGoalOrder(_ r: CommandResult) -> GoalOrderRead {
    // commander's answer to a command it does not know: nothing on stdout, exit 1
    if r.status != 0, r.stdout.trimmed.isEmpty, r.stderr.contains("unknown command 'goal-order'") { return .unsupported }
    switch parseBoardAnswer(r, as: GoalOrderAnswer.self) {
    case .success(let a): return .ok(a.goals)
    case .failure(let f): return .failed(f)
    }
}

func readGoalOrder(team: String, bin: String, run: TaskBoardRunner) -> GoalOrderRead {
    switch runMyTeamApi("goal-order", input: ["team_name": team], bin: bin, run: run) {
    case .success(let r): parseGoalOrder(r)
    case .failure(let f): .failed(f)
    }
}

public func readGoalOrder(team: String) -> GoalOrderRead {
    readGoalOrder(team: team, bin: myTeamBin, run: liveTaskBoardRunner)
}

/// One read per team in `teams`. The app passes every open task board window's team, whichever view it shows (D#13:
/// a task's detail lists its 선행·후행 in the panels view too). With no window open, my-team is never run.
func readGoalOrders(openViews teams: Set<String>, bin: String, run: TaskBoardRunner) -> [String: GoalOrderRead] {
    var out: [String: GoalOrderRead] = [:]
    for team in teams { out[team] = readGoalOrder(team: team, bin: bin, run: run) }
    return out
}

public func readGoalOrders(openViews teams: Set<String>) -> [String: GoalOrderRead] {
    readGoalOrders(openViews: teams, bin: myTeamBin, run: liveTaskBoardRunner)
}
