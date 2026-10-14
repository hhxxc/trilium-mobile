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

export async function searchNotes(query, limit = 30) {
  const { data } = await api.get('/etapi/search-notes', {
    params: { search: query },
  });
  return (data.results || data || []).slice(0, limit); // { results: [ {noteId,title,...} ] }
}

/** 最近修改的笔记：用搜索语法 order by dateModified desc（Trilium 搜索支持） */
export async function recentNotes(limit = 30) {
  const { data } = await api.get('/etapi/search-notes', {
    params: { search: `order by dateModified desc limit ${limit}` },
  });
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
