// Trilium ETAPI 客户端
// 文档: https://github.com/TriliumNext/Trilium/blob/main/apps/server/src/etapi/etapi-openapi.yaml
import axios from 'axios';
import { DEFAULT_SERVER, DEFAULT_INBOX_TITLE, CACHE_LIMIT } from './config.js';

const LS_KEY = 'trilium-mobile-config';
const LS_CACHE = 'trilium-mobile-cache';

export function loadSettings() {
  try {
    const s = JSON.parse(localStorage.getItem(LS_KEY) || '{}');
    return {
      server: s.server || DEFAULT_SERVER,
      token: s.token || '',
      inboxNoteId: s.inboxNoteId || '',
      inboxTitle: s.inboxTitle || DEFAULT_INBOX_TITLE,
    };
  } catch {
    return { server: DEFAULT_SERVER, token: '', inboxNoteId: '', inboxTitle: DEFAULT_INBOX_TITLE };
  }
}

export function saveSettings(patch) {
  const merged = { ...loadSettings(), ...patch };
  localStorage.setItem(LS_KEY, JSON.stringify(merged));
  if (patch.token !== undefined || patch.server !== undefined) api.defaults.baseURL = merged.server;
  if (patch.token !== undefined) api.defaults.headers.common.Authorization = merged.token;
  return merged;
}

export const api = axios.create({ baseURL: loadSettings().server, timeout: 15000 });
api.defaults.headers.common.Authorization = loadSettings().token;

// ---------- 401 全局处理 ----------
// 服务端一旦重启/换令牌，存着的 ETAPI token 就失效了，此后每个请求都是 401。
// 老版本只是把 401 当成普通错误显示在页面上，于是 App 卡在"已登录但全 401"的死状态，
// 永远进不了登录页（2026-10-16 用户实测反馈）。这里统一拦截：清掉本地 token 并广播事件，
// 由 App.vue 把界面踢回设置页重新登录。
export const AUTH_EXPIRED_EVENT = 'trilium-mobile-auth-expired';
let authExpiredFired = false;

api.interceptors.response.use(
  (r) => r,
  (e) => {
    const status = e && e.response && e.response.status;
    // 登录接口本身返回 401 = 密码错，不该触发"会话过期"
    const url = (e && e.config && e.config.url) || '';
    if (status === 401 && !/\/auth\/login/.test(url)) {
      if (!authExpiredFired) {
        authExpiredFired = true;
        try { saveSettings({ token: '' }); } catch { /* 忽略 */ }
        try { window.dispatchEvent(new CustomEvent(AUTH_EXPIRED_EVENT)); } catch { /* 忽略 */ }
      }
    }
    return Promise.reject(e);
  },
);

/** 登录成功后重置标记，允许下一次过期再触发（避免只生效一次） */
export function resetAuthExpiredFlag() { authExpiredFired = false; }

/** 连接自检：逐段探测，返回可读的诊断文本。出问题时不用猜是哪一环挂了。 */
export async function diagnose(server, token) {
  const base = String(server || '').replace(/\/+$/, '');
  const lines = [];
  lines.push('地址：' + base);
  lines.push('本地 token：' + (token ? token.slice(0, 6) + '…（' + token.length + ' 位）' : '（无）'));

  // 1) 服务是否活着：不带鉴权打 app-info，401 = 服务在（只是需要令牌），200 = 服务在且免鉴权
  try {
    const r = await axios.get(base + '/etapi/app-info', { timeout: 15000, validateStatus: () => true });
    lines.push('服务可达：是（HTTP ' + r.status + '）');
    if (r.data && r.data.appVersion) lines.push('服务版本：' + r.data.appVersion);
  } catch (e) {
    const how = e.response ? 'HTTP ' + e.response.status : (e.message || '网络错误');
    lines.push('服务可达：否（' + how + '）');
    lines.push('→ 地址写错了、不在同一网络、或 NAS 又断了');
    return lines.join('\n');
  }

  // 2) 令牌是否有效
  if (!token) {
    lines.push('令牌有效性：未登录（请在上面输入密码登录）');
    return lines.join('\n');
  }
  try {
    const r = await axios.get(base + '/etapi/notes/root', {
      headers: { Authorization: token }, timeout: 15000, validateStatus: () => true,
    });
    if (r.status === 200) lines.push('令牌有效性：有效');
    else if (r.status === 401) lines.push('令牌有效性：失效（服务端重启过就会这样）→ 重新输入密码登录即可');
    else lines.push('令牌有效性：异常（HTTP ' + r.status + '）');
  } catch (e) {
    lines.push('令牌有效性：无法判断（' + (e.message || '网络错误') + '）');
  }
  return lines.join('\n');
}

// ---------- 认证 ----------

/** 用密码换 ETAPI token；ETAPI 无独立账号体系，密码 = 登录密码。
 *  注意：服务端返回体是 { authToken }（见 etapi.openapi.yaml 的 /auth/login 201 响应），
 *  老版本/其他实现可能用 { token }，这里两个都兼容。 */
export async function login(server, password) {
  const { data } = await axios.post(
    `${server.replace(/\/+$/, '')}/etapi/auth/login`,
    { password, tokenName: 'trilium-mobile' },
    { timeout: 15000 },
  );
  const token = data.authToken || data.token;
  if (!token) throw new Error('服务端未返回 token（响应: ' + JSON.stringify(data).slice(0, 120) + '）');
  return token;
}

export async function logout() {
  try { await api.post('/etapi/auth/logout'); } catch { /* 忽略 */ }
}

export async function appInfo() {
  const { data } = await api.get('/etapi/app-info');
  return data;
}

// ---------- 笔记 ----------

export async function getNote(noteId) {
  const { data } = await api.get(`/etapi/notes/${noteId}`);
  return data; // { noteId, title, type, mime, childNoteIds, parentBranchIds, ... }
}

export async function getContent(noteId) {
  const { data } = await api.get(`/etapi/notes/${noteId}/content`, { responseType: 'text' });
  return data;
}

export async function putContent(noteId, content) {
  await api.put(`/etapi/notes/${noteId}/content`, content, {
    headers: { 'Content-Type': 'text/plain' },
  });
}

export async function patchNote(noteId, fields) {
  const { data } = await api.patch(`/etapi/notes/${noteId}`, fields);
  return data;
}

/** 创建子笔记（type=text 时 content 为 HTML） */
export async function createNote(parentNoteId, title, content = '', type = 'text') {
  const { data } = await api.post('/etapi/notes', {
    parentNoteId,
    title,
    type,
    mime: type === 'text' ? 'text/html' : undefined,
    content,
  });
  return data; // { note, branch }
}

/** 搜索笔记。
 *  ⚠️ TriliumNext v0.106 起搜索合并进 GET /etapi/notes?search=…（老版的 /etapi/search-notes 已 404），
 *  响应沿用 SearchResponse{results:[…]}；这里优先新路径，404 时回退老路径以兼容其他版本。 */
export async function searchNotes(query, limit = 30) {
  let data;
  try {
    ({ data } = await api.get('/etapi/notes', { params: { search: query } }));
  } catch (e) {
    if (e.response && e.response.status === 404) {
      ({ data } = await api.get('/etapi/search-notes', { params: { search: query } }));
    } else { throw e; }
  }
  return (data.results || data || []).slice(0, limit);
}

/** 最近修改的笔记：用搜索语法 order by dateModified desc（Trilium 搜索支持） */
export async function recentNotes(limit = 30) {
  let data;
  try {
    ({ data } = await api.get('/etapi/notes', { params: { search: `order by dateModified desc limit ${limit}` } }));
  } catch (e) {
    if (e.response && e.response.status === 404) {
      ({ data } = await api.get('/etapi/search-notes', { params: { search: `order by dateModified desc limit ${limit}` } }));
    } else { throw e; }
  }
  return data.results || data || [];
}

// ---------- 收件箱 ----------

/** 确保收件箱存在：在 root 下找标题匹配的子笔记，没有就创建 */
export async function ensureInbox() {
  const s = loadSettings();
  if (s.inboxNoteId) {
    try { await getNote(s.inboxNoteId); return s.inboxNoteId; } catch { /* 失效则重建 */ }
  }
  const root = await getNote('root');
  for (const childId of root.childNoteIds || []) {
    try {
      const n = await getNote(childId);
      if (n.title === s.inboxTitle) { saveSettings({ inboxNoteId: childId }); return childId; }
    } catch { /* 跳过 */ }
  }
  const created = await createNote('root', s.inboxTitle, '');
  saveSettings({ inboxNoteId: created.note.noteId });
  return created.note.noteId;
}

// ---------- 本地缓存（离线可看） ----------

export function readCache() {
  try { return JSON.parse(localStorage.getItem(LS_CACHE) || '[]'); } catch { return []; }
}

export function writeCache(notes) {
  localStorage.setItem(LS_CACHE, JSON.stringify(notes.slice(0, CACHE_LIMIT)));
}

export function cacheUpsert(note) {
  const list = readCache().filter((n) => n.noteId !== note.noteId);
  list.unshift(note);
  writeCache(list);
}
