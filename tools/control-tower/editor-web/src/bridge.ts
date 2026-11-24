// The page's side of the Swift bridge (plan §1.4, Sources/TowerCore/EditorBridge.swift).
// Page -> Swift: window.webkit.messageHandlers.ct.postMessage({kind, ...}), answered {result, ...}.
// Swift -> page: callAsyncJavaScript("return await window.ctBridge.receive(m)", arguments: {m}): values only, no code.
export type Reply = { result: 'ok' | 'conflict' | 'refused' | 'failed'; [k: string]: unknown }

const handler = (window as any).webkit?.messageHandlers?.ct

export function call(kind: string, payload: Record<string, unknown> = {}): Promise<Reply> {
  if (!handler) return Promise.resolve({ result: 'refused', reason: 'no bridge' })
  return handler.postMessage({ kind, ...payload })
}

/** A message whose answer nobody waits for (dirtyChanged, cursor, log). */
export function fire(kind: string, payload: Record<string, unknown> = {}) {
  void call(kind, payload).catch(() => {})
}

// errors of the page and of the editor's workers (which log through console.error) go to the app's log
const consoleError = console.error.bind(console)
console.error = (...args: unknown[]) => {
  consoleError(...args)
  fire('log', { message: args.map((a) => (a instanceof Error ? a.stack ?? a.message : String(a))).join(' ') })
}
window.addEventListener('error', (e) => fire('log', { message: `${e.message} (${e.filename}:${e.lineno})` }))
window.addEventListener('unhandledrejection', (e) => fire('log', { message: String(e.reason?.stack ?? e.reason) }))
