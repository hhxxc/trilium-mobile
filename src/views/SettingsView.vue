<script setup>
// 设置：服务器地址 + 密码登录（换 ETAPI token）
import { ref } from 'vue';
import { loadSettings, saveSettings, login, logout, appInfo } from '../api.js';
import { FALLBACK_SERVER } from '../config.js';

const settings = loadSettings();
const server = ref(settings.server);
const password = ref('');
const status = ref('');
const loggedIn = ref(!!settings.token);
const info = ref(null);

async function doLogin() {
  status.value = '连接中…';
  try {
    const token = await login(server.value, password.value);
    saveSettings({ server: server.value.replace(/\/+$/, ''), token });
    loggedIn.value = true;
    password.value = '';
    try { info.value = await appInfo(); } catch { info.value = null; }
    status.value = '已登录' + (info.value ? `（Trilium ${info.value.appVersion || ''}）` : '');
  } catch (e) {
    status.value = '登录失败：' + (e.response ? e.response.status : e.message)
      + `。检查地址是否正确（外网请改用 ${FALLBACK_SERVER} 或 Tailscale 地址）`;
  }
}

async function doLogout() {
  await logout();
  saveSettings({ token: '' });
  loggedIn.value = false;
  status.value = '已退出';
}
</script>

<template>
  <div class="topbar">设置</div>
  <template v-if="!loggedIn">
    <div class="field">
      <label>服务器地址（内网 31.198 / 星空 188.2 / Tailscale 100.95.218.4，端口 18190）</label>
      <input v-model="server" placeholder="http://192.168.31.198:18190" />
    </div>
    <div class="field">
      <label>Trilium 登录密码</label>
      <input v-model="password" type="password" placeholder="密码" @keyup.enter="doLogin" />
    </div>
    <button class="btn" @click="doLogin">登录</button>
  </template>
  <template v-else>
    <div class="card">
      <div class="title">已连接</div>
      <div class="meta">{{ server }}</div>
    </div>
    <button class="btn secondary" @click="doLogout">退出登录</button>
  </template>
  <p v-if="status" style="font-size:13px; color:var(--muted); margin:8px 16px;">{{ status }}</p>
</template>
