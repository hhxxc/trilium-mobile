// 应用内检查更新：读 NAS 清单 → 有新版就交给 TrollStore 安装
//
// 原理：TrollStore 注册了 apple-magnifier://install?url=<ipa地址> 协议，
// 跳过去它会自己下载安装（覆盖安装、数据保留）。App 只负责"发现新版本 + 发起跳转"。
//
// 清单放在 NAS（https://ezbookx.x.ddnsto.com/api/nestkeep/latest-trilium.json），
// 与巢记共用同一条无鉴权下载路由（放行 *.ipa 与 latest*.json）。
// 国内直连 GitHub 不可靠，所以走 NAS。

import pkg from '../package.json' with { type: 'json' };
import axios from 'axios';

const MANIFEST_URL = 'https://ezbookx.x.ddnsto.com/api/nestkeep/latest-trilium.json';
const IPA_URL_FALLBACK = 'https://ezbookx.x.ddnsto.com/api/nestkeep/trilium-mobile.ipa';

/** 当前版本：CI 构建前会把 package.json 的 version 改成 1.0.xx.xx，打包时一起进来 */
export const APP_VERSION = pkg.version || '0.0.0';

function parseVersion(v) {
  return String(v || '').replace(/^v/i, '').split('.').map((n) => parseInt(n, 10) || 0);
}

/** a 是否比 b 新（按数字段比较，兼容 1.0.00.05 / v1.2.3 等格式） */
export function isNewer(a, b) {
  const va = parseVersion(a);
  const vb = parseVersion(b);
  for (let i = 0; i < Math.max(va.length, vb.length); i++) {
    const d = (va[i] || 0) - (vb[i] || 0);
    if (d) return d > 0;
  }
  return false;
}

/** 拉取远端清单，返回 { current, latest, ipaUrl, hasUpdate }；网络失败会 throw。
 *
 *  ⚠️ 「检查更新」曾报 Load failed 的根因（2026-10-16 读 iOS 原生源码定位）：
 *  iOS 上启用了 CapacitorHttp（绕 CORS 必需），它把 window.fetch 做了 patch，
 *  而 patch 后的 fetch 分两条路（见 @capacitor/ios/.../native-bridge.js）：
 *    · GET/HEAD/OPTIONS/TRACE → createProxyUrl() 拼成
 *        <serverUrl>/_capacitor_http_interceptor_?u=<编码后的真URL>
 *      再交给 WKWebView，依赖原生 WebViewAssetHandler 拦截转发 —— 对**外站 HTTPS** 不稳，报 Load failed
 *    · POST/PUT/PATCH/DELETE → cap.nativePromise('CapacitorHttp','request') 原生网络栈直连 —— 稳定
 *  笔记读写以 POST/PUT/PATCH 为主，所以一直正常；唯独「检查更新」是纯 GET，才暴露这个问题。
 *
 *  因此这里不再依赖被 patch 的 fetch，直接调 CapacitorHttp 插件的原生方法（等价于 POST 那条稳定路径），
 *  拿不到插件时再退回 fetch。失败时把每条的错因都带上，便于在 App 里直接定位。 */
export async function checkUpdate() {
  const m = await fetchManifest();
  const latest = String(m.version || '');
  return {
    current: APP_VERSION,
    latest,
    ipaUrl: m.ipaUrl || IPA_URL_FALLBACK,
    hasUpdate: isNewer(latest, APP_VERSION),
  };
}

/** 导出给「连接自检」用：单独探测清单可达性，并报告是哪条通道打通的 */
export async function probeManifest() {
  try {
    const { data, via } = await fetchManifestDetailed();
    return { ok: true, version: String(data.version || ''), url: MANIFEST_URL, via };
  } catch (e) {
    return { ok: false, error: e && e.message ? e.message : String(e), url: MANIFEST_URL };
  }
}

async function fetchManifest() {
  return (await fetchManifestDetailed()).data;
}

/**
 * 把各通道返回的清单统一成对象。
 * CapacitorHttp 原生层在 content-type 含 json 时**已经解析过了**（res.data 是对象），
 * 再 JSON.parse 一次就会抛 "cannot parse response"；而 axios/fetch 可能给字符串。
 * 这里统一兜住：对象直接用，字符串才 parse，解析失败就给出可读错误。
 */
function normalizeManifest(raw) {
  if (raw && typeof raw === 'object') return raw;
  if (typeof raw !== 'string' || !raw.trim()) {
    throw new Error('清单为空（HTTP 层成功但无响应体）');
  }
  try {
    return JSON.parse(raw);
  } catch {
    throw new Error('清单不是合法 JSON：' + raw.slice(0, 60));
  }
}

async function fetchManifestDetailed() {
  // 通道① 直接调 CapacitorHttp 插件的原生 request（只支持原生平台；web 上会 throw）
  //   这条等价于笔记写操作走的稳定路径，不经过 patch 后的 fetch proxy。
  // 通道② axios（其 XHR 在 iOS 上会被 patch，作为兜底）
  // 通道③ 裸 fetch（桌面/浏览器调试场景）
  const attempts = [
    ['capacitor-http', async () => {
      const { CapacitorHttp } = await import('@capacitor/core');
      const res = await CapacitorHttp.request({
        url: MANIFEST_URL,
        method: 'GET',
        headers: { 'Cache-Control': 'no-cache' },
        connectTimeout: 20000,
        readTimeout: 20000,
      });
      if (res.status < 200 || res.status >= 300) throw new Error(`HTTP ${res.status}`);
      // ⚠️ 原生层会按 content-type 自动解析：application/json 时 res.data 已是**对象**，
      // 不要再 JSON.parse 一次（否则 "cannot parse response"）。只有拿到字符串才 parse。
      return normalizeManifest(res.data);
    }],
    ['axios', async () => normalizeManifest((await axios.get(MANIFEST_URL, { timeout: 20000, headers: { 'Cache-Control': 'no-cache' } })).data)],
    ['fetch', async () => {
      const r = await fetch(MANIFEST_URL, { cache: 'no-store' });
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      return normalizeManifest(await r.text());
    }],
  ];
  const errs = [];
  for (const [name, fn] of attempts) {
    try { return { data: await fn(), via: name }; } catch (e) {
      errs.push(`${name}: ${(e && e.message) || e}`);
    }
  }
  throw new Error(errs.join(' | '));
}

/** 跳转 TrollStore 安装（覆盖安装，数据保留）。a.click() 让 Capacitor 把自定义协议交给系统 */
export function startTrollStoreUpdate(ipaUrl) {
  const a = document.createElement('a');
  a.href = 'apple-magnifier://install?url=' + encodeURIComponent(ipaUrl);
  document.body.appendChild(a);
  a.click();
  a.remove();
}
