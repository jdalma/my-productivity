# Vendored: highlight.js

- File: `highlight.min.js` (the "common" browser build, 35 languages)
- Version: 11.12.0 (git f7f7d3803b)
- Source: https://registry.npmjs.org/@highlightjs/cdn-assets/-/cdn-assets-11.12.0.tgz, `package/highlight.min.js`
- sha256: 8ab71eb09c51f501e5e25157d9cff100e46cc29bcbfc744d0b746d451fca7f53
- License: BSD-3-Clause, full text in `highlight.js-LICENSE` (shipped in the app bundle beside this file)

Runs in a JavaScriptCore context with no network APIs. Diff lines are passed as call arguments, never spliced into script text.
To update: replace the file from the same npm path, then update the version and sha256 here.

# Linked: SwiftTerm

- Package: https://github.com/migueldeicaza/SwiftTerm, pinned `exact: "1.99.1"` in Package.swift
- Used for: the board's pane terminal (TowerApp, T46)
- License: MIT, full text in `SwiftTerm-LICENSE` (shipped in the app bundle beside this file)

SwiftTerm's manifest also declares swift-argument-parser, swift-docc-plugin and swift-png. SwiftPM resolves some of them,
but the app binary links SwiftTerm alone; the others serve SwiftTerm's own tools and non-Apple platforms.
