import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// Vite config. Build output is consumed by `//go:embed web/dist/*` in
// cmd/fastdrop. The dev server proxies /api and /ws to the Go server
// at http://127.0.0.1:9527 for hot-reload during development.
export default defineConfig({
  plugins: [vue()],
  build: {
    outDir: 'dist',
    emptyOutDir: true,
  },
  server: {
    port: 5173,
    strictPort: true,
    proxy: {
      '/api': 'http://127.0.0.1:9527',
      '/ws': { target: 'ws://127.0.0.1:9527', ws: true },
    },
  },
})
