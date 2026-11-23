import SwiftUI
import TowerCore

// The task board's 순서 view (T214; design design/goal-order-view.md §2, §3): a section per goal, a column per wave,
// a card per node. Read only: a card picks its task as a line of the panels does.

/// The View menu's 상태별로 보기 ⌘1 and 순서로 보기 ⌘2 for the task board window in front (design §1).
struct BoardModeControl {
    var mode: TaskBoardMode
    /// my-team answers goal-order: an older one has neither item (design §3).
    var supported: Bool
    var set: (TaskBoardMode) -> Void
}

extension FocusedValues {
    @Entry var boardMode: BoardModeControl?
}

struct GoalOrderList: View {
    let read: GoalOrderRead?
    let query: String
    let selected: String?
    let pick: (String?) -> Void
    @Binding var prefs: TaskPanelPrefs
    let openGoalFile: (GoalOrder) -> Void
    let reload: () -> Void
    /// The task whose card the detail's 목표 line asked for: its goal opens and the card scrolls into view, also when
    /// this view has just appeared for it (T214 R1 S1). `scrolled` hands it back once done.
    let scrollTo: OrderScroll?
    let scrolled: () -> Void
    @State private var width: CGFloat = 0
    @Environment(\.boardFontScale) private var scale

    var body: some View {
        switch read {
        case .ok(let goals) where goals.isEmpty:
            ContentUnavailableView {
                Label("목표가 없습니다", systemImage: "list.number")
            } description: {
                Text("요청을 2개 이상의 작업으로 나누면 pm이 팀 문서 폴더의 goals/ 에 목표 파일을 씁니다.")
            }
        case .ok(let goals): list(goalsInOrder(goals))
        case .failed(let f):
            let p = taskBoardProblem(f, bin: myTeamBin)
            ContentUnavailableView {
                Label("순서를 읽지 못함", systemImage: "exclamationmark.triangle")
            } description: {
                Text("\(p.title)\n\(p.detail)").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            } actions: {
                Button("다시 읽기", action: reload).help("다시 읽기 (⌘R)")
            }
        case .unsupported, nil:
            ProgressView("순서를 읽는 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func list(_ goals: [GoalOrder]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // not lazy: a card in a goal far down must be there to scroll to (a team has a few goals)
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(goals, id: \.path) { g in section(g) }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { move(.up, goals) }
            .onKeyPress(.downArrow) { move(.down, goals) }
            .onKeyPress(.leftArrow) { move(.left, goals) }
            .onKeyPress(.rightArrow) { move(.right, goals) }
            .task(id: scrollTo) {
                guard let to = scrollTo else { return }
                defer { scrolled() }
                // the goal the line was for, a task may be in several (R2 S1)
                guard let g = goals.first(where: { $0.path == to.goal }),
                      let n = g.waves.joined().first(where: { $0.task == to.task }) else { return }
                prefs.goalFolds[g.path] = false
                // the goal unfolds first; its cards are laid out on the next pass
                try? await Task.sleep(for: .milliseconds(150))
                withAnimation { proxy.scrollTo(cardID(g, n), anchor: .center) }
            }
        }
    }

    // MARK: A goal

    @ViewBuilder
    private func section(_ g: GoalOrder) -> some View {
        let tag = GoalTag(g)
        let found = g.waves.joined().contains { goalCardMatches($0, query: query) }
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        if tag == .noOrder {
            // nothing to unfold: no triangle, the name where the others' names start
            head(g, tag).padding(.leading, 20 * scale).help("목표 파일에 ## 순서 섹션이 없습니다")
                .accessibilityElement(children: .combine).accessibilityLabel(goalSpoken(g))
        } else {
            DisclosureGroup(isExpanded: Binding {
                !goalFolded(g, stored: prefs.goalFolds) && (!searching || found || g.waves.isEmpty)
            } set: { open in
                prefs.goalFolds[g.path] = !open
            }) {
                body(g).padding(.top, 8)
            } label: {
                head(g, tag)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(goalSpoken(g))
        }
    }

    private func head(_ g: GoalOrder, _ tag: GoalTag) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(g.id).scaledFont(.callout, design: .monospaced).foregroundStyle(.secondary)
            Text(g.title ?? (g.path as NSString).lastPathComponent).scaledFont(.headline, weight: .semibold).lineLimit(1)
            Spacer(minLength: 8)
            tagView(tag)
        }
        .contentShape(.rect)
        .contextMenu { Button("목표 파일 열기") { openGoalFile(g) } }
    }

    @ViewBuilder
    private func tagView(_ tag: GoalTag) -> some View {
        switch tag {
        case .startable:
            Label(tag.text, systemImage: "play.circle.fill").scaledFont(.callout).foregroundStyle(Color.accentColor)
        case _ where tag.warns:
            Label(tag.text, systemImage: "exclamationmark.triangle.fill").scaledFont(.callout).foregroundStyle(TaskColor.orange)
        default:
            Text(tag.text).scaledFont(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func body(_ g: GoalOrder) -> some View {
        if let cycle = g.cycle {
            VStack(alignment: .leading, spacing: 6) {
                Label("순서에 순환이 있어 단계를 계산할 수 없습니다", systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(.callout, weight: .semibold).foregroundStyle(TaskColor.orange)
                Text(cycle.joined(separator: " → ")).scaledFont(.callout, design: .monospaced).textSelection(.enabled)
                Text("pm이 목표 파일의 ## 순서를 고쳐야 합니다.").scaledFont(.callout).foregroundStyle(.secondary)
                Button("목표 파일 열기") { openGoalFile(g) }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TaskColor.orange.opacity(0.1), in: .rect(cornerRadius: 8))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let line = goalErrorLine(g.errors) {
                    Label(line, systemImage: "exclamationmark.triangle.fill").scaledFont(.callout)
                        .foregroundStyle(TaskColor.orange).lineLimit(2)
                        .help(g.errors.map { "\($0.line.map { "\($0): " } ?? "")\($0.text) — \($0.reason)" }.joined(separator: "\n"))
                }
                if wavesStack(waves: g.waves.count, width: max(0, width - 24), scale: scale) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(g.waves.enumerated()), id: \.offset) { i, w in
                            let h = WaveHead(w, number: i + 1)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("단계 \(h.number) · \(h.count)").scaledFont(.subheadline, weight: .semibold)
                                    .foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                                cards(g, w)
                            }
                            .accessibilityElement(children: .contain).accessibilityLabel(h.spoken)
                        }
                    }
                } else {
                    HStack(alignment: .top, spacing: waveSpacing) {
                        ForEach(Array(g.waves.enumerated()), id: \.offset) { i, w in
                            column(g, w, WaveHead(w, number: i + 1))
                        }
                    }
                    // behind the cards: an arrow shows in the gaps between them, and never covers a card's words
                    .backgroundPreferenceValue(CardBounds.self) { cards in
                        GeometryReader { geo in
                            GoalArrows(edges: goalEdges(g), cards: cards.mapValues { geo[$0] })
                        }
                    }
                }
            }
        }
    }

    private func column(_ g: GoalOrder, _ w: [GoalNode], _ h: WaveHead) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                if h.allComplete { Image(systemName: "checkmark.circle.fill").foregroundStyle(TaskColor.green) }
                Text("단계 \(h.number)").scaledFont(.subheadline, weight: .semibold)
                Spacer(minLength: 4)
                Text(h.count).scaledFont(.caption1).monospacedDigit().foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
            cards(g, w)
        }
        .frame(minWidth: waveColumnWidth * scale, maxWidth: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(h.spoken)
    }

    private func cards(_ g: GoalOrder, _ w: [GoalNode]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(waveCards(w), id: \.ref) { n in
                GoalCard(node: n, selected: n.task == selected, found: goalCardMatches(n, query: query)) { pick(n.task) }
                    .id(cardID(g, n))
                    .anchorPreference(key: CardBounds.self, value: .bounds) { [n.ref: $0] }
            }
        }
    }

    private func cardID(_ g: GoalOrder, _ n: GoalNode) -> String { "\(g.path)#\(n.ref)" }

    // MARK: Keys (design §2 키보드)

    private func move(_ m: CardMove, _ goals: [GoalOrder]) -> KeyPress.Result {
        guard let id = selected else { return .ignored }
        for g in goals where g.cycle == nil {
            let drawn = g.waves.map(waveCards)
            for (wi, w) in drawn.enumerated() {
                guard let ci = w.firstIndex(where: { $0.task == id }) else { continue }
                guard let to = movedCard((wi, ci), m, sizes: drawn.map(\.count)) else { return .handled }
                let n = drawn[to.wave][to.index]
                if n.state != nil { pick(n.task) }
                return .handled
            }
        }
        return .ignored
    }
}

/// One node of a wave (design §2 카드): state icon and id, the title on two lines at most, the status line.
private struct GoalCard: View {
    let node: GoalNode
    let selected: Bool
    /// The search finds it; a card it does not find stays, dimmed.
    let found: Bool
    let open: () -> Void

    var body: some View {
        let line = GoalCardLine(node)
        let muted = line == .done || line == .cancelled
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if let state = node.state { TaskStateIcon(state: state, style: .callout, muted: muted) }
                Text(node.task).scaledFont(.callout, design: .monospaced)
                if let items = itemsLabel(node.items) { Text(items).scaledFont(.caption1).foregroundStyle(.secondary) }
            }
            if let title = node.title {
                Text(title).scaledFont(.callout).lineLimit(2).help(title)
            }
            status(line)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        // the words dim, the ground stays opaque under the selection's tint: an arrow behind a card, done or not found
        // by the search too, never shows through it (R1 L3)
        .opacity(found ? (muted ? 0.6 : 1) : 0.35)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor))
                if selected { RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18)) }
            }
        }
        .overlay { border(line) }
        .contentShape(.rect)
        .onTapGesture { if line != .unregistered { open() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(goalCardSpoken(node))
        .accessibilityAddTraits(line == .unregistered ? [] : .isButton)
        .accessibilityHint(line == .unregistered ? "작업판에 없는 작업입니다" : "작업 상세로 갑니다")
        .accessibilityAction { if line != .unregistered { open() } }
    }

    @ViewBuilder
    private func status(_ line: GoalCardLine) -> some View {
        switch line {
        case .startable:
            Label(line.text(), systemImage: "play.circle.fill").scaledFont(.caption1).foregroundStyle(Color.accentColor)
        case .state(let s):
            Text(line.text()).scaledFont(.caption1).foregroundStyle(TaskStateStyle.of(s).color)
        case .waiting where line.blockedByCancelled:
            Label(line.text(), systemImage: "exclamationmark.triangle.fill").scaledFont(.caption1)
                .foregroundStyle(TaskColor.orange).help(line.text(full: true))
        case .waiting:
            Text(line.text()).scaledFont(.caption1).foregroundStyle(.secondary).help(line.text(full: true))
        default:
            Text(line.text()).scaledFont(.caption1).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func border(_ line: GoalCardLine) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        switch line {
        case .startable: shape.strokeBorder(Color.accentColor, lineWidth: 1.5)
        case .unregistered: shape.strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        default: shape.strokeBorder(Color.secondary.opacity(selected ? 0 : 0.25), lineWidth: 1)
        }
    }
}

/// Each card's bounds by its ref, for the arrows of its goal's waves.
private struct CardBounds: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { a, _ in a }
    }
}

/// The order as arrows (user's request, 11-19): from the right of each predecessor's card to the left of the card that
/// waits for it, a curve and a head. Drawn only with the waves side by side; stacked, the cards' 대기 lines say it.
/// Hidden from VoiceOver, which reads the same in each card's status line.
private struct GoalArrows: View {
    let edges: [GoalEdge]
    let cards: [String: CGRect]

    var body: some View {
        Canvas { context, _ in
            for e in edges {
                guard let a = cards[e.from], let b = cards[e.to] else { continue }
                let start = CGPoint(x: a.maxX, y: a.midY), end = CGPoint(x: b.minX - 1, y: b.midY)
                guard end.x - start.x > 4 else { continue }
                let bend = max(12, (end.x - start.x) / 2)
                var line = Path()
                line.move(to: start)
                line.addCurve(to: end, control1: CGPoint(x: start.x + bend, y: start.y), control2: CGPoint(x: end.x - bend, y: end.y))
                context.stroke(line, with: .color(.secondary.opacity(0.7)), lineWidth: 1.2)
                var head = Path()
                head.move(to: end)
                head.addLine(to: CGPoint(x: end.x - 7, y: end.y - 4))
                head.addLine(to: CGPoint(x: end.x - 7, y: end.y + 4))
                head.closeSubpath()
                context.fill(head, with: .color(.secondary.opacity(0.9)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
