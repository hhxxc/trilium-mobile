<script setup>
// 布局 C：面包屑层级浏览（Trilium 树天然契合）
import { ref } from 'vue';
import { getNote } from '../api.js';

const emit = defineEmits(['open']);
const crumbs = ref([{ noteId: 'root', title: 'root' }]);
const children = ref([]);
const loading = ref(false);
const error = ref('');

async function loadChildren(noteId) {
  loading.value = true; error.value = '';
  try {
    const n = await getNote(noteId);
    const kids = [];
    for (const id of n.childNoteIds || []) {
      try { kids.push(await getNote(id)); } catch { /* 跳过 */ }
    }
    children.value = kids;
  } catch (e) {
    error.value = '加载失败：' + (e.response ? e.response.status : e.message);
  } finally {
    loading.value = false;
  }
}

async function enter(c) {
  crumbs.value = crumbs.value.slice(0, crumbs.value.findIndex((x) => x.noteId === c.noteId) + 1);
  await loadChildren(c.noteId);
}

async function openRow(n) {
  if ((n.childNoteIds || []).length > 0) {
    crumbs.value.push({ noteId: n.noteId, title: n.title });
    await loadChildren(n.noteId);
  } else {
    emit('open', n.noteId);
  }
}

loadChildren('root');
</script>

<template>
  <div class="topbar">
    <span v-for="(c, i) in crumbs" :key="c.noteId" style="margin-right:6px;">
      <template v-if="i > 0">› </template>
      <span :style="i === crumbs.length - 1 ? 'color:var(--text)' : 'color:var(--muted)'" @click="enter(c)">{{ c.title }}</span>
    </span>
  </div>
  <p v-if="error" style="color:#a32d2d; font-size:13px; margin:8px 16px;">{{ error }}</p>
  <p v-if="loading" class="empty">加载中…</p>
  <div
    v-for="n in children" :key="n.noteId"
    class="tree-row" :class="{ folder: (n.childNoteIds || []).length > 0 }"
    @click="openRow(n)"
  >
    <span class="name">{{ n.title }}</span>
    <span class="arrow">{{ (n.childNoteIds || []).length > 0 ? '›' : '' }}</span>
  </div>
  <div v-if="!loading && !children.length" class="empty">此级无子笔记</div>
</template>
