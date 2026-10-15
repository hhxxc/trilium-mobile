<script setup>
// 启动锁：账号 + 密码才能进入
import { ref, onMounted } from 'vue';
import { LOCK_ACCOUNT, verifyUnlock } from '../lock.js';

const emit = defineEmits(['unlock']);
const account = ref(LOCK_ACCOUNT);
const password = ref('');
const status = ref('');
const pwdEl = ref(null);

onMounted(() => { setTimeout(() => pwdEl.value && pwdEl.value.focus(), 150); });

function tryUnlock() {
  if (!password.value) { status.value = '请输入密码'; return; }
  if (verifyUnlock(account.value, password.value)) {
    password.value = '';
    status.value = '';
    emit('unlock');
    return;
  }
  status.value = '账号或密码不对';
  password.value = '';
}
</script>

<template>
  <div class="topbar">已锁定</div>
  <div class="page">
    <div class="card">
      <div class="title">Trilium 笔记已锁定</div>
      <div class="meta">账号 {{ LOCK_ACCOUNT }} · 输入解锁密码进入</div>
    </div>
    <div class="field">
      <label>账号（固定为 {{ LOCK_ACCOUNT }}）</label>
      <input :value="LOCK_ACCOUNT" readonly autocapitalize="off" autocorrect="off" spellcheck="false" style="color:var(--muted);" />
    </div>
    <div class="field">
      <label>解锁密码</label>
      <input
        ref="pwdEl" v-model="password" type="password" placeholder="密码"
        @keyup.enter="tryUnlock"
      />
    </div>
    <button class="btn" @click="tryUnlock">解锁</button>
    <p v-if="status" style="font-size:13px; color:var(--muted); margin:8px 16px;">{{ status }}</p>
  </div>
</template>
