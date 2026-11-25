// The editor's keys stay in the page (G4 I8). WebKit hands a key the page did not take to the app's menu (T14 §5.3),
// so a key Monaco leaves (⌘[ in a read-only file, Esc with nothing to close, ⌘P with no quick open yet) would move
// the window back, close it or beep. These are SharedKey's editor keys in KeyRouting.swift: keep the two lists equal.
// The app's own keys (⌘W, ⌘+ ⌘- ⌘0, ⌘R, ⌘1 ⌘2) are left alone and reach the menu.
import type { editor } from '@codingame/monaco-vscode-editor-api'

const editorKey = (e: KeyboardEvent) => {
  if (e.key === 'Escape') return !e.metaKey && !e.ctrlKey && !e.altKey
  if (!e.metaKey || e.ctrlKey || e.altKey) return false
  const k = e.key.toLowerCase()
  return e.shiftKey ? k === 'p' : ['f', 'k', '[', ']', 'd', 'z', 'p'].includes(k)
}

/** After Monaco (bubble phase): a key it took has stopped propagating; one it left is marked taken here. */
export function keepEditorKeys(ed: editor.IStandaloneCodeEditor) {
  window.addEventListener('keydown', (e) => {
    if (ed.hasWidgetFocus() && editorKey(e)) e.preventDefault()
  })
}
