<script setup>
import { ref } from 'vue';
import { searchNotes } from '../api.js';

const emit = defineEmits(['open']);
const query = ref('');
const results = ref([]);
const loading = ref(false);
const searched = ref(false);

async function doSearch() {
  if (!query.value.trim()) return;
  loading.value = true; searched.value = true;
  try {
    results.value = await searchNotes(query.value.trim(), 30);
  } catch {
    results.value = [];
  } finally {
    loading.value = false;
  }
}
</script>

<template>
  <div class="topbar">搜索</div>
  <div class="quickbar">
    <input v-model="query" placeholder="全文搜索…" @keyup.enter="doSearch" />
    <button :disabled="loading" @click="doSearch">⌕</button>
  </div>
  <p v-if="loading" class="empty">搜索中…</p>
  <div v-for="n in results" :key="n.noteId" class="card" @click="emit('open', n.noteId)">
    <div class="title">{{ n.title }}</div>
  </div>
  <div v-if="!loading && searched && !results.length" class="empty">没有匹配的笔记</div>
</template>
