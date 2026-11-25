// The page's side of the LSP relay (G4 I11, Sources/TowerCore/LanguageServer.swift): MonacoLanguageClient talks to a
// language server the app runs, over the bridge. Page to server: lspSend; server to page: lspReceive, in order.
import * as vscode from 'vscode'
import { AbstractMessageReader, AbstractMessageWriter, type DataCallback, type Disposable, type Message } from 'vscode-jsonrpc'
import { MonacoLanguageClient } from 'monaco-languageclient'
import { call } from './bridge'

class BridgeReader extends AbstractMessageReader {
  private callback?: DataCallback
  private early: Message[] = []

  listen(callback: DataCallback): Disposable {
    this.callback = callback
    for (const m of this.early.splice(0)) callback(m)
    return { dispose: () => { this.callback = undefined } }
  }

  push(m: Message) {
    if (this.callback) this.callback(m)
    else this.early.push(m)
  }

  close() { this.fireClose() }
}

class BridgeWriter extends AbstractMessageWriter {
  constructor(private readonly channel: string) { super() }

  async write(msg: Message): Promise<void> {
    const r = await call('lspSend', { channel: this.channel, message: JSON.stringify(msg) })
    if (r.result !== 'ok') this.fireError(new Error(`lspSend ${String(r.reason ?? r.result)}`), msg, 1)
  }

  end(): void {}
}

type Client = { reader: BridgeReader; client: MonacoLanguageClient }
const clients = new Map<string, Client>()

/** After a file of `languageId` opens: its server's client, started once per channel. Swift decides whether there is
 *  a server (the fixed table) and shows the notice when it is not installed; the page only connects. */
export async function connectLanguageServer(languageId: string, path: string) {
  const r = await call('lspStart', { languageId, path })
  if (r.result !== 'ok') return
  const channel = r.channel as string
  if (clients.has(channel)) return
  const root = r.root as string
  const reader = new BridgeReader()
  const client = new MonacoLanguageClient({
    name: channel,
    clientOptions: {
      documentSelector: (r.languages as string[]).map((language) => ({ language })),
      workspaceFolder: { index: 0, name: root.split('/').pop() || root, uri: vscode.Uri.file(root) },
    },
    messageTransports: { reader, writer: new BridgeWriter(channel) },
  })
  clients.set(channel, { reader, client })
  await client.start().catch((e) => {
    clients.delete(channel)
    console.error(`language client ${channel} failed to start`, e)
  })
}

export function receive(channel: string, message: string) {
  clients.get(channel)?.reader.push(JSON.parse(message))
}

/** The server ended: drop its client; the next file of its language connects again. */
export function closed(channel: string) {
  const c = clients.get(channel)
  if (!c) return
  clients.delete(channel)
  c.reader.close()
  void c.client.dispose().catch(() => {})
}
