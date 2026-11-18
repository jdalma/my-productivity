import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TowerApp

@Test func aFailureGoesOnTheBoardWindowWhileItIsTheKeyWindow() {
    #expect(failureRoute(OpenWindows(board: true, boardKey: true)) == .sheet)
    #expect(failureRoute(OpenWindows(board: true, diffs: [DiffTarget(workspace: "/example")], boardKey: true)) == .sheet)
}

@Test func aFailureWithTheBoardBehindOrClosedGoesToNotificationCenter() {
    #expect(failureRoute(OpenWindows(board: true, boardKey: false)) == .notification)
    #expect(failureRoute(OpenWindows()) == .notification)
    #expect(failureRoute(OpenWindows(board: false, diffs: [DiffTarget(workspace: "/example")])) == .notification)
}

@Test func theFoldedInfoLineListsTheFactsInOrderWithoutTheEmptyOnes() {
    let facts = [("에이전트", "Claude Code"), ("워크스페이스", "~/example"), ("branch", ""), ("tmux", "example · pane %1")]
    #expect(DetailInfo.summary(facts, expanded: false) == "Claude Code · ~/example · example · pane %1")
}

@Test func theOpenInfoLineLeavesTheValuesToTheTable() {
    #expect(DetailInfo.summary([("에이전트", "Claude Code")], expanded: true) == nil)
}

/// The board window's least height comes from its content's, asked with no room at all: a fact that grows a line
/// for every few characters there made the window taller than the screen with the info open, the board slid up
/// under the toolbar and the terminal ran to its largest font (T80).
@MainActor @Test func theOpenInfoTableAsksForLittleHeightWhateverTheWidth() {
    let old = UserDefaults.standard.object(forKey: DetailInfo.storageKey)
    defer { UserDefaults.standard.set(old, forKey: DetailInfo.storageKey) }
    let facts = [("에이전트", "Claude"), ("워크스페이스", "~/IdeaProjects/example-plugin/.worktrees/detail"), ("branch", "feat/example-detail"),
                 ("tmux", "my-team-example · pane %12 · attached"), ("메일", "안 읽은 메일 2 · 답 기다림 1"),
                 ("diff 범위", "팀 공유 폴더 (pm, reviewer와 함께)")]
    for expanded in [false, true] {
        UserDefaults.standard.set(expanded, forKey: DetailInfo.storageKey)
        let least = NSHostingController(rootView: DetailInfoView(facts: facts)).sizeThatFits(in: .zero)
        // six facts of at most two lines each, the label line and the spacing: under 300 points at the standard size
        #expect(least.height < 300, "expanded \(expanded): \(least)")
    }
}
