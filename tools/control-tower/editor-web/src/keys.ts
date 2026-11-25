// The editor's keys stay in the page (G4 I8). WebKit hands a key the page did not take to the app's menu (T14 §5.3),
// so a key Monaco leaves (⌘[ in a read-only file, Esc with nothing to close) would move the window back, close it or
// beep. These are SharedKey's editor keys in KeyRouting.swift: keep the two lists equal.
// The app's own keys (⌘W, ⌘+ ⌘- ⌘0, ⌘R, ⌘1 ⌘2) are left alone and reach the menu.
// ⌘P and ⌘⇧F are the app's search panel (T39): Monaco's own quick open has no files to list, so they go to Swift.
import type { editor } from '@codingame/monaco-vscode-editor-api'
import { fire } from './bridge'

const command = (e: KeyboardEvent) => e.metaKey && !e.ctrlKey && !e.altKey

const editorKey = (e: KeyboardEvent) => {
  if (e.key === 'Escape') return !e.metaKey && !e.ctrlKey && !e.altKey
  if (!command(e)) return false
  const k = e.key.toLowerCase()
  return e.shiftKey ? k === 'p' : ['f', 'k', '[', ']', 'd', 'z'].includes(k)
}

const searchKey = (e: KeyboardEvent) => {
  if (!command(e)) return undefined
  const k = e.key.toLowerCase()
  if (!e.shiftKey && k === 'p') return 'quickOpen'
  if (e.shiftKey && k === 'f') return 'findInFiles'
  return undefined
}

export function keepEditorKeys(ed: editor.IStandaloneCodeEditor) {
  // before Monaco (capture phase): its quick open would take ⌘P
  window.addEventListener('keydown', (e) => {
    const search = ed.hasWidgetFocus() ? searchKey(e) : undefined
    if (!search) return
    e.preventDefault()
    e.stopPropagation()
    fire(search)
  }, true)
  // after Monaco (bubble phase): a key it took has stopped propagating; one it left is marked taken here
  window.addEventListener('keydown', (e) => {
    if (ed.hasWidgetFocus() && editorKey(e)) e.preventDefault()
  })
}
