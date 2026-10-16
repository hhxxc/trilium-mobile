<script setup>
// 布局方案 D 首页：最近笔记卡片流 + 底部速记条（速记落「收件箱」）
import { ref, onMounted, onUnmounted } from 'vue';
import { recentNotes, ensureInbox, createNote, readCache, writeCache, cacheUpsert, loadSettings } from '../api.js';

const emit = defineEmits(['open']);
const notes = ref(readCache());
const loading = ref(false);
const error = ref('');
const draft = ref('');
const saving = ref(false);

// ---------- 下拉刷新 ----------
const pullY = ref(0);
let tsY = 0, tsActive = false, tsOnTop = false;
function onTS(e) {
  const page = document.querySelector('.page');
  tsOnTop = !!(page && page.scrollTop <= 0);
  tsY = e.touches[0].clientY;
  tsActive = true;
}
function onTM(e) {
  if (!tsActive || !tsOnTop || loading.value) return;
  const dy = e.touches[0].clientY - tsY;
  if (dy > 0) pullY.value = Math.min(Math.round(dy * 0.45), 64);
}
async function onTE() {
  tsActive = false;
  const should = pullY.value > 44;
  pullY.value = should ? 52 : 0;
  if (should) await refresh();
  pullY.value = 0;
}
onMounted(() => {
  document.addEventListener('touchstart', onTS, { passive: true });
  document.addEventListener('touchmove', onTM, { passive: true });
  document.addEventListener('touchend', onTE);
});
onUnmounted(() => {
  document.removeEventListener('touchstart', onTS);
  document.removeEventListener('touchmove', onTM);
  document.removeEventListener('touchend', onTE);
});

function snippet(content) {
  const text = String(content || '').replace(/<[^>]+>/g, ' ').replace(/&nbsp;/g, ' ').trim();
  return text.slice(0, 80);
}

function fmtDate(iso) {
  if (!iso) return '';
  return iso.replace('T', ' ').slice(0, 16);
}

async function refresh() {
  loading.value = true; error.value = '';
  try {
    const list = await recentNotes(30);
    notes.value = list.map((n) => ({ ...n, _content: undefined }));
    writeCache(notes.value);
  } catch (e) {
    const code = e.response ? e.response.status : e.message;
    const hint = code === 404
      ? '（404＝服务器地址不对：外网 https://dsm920-ddsnto-trilium-notes.x.ddnsto.com，内网要带 :18190，别加 /etapi）'
      : code === 401
        ? '（401＝登录已失效，服务器可能重启过，请去设置页重新输入密码登录）'
        : '';
    error.value = '加载失败：' + code + hint + '（显示本地缓存）';
  } finally {
    loading.value = false;
  }
}

// 中文输入法用回车上屏候选词时不应触发保存（isComposing / 229 兼容）
function onEnter(e) {
  if (e.isComposing || e.keyCode === 229) return;
  quickSave();
}

async function quickSave() {
  const title = draft.value.trim().split('\n')[0].slice(0, 40) || '速记';
  const body = draft.value.trim();
  if (!body || saving.value) return;
  saving.value = true;
  try {
    const inboxId = await ensureInbox();
    const html = body.split(/\n{2,}/).map((p) => `<p>${p.replace(/\n/g, '<br>').replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]))}</p>`).join('');
    const created = await createNote(inboxId, title, html);
    cacheUpsert({ noteId: created.note.noteId, title, _local: true });
    draft.value = '';
    refresh();
  } catch (e) {
    error.value = '保存失败：' + (e.response ? e.response.status : e.message);
  } finally {
    saving.value = false;
  }
}

onMounted(() => { if (loadSettings().token) refresh(); });
</script>

<template>
  <div class="topbar large">最近</div>
  <div class="quickbar">
    <input v-model="draft" placeholder="记一笔…" @keyup.enter="onEnter" />
    <button :disabled="saving" @click="quickSave">↑</button>
  </div>
  <div class="pull-ind" :style="{ height: pullY + 'px', opacity: Math.min(pullY / 44, 1) }">
    <svg class="pull-spin" :class="{ spin: loading }" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round">
      <path d="M12 3a9 9 0 1 1-8.5 6" />
    </svg>
  </div>
  <p v-if="error" style="color:var(--red); font-size:13px; margin:8px 16px; line-height:1.5;">{{ error }}</p>
  <button v-if="error" class="btn secondary" style="margin-top:4px;" @click="emit('settings')">去设置页重新登录 / 检查地址</button>
  <p v-if="loading" class="empty">加载中…</p>
  <div v-for="n in notes" :key="n.noteId" class="card" @click="emit('open', n.noteId)">
    <div class="title">{{ n.title }}</div>
    <div v-if="snippet(n._content || n.content)" class="snippet">{{ snippet(n._content || n.content) }}</div>
    <div class="meta">{{ fmtDate(n.dateModified) }}{{ n._local ? ' · 本地' : '' }}</div>
  </div>
  <div v-if="!loading && !notes.length" class="empty">
    <div class="empty-ic">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="8.25"/><path d="M12 7.75V12l2.75 1.75"/></svg>
    </div>
    还没有笔记
    <div class="sub">在上方输入框记下第一笔吧</div>
  </div>
</template>
