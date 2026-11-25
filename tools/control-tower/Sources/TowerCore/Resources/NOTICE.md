# Vendored: highlight.js

- File: `highlight.min.js` (the "common" browser build, 35 languages)
- Version: 11.12.0 (git f7f7d3803b)
- Source: https://registry.npmjs.org/@highlightjs/cdn-assets/-/cdn-assets-11.12.0.tgz, `package/highlight.min.js`
- sha256: 8ab71eb09c51f501e5e25157d9cff100e46cc29bcbfc744d0b746d451fca7f53
- License: BSD-3-Clause, full text in `highlight.js-LICENSE` (shipped in the app bundle beside this file)

Runs in a JavaScriptCore context with no network APIs. Diff lines are passed as call arguments, never spliced into script text.
To update: replace the file from the same npm path, then update the version and sha256 here.

# Built at bundle time: the editor page (Monaco)

- Source: `editor-web/` (Vite). `scripts/bundle-app.sh` runs `npm ci && npm run build`, which writes `Resources/editor/`;
  that folder is built, never committed. Versions are pinned exactly in `editor-web/package.json` and `package-lock.json`.
- Main packages, all MIT:
  - `@codingame/monaco-vscode-api` and `@codingame/monaco-vscode-editor-api` 37.6.1 (Monaco and VS Code services,
    https://github.com/CodinGame/monaco-vscode-api)
  - `@codingame/monaco-vscode-*-default-extension` 37.6.1: the VS Code grammars for Swift, TypeScript, JavaScript, Java,
    Python, JSON, Markdown, shell and YAML, and the default themes
  - `monaco-languageclient` 11.0.3 (https://github.com/TypeFox/monaco-languageclient)
- Every production package of the lockfile, with its license text: `editor/THIRD-PARTY-LICENSES.md`, written by the
  build (`editor-web/scripts/licenses.mjs`) and shipped in the app bundle beside this file. All are MIT except
  `jschardet` (LGPL-2.1+, file encoding detection, its own files in `editor/assets/`), `dompurify` (MPL-2.0 or
  Apache-2.0), `minimatch` (BlueOak-1.0.0) and `semver` (ISC).
- No web extension code runs in the page (extension host off): grammars and themes are data only.
