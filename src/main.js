import { createApp } from 'vue';
import App from './App.vue';
import './style.css';

// 启动锁已移除（2026-10-16）：清掉旧版本残留在本地的锁配置，避免占地方
for (const k of ['trilium-mobile-lock', 'trilium-mobile-bg-at', 'trilium-mobile-last-unlock']) {
  try { localStorage.removeItem(k); } catch { /* 忽略 */ }
}

createApp(App).mount('#app');
