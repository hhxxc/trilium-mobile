// 发现新版本后的静默预下载（抄巢记「闲时自动下载安装包」）。
// WebView 无法真后台：采用「App 启动后延迟自动检查 + 有新版就静默下载到内存」，
// 用户进设置页时安装包已在，点一下直接弹分享面板。
// 静默失败不打扰用户——手动「点此安装」时仍会走可见的进度条下载。
import { reactive } from 'vue';
import { checkUpdate, downloadIpa } from './update.js';

export const pre = reactive({
  state: 'idle',   // idle | downloading | ready | error
  version: '',
  pct: 0,
  err: '',
});

let bytes = null;

export function preBytes() { return bytes; }

export function setPreResult(b, version) {
  bytes = b;
  pre.state = 'ready';
  pre.version = version;
  pre.pct = 100;
}

export async function preloadUpdate() {
  if (pre.state === 'downloading' || pre.state === 'ready') return;
  try {
    const u = await checkUpdate();
    if (!u.hasUpdate) { pre.state = 'idle'; return; }
    pre.state = 'downloading';
    pre.version = u.latest;
    pre.pct = 0;
    const b = await downloadIpa(u.ipaUrl, (got, total) => {
      pre.pct = Math.round((got / total) * 100);
    });
    bytes = b;
    pre.state = 'ready';
  } catch (e) {
    pre.state = 'error';
    pre.err = (e && e.message) || String(e);
  }
}
