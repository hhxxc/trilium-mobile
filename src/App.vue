<script setup>
import { ref, computed, onMounted, onUnmounted } from 'vue';
import { loadSettings } from './api.js';
import { isLockEnabled, markBackgrounded, shouldRelockOnResume, markUnlocked, isRecentlyUnlocked, clearUnlockGrace } from './lock.js';
import LockView from './views/LockView.vue';
import RecentView from './views/RecentView.vue';
import TreeView from './views/TreeView.vue';
import SearchView from './views/SearchView.vue';
import SettingsView from './views/SettingsView.vue';
import EditorView from './views/EditorView.vue';

const tabs = [
  { id: 'recent', icon: '▤', label: '最近' },
  { id: 'tree', icon: '☰', label: '笔记树' },
  { id: 'search', icon: '⌕', label: '搜索' },
  { id: 'settings', icon: '⚙', label: '设置' },
];

// 启动锁：启用了就先进锁屏；解锁状态只保存在内存里。
// 宽限优化（2026-10-15）：解锁后 2 分钟内冷启动不再锁；切后台 5 分钟内回来不重锁。
const locked = ref(isLockEnabled() && !isRecentlyUnlocked());
function unlock() { locked.value = false; markUnlocked(); }

const tab = ref(loadSettings().token ? 'recent' : 'settings');
const editorNoteId = ref(null);

const isEditing = computed(() => editorNoteId.value !== null);

function openNote(id) { editorNoteId.value = id; }
function closeEditor() { editorNoteId.value = null; }

// 切后台超过 5 分钟再回来 → 重新上锁
function onHide() { markBackgrounded(); }
function onShow() { if (shouldRelockOnResume()) { clearUnlockGrace(); locked.value = true; } }
function onVisibility() { if (document.hidden) onHide(); else onShow(); }

onMounted(() => {
  document.addEventListener('visibilitychange', onVisibility);
  window.addEventListener('pagehide', onHide);
  window.addEventListener('pageshow', onShow);
});
onUnmounted(() => {
  document.removeEventListener('visibilitychange', onVisibility);
  window.removeEventListener('pagehide', onHide);
  window.removeEventListener('pageshow', onShow);
});
</script>

<template>
  <LockView v-if="locked" @unlock="unlock" />
  <EditorView v-else-if="isEditing" :note-id="editorNoteId" @close="closeEditor" />
  <template v-else>
    <div class="page">
      <RecentView v-if="tab === 'recent'" @open="openNote" />
      <TreeView v-else-if="tab === 'tree'" @open="openNote" />
      <SearchView v-else-if="tab === 'search'" @open="openNote" />
      <SettingsView v-else />
    </div>
    <nav class="tabbar">
      <button
        v-for="t in tabs" :key="t.id" :class="{ active: tab === t.id }"
        @click="tab = t.id"
      >
        <span class="ico">{{ t.icon }}</span>{{ t.label }}
      </button>
    </nav>
  </template>
</template>
