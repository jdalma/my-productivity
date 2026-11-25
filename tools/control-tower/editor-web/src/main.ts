// The editor page: monaco-vscode-api in its extended configuration (VS Code TextMate grammars and themes) with one editor.
// The Swift bridge (open, save, LSP) is added by the app's editor view (I4); this page only starts the editor.
import '@codingame/monaco-vscode-swift-default-extension'
import '@codingame/monaco-vscode-typescript-basics-default-extension'
import '@codingame/monaco-vscode-javascript-default-extension'
import '@codingame/monaco-vscode-java-default-extension'
import '@codingame/monaco-vscode-python-default-extension'
import '@codingame/monaco-vscode-json-default-extension'
import '@codingame/monaco-vscode-markdown-basics-default-extension'
import '@codingame/monaco-vscode-shellscript-default-extension'
import '@codingame/monaco-vscode-yaml-default-extension'
import { MonacoVscodeApiWrapper } from 'monaco-languageclient/vscodeApiWrapper'
import { configureDefaultWorkerFactory } from 'monaco-languageclient/workerFactory'
import { EditorApp } from 'monaco-languageclient/editorApp'

const dark = matchMedia('(prefers-color-scheme: dark)').matches

async function main() {
  await new MonacoVscodeApiWrapper({
    $type: 'extended',
    viewsConfig: { $type: 'EditorService' },
    userConfiguration: {
      json: JSON.stringify({
        'workbench.colorTheme': dark ? 'Default Dark Modern' : 'Default Light Modern',
        'editor.wordBasedSuggestions': 'off',
      }),
    },
    monacoWorkerFactory: configureDefaultWorkerFactory,
    // no web extension code runs in the page (D#10 a): grammars and themes only
    advanced: { enableExtHostWorker: false },
  }).start()
  await new EditorApp({ codeResources: { modified: { text: '', uri: '/untitled.txt' } } }).start(document.getElementById('root')!)
}

main().catch((e) => console.error('editor failed to start', e))
