// Drives the TEST instance of Control Tower through accessibility (T98). It acts on one pid only, and refuses any
// app whose bundle id is not a test one (local.control-tower.*), the installed app (local.control-tower) included.
// Nothing here posts a global event or brings an app forward: AX actions and attributes work on a window in the
// back, and a key goes to the test app's pid alone (CGEventPostToPid).
//
// Usage: swift scripts/ax.swift <test app pid> <command> [args]
//   or compile it once, then each call takes milliseconds: swiftc -O scripts/ax.swift -o .build/ax; .build/ax <pid> …
//   windows                      its windows: number (for screencapture -l), title, size, on screen
//   dump [depth]                 each window's element tree: role, then title | description | value | identifier
//   menu [depth]                 the menu bar: each item with its key equivalent, and whether it is disabled
//   menu-press <menu> <item> [subitem …]
//                                press a menu item by its path of exact titles (`menu-press View "글자 크게"`): what
//                                its key equivalent would do. Only the app's own commands (AX identifier
//                                menuAction:, e.g. 글자 크게, Settings…, 새 팀); the Apple, Window and Help menus and
//                                every item AppKit makes (Hide Others, Services, Quit, copy and paste) are refused.
//                                A disabled item is refused too: one that acts on the focused window (뒤로, 검색,
//                                닫기, 변경 보기 …) is disabled while the app is not active. It waits two seconds
//                                after pressing: the same item pressed again sooner counts from the old value
//   press <text>                 AXPress the first button, row, cell or text holding <text>, in a window
//                                (`press =<text>`: whose text is exactly <text>, when a longer text holds it first)
//   select <text>                select the first list row holding <text>: what ↑ and ↓ do in a list
//   open <text>                  select that row and send Return: a list's primary action, as a double click
//   actions <text>               the actions of the element holding <text>
//   action <text> <name>         perform one of them (AXShowMenu, or a named one the app gives)
//   key <key> [cmd] [shift] [option] [ctrl]
//                                one key to the test app's pid: a letter, a digit, return, escape, tab, space,
//                                delete, up, down, left, right (e.g. `key r cmd` for ⌘R). It does nothing unless
//                                the test app is the active app (T109): an app that is not active has no key
//                                window, and AppKit drops the key. The test app never activates itself, so `key`
//                                and `open` only work after the user has clicked one of its windows. Use
//                                menu-press, select and press instead. Typing has no such stand-in: a value set
//                                through AX does not reach the app's search fields.
//   size <width> <height> [title] resize the window (titled <title>, else every window)
//   close [title]                press the close button of the window titled <title>, else of the first window
//   fullscreen-off               leave full screen
//   check <menu title> [key]     whether press would refuse that menu item; no pid needed (`swift scripts/ax.swift check 복사하기`)
//   check-menu <identifier> <menu> <item> [subitem …]
//                                whether menu-press would refuse that path, for an item with that AX identifier (the
//                                one `menu` prints after `|`); no pid needed
//   self-test                    the refusal rules below, checked against made-up answers; no pid needed
// Needs Accessibility permission for the terminal that runs it.
//
// What it never touches (T119, after `press "정보"` pressed the Apple menu's System Information twice):
// - A window is an element whose role is AXWindow. While the screen is locked AX answers the app itself for its
//   windows; that is no window, and with no window press, select, open, action(s), dump, size, close and
//   fullscreen-off stop (exit 1).
// - press, select, open and action(s) search the windows' trees only, never the menu bar, and refuse an element
//   that is a menu, a menu item or inside one: a context menu's items too. Menus are pressed by menu-press alone,
//   and only the app's own commands.
// - Every command that takes a pid stops while the screen is locked or the login window is in front.
//
// The system clipboard is the user's (T97, T101): `key` refuses ⌘C, ⌘X, ⌘V and ⌘E (the find pasteboard every app
// shares), and `menu-press` refuses the system's Copy, Cut and Paste items: a menu item whose title is exactly one
// of `systemClipboardItems`, or whose key equivalent is one of those keys with ⌘ alone. Exit 1 on a refusal.
import AppKit
import ApplicationServices

let args = CommandLine.arguments
func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }

/// ⌘ with these keys copies, cuts, pastes or fills the find pasteboard: the system's, not the app's.
let clipboardKeys: Set<String> = ["c", "x", "v", "e"]
/// The system's own items, as macOS titles them in English and Korean.
let systemClipboardItems: Set<String> = [
    "copy", "cut", "paste", "paste and match style", "use selection for find",
    "복사하기", "잘라내기", "붙여넣기", "붙여넣고 스타일 일치시키기", "선택 항목을 찾기에 사용",
]
/// Why pressing a menu item titled `title` with key equivalent `key` (⌘ alone) would touch the system clipboard.
func clipboardRefusal(title: String, key: String?) -> String? {
    if systemClipboardItems.contains(title.trimmingCharacters(in: .whitespaces).lowercased()) {
        return "'\(title)' is the system's clipboard item"
    }
    if let key, clipboardKeys.contains(key.lowercased()) { return "'\(title)' is ⌘\(key.uppercased()), the system clipboard's key" }
    return nil
}
/// The menus `menu-press` never enters: the Apple menu (System Settings, sleep, restart, log out, force quit), and
/// Window and Help, whose items bring windows or other apps forward.
let systemMenus: Set<String> = ["Apple", "Window", "Help", "윈도우", "도움말"]
/// What SwiftUI gives an item made with Button in the app's commands. Every item AppKit makes (Hide Others,
/// Show All, Services, Quit, Edit's copy and paste, full screen) names its own selector instead.
let appCommandAction = "menuAction:"
/// Why `menu-press` refuses the item at `path` whose AX identifier is `identifier`, or nil: it presses the app's
/// own commands only (T109 R34 M1).
func menuRefusal(path: [String], identifier: String) -> String? {
    if let top = path.first, systemMenus.contains(top) { return "the '\(top)' menu is the system's" }
    if identifier != appCommandAction {
        return "'\(path.joined(separator: " > "))' is not one of the app's own commands (\(identifier.isEmpty ? "no action" : identifier))"
    }
    return nil
}
/// The roles of a menu and what is in one. An element with one of them, or under one, is never pressed but by menu-press.
let menuRoles: Set<String> = ["AXMenuBar", "AXMenuBarItem", "AXMenu", "AXMenuItem"]
/// Why an element whose role and its ancestors' roles are `chain` (the element's first) is not pressed, or nil.
func menuElementRefusal(chain: [String]) -> String? {
    guard let role = chain.first(where: menuRoles.contains) else { return nil }
    return chain.first == role ? "it is a menu element (\(role))" : "it is inside a menu (\(role))"
}
/// The windows among what AX answers for an app's windows: AXWindow elements only.
func onlyWindows<T>(_ items: [T], role: (T) -> String) -> [T] { items.filter { role($0) == "AXWindow" } }

/// How the press path reads an accessibility tree. The tool walks AX with it, and the self-test walks a made-up
/// tree through the same functions, so a check taken out of the path fails the self-test (T121, R42 L1).
struct Tree<N> {
    var role: (N) -> String
    var label: (N) -> String
    var kids: (N) -> [N]
    var parent: (N) -> N?
}
struct Stop: Error { let why: String }
let findable: Set<String> = ["AXButton", "AXRow", "AXCell", "AXStaticText",
                             "AXDisclosureTriangle", "AXCheckBox", "AXRadioButton", "AXLink", "AXGroup", "AXHeading",
                             "AXUnknown"]  // a SwiftUI list line's content reads as AXUnknown
/// The app's windows: what it answers for its windows, else its children, AXWindow ones only.
func windowsIn<N>(answered: [N], children: [N], _ t: Tree<N>) -> [N] {
    let w = onlyWindows(answered, role: t.role)
    return w.isEmpty ? onlyWindows(children, role: t.role) : w
}
/// The first findable element holding `needle` under `e`, never entering a menu.
func findIn<N>(_ e: N, _ needle: String, _ t: Tree<N>, _ d: Int = 0) -> N? {
    let role = t.role(e)
    guard d <= 40, !menuRoles.contains(role) else { return nil }
    let label = t.label(e)
    if findable.contains(role), needle.hasPrefix("=") ? needle.count > 1 && label == needle.dropFirst() : label.contains(needle) { return e }
    for k in t.kids(e) { if let f = findIn(k, needle, t, d + 1) { return f } }
    return nil
}
/// `e`'s role, then its ancestors'.
func roleChainOf<N>(_ e: N, _ t: Tree<N>) -> [String] {
    var chain: [String] = [], at: N? = e
    while let x = at, chain.count < 60 {
        chain.append(t.role(x))
        at = t.parent(x)
    }
    return chain
}
/// What press, action(s) act on: the first findable element holding `needle` in a window, not in or under a menu.
func pressTarget<N>(_ windows: [N], _ needle: String, _ t: Tree<N>) -> Result<N, Stop> {
    guard !windows.isEmpty else { return .failure(Stop(why: "shows no window (AXWindow) to work in; doing nothing")) }
    guard let e = windows.lazy.compactMap({ findIn($0, needle, t) }).first else { return .failure(Stop(why: "not found: \(needle)")) }
    if let why = menuElementRefusal(chain: roleChainOf(e, t)) {
        return .failure(Stop(why: "'\(t.label(e).prefix(60))': \(why); menus are pressed by menu-press only; refused"))
    }
    return .success(e)
}
/// What select and open act on: the first list row in a window with a findable element holding `needle`.
func rowTarget<N>(_ windows: [N], _ needle: String, _ t: Tree<N>) -> Result<N, Stop> {
    guard !windows.isEmpty else { return .failure(Stop(why: "shows no window (AXWindow) to work in; doing nothing")) }
    func search(_ e: N, _ d: Int) -> N? {
        guard d <= 40, !menuRoles.contains(t.role(e)) else { return nil }
        if t.role(e) == "AXRow", findIn(e, needle, t) != nil { return e }
        for k in t.kids(e) { if let r = search(k, d + 1) { return r } }
        return nil
    }
    guard let r = windows.lazy.compactMap({ search($0, 0) }).first else { return .failure(Stop(why: "no list row holding: \(needle)")) }
    if let why = menuElementRefusal(chain: roleChainOf(r, t)) {
        return .failure(Stop(why: "'\(t.label(r).prefix(60))': \(why); menus are pressed by menu-press only; refused"))
    }
    return .success(r)
}
/// Why nothing is done right now, or nil: the screen is locked or the login window is in front, and AX then hands
/// back the app or the menu bar where a window was.
func lockRefusal(frontBundle: String?, screenLocked: Bool) -> String? {
    if screenLocked { return "the screen is locked" }
    if frontBundle == "com.apple.loginwindow" { return "the login window is in front (the screen is locked or switching user)" }
    return nil
}
func keyRefusal(_ key: String, _ modifiers: [String]) -> String? {
    guard modifiers.contains("cmd"), clipboardKeys.contains(key.lowercased()) else { return nil }
    return "⌘\(key.uppercased()) reads or writes the user's system clipboard (⌘E: the find pasteboard every app shares); refused"
}
/// ANSI virtual key codes; menus match a key equivalent by its characters, which the event carries too.
let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
    "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
    "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, ",": 43, "/": 44, "n": 45, "m": 46,
    ".": 47, "[": 33, "]": 30, "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
    "left": 123, "right": 124, "down": 125, "up": 126,
]

/// Everything the commands touch outside the tool: whether the screen is locked, the app's accessibility tree, AX
/// actions and attribute writes, keys to the pid, the window list, output and waiting (T140, R45 L1 L2). The tool runs
/// the commands on the real host (AX); the self-test runs the same commands on a made-up host that records what they
/// did. The commands are generic over the element type, so they reach no AX call but through the host.
struct Host<N> {
    /// Why nothing may be done now, or nil. Read at each command's start and again right before every write and key.
    var lock: () -> String?
    var app: N
    var attr: (N, String) -> Any?
    var perform: (N, String) -> Int32
    /// A Bool or a CGSize value.
    var set: (N, String, Any) -> Int32
    var actionNames: (N) -> [String]
    var postKey: (_ code: CGKeyCode, _ flags: CGEventFlags, _ key: String, _ down: Bool) -> Void
    var windowList: () -> [String]
    var out: (String) -> Void
    var pause: (UInt32) -> Void
    /// `pid 123`, for messages.
    var who: String
}

/// The commands. A refusal or a stop is a thrown `Stop`; the caller exits 1 with its words.
func run<N>(_ argv: [String], on h: Host<N>) throws {
    guard let command = argv.first else { throw Stop(why: "which command?") }
    func arg(_ i: Int) -> String? { argv.count > i ? argv[i] : nil }
    func stopIfLocked() throws { if let why = h.lock() { throw Stop(why: "ax.swift: \(why); doing nothing until it is unlocked") } }
    /// Every press, selection, resize and close goes through here, right after the lock is read again (R42 L2).
    func act(_ body: () -> Int32) throws -> Int32 {
        try stopIfLocked()
        return body()
    }
    if command == "key", let key = arg(1), let why = keyRefusal(key, Array(argv.dropFirst(2))) { throw Stop(why: "ax.swift: \(why)") }
    try stopIfLocked()  // every command, reading ones too, stops at its start while locked

    func s(_ e: N, _ n: String) -> String { (h.attr(e, n) as? String) ?? "" }
    func kids(_ e: N) -> [N] { (h.attr(e, kAXChildrenAttribute) as? [N]) ?? [] }
    func label(_ e: N) -> String {
        [s(e, kAXTitleAttribute), s(e, kAXDescriptionAttribute), s(e, kAXValueAttribute), s(e, kAXIdentifierAttribute)]
            .filter { !$0.isEmpty }.joined(separator: " | ")
    }
    let tree = Tree<N>(role: { s($0, kAXRoleAttribute) }, label: label, kids: kids, parent: { h.attr($0, kAXParentAttribute) as? N })
    var windows: [N] { windowsIn(answered: (h.attr(h.app, kAXWindowsAttribute) as? [N]) ?? [], children: kids(h.app), tree) }
    func someWindows() throws -> [N] {
        let w = windows
        if w.isEmpty { throw Stop(why: "ax.swift: \(h.who) shows no window (AXWindow) to work in; doing nothing") }
        return w
    }
    func element(_ needle: String?) throws -> N {
        guard let needle else { throw Stop(why: "\(command): which text?") }
        switch pressTarget(windows, needle, tree) {
        case .failure(let stop): throw Stop(why: "ax.swift: \(h.who): \(stop.why)")
        case .success(let e):
            h.out("found: \(s(e, kAXRoleAttribute)) \(label(e).prefix(120))")
            return e
        }
    }
    func row(_ needle: String?) throws -> N {
        guard let needle else { throw Stop(why: "\(command): which text?") }
        switch rowTarget(windows, needle, tree) {
        case .failure(let stop): throw Stop(why: "ax.swift: \(h.who): \(stop.why)")
        case .success(let r):
            h.out("found row holding: \(needle)")
            return r
        }
    }
    func window(titled title: String?) throws -> [N] {
        let all = try someWindows()
        guard let title else { return all }
        return all.filter { s($0, kAXTitleAttribute).contains(title) }
    }
    /// A menu item's key equivalent as the menu shows it, e.g. `  ⇧⌘T`; empty without one.
    func keyEquivalent(_ e: N) -> String {
        let char = s(e, kAXMenuItemCmdCharAttribute)
        let glyph = h.attr(e, kAXMenuItemCmdGlyphAttribute) as? Int
        guard !char.isEmpty || glyph != nil else { return "" }
        // AXMenuItemCmdModifiers: bit 0 shift, 1 option, 2 control, 3 no command
        let m = (h.attr(e, kAXMenuItemCmdModifiersAttribute) as? Int) ?? 0
        let marks = (m & 4 != 0 ? "⌃" : "") + (m & 2 != 0 ? "⌥" : "") + (m & 1 != 0 ? "⇧" : "") + (m & 8 == 0 ? "⌘" : "")
        return "  " + marks + (char == "\u{1b}" ? "esc" : char.isEmpty ? "glyph \(glyph!)" : char)
    }
    func dump(_ e: N, _ d: Int, _ maxD: Int) {
        guard d <= maxD else { return }
        let role = s(e, kAXRoleAttribute), l = label(e)
        if !l.isEmpty || ["AXWindow", "AXButton", "AXRow", "AXOutline", "AXTable", "AXToolbar", "AXMenuBarItem"].contains(role) {
            let item = role == "AXMenuItem" ? keyEquivalent(e) + ((h.attr(e, kAXEnabledAttribute) as? Bool) == false ? "  (disabled)" : "") : ""
            h.out(String(repeating: "  ", count: d) + role + (l.isEmpty ? "" : "  " + String(l.prefix(160)).replacingOccurrences(of: "\n", with: "⏎")) + item)
        }
        for k in kids(e) { dump(k, d + 1, maxD) }
    }
    /// A menu item that would copy, cut or paste with the system clipboard is never pressed.
    func refuseClipboardItem(_ e: N) throws {
        guard s(e, kAXRoleAttribute) == "AXMenuItem" else { return }
        let modifiers = (h.attr(e, kAXMenuItemCmdModifiersAttribute) as? Int) ?? 0  // 0: ⌘ alone
        let key = modifiers == 0 && !s(e, kAXMenuItemCmdCharAttribute).isEmpty ? s(e, kAXMenuItemCmdCharAttribute) : nil
        if let why = clipboardRefusal(title: s(e, kAXTitleAttribute), key: key) { throw Stop(why: "ax.swift: \(why); refused") }
    }
    func post(key: String, modifiers: [String]) throws {
        if let why = keyRefusal(key, modifiers) { throw Stop(why: "ax.swift: \(why)") }
        guard let code = keyCodes[key] else { throw Stop(why: "unknown key \(key)") }
        var flags: CGEventFlags = []
        for m in modifiers {
            switch m {
            case "cmd": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option": flags.insert(.maskAlternate)
            case "ctrl": flags.insert(.maskControl)
            default: throw Stop(why: "unknown modifier \(m)")
            }
        }
        for down in [true, false] { _ = try act { h.postKey(code, flags, key, down); return 0 } }
        h.out("key: \(([key] + modifiers).joined(separator: " ")) → \(h.who)")
    }

    switch command {
    case "windows":
        for line in h.windowList() { h.out(line) }
    case "dump":
        let maxD = arg(1).flatMap(Int.init) ?? 30
        let all = try someWindows()
        h.out("windows: \(all.count)")
        for w in all {
            h.out("== window: \(s(w, kAXTitleAttribute)) fullscreen: \(h.attr(w, "AXFullScreen") ?? "?")")
            dump(w, 0, maxD)
        }
    case "menu":
        if let mb = h.attr(h.app, kAXMenuBarAttribute) as? N { dump(mb, 0, arg(1).flatMap(Int.init) ?? 4) }
    case "menu-press":
        let path = Array(argv.dropFirst())
        guard path.count >= 2, var e = h.attr(h.app, kAXMenuBarAttribute) as? N else { throw Stop(why: "menu-press <menu> <item> [subitem …]") }
        if let why = menuRefusal(path: path, identifier: appCommandAction) { throw Stop(why: "ax.swift: \(why); refused") }
        for title in path {
            // a menu bar item or a submenu item holds one AXMenu, and that holds the items
            let items = kids(e).flatMap { s($0, kAXRoleAttribute) == "AXMenu" ? kids($0) : [$0] }
            guard let next = items.first(where: { s($0, kAXTitleAttribute) == title }) else {
                throw Stop(why: "no '\(title)' there; it has: " + items.map { s($0, kAXTitleAttribute) }.filter { !$0.isEmpty }.joined(separator: ", "))
            }
            e = next
        }
        if let why = menuRefusal(path: path, identifier: s(e, kAXIdentifierAttribute)) { throw Stop(why: "ax.swift: \(why); refused") }
        try refuseClipboardItem(e)
        if (h.attr(e, kAXEnabledAttribute) as? Bool) == false { throw Stop(why: "'\(path.joined(separator: " > "))' is disabled") }
        let pressed = try act { h.perform(e, kAXPressAction) }
        h.out("menu-press: \(path.joined(separator: " > ")) \(pressed)")
        // the same item pressed again within about a second counts from the value before this press (R34 S1: lost after
        // 0.5 and 0.7 s, counted after 3 s); another item is not affected
        h.pause(2_000_000)
    case "press":
        let e = try element(arg(1))
        h.out("press: \(try act { h.perform(e, kAXPressAction) })")
    case "select", "open":
        let r = try row(arg(1))
        h.out("select: \(try act { h.set(r, kAXSelectedAttribute, true) })")
        if command == "open" {
            h.pause(200_000)
            try post(key: "return", modifiers: [])
        }
    case "actions":
        for n in h.actionNames(try element(arg(1))) { h.out(n) }
    case "action":
        guard let name = arg(2) else { throw Stop(why: "action <text> <name>") }
        let e = try element(arg(1))
        h.out("action: \(try act { h.perform(e, name) })")
    case "key":
        guard let key = arg(1) else { throw Stop(why: "key <key> [cmd] [shift] [option] [ctrl]") }
        try post(key: key, modifiers: Array(argv.dropFirst(2)))
    case "size":
        guard let w = arg(1).flatMap(Double.init), let ht = arg(2).flatMap(Double.init) else { throw Stop(why: "size <width> <height> [title]") }
        for win in try window(titled: arg(3)) {
            h.out("size: \(s(win, kAXTitleAttribute)) \(try act { h.set(win, kAXSizeAttribute, CGSize(width: w, height: ht)) })")
        }
    case "close":
        guard let win = try window(titled: arg(1)).first, let button = h.attr(win, kAXCloseButtonAttribute) as? N else { throw Stop(why: "no such window") }
        h.out("close: \(s(win, kAXTitleAttribute)) \(try act { h.perform(button, kAXPressAction) })")
    case "fullscreen-off":
        for w in try someWindows() { h.out("fullscreen-off: \(s(w, kAXTitleAttribute)) \(try act { h.set(w, "AXFullScreen", false) })") }
    default:
        throw Stop(why: "unknown command \(command)")
    }
}

// checks that need no app: they only refuse
if args.count >= 2, args[1] == "self-test" {
    func expect(_ ok: Bool, _ what: String) { if !ok { fail("self-test: " + what) } }
    expect(onlyWindows(["AXApplication"], role: { $0 }).isEmpty, "a locked screen's answer, the app itself, is no window")
    expect(onlyWindows(["AXWindow", "AXMenuBar", "AXWindow", "AXSheet"], role: { $0 }) == ["AXWindow", "AXWindow"], "only AXWindow")
    expect(menuElementRefusal(chain: ["AXMenuItem", "AXMenu", "AXMenuBarItem", "AXMenuBar", "AXApplication"]) != nil, "Apple menu's item")
    expect(menuElementRefusal(chain: ["AXMenuBarItem", "AXMenuBar", "AXApplication"]) != nil, "a menu bar item")
    expect(menuElementRefusal(chain: ["AXStaticText", "AXMenuItem", "AXMenu", "AXApplication"]) != nil, "text inside a context menu's item")
    expect(menuElementRefusal(chain: ["AXButton", "AXGroup", "AXWindow", "AXApplication"]) == nil, "a window's button")
    expect(menuElementRefusal(chain: ["AXStaticText", "AXRow", "AXOutline", "AXWindow"]) == nil, "a list row's text")
    expect(lockRefusal(frontBundle: "com.apple.loginwindow", screenLocked: false) != nil, "loginwindow in front")
    expect(lockRefusal(frontBundle: "com.mitchellh.ghostty", screenLocked: true) != nil, "a locked session")
    expect(lockRefusal(frontBundle: "com.mitchellh.ghostty", screenLocked: false) == nil, "an unlocked session")
    expect(lockRefusal(frontBundle: nil, screenLocked: false) == nil, "no front app known")
    expect(menuRefusal(path: ["Apple", "시스템 정보…"], identifier: "_systemInformationRequested:") != nil, "menu-press Apple menu")
    expect(menuRefusal(path: ["View", "글자 크게"], identifier: appCommandAction) == nil, "menu-press an app command")
    expect(clipboardRefusal(title: "Paste", key: nil) != nil, "the system's paste")

    // the press path, over a made-up tree (R42 L1): each check below fails when its step is taken out
    final class Node {
        let role: String, label: String
        var kids: [Node] = []
        var parent: Node?  // strong: a parent made only to hold a node must stay (the self-test exits right after)
        var more: [String: Any] = [:]
        init(_ role: String, _ label: String = "", _ kids: [Node] = [], _ more: [String: Any] = [:]) {
            self.role = role; self.label = label; self.kids = kids; self.more = more
            for k in kids { k.parent = self }
        }
    }
    let t = Tree<Node>(role: { $0.role }, label: { $0.label }, kids: { $0.kids }, parent: { $0.parent })
    func stopped(_ r: Result<Node, Stop>) -> Bool { if case .failure = r { return true } else { return false } }
    func hit(_ r: Result<Node, Stop>) -> Node? { if case .success(let n) = r { return n } else { return nil } }
    func why(_ r: Result<Node, Stop>) -> String { if case .failure(let s) = r { return s.why } else { return "" } }
    let locked = Node("AXApplication", "Control Tower")
    expect(windowsIn(answered: [locked], children: [locked], t).isEmpty, "a locked screen's app is no window")
    let exact = Node("AXDisclosureTriangle", "티켓 전문")
    let exactWindow = Node("AXWindow", "board", [Node("AXStaticText", "\"티켓 전문\"을 펼치면"), exact])
    expect(hit(pressTarget([exactWindow], "=티켓 전문", t)) === exact, "press =<text> passes over a longer text holding it")
    expect(hit(pressTarget([Node("AXWindow", "board", [Node("AXButton", "")])], "=", t)) == nil, "press = with no text finds nothing")
    let rowUnderMenu = Node("AXWindow", "popup", [Node("AXRow", "", [Node("AXStaticText", "alpha")])])
    _ = Node("AXMenu", "", [rowUnderMenu])
    expect(stopped(rowTarget([rowUnderMenu], "alpha", t)), "select refuses a row under a menu")

    // The commands themselves, run on a made-up app (T140, R45 L1 L2): what each one does, and that nothing is
    // written or keyed while the screen is locked, checked by what the host saw, not by reading this file.
    final class Seen {
        var writes: [(target: String, what: String)] = []
        var keys: [String] = []
        var reads = 0
        var lockReads = 0
    }
    /// The board app: a window with a button 정보, a context menu ahead of a button 시스템 정보, a list whose row
    /// alpha comes after a menu's row alpha, a popup window under a menu, a row alpha outside every window (what an
    /// app's children hold besides its windows), and a menu bar whose Apple menu has 정보 under the app's own command
    /// identifier, so only the menu's name refuses it.
    func board() -> Node {
        let closeButton = Node("AXButton", "close")
        let window = Node("AXWindow", "board", [
            Node("AXGroup", "", [Node("AXButton", "정보")]),
            Node("AXMenu", "", [Node("AXMenuItem", "", [Node("AXStaticText", "시스템 정보")])]),
            Node("AXButton", "시스템 정보"),
            Node("AXMenu", "", [Node("AXRow", "menu row", [Node("AXStaticText", "alpha")])]),
            Node("AXOutline", "", [Node("AXRow", "list row", [Node("AXUnknown", "alpha")])]),
        ], [kAXCloseButtonAttribute: closeButton])
        closeButton.parent = window
        let popup = Node("AXWindow", "popup", [Node("AXButton", "확인")])
        let menuBar = Node("AXMenuBar", "", [
            Node("AXMenuBarItem", "Apple", [Node("AXMenu", "", [Node("AXMenuItem", "정보", [], [kAXIdentifierAttribute: appCommandAction])])]),
            Node("AXMenuBarItem", "View", [Node("AXMenu", "", [Node("AXMenuItem", "글자 크게", [], [kAXIdentifierAttribute: appCommandAction])])]),
        ])
        _ = Node("AXMenu", "", [popup])
        let stray = Node("AXGroup", "", [Node("AXRow", "stray row", [Node("AXStaticText", "alpha")])])
        return Node("AXApplication", "Control Tower", [stray, menuBar, window], [kAXWindowsAttribute: [window, popup], kAXMenuBarAttribute: menuBar])
    }
    /// `lockedAfter`: how many lock reads pass before the screen locks (0: locked from the start).
    func runOn(_ argv: [String], lockedAfter: Int = .max, app: Node = board()) -> (seen: Seen, stop: String?) {
        let seen = Seen()
        let host = Host<Node>(
            lock: { seen.lockReads += 1; return seen.lockReads > lockedAfter ? "the screen is locked" : nil },
            app: app,
            attr: { n, a in
                seen.reads += 1
                switch a {
                case kAXRoleAttribute: return n.role
                case kAXTitleAttribute: return n.label
                case kAXChildrenAttribute: return n.kids
                case kAXParentAttribute: return n.parent
                default: return n.more[a]
                }
            },
            perform: { n, a in seen.writes.append((n.label, a)); return 0 },
            set: { n, a, _ in seen.writes.append((n.label, a)); return 0 },
            actionNames: { _ in ["AXPress"] },
            postKey: { _, _, key, down in seen.keys.append("\(key) \(down ? "down" : "up")") },
            windowList: { seen.reads += 1; return [] },
            out: { _ in }, pause: { _ in }, who: "pid 0")
        do { try run(argv, on: host); return (seen, nil) } catch { return (seen, (error as? Stop)?.why ?? "\(error)") }
    }
    func did(_ r: (seen: Seen, stop: String?)) -> [String] { r.seen.writes.map { "\($0.target) \($0.what)" } }

    // only in a window, never a menu, never what is under one
    expect(did(runOn(["press", "정보"])) == ["정보 AXPress"] && runOn(["press", "정보"]).stop == nil, "press finds the window's button")
    let pressedSystem = runOn(["press", "시스템 정보"])
    expect(did(pressedSystem) == ["시스템 정보 AXPress"] && pressedSystem.seen.writes.count == 1, "press never searches a menu")
    expect(did(runOn(["select", "alpha"])) == ["list row AXSelected"], "select finds the list's row, never one in a menu")
    let underMenu = runOn(["press", "확인"])
    expect(did(underMenu).isEmpty && underMenu.stop?.contains("inside a menu") == true, "press refuses an element under a menu")
    let lockedApp = Node("AXApplication", "Control Tower", [], [kAXWindowsAttribute: [Node("AXApplication", "Control Tower")]])
    for argv in [["press", "정보"], ["select", "alpha"], ["fullscreen-off"]] {
        let r = runOn(argv, app: lockedApp)
        expect(did(r).isEmpty && r.stop?.contains("no window") == true, "\(argv[0]) with no window stops")
    }
    expect(did(runOn(["action", "정보", "AXShowMenu"])) == ["정보 AXShowMenu"], "action acts on the window's element")
    expect(did(runOn(["menu-press", "View", "글자 크게"])) == ["글자 크게 AXPress"], "menu-press presses an app command")
    expect(did(runOn(["menu-press", "Apple", "정보"])).isEmpty, "menu-press refuses the Apple menu")
    expect(did(runOn(["close", "board"])) == ["close AXPress"], "close presses the window's close button")
    expect(runOn(["key", "return"]).seen.keys == ["return down", "return up"], "a key goes down and up")
    expect(runOn(["key", "v", "cmd"]).seen.keys.isEmpty, "⌘V is refused")

    // locked from the start: no command reads or writes anything (R45 L2: the start's check)
    let everyCommand: [[String]] = [["windows"], ["dump"], ["menu"], ["press", "정보"], ["select", "alpha"], ["open", "alpha"],
                                    ["actions", "정보"], ["action", "정보", "AXPress"], ["key", "return"], ["size", "800", "600"],
                                    ["close"], ["fullscreen-off"], ["menu-press", "View", "글자 크게"]]
    for argv in everyCommand {
        let r = runOn(argv, lockedAfter: 0)
        expect(r.seen.reads == 0 && r.seen.writes.isEmpty && r.seen.keys.isEmpty && r.stop?.contains("locked") == true,
               "\(argv[0]) read or did something while locked")
    }
    // locked after the start's check: every write and every key reads the lock again first, so none happens
    for argv in everyCommand {
        let r = runOn(argv, lockedAfter: 1)
        expect(r.seen.writes.isEmpty && r.seen.keys.isEmpty, "\(argv[0]) acted without reading the lock again")
    }
    // and the same commands unlocked do act: the two loops above are no accident of a command that does nothing
    for argv in everyCommand where !["windows", "dump", "menu", "actions"].contains(argv[0]) {
        let r = runOn(argv)
        expect(!r.seen.writes.isEmpty || !r.seen.keys.isEmpty, "\(argv[0]) did nothing unlocked: \(r.stop ?? "")")
    }
    // open: the key after the selection reads the lock again too
    let openLocking = runOn(["open", "alpha"], lockedAfter: 2)
    expect(did(openLocking) == ["list row AXSelected"] && openLocking.seen.keys.isEmpty, "open keyed Return without reading the lock again")
    print("self-test: ok")
    exit(0)
}
if args.count >= 2, args[1] == "check-menu" {
    guard args.count >= 5 else { fail("check-menu <identifier> <menu> <item> [subitem …]") }
    if let why = menuRefusal(path: Array(args.dropFirst(3)), identifier: args[2]) { fail("refuse: " + why) }
    print("allow: '\(args.dropFirst(3).joined(separator: " > "))'")
    exit(0)
}
if args.count >= 2, args[1] == "check" {
    guard let title = args.count > 2 ? args[2] : nil else { fail("check <menu title> [key]") }
    if let why = clipboardRefusal(title: title, key: args.count > 3 ? args[3] : nil) { fail("refuse: " + why) }
    print("allow: '\(title)'")
    exit(0)
}
guard args.count >= 3, let pidValue = Int32(args[1]) else { fail("usage: swift scripts/ax.swift <test app pid> <command> [args]") }
let pid = pid_t(pidValue)
let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
guard let bundleId, bundleId.hasPrefix("local.control-tower.") else {
    fail("ax.swift: pid \(pid) is \(bundleId ?? "no app"), not a test instance (local.control-tower.*); refused")
}

/// The real host: AX on the test app's pid. It reads only which app is in front and whether the session is locked.
let axHost = Host<AXUIElement>(
    lock: {
        let locked = ((CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool) ?? false
        return lockRefusal(frontBundle: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, screenLocked: locked)
    },
    app: AXUIElementCreateApplication(pid),
    attr: { e, n in
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil
    },
    perform: { e, a in AXUIElementPerformAction(e, a as CFString).rawValue },
    set: { e, a, value in
        switch value {
        case let b as Bool: return AXUIElementSetAttributeValue(e, a as CFString, b ? kCFBooleanTrue : kCFBooleanFalse).rawValue
        case var size as CGSize: return AXUIElementSetAttributeValue(e, a as CFString, AXValueCreate(.cgSize, &size)!).rawValue
        default: return AXError.illegalArgument.rawValue
        }
    },
    actionNames: { e in
        var names: CFArray?
        AXUIElementCopyActionNames(e, &names)
        return (names as? [String]) ?? []
    },
    postKey: { code, flags, key, down in
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { return }
        e.flags = flags
        if key.count == 1 { e.keyboardSetUnicodeString(stringLength: 1, unicodeString: Array(key.utf16)) }
        e.postToPid(pid)  // this pid only, never the session's event stream
    },
    windowList: {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let shownOrHiddenTestWindow = [0, Int(CGWindowLevelForKey(.minimumWindow))]
        return list.filter { w in
            (w[kCGWindowOwnerPID as String] as? Int32) == pid && (w[kCGWindowLayer as String] as? Int).map(shownOrHiddenTestWindow.contains) == true
        }.map { w in
            let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            return "\(w[kCGWindowNumber as String] ?? "") title: \(w[kCGWindowName as String] ?? "") size: \(b["Width"] ?? "") x \(b["Height"] ?? "") onscreen: \(w[kCGWindowIsOnscreen as String] ?? false)"
        }
    },
    out: { print($0) },
    pause: { usleep($0) },
    who: "pid \(pid)")
do { try run(Array(args.dropFirst(2)), on: axHost) } catch let stop as Stop { fail(stop.why) } catch { fail("\(error)") }
