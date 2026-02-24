import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [react()],
  server: {
    host: '0.0.0.0', // Expose to network
    proxy: {
      '/api': {
        target: process.env.BACKEND_URL || 'http://backend:8080',
        changeOrigin: true,
      },
    },
  },
})
