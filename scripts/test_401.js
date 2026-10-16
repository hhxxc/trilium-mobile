// 401 拦截逻辑单测：打桩 localStorage + window，直接跑 src/api.js 的拦截器行为。
// 跑法： node scripts/test_401.js
import assert from 'node:assert';

// ---- 打桩浏览器环境（api.js 顶层就会读 localStorage）----
const store = new Map();
globalThis.localStorage = {
  getItem: (k) => (store.has(k) ? store.get(k) : null),
  setItem: (k, v) => store.set(k, String(v)),
  removeItem: (k) => store.delete(k),
};
const listeners = new Map();
globalThis.window = {
  dispatchEvent: (ev) => { (listeners.get(ev.type) || []).forEach((f) => f(ev)); return true; },
  addEventListener: (t, f) => { if (!listeners.has(t)) listeners.set(t, []); listeners.get(t).push(f); },
};
globalThis.CustomEvent = class { constructor(type, opts) { this.type = type; this.detail = opts && opts.detail; } };

const { api, AUTH_EXPIRED_EVENT, saveSettings, resetAuthExpiredFlag, loadSettings } = await import('../src/api.js');

let fired = 0;
window.addEventListener(AUTH_EXPIRED_EVENT, () => { fired++; });

// ---- 用例 ----
const cases = [];
function ok(name, fn) { cases.push([name, fn]); }

ok('非 401 错误不触发', () => {
  resetAuthExpiredFlag();
  saveSettings({ token: 'tok-abc' });
  fired = 0;
  const h = api.interceptors.response.handlers.find((x) => x && x.rejected);
  h.rejected({ response: { status: 500 }, config: { url: '/etapi/notes' } });
  assert.strictEqual(fired, 0);
  assert.strictEqual(loadSettings().token, 'tok-abc', 'token 不该被清');
});

ok('业务接口 401 触发：清 token + 广播事件', () => {
  resetAuthExpiredFlag();
  saveSettings({ token: 'tok-abc' });
  fired = 0;
  const h = api.interceptors.response.handlers.find((x) => x && x.rejected);
  h.rejected({ response: { status: 401 }, config: { url: '/etapi/notes' } });
  assert.strictEqual(fired, 1, '应广播一次');
  assert.strictEqual(loadSettings().token, '', 'token 应被清空');
});

ok('登录接口自身 401（密码错）不触发', () => {
  resetAuthExpiredFlag();
  saveSettings({ token: '' });
  fired = 0;
  const h = api.interceptors.response.handlers.find((x) => x && x.rejected);
  h.rejected({ response: { status: 401 }, config: { url: 'https://x/etapi/auth/login' } });
  assert.strictEqual(fired, 0, '登录 401 不该被当成会话过期');
});

ok('同一轮多次 401 只广播一次（防重复踢）', () => {
  resetAuthExpiredFlag();
  saveSettings({ token: 'tok-abc' });
  fired = 0;
  const h = api.interceptors.response.handlers.find((x) => x && x.rejected);
  h.rejected({ response: { status: 401 }, config: { url: '/etapi/notes/a' } });
  h.rejected({ response: { status: 401 }, config: { url: '/etapi/notes/b' } });
  h.rejected({ response: { status: 401 }, config: { url: '/etapi/app-info' } });
  assert.strictEqual(fired, 1, '并发 401 只广播一次');
});

ok('重新登录后（resetAuthExpiredFlag）可再次触发', () => {
  saveSettings({ token: 'new-token' });
  resetAuthExpiredFlag();
  fired = 0;
  const h = api.interceptors.response.handlers.find((x) => x && x.rejected);
  h.rejected({ response: { status: 401 }, config: { url: '/etapi/notes' } });
  assert.strictEqual(fired, 1, '重置后应能再次触发');
});

// ---- 跑 ----
let pass = 0;
for (const [name, fn] of cases) {
  try { fn(); console.log('  ✓ ' + name); pass++; }
  catch (e) { console.log('  ✗ ' + name + '\n      ' + e.message); }
}
console.log(`\n${pass}/${cases.length} 通过`);
process.exit(pass === cases.length ? 0 : 1);
