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

const isFolder = (n) => (n.childNoteIds || []).length > 0;

loadChildren('root');
</script>

<template>
  <div class="topbar topbar-left">
    <template v-for="(c, i) in crumbs" :key="c.noteId">
      <span v-if="i > 0" class="crumb-sep">›</span>
      <span class="crumb" :class="{ active: i === crumbs.length - 1 }" @click="enter(c)">{{ c.title }}</span>
    </template>
  </div>
  <p v-if="error" class="hint error">{{ error }}</p>
  <template v-if="loading">
    <div v-for="i in 6" :key="'sk' + i" class="card skel" style="padding:13px 16px;">
      <div class="bar t"></div>
    </div>
  </template>
  <div
    v-for="n in children" :key="n.noteId"
    class="tree-row" :class="{ folder: isFolder(n) }"
    @click="openRow(n)"
  >
    <span class="tree-ic" :class="{ leaf: !isFolder(n) }">
      <svg v-if="isFolder(n)" viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>
      <svg v-else viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M5 5h14M5 10h14M5 15h9"/></svg>
    </span>
    <span class="name">{{ n.title }}</span>
    <span v-if="isFolder(n)" class="tree-count">{{ (n.childNoteIds || []).length }}</span>
    <span class="arrow">›</span>
  </div>
  <div v-if="!loading && !children.length" class="empty">
    <div class="empty-ic">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>
    </div>
    此级无子笔记
    <div class="sub">这一层下面还没有内容</div>
  </div>
</template>
