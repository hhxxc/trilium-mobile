import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';

export default defineConfig({
  plugins: [vue()],
  server: { port: 5273 },
  // iOS 15 兼容：Vite 7 默认 target≈Safari 16，降到 es2019 消除语法层面风险
  build: { outDir: 'dist', target: 'es2019' },
});
