<script setup>
import { ref, computed } from 'vue';
import { loadSettings } from './api.js';
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
const tab = ref(loadSettings().token ? 'recent' : 'settings');
const editorNoteId = ref(null);

const isEditing = computed(() => editorNoteId.value !== null);

function openNote(id) { editorNoteId.value = id; }
function closeEditor() { editorNoteId.value = null; }
</script>

<template>
  <EditorView v-if="isEditing" :note-id="editorNoteId" @close="closeEditor" />
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
