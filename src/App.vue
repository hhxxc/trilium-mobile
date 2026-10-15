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

// SF Symbols 风格线性图标（clock / list / magnifier / sliders）
const ICONS = {
  recent: '<circle cx="12" cy="12" r="8.25"/><path d="M12 7.75V12l2.75 1.75"/>',
  tree: '<path d="M9 6.5h11M9 12h11M9 17.5h11"/><path d="M4.6 6.5h.01M4.6 12h.01M4.6 17.5h.01"/>',
  search: '<circle cx="11" cy="11" r="6.5"/><path d="M15.8 15.8L20 20"/>',
  settings: '<path d="M4 8h9.5M19.5 8H20M4 16h.5M10.5 16H20"/><circle cx="16.5" cy="8" r="2.2"/><circle cx="7.5" cy="16" r="2.2"/>',
};
function iconSvg(id) {
  return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">' + ICONS[id] + '</svg>';
}

const tabs = [
  { id: 'recent', icon: 'recent', label: '最近' },
  { id: 'tree', icon: 'tree', label: '笔记树' },
  { id: 'search', icon: 'search', label: '搜索' },
  { id: 'settings', icon: 'settings', label: '设置' },
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
      <RecentView v-if="tab === 'recent'" @open="openNote" @settings="tab = 'settings'" />
      <TreeView v-else-if="tab === 'tree'" @open="openNote" />
      <SearchView v-else-if="tab === 'search'" @open="openNote" />
      <SettingsView v-else />
    </div>
    <nav class="tabbar">
      <button
        v-for="t in tabs" :key="t.id" :class="{ active: tab === t.id }"
        @click="tab = t.id"
      >
        <span class="ico" v-html="iconSvg(t.icon)"></span>{{ t.label }}
      </button>
    </nav>
  </template>
</template>
