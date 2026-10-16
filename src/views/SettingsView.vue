<script setup>
// 设置：服务器地址 + 密码登录（换 ETAPI token）+ 应用内更新
import { ref, onMounted, watch } from 'vue';
import { loadSettings, saveSettings, login, logout, appInfo, resetAuthExpiredFlag, diagnose } from '../api.js';

const props = defineProps({ notice: { type: String, default: '' } });
const emit = defineEmits(['notice-consumed']);
import { APP_VERSION, checkUpdate, startTrollStoreUpdate, probeManifest } from '../update.js';

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
    const base = await diagnose(server.value, loadSettings().token);
    const p = await probeManifest();
    const updLine = p.ok
      ? `更新清单：可达（服务端最新 v${p.version}，通道 ${p.via || '?'}）`
      : `更新清单：不可达 → ${p.error}\n  （地址 ${p.url}）`;
    diagOut.value = base + '\n' + updLine;
  } catch (e) {
    diagOut.value = '检测异常：' + (e.message || e);
  } finally {
    diagBusy.value = false;
  }
}

// ---------- 应用内更新（交互照抄巢记 NestKeep） ----------
const upd = ref(null);        // checkUpdate() 的结果
const updMsg = ref('');       // 检查/更新过程提示
const updChecking = ref(false);
const updDetail = ref('');    // 诊断细节（通道/HTTP/content-type/字节数）
const showDetail = ref(false);
const showSteps = ref(false); // 复制直链后显示安装步骤

async function doCheckUpdate(silent = false) {
  if (!silent) updChecking.value = true;
  updMsg.value = silent ? '' : '正在检查更新…';
  updDetail.value = '';
  try {
    upd.value = await checkUpdate();
    updDetail.value =
      `通道 ${upd.value.via}｜HTTP 200｜content-type ${upd.value.contentType || '(无)'}｜${upd.value.bytes} 字节\n` +
      `本地 v${upd.value.current} → 云端 v${upd.value.latest}`;
    if (upd.value.hasUpdate) {
      updMsg.value = '';   // 有新版时正文交给卡片展示
    } else {
      updMsg.value = silent ? '' : '已是最新版本';
    }
  } catch (e) {
    upd.value = null;
    if (!silent) updMsg.value = '无法获取版本信息：' + (e.message || '网络不可达');
  } finally {
    updChecking.value = false;
  }
}

/** 直接唤起 TrollStore（apple-magnifier）。若跳到「放大器」说明未接管 scheme，用复制直链兜底 */
function doUpdate() {
  if (!upd.value) return;
  try {
    startTrollStoreUpdate(upd.value.ipaUrl, 'apple-magnifier');
    updMsg.value = '已唤起 TrollStore。若跳到了「放大器」，说明 TrollStore 没接管放大器，用下面的复制直链粘贴安装即可。';
  } catch (e) {
    updMsg.value = '拉起失败：' + (e.message || e);
  }
}

/** 复制 IPA 直链（巢记模式兜底：到 TrollStore 里「从 URL 安装」粘贴） */
function doCopyLink() {
  if (!upd.value) return;
  const link = upd.value.ipaUrl;
  if (navigator.clipboard) {
    navigator.clipboard.writeText(link)
      .then(() => { showSteps.value = true; updMsg.value = '安装链接已复制。'; })
      .catch(() => { showSteps.value = true; updMsg.value = '复制失败，直链：' + link; });
  } else {
    showSteps.value = true;
    updMsg.value = '直链：' + link;
  }
}

function copyDetail() {
  const text = genCopyText();
  if (navigator.clipboard) {
    navigator.clipboard.writeText(text)
      .then(() => (updMsg.value = '已复制诊断信息'))
      .catch(() => (updDetail.value = text));
  } else {
    updDetail.value = text;
  }
}

function genCopyText() {
  return [
    `当前版本：v${APP_VERSION}`,
    upd.value ? `云端版本：v${upd.value.latest}` : '云端版本：未取到',
    upd.value ? `清单通道：${upd.value.via}` : '',
    updDetail.value,
    updMsg.value,
  ].filter(Boolean).join('\n');
}

onMounted(() => { doCheckUpdate(true); });
</script>

<template>
  <div class="topbar large">设置</div>
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

  <template v-if="upd && upd.hasUpdate">
    <button class="btn" @click="doUpdate">直接唤起 TrollStore 安装 v{{ upd.latest }}</button>
    <button class="btn secondary" @click="doCopyLink">复制直链</button>
    <p style="font-size:12px; color:var(--muted); margin:4px 16px 8px; line-height:1.6;">
      同变体会覆盖旧版并保留数据。点「直接唤起」后如果跳到了「放大器」，说明这台设备上
      TrollStore 没接管放大器，用「复制直链」到 TrollStore 里从 URL 安装即可。
    </p>
    <template v-if="showSteps">
      <div class="card" style="margin:8px 16px;">
        <div class="title" style="font-size:14px;">安装步骤</div>
        <div class="meta" style="line-height:1.8;">
          1. 打开 TrollStore<br />
          2. 点右上角「+」<br />
          3. 选「从 URL 安装」，粘贴链接<br />
          4. 确认安装（同变体才会覆盖旧版）
        </div>
      </div>
    </template>
  </template>

  <p v-if="updMsg" style="font-size:13px; color:var(--muted); margin:8px 16px;">{{ updMsg }}</p>
  <button class="btn secondary" :disabled="updChecking" @click="doCheckUpdate(false)">{{ updChecking ? '正在检查更新…' : '检查更新' }}</button>

  <button class="btn secondary" style="margin-top:8px;" @click="showDetail = !showDetail">
    {{ showDetail ? '收起诊断信息' : '显示诊断信息' }}
  </button>
  <template v-if="showDetail">
    <pre style="font-size:12px; color:var(--muted); margin:8px 16px; white-space:pre-wrap; line-height:1.6; font-family:inherit;">{{ updDetail || '（先点一次「检查更新」）' }}</pre>
    <button class="btn secondary" @click="copyDetail">复制诊断信息</button>
  </template>
</template>
