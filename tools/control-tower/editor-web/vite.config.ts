import { defineConfig } from 'vite'

// The page is served from a custom scheme by the app (WKURLSchemeHandler), so every asset URL is relative.
// Output goes to TowerCore's resources; it is built, never committed (.gitignore, D#11 b).
export default defineConfig({
  base: './',
  build: {
    target: 'esnext',
    outDir: '../Sources/TowerCore/Resources/editor',
    emptyOutDir: true,
    assetsInlineLimit: 0,
    chunkSizeWarningLimit: 4096,
  },
  worker: { format: 'es' },
})
