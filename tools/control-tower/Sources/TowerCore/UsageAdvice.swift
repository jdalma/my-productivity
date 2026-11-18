import Foundation

// The dashboard's analysis and advice (T201): the sums the dashboard already shows go to one fixed `claude` call,
// and what it writes is kept. Nothing of a conversation goes out: no prompt, no response, no title, no path.

// MARK: what is sent

/// The request: what to write, then a period's sums. Only numbers, model names and project folder names.
/// A session is named by its project alone: its title is cut from what the user typed, which is conversation text.
public func usageAdviceRequest(_ report: UsageReport, home: String = homeDirectory(), calendar: Calendar = .current) -> String {
    func n(_ value: Int) -> String { String(value) }
    func tokens(_ t: UsageTokens) -> String {
        "출력 \(n(t.output)), cache 읽기 \(n(t.cacheRead)), cache 생성 \(n(t.cacheCreation)), 입력 \(n(t.input)), 응답 \(n(t.responses))개"
    }
    // the folder's own name: the path above it starts with the home folder, and the home folder's name is the account's,
    // however the path was typed (`/Users/Name/` on a volume that ignores case is the same folder)
    func folders(_ path: String) -> [String] { path.lowercased().split(separator: "/").map(String.init) }
    func project(_ path: String) -> String {
        if !path.isEmpty, folders(path) == folders(home) { return "홈 폴더" }
        // a name is data in one line of the request: no line of its own, no length of its own
        let name = usageProjectName(path).map { $0.isNewline || $0.unicodeScalars.contains { $0.properties.generalCategory == .control } ? " " : $0 }
        return String(String(name).prefix(usageAdviceNameLength))
    }
    func stamp(_ date: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = format
        return f.string(from: date)
    }

    let periodName = switch report.period {
    case .today: "오늘"
    case .week: "지난 7일"
    case .month: "지난 30일"
    }
    let bars = report.buckets.map { "\(stamp($0.start, report.period == .today ? "H시" : "MM-dd")) \(n($0.output))" }
    let leaking = report.sessions.filter { $0.rewrittenCache > 0 || $0.compactions >= usageRepeatedCompactions }
        .sorted { ($0.rewrittenCache, $0.compactions) > ($1.rewrittenCache, $1.compactions) }
        .prefix(usageAdviceSessions)
    let created = report.totals.cacheCreation
    let share = created > 0 ? " (cache 생성의 \(usageSharePercent(Double(report.rewrittenCache.tokens) / Double(created)))%)" : ""

    var lines = [
        "아래는 한 사용자의 Claude Code 토큰 사용량 집계입니다. 대화 내용은 없고 숫자와 프로젝트 폴더 이름뿐입니다.",
        "이 숫자만 보고 답하십시오. 도구를 쓸 수 없고 더 물어볼 수도 없습니다. 숫자에 없는 사실은 지어내지 마십시오.",
        "",
        "한국어 markdown으로, 아래 두 제목만 써서 짧게 답하십시오. 머리말과 맺음말은 쓰지 않습니다.",
        "## 분석",
        "토큰이 어디에서 새는지를 근거가 되는 숫자와 함께 3~5개 항목으로.",
        "## 조언",
        "사용량을 줄이려면 무엇을 바꿀지 3~5개 항목으로. 항목마다 어느 숫자에서 나온 조언인지 밝힙니다.",
        "",
        "용어",
        "- 쉰 뒤 다시 쓴 cache: cache 유지 시간(5분 또는 1시간)을 넘겨 쉰 뒤 이어 쓴 세션에서 다시 만든 cache 토큰.",
        "- 압축: 대화가 길어져 context를 요약한 일. 한 세션에서 \(usageRepeatedCompactions)번 이상이면 반복으로 봅니다.",
        "- 종류: interactive는 사람이 쓴 세션, subagent는 그 세션이 띄운 하위 에이전트, sdk는 프로그램이 실행한 세션.",
        "",
        "# 집계",
        "기간: \(periodName) (\(stamp(report.from, "yyyy-MM-dd")) ~ \(stamp(report.to, "yyyy-MM-dd HH:mm")))",
        "합계: \(tokens(report.totals)), 활동한 날 \(n(report.activeDays))일",
        "평소 대비: \(usageComparisonText(report, sentence: false) ?? "비교할 평소 값 없음")",
        "\(report.period == .today ? "시간별" : "일별") 출력: \(bars.joined(separator: ", "))",
        "프로젝트별:",
    ]
    lines += report.projects.prefix(usageAdviceRanks).map { "- \(project($0.name)): \(tokens($0.tokens))" }
    if report.projects.count > usageAdviceRanks { lines.append("- 그 외 \(report.projects.count - usageAdviceRanks)개") }
    lines.append("모델별:")
    lines += report.models.prefix(usageAdviceRanks).map { "- \($0.name): \(tokens($0.tokens))" }
    lines.append("종류별:")
    lines += report.kinds.map { "- \($0.kind.rawValue): \(tokens($0.tokens))" }
    lines.append("쉰 뒤 다시 쓴 cache: \(n(report.rewrittenCache.tokens)) 토큰\(share), 응답 \(n(report.rewrittenCache.responses))개, 세션 \(n(report.rewrittenCache.sessions))개")
    lines.append("압축 횟수 분포: " + (report.compactions.isEmpty ? "압축 없음"
        : report.compactions.map { "\($0.compactions)번 세션 \($0.sessions)개" }.joined(separator: ", ")))
    lines.append("다시 쓴 cache나 압축이 큰 세션:")
    lines += leaking.isEmpty ? ["- 없음"] : leaking.map {
        "- 프로젝트 \(project($0.project)): 출력 \(n($0.output)), 다시 쓴 cache \(n($0.rewrittenCache)), 압축 \(n($0.compactions))번"
    }
    return lines.joined(separator: "\n") + "\n"
}

/// How many projects and models are listed, and how many sessions.
let usageAdviceRanks = 10
let usageAdviceSessions = 8
/// The most characters of a folder's name that go out.
let usageAdviceNameLength = 60

// MARK: the one call

public let usageAdviceModel = "sonnet"
public let usageAdviceTimeout: TimeInterval = 120

/// Where `claude` is looked for, in order: the native installer's place, then Homebrew's and npm's global ones.
/// Not the PATH: the app is started by launchd without the shell's, and a fixed list cannot be led to another program.
public func usageAdviceExecutables(home: String = homeDirectory()) -> [String] {
    ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
}

/// The arguments, the same on every run: nothing of the user's data is among them, the request goes to stdin.
/// `--tools ""` leaves no tool; `--safe-mode` leaves out CLAUDE.md, hooks, plugins, skills and MCP servers, and
/// `--strict-mcp-config` with no config leaves no MCP server either way; `--no-session-persistence` writes no
/// transcript, so the run is not in the dashboard's own sums.
public let usageAdviceArguments = [
    "-p", "--model", usageAdviceModel, "--tools", "", "--safe-mode", "--strict-mcp-config", "--disable-slash-commands",
    "--no-session-persistence", "--output-format", "json",
    "--system-prompt", "너는 Claude Code 사용량 집계를 읽고 한국어로 짧게 분석과 조언을 쓰는 분석가다.",
]

/// Why a run gave no text, as the dashboard says it.
public struct UsageAdviceFailure: Error, Codable, Hashable, Sendable {
    public var reason: String

    public init(reason: String) { self.reason = reason }

    static let notFound = UsageAdviceFailure(reason: "claude 실행 파일을 찾지 못했습니다(~/.local/bin, /opt/homebrew/bin, /usr/local/bin).")
    static let unreadable = UsageAdviceFailure(reason: "claude의 출력을 읽지 못했습니다.")
    static func timedOut(_ seconds: TimeInterval) -> UsageAdviceFailure {
        UsageAdviceFailure(reason: "\(Int(seconds))초 안에 끝나지 않아 멈췄습니다.")
    }
    static func failed(_ detail: String) -> UsageAdviceFailure {
        let line = detail.split(separator: "\n").first.map(String.init) ?? ""
        return UsageAdviceFailure(reason: "claude가 오류로 끝났습니다" + (line.isEmpty ? "." : ": \(line.prefix(200))"))
    }
}

/// Runs the one call and gives the text it wrote. It blocks until the call ends or the time is up.
public func runUsageAdvice(_ request: String) -> Result<String, UsageAdviceFailure> {
    guard let claude = usageAdviceExecutables().first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
        return .failure(.notFound)
    }
    return runUsageAdvice(request, command: [claude] + usageAdviceArguments, timeout: usageAdviceTimeout)
}

/// `command` is run in an empty folder made for it, never through a shell, with `request` as its input.
func runUsageAdvice(_ request: String, command: [String], timeout: TimeInterval) -> Result<String, UsageAdviceFailure> {
    let folder = FileManager.default.temporaryDirectory.appending(path: "tower-advice-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let started = Date()
    do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let result = try runCommand(command, timeout: timeout, input: Data(request.utf8), cwd: folder.path)
        if result.status != 0, Date().timeIntervalSince(started) >= timeout { return .failure(.timedOut(timeout)) }
        return usageAdviceText(status: result.status, stdout: result.stdout, stderr: result.stderr)
    } catch {
        return .failure(.failed("\(error)"))
    }
}

/// The text of `--output-format json`: one object whose `result` is what was written and `is_error` says a failure.
func usageAdviceText(status: Int32, stdout: String, stderr: String) -> Result<String, UsageAdviceFailure> {
    let object = (try? JSONSerialization.jsonObject(with: Data(stdout.utf8))) as? [String: Any]
    let text = (object?["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if status != 0 || object?["is_error"] as? Bool == true {
        return .failure(.failed(text.isEmpty ? stderr.isEmpty ? stdout : stderr : text))
    }
    return text.isEmpty ? .failure(.unreadable) : .success(text)
}

// MARK: what is kept

/// The last analysis and the last try. A failed try keeps the analysis before it.
public struct UsageAdviceRecord: Codable, Hashable, Sendable {
    public struct Advice: Codable, Hashable, Sendable {
        public var body: String
        public var at: Date
        /// The period whose sums it was written from, and the span they covered.
        public var period: UsagePeriod
        public var from: Date
        public var to: Date
    }

    public struct Failed: Codable, Hashable, Sendable {
        public var reason: String
        public var at: Date
    }

    public var advice: Advice?
    /// Set while the last try is a failed one; a success clears it.
    public var failed: Failed?
    /// When the last try started, by hand or not, ended or not.
    public var attemptedAt: Date?

    public init() {}

    public mutating func take(_ result: Result<String, UsageAdviceFailure>, of report: UsageReport, at: Date) {
        switch result {
        case .success(let body):
            advice = Advice(body: body, at: at, period: report.period, from: report.from, to: report.to)
            failed = nil
        case .failure(let failure):
            failed = Failed(reason: failure.reason, at: at)
        }
    }
}

/// One file under the home's Application Support.
public struct UsageAdviceStore: Sendable {
    let path: String

    public init(path: String = homeDirectory() + "/Library/Application Support/ControlTower/advice/v1.json") { self.path = path }

    public func load() -> UsageAdviceRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return FileManager.default.contents(atPath: path).flatMap { try? decoder.decode(UsageAdviceRecord.self, from: $0) } ?? UsageAdviceRecord()
    }

    public func save(_ record: UsageAdviceRecord) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return }
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            warn("advice not saved: \(error.localizedDescription)")
        }
    }
}

/// The day's one automatic run: due when no try, by hand or not, started on `now`'s local date.
public func usageAdviceDue(_ record: UsageAdviceRecord, now: Date, calendar: Calendar = .current) -> Bool {
    guard let last = record.attemptedAt else { return true }
    return !calendar.isDate(last, inSameDayAs: now)
}
