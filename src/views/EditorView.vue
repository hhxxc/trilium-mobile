<script setup>
// 全屏编辑器（v1：标题 + 纯文本编辑正文；text 笔记的正文是 HTML，保存原样回写）
import { ref, onMounted } from 'vue';
import { getNote, getContent, putContent, patchNote, cacheUpsert } from '../api.js';

const props = defineProps({ noteId: { type: String, required: true } });
const emit = defineEmits(['close']);

const title = ref('');
const content = ref('');
const status = ref('');
const loading = ref(true);
const saving = ref(false);
const type = ref('text');

onMounted(async () => {
  try {
    const n = await getNote(props.noteId);
    title.value = n.title;
    type.value = n.type;
    if (['text', 'code'].includes(n.type)) {
      content.value = await getContent(props.noteId);
    } else {
      content.value = `（此笔记类型为 ${n.type}，v1 暂不支持在手机编辑，仅可改标题）`;
    }
  } catch (e) {
    status.value = '加载失败：' + (e.response ? e.response.status : e.message);
  } finally {
    loading.value = false;
  }
});

async function save() {
  if (saving.value) return;
  saving.value = true; status.value = '保存中…';
  try {
    await patchNote(props.noteId, { title: title.value });
    if (['text', 'code'].includes(type.value)) await putContent(props.noteId, content.value);
    cacheUpsert({ noteId: props.noteId, title: title.value });
    status.value = '已保存';
  } catch (e) {
    status.value = '保存失败：' + (e.response ? e.response.status : e.message);
  } finally {
    saving.value = false;
  }
}
</script>

<template>
  <div class="topbar nav">
    <span class="nav-btn" @click="emit('close')">‹ 返回</span>
    <span class="nav-status">{{ status }}</span>
    <span class="nav-btn" :class="{ disabled: saving }" @click="save">{{ saving ? '…' : '保存' }}</span>
  </div>
  <p v-if="loading" class="empty">加载中…</p>
  <template v-else>
    <div class="field" style="margin-top:14px;">
      <label>标题</label>
      <input v-model="title" />
    </div>
    <textarea v-model="content" class="editor-text" spellcheck="false"></textarea>
  </template>
</template>
