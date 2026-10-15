// 启动锁：本地密码校验（不联网）
//
// 设计取舍：
// - 不用 crypto.subtle —— WKWebView 里 capacitor://localhost 不保证是 secure context，
//   crypto.subtle 可能 undefined，所以自带一份纯 JS SHA-256（已与 Node crypto 对拍验证）。
// - 只存 sha256(salt + ':' + 密码)，不存明文；salt 随机 16 字节。
// - 这是「界面层门禁」：防的是拿到手机的人直接翻笔记，不防能调试 WebView 的人。

// ---------- SHA-256（纯 JS） ----------
const K = new Uint32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]);

function rotr(x, n) { return (x >>> n) | (x << (32 - n)); }

export function sha256hex(message) {
  const bytes = new TextEncoder().encode(message);
  const len = bytes.length;
  const padded = new Uint8Array(Math.ceil((len + 9) / 64) * 64);
  padded.set(bytes);
  padded[len] = 0x80;
  const view = new DataView(padded.buffer);
  view.setUint32(padded.length - 8, Math.floor((len * 8) / 4294967296), false);
  view.setUint32(padded.length - 4, (len * 8) >>> 0, false);

  const H = new Uint32Array([
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ]);
  const w = new Uint32Array(64);

  for (let off = 0; off < padded.length; off += 64) {
    for (let i = 0; i < 16; i++) w[i] = view.getUint32(off + i * 4, false);
    for (let i = 16; i < 64; i++) {
      const x = w[i - 15];
      const y = w[i - 2];
      const s0 = rotr(x, 7) ^ rotr(x, 18) ^ (x >>> 3);
      const s1 = rotr(y, 17) ^ rotr(y, 19) ^ (y >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
    }
    let a = H[0], b = H[1], c = H[2], d = H[3], e = H[4], f = H[5], g = H[6], h = H[7];
    for (let i = 0; i < 64; i++) {
      const S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      const ch = (e & f) ^ (~e & g);
      const t1 = (h + S1 + ch + K[i] + w[i]) >>> 0;
      const S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const t2 = (S0 + maj) >>> 0;
      h = g; g = f; f = e; e = (d + t1) >>> 0;
      d = c; c = b; b = a; a = (t1 + t2) >>> 0;
    }
    H[0] = (H[0] + a) >>> 0; H[1] = (H[1] + b) >>> 0; H[2] = (H[2] + c) >>> 0; H[3] = (H[3] + d) >>> 0;
    H[4] = (H[4] + e) >>> 0; H[5] = (H[5] + f) >>> 0; H[6] = (H[6] + g) >>> 0; H[7] = (H[7] + h) >>> 0;
  }
  let out = '';
  for (let i = 0; i < 8; i++) out += H[i].toString(16).padStart(8, '0');
  return out;
}

// ---------- 锁配置 ----------
const LOCK_KEY = 'trilium-mobile-lock';
const BG_KEY = 'trilium-mobile-bg-at';

/** 允许的账号（大小写不敏感比较） */
export const LOCK_ACCOUNT = 'hhxxc';

function randomHex(bytes = 16) {
  const a = new Uint8Array(bytes);
  if (typeof crypto !== 'undefined' && crypto.getRandomValues) crypto.getRandomValues(a);
  else for (let i = 0; i < bytes; i++) a[i] = Math.floor(Math.random() * 256);
  return Array.from(a, (b) => b.toString(16).padStart(2, '0')).join('');
}

export function loadLock() {
  try { return JSON.parse(localStorage.getItem(LOCK_KEY) || '{}') || {}; } catch { return {}; }
}

export function isLockEnabled() {
  const c = loadLock();
  return !!(c.hash && c.salt);
}

/** 设置/修改解锁密码 */
export function setLockPassword(password, account = LOCK_ACCOUNT) {
  const salt = randomHex(16);
  localStorage.setItem(LOCK_KEY, JSON.stringify({
    account,
    salt,
    hash: sha256hex(`${salt}:${password}`),
    updatedAt: new Date().toISOString(),
  }));
}

export function clearLock() {
  localStorage.removeItem(LOCK_KEY);
  localStorage.removeItem(BG_KEY);
}

/** 校验 账号 + 密码；未启用锁时恒为 true */
export function verifyUnlock(account, password) {
  const c = loadLock();
  if (!c.hash) return true;
  const want = (c.account || LOCK_ACCOUNT).toLowerCase();
  const got = String(account || '').trim().toLowerCase();
  if (got !== want) return false;
  return sha256hex(`${c.salt}:${password || ''}`) === c.hash;
}

// ---------- 切到后台再回来是否要重新上锁 ----------
// 2026-10-15 放宽（用户反馈"太烦"）：60s → 5 分钟；并新增冷启动宽限。
const RELOCK_GRACE_MS = 5 * 60 * 1000;   // 切后台 5 分钟内回来不重锁
const COLD_GRACE_MS = 2 * 60 * 1000;     // 解锁后 2 分钟内冷启动（App 被系统杀掉重开）不重锁
const LAST_UNLOCK_KEY = 'trilium-mobile-last-unlock';

export function markBackgrounded() {
  localStorage.setItem(BG_KEY, String(Date.now()));
}

export function shouldRelockOnResume() {
  const t = Number(localStorage.getItem(BG_KEY) || 0);
  localStorage.removeItem(BG_KEY);
  return isLockEnabled() && t > 0 && Date.now() - t > RELOCK_GRACE_MS;
}

/** 解锁成功时记录时间，供冷启动宽限判断 */
export function markUnlocked() {
  localStorage.setItem(LAST_UNLOCK_KEY, String(Date.now()));
}

/** 冷启动时：距上次解锁不足 COLD_GRACE_MS 就不再锁（快速关掉重开的场景） */
export function isRecentlyUnlocked() {
  const t = Number(localStorage.getItem(LAST_UNLOCK_KEY) || 0);
  return t > 0 && Date.now() - t < COLD_GRACE_MS;
}

/** 重新上锁时清掉宽限标记（后台超时重锁 / 主动锁定） */
export function clearUnlockGrace() {
  localStorage.removeItem(LAST_UNLOCK_KEY);
}
