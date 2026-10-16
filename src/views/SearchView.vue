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
  <div class="topbar large">搜索</div>
  <div class="quickbar">
    <input v-model="query" placeholder="全文搜索…" @keyup.enter="doSearch" />
    <button :disabled="loading" @click="doSearch">
      <svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><circle cx="11" cy="11" r="6.5"/><path d="M15.8 15.8L20 20"/></svg>
    </button>
  </div>
  <template v-if="loading">
    <div v-for="i in 4" :key="'sk' + i" class="list skel" style="padding:14px 16px;">
      <div class="bar t"></div>
      <div class="bar s"></div>
    </div>
  </template>
  <template v-else-if="results.length">
    <div class="group-h">结果 {{ results.length }}</div>
    <div class="list">
      <div v-for="n in results" :key="n.noteId" class="row" @click="emit('open', n.noteId)">
        <div class="row-main">
          <div class="row-title">{{ n.title }}</div>
        </div>
        <div class="row-side"><span class="chev">›</span></div>
      </div>
    </div>
  </template>
  <div v-if="!loading && searched && !results.length" class="empty">
    <div class="empty-ic">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"><circle cx="11" cy="11" r="6.5"/><path d="M15.8 15.8L20 20"/></svg>
    </div>
    没有匹配的笔记
    <div class="sub">换个关键词再试一次</div>
  </div>
</template>
