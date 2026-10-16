import type { CapacitorConfig } from '@capacitor/cli';

/**
 * Trilium 手机伴侣端（布局方案 D：最近 + 速记 + 搜索 + 树浏览）
 *
 * 与巢记不同：这不是远程加载壳，而是一个完整打包进 IPA 的 Vue 应用，
 * 通过 Trilium 服务端的 ETAPI（REST）读写笔记数据。
 *
 * 服务器地址与密码在 App 内「设置」页配置，保存在 localStorage。
 * 默认地址在 src/config.js 里定义（构建时可被环境变量覆盖）。
 */
const config: CapacitorConfig = {
  appId: 'com.hhxxc.trilium',
  appName: 'Trilium',
  webDir: 'dist',
  ios: {
    // ⚠️ 不要设 contentInset: 'always'（2026-10-17 修）：它让 WKWebView 自动加安全区
    // contentInset，与 CSS 的 viewport-fit=cover + env(safe-area-inset-*) 全出血方案叠加，
    // 导致顶栏不贴状态栏、底部标签栏悬空一大块黑边。全靠 CSS env() 处理安全区即可。
    backgroundColor: '#f6f6f8ff',
  },
  android: {
    backgroundColor: '#f6f6f8ff',
  },
  // 关键：让 fetch/XHR 走原生 HTTP 通道（CapacitorHttp），绕过 WKWebView 的 CORS 拦截。
  // Trilium 服务端不发 Access-Control-Allow-Origin，而 WebView 源是 capacitor://localhost，
  // 一切到服务器的请求都会被 CORS 拦掉（2026-10-15 实测定性）。
  plugins: {
    CapacitorHttp: {
      enabled: true,
    },
  },
};

export default config;
