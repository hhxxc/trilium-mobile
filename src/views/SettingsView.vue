<script setup>
// 设置：服务器地址 + 密码登录（换 ETAPI token）+ 应用内更新
import { ref, onMounted, watch } from 'vue';
import { loadSettings, saveSettings, login, logout, appInfo, resetAuthExpiredFlag, diagnose } from '../api.js';

const props = defineProps({ notice: { type: String, default: '' } });
const emit = defineEmits(['notice-consumed']);
import { APP_VERSION, checkUpdate, startTrollStoreUpdate, probeManifest, downloadIpa } from '../update.js';

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

// ---------- 应用内更新（交互照抄巢记 NestKeep：下载 IPA → 系统分享面板 → 选 TrollStore） ----------
const upd = ref(null);        // checkUpdate() 的结果
const updMsg = ref('');       // 检查/更新过程提示
const updChecking = ref(false);
const updDetail = ref('');    // 诊断细节（通道/HTTP/content-type/字节数）
const showDetail = ref(false);
const showSteps = ref(false); // 复制直链后显示安装步骤
const dlState = ref('idle');  // idle | downloading | ready | error
const dlPct = ref(0);         // 下载进度 0-100
const dlBytes = ref('');      // 已下载/总大小（人类可读）
let ipaFile = null;           // 已下载的 IPA File 对象（内存 ~600KB，可接受）

function fmtKB(n) {
  return n >= 1024 * 1024 ? (n / 1024 / 1024).toFixed(1) + ' MB' : Math.round(n / 1024) + ' KB';
}

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
      updMsg.value = '';
      dlState.value = 'idle';
      ipaFile = null;
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

/** 分段下载 IPA（带进度条），完成后弹系统分享面板 */
async function doDownloadAndShare() {
  if (!upd.value) return;
  if (dlState.value === 'ready' && ipaFile) { await shareIpaFile(); return; }
  dlState.value = 'downloading';
  dlPct.value = 0;
  dlBytes.value = '';
  updMsg.value = '';
  try {
    const bytes = await downloadIpa(upd.value.ipaUrl, (got, total) => {
      dlPct.value = Math.round((got / total) * 100);
      dlBytes.value = `${fmtKB(got)} / ${fmtKB(total)}`;
    });
    ipaFile = new File([bytes], `Trilium-${upd.value.latest}.ipa`, { type: 'application/octet-stream' });
    dlState.value = 'ready';
    dlPct.value = 100;
    dlBytes.value = fmtKB(bytes.length) + ' 下载完成';
    await shareIpaFile();
  } catch (e) {
    dlState.value = 'error';
    dlMsg.value = '下载失败：' + (e.message || e) + '（点「点此安装」可重试）';
  }
}

/** 弹 iOS 系统分享面板，用户选 TrollStore 直接安装 */
async function shareIpaFile() {
  try {
    if (navigator.canShare && navigator.canShare({ files: [ipaFile] })) {
      await navigator.share({ files: [ipaFile], title: `Trilium v${upd.value.latest}` });
    } else {
      dlMsg.value = '此系统不支持直接分享文件，用下面的「复制直链」安装即可。';
      showSteps.value = true;
    }
  } catch (e) {
    if (e && e.name !== 'AbortError') dlMsg.value = '分享失败：' + (e.message || e);
  }
}

/** 直接唤起 TrollStore（apple-magnifier）——分享面板不可用时的备用 */
function doMagnifier() {
  if (!upd.value) return;
  try {
    startTrollStoreUpdate(upd.value.ipaUrl, 'apple-magnifier');
    updMsg.value = '已唤起 TrollStore。若跳到了「放大器」没反应，用「复制直链」粘贴安装即可。';
  } catch (e) {
    updMsg.value = '拉起失败：' + (e.message || e);
  }
}

/** 复制 IPA 直链（兜底：TrollStore 里「从 URL 安装」粘贴） */
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

function openRelease() {
  if (upd.value && upd.value.releaseUrl) window.open(upd.value.releaseUrl, '_blank', 'noopener');
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
    <div class="upd-hero">
      <div class="upd-icon" :class="{ 'upd-icon-dl': dlState === 'downloading' }">
        <svg v-if="dlState !== 'downloading'" width="30" height="30" viewBox="0 0 24 24" fill="none">
          <path d="M12 4v12m0 0l-5-5m5 5l5-5" stroke="#fff" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/>
        </svg>
        <svg v-else class="pull-spin spin" width="30" height="30" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2.4" stroke-linecap="round">
          <path d="M12 3a9 9 0 1 1-8.5 6" />
        </svg>
      </div>
      <div class="upd-title">发现新版本 v{{ upd.latest }}</div>
      <div class="upd-sub">当前版本 v{{ upd.current }}</div>
    </div>
    <template v-if="dlState === 'downloading'">
      <div class="dl-bar"><div class="dl-bar-in" :style="{ width: dlPct + '%' }"></div></div>
      <p style="text-align:center; font-size:13px; color:var(--muted); margin:8px 16px 4px;">
        正在下载 {{ dlPct }}%{{ dlBytes ? '（' + dlBytes + '）' : '' }}
      </p>
    </template>
    <template v-else-if="dlState === 'ready' && dlPct === 100">
      <div class="dl-bar"><div class="dl-bar-in" style="width:100%"></div></div>
      <p style="text-align:center; font-size:13px; color:var(--muted); margin:8px 16px 4px;">
        {{ dlBytes }}{{ ipaFile ? ' · 已弹出分享面板' : '' }}
      </p>
    </template>
    <button class="btn" :disabled="dlState === 'downloading'" @click="doDownloadAndShare">
      {{ dlState === 'downloading' ? '下载中 ' + dlPct + '%' : (dlState === 'ready' ? '再次弹出安装面板' : '点此安装') }}
    </button>
    <p style="font-size:12px; color:var(--muted); margin:4px 16px 8px; line-height:1.6;">
      安装包下载完成后会弹出系统分享面板，选择 TrollStore 确认安装即可（同变体会覆盖旧版并保留数据）。
    </p>
    <a class="release-link" style="margin-bottom:8px;" @click.prevent="doDownloadAndShare()">重新下载</a>
    <button class="btn secondary" @click="openRelease">打开发布页</button>
    <details style="margin:10px 16px;">
      <summary style="font-size:12px; color:var(--muted);">其他安装方式（分享面板没弹出时用）</summary>
      <button class="btn secondary" style="margin-top:8px;" @click="doMagnifier">直接唤起 TrollStore</button>
      <button class="btn secondary" @click="doCopyLink">复制直链</button>
      <template v-if="showSteps">
        <div class="card" style="margin:8px 0 0;">
          <div class="title" style="font-size:14px;">安装步骤</div>
          <div class="meta" style="line-height:1.8;">
            1. 打开 TrollStore<br />
            2. 点右上角「+」<br />
            3. 选「从 URL 安装」，粘贴链接<br />
            4. 确认安装（同变体才会覆盖旧版）
          </div>
        </div>
      </template>
    </details>
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
