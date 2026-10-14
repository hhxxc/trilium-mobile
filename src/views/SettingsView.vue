<script setup>
// 设置：服务器地址 + 密码登录（换 ETAPI token）；启动锁（账号 + 本地解锁密码）
import { ref } from 'vue';
import { loadSettings, saveSettings, login, logout, appInfo } from '../api.js';
import { isLockEnabled, setLockPassword, clearLock, LOCK_ACCOUNT } from '../lock.js';

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
    status.value = info.value
      ? `已登录（Trilium ${info.value.appVersion || ''}）`
      : '已登录，但读取服务器信息失败，请检查密码与地址';
  } catch (e) {
    const code = e.response ? `HTTP ${e.response.status}` : e.message;
    const hint = !e.response
      ? '（连不上服务器：地址不对或不在同一网络）'
      : e.response.status === 401
        ? '（密码不对）'
        : e.response.status === 429
          ? '（失败次数过多，服务器暂时拉黑，等一会儿再试）'
          : '';
    status.value = `登录失败：${code}${hint}`;
  }
}

async function doLogout() {
  await logout();
  saveSettings({ token: '' });
  loggedIn.value = false;
  status.value = '已退出';
}

// ---------- 启动锁 ----------
const lockOn = ref(isLockEnabled());
const lockPwd = ref('');
const lockPwd2 = ref('');
const lockMsg = ref('');

function saveLock() {
  if (lockPwd.value.length < 4) { lockMsg.value = '解锁密码至少 4 位'; return; }
  if (lockPwd.value !== lockPwd2.value) { lockMsg.value = '两次输入不一致'; return; }
  const wasOn = lockOn.value;
  setLockPassword(lockPwd.value);
  lockOn.value = true;
  lockPwd.value = '';
  lockPwd2.value = '';
  lockMsg.value = `已${wasOn ? '更新' : '启用'}：下次打开 App 需输入「${LOCK_ACCOUNT} + 解锁密码」`;
}

function removeLock() {
  clearLock();
  lockOn.value = false;
  lockPwd.value = '';
  lockPwd2.value = '';
  lockMsg.value = '已关闭启动锁';
}
</script>

<template>
  <div class="topbar">设置</div>
  <template v-if="!loggedIn">
    <div class="field">
      <label>服务器地址（内网 http://192.168.31.198:18190 ；外网 https://dsm920-ddsnto-trilium-notes.x.ddnsto.com）</label>
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

  <div class="card" style="margin-top:20px;">
    <div class="title">启动锁</div>
    <div class="meta">
      {{ lockOn ? '已启用：每次打开 App 需「账号 + 解锁密码」' : '未启用：打开 App 直接进入' }}
    </div>
  </div>
  <div class="field">
    <label>账号（固定）</label>
    <input :value="LOCK_ACCOUNT" disabled />
  </div>
  <div class="field">
    <label>{{ lockOn ? '新的解锁密码' : '解锁密码' }}</label>
    <input v-model="lockPwd" type="password" placeholder="至少 4 位" />
  </div>
  <div class="field">
    <label>再输一次</label>
    <input v-model="lockPwd2" type="password" placeholder="确认密码" @keyup.enter="saveLock" />
  </div>
  <button class="btn" @click="saveLock">{{ lockOn ? '修改解锁密码' : '启用启动锁' }}</button>
  <button v-if="lockOn" class="btn secondary" @click="removeLock">关闭启动锁</button>
  <p v-if="lockMsg" style="font-size:13px; color:var(--muted); margin:8px 16px;">{{ lockMsg }}</p>
</template>
