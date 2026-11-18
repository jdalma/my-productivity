import Testing
@testable import TowerCore

// A GUI app starts with launchd's environment: no LANG, PATH=/usr/bin:/bin:/usr/sbin:/sbin.
private let launchd = ["HOME": "/Users/me", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

@Test func withoutALocaleChildrenGetUTF8SoTmuxKeepsTabsInFormats() {
    #expect(childEnvironment(base: launchd, extra: [:])["LC_CTYPE"] == "UTF-8")
}

@Test func anExistingLocaleIsLeftAlone() {
    let env = childEnvironment(base: launchd.merging(["LANG": "ko_KR.UTF-8"]) { $1 }, extra: [:])
    #expect(env["LANG"] == "ko_KR.UTF-8")
    #expect(env["LC_CTYPE"] == nil)
    #expect(childEnvironment(base: launchd, extra: ["LC_ALL": "C"])["LC_ALL"] == "C")
}

@Test func childrenSearchHomebrewToo() {
    let path = childEnvironment(base: launchd, extra: [:])["PATH"]?.split(separator: ":").map(String.init) ?? []
    #expect(path.contains("/opt/homebrew/bin"))
    #expect(path.first == "/usr/bin")
}
