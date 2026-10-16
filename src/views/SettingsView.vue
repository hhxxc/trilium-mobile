<script setup>
// 设置：服务器地址 + 密码登录（换 ETAPI token）；启动锁（账号 + 本地解锁密码）
import { ref, onMounted, watch } from 'vue';
import { loadSettings, saveSettings, login, logout, appInfo, resetAuthExpiredFlag, diagnose } from '../api.js';

const props = defineProps({ notice: { type: String, default: '' } });
const emit = defineEmits(['notice-consumed']);
import { isLockEnabled, setLockPassword, clearLock, LOCK_ACCOUNT } from '../lock.js';
import { APP_VERSION, checkUpdate, startTrollStoreUpdate } from '../update.js';

const settings = loadSettings();
const server = ref(settings.server);
const password = ref('');
const status = ref('');
const loggedIn = ref(!!settings.token);
const info = ref(null);

// 从外部（如 token 失效被踢回来）带进来的提示，直接显示出来
watch(() => props.notice, (v) => {
  if (v) { status.value = v; emit('notice-consumed'); }
}, { immediate: true });

async function doLogin() {
  status.value = '连接中…';
  try {
    const token = await login(server.value, password.value);
    saveSettings({ server: server.value.replace(/\/+$/, ''), token });
    resetAuthExpiredFlag();
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

// ---------- 连接自检 ----------
const diagOut = ref('');
const diagBusy = ref(false);
async function doDiagnose() {
  diagBusy.value = true;
  diagOut.value = '检测中…';
  try {
    diagOut.value = await diagnose(server.value, loadSettings().token);
  } catch (e) {
    diagOut.value = '检测异常：' + (e.message || e);
  } finally {
    diagBusy.value = false;
  }
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

// ---------- 应用内更新 ----------
const upd = ref(null);        // checkUpdate() 的结果
const updMsg = ref('');       // 检查/更新过程提示
const updChecking = ref(false);

async function doCheckUpdate(silent = false) {
  if (!silent) updChecking.value = true;
  updMsg.value = silent ? '' : '检查中…';
  try {
    upd.value = await checkUpdate();
    if (upd.value.hasUpdate) updMsg.value = '';
    else updMsg.value = silent ? '' : '已是最新版本';
  } catch (e) {
    if (!silent) updMsg.value = '检查失败：' + (e.message || '网络不可达');
  } finally {
    updChecking.value = false;
  }
}

function doUpdate() {
  if (!upd.value) return;
  updMsg.value = '正在拉起 TrollStore…（它会下载并覆盖安装，数据保留）';
  startTrollStoreUpdate(upd.value.ipaUrl);
}

onMounted(() => { doCheckUpdate(true); });
</script>

<template>
  <div class="topbar">设置</div>
  <template v-if="!loggedIn">
    <div class="field">
      <label>服务器地址（默认 ddnsto 公网，家内外通用；在家可改内网 http://192.168.31.198:18190 更快）</label>
      <input v-model="server" placeholder="https://dsm920-ddsnto-trilium-notes.x.ddnsto.com" />
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
  <button class="btn secondary" :disabled="diagBusy" @click="doDiagnose">{{ diagBusy ? '检测中…' : '连接自检' }}</button>
  <pre v-if="diagOut" style="font-size:12px; color:var(--muted); margin:8px 16px; white-space:pre-wrap; line-height:1.6; font-family:inherit;">{{ diagOut }}</pre>

  <div class="card" style="margin-top:20px;">
    <div class="title">更新</div>
    <div class="meta">当前版本 v{{ APP_VERSION }}<template v-if="upd && upd.hasUpdate"> · 发现新版本 v{{ upd.latest }}</template></div>
  </div>
  <p v-if="updMsg" style="font-size:13px; color:var(--muted); margin:8px 16px;">{{ updMsg }}</p>
  <button class="btn secondary" :disabled="updChecking" @click="doCheckUpdate(false)">{{ updChecking ? '检查中…' : '检查更新' }}</button>
  <button v-if="upd && upd.hasUpdate" class="btn" @click="doUpdate">更新到 v{{ upd.latest }}</button>

  <div class="card" style="margin-top:20px;">
    <div class="title">启动锁</div>
    <div class="meta">
      {{ lockOn ? '已启用：冷启动/切后台超 5 分钟需解锁（刚解锁过 2 分钟内免锁）' : '未启用：打开 App 直接进入' }}
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
