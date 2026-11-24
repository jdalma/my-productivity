// The editor page: monaco-vscode-api in its extended configuration (VS Code TextMate grammars and themes) with one editor,
// driven by the app over the bridge (bridge.ts). Files come from Swift and go back through it; the page never names a
// file Swift did not open, and Swift judges every path again (EditorBridge.swift).
import './bridge'
import '@codingame/monaco-vscode-swift-default-extension'
import '@codingame/monaco-vscode-typescript-basics-default-extension'
import '@codingame/monaco-vscode-javascript-default-extension'
import '@codingame/monaco-vscode-java-default-extension'
import '@codingame/monaco-vscode-python-default-extension'
import '@codingame/monaco-vscode-json-default-extension'
import '@codingame/monaco-vscode-markdown-basics-default-extension'
import '@codingame/monaco-vscode-shellscript-default-extension'
import '@codingame/monaco-vscode-yaml-default-extension'
import { KeyCode, KeyMod, Uri } from '@codingame/monaco-vscode-editor-api'
import { createModelReference } from '@codingame/monaco-vscode-api/monaco'
import { getService, IConfigurationService } from '@codingame/monaco-vscode-api/services'
import { MonacoVscodeApiWrapper } from 'monaco-languageclient/vscodeApiWrapper'
import { configureDefaultWorkerFactory } from 'monaco-languageclient/workerFactory'
import { EditorApp } from 'monaco-languageclient/editorApp'
import { call, fire, type Reply } from './bridge'

const theme = (dark: boolean) => (dark ? 'Default Dark Modern' : 'Default Light Modern')

/** A file Swift opened: its model, the hash of the disk bytes the buffer started from, and whether it may be edited. */
type OpenFile = {
  ref: Awaited<ReturnType<typeof createModelReference>>
  hash: string
  savedVersion: number
  readOnly: boolean
  reportedDirty: boolean
}

async function main() {
  await new MonacoVscodeApiWrapper({
    $type: 'extended',
    viewsConfig: { $type: 'EditorService' },
    userConfiguration: {
      json: JSON.stringify({
        'workbench.colorTheme': theme(matchMedia('(prefers-color-scheme: dark)').matches),
        'editor.wordBasedSuggestions': 'off',
      }),
    },
    monacoWorkerFactory: configureDefaultWorkerFactory,
    // no web extension code runs in the page (D#10 a): grammars and themes only
    advanced: { enableExtHostWorker: false },
  }).start()
  const app = new EditorApp({ codeResources: { modified: { text: '', uri: '/untitled.txt' } } })
  await app.start(document.getElementById('root')!)
  const editor = app.getEditor()!
  editor.updateOptions({ readOnly: true })
  const configuration = await getService(IConfigurationService)

  const files = new Map<string, OpenFile>()
  let shown: string | undefined
  const model = (f: OpenFile) => f.ref.object.textEditorModel!
  const isDirty = (f: OpenFile) => model(f).getAlternativeVersionId() !== f.savedVersion
  const showReadOnly = (f: OpenFile) =>
    editor.updateOptions({ readOnly: f.readOnly, readOnlyMessage: { value: '읽기 전용입니다. 잠금을 풀어야 편집할 수 있습니다.' } })
  const reportDirty = (path: string, f: OpenFile) => {
    const dirty = isDirty(f)
    if (dirty !== f.reportedDirty) {
      f.reportedDirty = dirty
      fire('dirtyChanged', { path, dirty })
    }
  }
  /** Takes the disk's text into a clean buffer; a dirty one is kept, and Swift shows its banner (EditorBuffers.swift). */
  const reload = (path: string, f: OpenFile, text: string, hash: string) => {
    if (isDirty(f)) return false
    if (model(f).getValue() !== text) model(f).setValue(text)
    f.hash = hash
    f.savedVersion = model(f).getAlternativeVersionId()
    reportDirty(path, f)
    return true
  }

  async function save(path = shown): Promise<Reply> {
    const f = path === undefined ? undefined : files.get(path)
    if (path === undefined || !f) return { result: 'refused', reason: 'notOpen' }
    if (f.readOnly) return { result: 'refused', reason: 'readOnly' }
    const version = model(f).getAlternativeVersionId()
    const r = await call('writeFile', { path, text: model(f).getValue(), baseHash: f.hash })
    if (r.result === 'ok') {
      f.hash = r.hash as string
      f.savedVersion = version
      reportDirty(path, f)
    }
    return r
  }

  editor.addCommand(KeyMod.CtrlCmd | KeyCode.KeyS, () => void save())
  editor.onDidChangeModelContent(() => {
    const f = shown === undefined ? undefined : files.get(shown)
    if (shown !== undefined && f) reportDirty(shown, f)
  })
  editor.onDidChangeCursorPosition((e) => {
    if (shown !== undefined) fire('cursor', { path: shown, line: e.position.lineNumber, col: e.position.column })
  })

  const commands: Record<string, (m: any) => Promise<Reply> | Reply> = {
    async openFile(m) {
      let f = files.get(m.path)
      if (!f) {
        const ref = await createModelReference(Uri.file(m.path) as any, m.text)
        f = { ref, hash: m.hash, savedVersion: ref.object.textEditorModel!.getAlternativeVersionId(), readOnly: m.readOnly, reportedDirty: false }
        files.set(m.path, f)
      } else {
        reload(m.path, f, m.text, m.hash)
        f.readOnly = m.readOnly
      }
      editor.setModel(model(f))
      shown = m.path
      showReadOnly(f)
      if (m.line) {
        editor.revealLineInCenter(m.line)
        editor.setPosition({ lineNumber: m.line, column: 1 })
      }
      return { result: 'ok', language: model(f).getLanguageId() }
    },
    fileChangedOnDisk(m) {
      const f = files.get(m.path)
      if (!f || m.text === undefined) return { result: 'ok', applied: false }
      return { result: 'ok', applied: reload(m.path, f, m.text, m.hash) }
    },
    /** The banner's 디스크로 다시 읽기: the disk's text over the buffer, as one edit that undo takes back. */
    reloadFile(m) {
      const f = files.get(m.path)
      if (!f) return { result: 'refused', reason: 'notOpen' }
      if (model(f).getValue() !== m.text) {
        model(f).pushStackElement()
        model(f).pushEditOperations(null, [{ range: model(f).getFullModelRange(), text: m.text }], () => null)
        model(f).pushStackElement()
      }
      f.hash = m.hash
      f.savedVersion = model(f).getAlternativeVersionId()
      reportDirty(m.path, f)
      return { result: 'ok', applied: true }
    },
    /** The banner's 덮어쓰기: a save from the disk bytes the banner was for. */
    overwrite(m) {
      const f = files.get(m.path)
      if (!f) return { result: 'refused', reason: 'notOpen' }
      f.hash = m.diskHash
      return save(m.path)
    },
    /** The tree renamed an open file: its buffer stays, under the new path (the language stays the old name's until it is opened again). */
    renameFile(m) {
      const f = files.get(m.from)
      if (!f) return { result: 'refused', reason: 'notOpen' }
      files.delete(m.from)
      files.set(m.to, f)
      if (shown === m.from) shown = m.to
      return { result: 'ok' }
    },
    getText(m) {
      const f = files.get(m.path)
      return f ? { result: 'ok', text: model(f).getValue() } : { result: 'refused', reason: 'notOpen' }
    },
    fileDeleted(m) {
      // nothing to save to: Swift refuses a save of a missing file anyway; the buffer stays for the user to copy
      const f = files.get(m.path)
      if (f) {
        f.readOnly = true
        if (shown === m.path) showReadOnly(f)
      }
      return { result: 'ok' }
    },
    async setTheme(m) {
      await configuration.updateValue('workbench.colorTheme', theme(m.dark))
      return { result: 'ok' }
    },
    async setFontSize(m) {
      await configuration.updateValue('editor.fontSize', m.size)
      return { result: 'ok' }
    },
    setReadOnly(m) {
      const f = files.get(m.path)
      if (!f) return { result: 'refused', reason: 'notOpen' }
      f.readOnly = m.readOnly
      if (shown === m.path) showReadOnly(f)
      return { result: 'ok' }
    },
    save: () => save(),
  }
  ;(window as any).ctBridge = {
    receive: async (m: { kind: string }) => {
      const run = commands[m?.kind]
      return run ? run(m) : { result: 'refused', reason: `unknown ${m?.kind}` }
    },
  }
  await call('ready')
}

main().catch((e) => console.error('editor failed to start', e))
