// 应用内检查更新：读 NAS 清单 → 有新版就交给 TrollStore / AltStore 安装
//
// 原理：装一个 URL scheme 协议（TrollStore 是 apple-magnifier://，AltStore 是 altstore://），
// 跳过去它会自己下载安装（覆盖安装、数据保留）。App 只负责"发现新版本 + 发起跳转"。
//
// 清单放在 NAS（https://ezbookx.x.ddnsto.com/api/nestkeep/latest-trilium.json），
// 与巢记共用同一条无鉴权下载路由（放行 *.ipa 与 latest*.json）。
// 国内直连 GitHub 不可靠，所以走 NAS。
//
// ⚠️ 历史坑（都别踩回去）：
//  1) 路由前缀是 /api/nestkeep（与巢记共用），拼错整个 404
//  2) 该路由**只放行 GET，HEAD 返回 404** → 探活一律用 GET
//  3) HTTP 层必须显式 Accept 非 html；若返回 text/html + chunked，说明被某个中间层
//     （运营商网关 / ddnsto 的登录页）劫持了，不是真清单 → 直接判失败并报出来

import pkg from '../package.json' with { type: 'json' };
import axios from 'axios';

const MANIFEST_URL = 'https://ezbookx.x.ddnsto.com/api/nestkeep/latest-trilium.json';
const IPA_URL_FALLBACK = 'https://ezbookx.x.ddnsto.com/api/nestkeep/trilium-mobile.ipa';

/** 当前版本：CI 构建前会把 package.json 的 version 改成 1.0.xx.xx，打包时一起进来 */
export const APP_VERSION = pkg.version || '0.0.0';

/** 支持的安装器协议，按顺序尝试；也可以由清单里的 `schemes` 字段覆盖 */
const DEFAULT_SCHEMES = [
  { key: 'apple-magnifier', name: 'TrollStore', url: (ipa) => 'apple-magnifier://install?url=' + encodeURIComponent(ipa) },
  { key: 'altstore', name: 'AltStore', url: (ipa) => 'altstore://install?url=' + encodeURIComponent(ipa) },
  { key: 'sidestore', name: 'SideStore', url: (ipa) => 'sidestore://install?url=' + encodeURIComponent(ipa) },
];

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

/** 拉取远端清单，返回 { current, latest, ipaUrl, hasUpdate }；网络失败会 throw。 */
export async function checkUpdate() {
  const { data: m, via, contentType, bytes } = await fetchManifestDetailed();
  const latest = String(m.version || '');
  return {
    current: APP_VERSION,
    latest,
    ipaUrl: m.ipaUrl || IPA_URL_FALLBACK,
    schemes: Array.isArray(m.schemes) ? m.schemes : null,
    hasUpdate: isNewer(latest, APP_VERSION),
    via,
    contentType,
    bytes,
  };
}

/** 导出给「连接自检」用：单独探测清单可达性，并报告是哪条通道打通的 */
export async function probeManifest() {
  try {
    const { data, via, contentType, bytes } = await fetchManifestDetailed();
    return { ok: true, version: String(data.version || ''), url: MANIFEST_URL, via, contentType, bytes };
  } catch (e) {
    return { ok: false, error: e && e.message ? e.message : String(e), url: MANIFEST_URL };
  }
}

/**
 * 把各通道返回的响应体统一成对象。
 * CapacitorHttp 原生层在 content-type 含 json 时**已经解析过了**（res.data 是对象），
 * 再 JSON.parse 一次就会抛 "cannot parse response"；而 axios/fetch 可能给字符串。
 * 这里统一兜住：对象直接用，字符串才 parse，解析失败就给出可读错误。
 */
function normalizeManifest(raw) {
  if (raw && typeof raw === 'object') return raw;
  if (typeof raw !== 'string' || !raw.trim()) {
    throw new Error('清单为空（HTTP 层成功但无响应体）');
  }
  const s = raw.trim();
  // 被劫持成 HTML 是常见故障（热点/运营商网关拦截），单独给一眼能懂的结论
  if (/^</.test(s)) {
    throw new Error('返回的不是清单而是网页（可能被网络劫持）→ ' + s.slice(0, 60).replace(/\s+/g, ' '));
  }
  try {
    return JSON.parse(s);
  } catch {
    throw new Error('清单不是合法 JSON：' + s.slice(0, 60));
  }
}

/**
 * 依次尝试：① CapacitorHttp 原生 request（最稳，等价于笔记写操作走的路径）
 *            ② axios ③ 裸 fetch
 * 记录每条的错因，全失败时拼成一行给人看。
 */
async function fetchManifestDetailed() {
  const attempts = [
    ['capacitor-http', async () => {
      const { CapacitorHttp } = await import('@capacitor/core');
      const res = await CapacitorHttp.request({
        url: MANIFEST_URL,
        method: 'GET',
        headers: { 'Cache-Control': 'no-cache', Accept: 'application/json,*/*' },
        connectTimeout: 20000,
        readTimeout: 20000,
      });
      if (res.status < 200 || res.status >= 300) throw new Error(`HTTP ${res.status}`);
      const raw = res.data;
      const bytes = typeof raw === 'string' ? raw.length : JSON.stringify(raw || '').length;
      return { data: normalizeManifest(raw), contentType: headerOf(res.headers, 'content-type'), bytes };
    }],
    ['axios', async () => {
      const r = await axios.get(MANIFEST_URL, {
        timeout: 20000,
        responseType: 'text',
        transformResponse: [(d) => d],
        headers: { 'Cache-Control': 'no-cache', Accept: 'application/json,*/*' },
      });
      return { data: normalizeManifest(r.data), contentType: r.headers && r.headers['content-type'], bytes: (r.data || '').length };
    }],
    ['fetch', async () => {
      const r = await fetch(MANIFEST_URL, { cache: 'no-store', headers: { Accept: 'application/json,*/*' } });
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const text = await r.text();
      return { data: normalizeManifest(text), contentType: r.headers.get('content-type'), bytes: text.length };
    }],
  ];
  const errs = [];
  for (const [name, fn] of attempts) {
    try { return Object.assign(await fn(), { via: name }); } catch (e) {
      errs.push(`${name}: ${(e && e.message) || e}`);
    }
  }
  throw new Error(errs.join(' | '));
}

/** header 名大小写不敏感地取值 */
function headerOf(headers, name) {
  if (!headers || typeof headers !== 'object') return '';
  const key = Object.keys(headers).find((k) => k.toLowerCase() === name);
  return key ? String(headers[key]) : '';
}

/** 该安装器协议是否可用（跳转前先探一下，不可用就别乱跳） */
export function installerUrl(schemeKey, ipaUrl) {
  const s = DEFAULT_SCHEMES.find((x) => x.key === schemeKey);
  return s ? s.url(ipaUrl) : '';
}

/**
 * 拉起安装器。TrollStore 的 URL scheme（apple-magnifier）在它的 Info.plist 里注册；
 * 若跳转后没人接管，点击会静默失败 —— 所以这里把「怎么跳、跳哪个」的文本也返回，
 * 让界面能把兜底信息显示给用户。
 */
export function startTrollStoreUpdate(ipaUrl, schemeKey = 'apple-magnifier') {
  const url = installerUrl(schemeKey, ipaUrl);
  if (!url) throw new Error('未知的安装器协议：' + schemeKey);
  const a = document.createElement('a');
  a.href = url;
  document.body.appendChild(a);
  a.click();
  a.remove();
  return url;
}

/** 取消安卓/iOS 没装安装器时的兜底：直接下载 IPA（Safari 会存到"文件"） */
export function downloadDirect(ipaUrl) {
  const a = document.createElement('a');
  a.href = ipaUrl;
  a.target = '_blank';
  a.rel = 'noopener';
  document.body.appendChild(a);
  a.click();
  a.remove();
}
