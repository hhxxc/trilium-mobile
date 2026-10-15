// 应用内检查更新：读 NAS 清单 → 有新版就交给 TrollStore 安装
//
// 原理：TrollStore 注册了 apple-magnifier://install?url=<ipa地址> 协议，
// 跳过去它会自己下载安装（覆盖安装、数据保留）。App 只负责"发现新版本 + 发起跳转"。
//
// 清单放在 NAS（https://ezbookx.x.ddnsto.com/api/nestkeep/latest-trilium.json），
// 与巢记共用同一条无鉴权下载路由（放行 *.ipa 与 latest*.json）。
// 国内直连 GitHub 不可靠，所以走 NAS。

import pkg from '../package.json' with { type: 'json' };

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

/** 拉取远端清单，返回 { current, latest, ipaUrl, hasUpdate }；网络失败会 throw */
export async function checkUpdate() {
  const r = await fetch(MANIFEST_URL, { cache: 'no-store' });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  const m = await r.json();
  const latest = String(m.version || '');
  return {
    current: APP_VERSION,
    latest,
    ipaUrl: m.ipaUrl || IPA_URL_FALLBACK,
    hasUpdate: isNewer(latest, APP_VERSION),
  };
}

/** 跳转 TrollStore 安装（覆盖安装，数据保留）。a.click() 让 Capacitor 把自定义协议交给系统 */
export function startTrollStoreUpdate(ipaUrl) {
  const a = document.createElement('a');
  a.href = 'apple-magnifier://install?url=' + encodeURIComponent(ipaUrl);
  document.body.appendChild(a);
  a.click();
  a.remove();
}
