# HANDOFF — Trilium 手机伴侣端（新会话必读）

> 本文件是跨会话交接文档：切空间/新开会话后，读完此文件即可继续开发，无需翻旧对话。

## 一、这是什么项目

用户（hhxxc）的 iPhone 是 **iOS 15.x（明确不升级）**，官方 Trilium 网页版在其 Safari 上报
`Object.hasOwn is not a function`（ES2022 语法，iOS 15.4 前不支持）——服务端已注入 polyfill 修好
（见下），但**移动端布局难用**（桌面版挤小屏）。用户决定照「巢记 NestKeep」（其自研记账 App，
`D:\ezbookkeeping-ios`）的路子自搓一个 Trilium 手机伴侣端。

选定布局方案 D（原型见 2026-10-14 会话的 Visualizer）：
**首页=最近笔记卡片流 + 底部速记条（速记落「收件箱」）；底部 4 tab：最近/笔记树(面包屑)/搜索/设置；编辑器全屏。**
v1 只做这四件事，不做全功能客户端；复杂编辑（表格/代码块/图片）回电脑。

## 二、服务器与环境（关键事实）

- NAS Trilium 服务端：TriliumNext v0.106.0，compose 目录 `/volume2/docker/trilium`，端口 **18190**（2026-10-14 从 8080 改的）
  - 内网 `http://192.168.31.198:18190` / 星空 `http://192.168.188.2:18190` / Tailscale `http://100.95.218.4:18190`
  - **未设密码**（authRequired=false），syncVersion=39，用户已初始化并建了「Work」等笔记
  - ⚠️ index.html 已打 iOS polyfill 补丁：宿主 `patch/index.html` 文件级挂载到容器 `/usr/src/app/public/index.html`，**升级容器时补丁会自动保留（挂载在 compose 里）**
- NAS SSH：`hhxxc@192.168.31.198:8122`（**密码见 `HANDOFF.local.md`**，该文件已 gitignore、不进仓库），异地走 Tailscale `100.95.218.4:8122`；工作区 `D:\nas-tools-backup\_nas_run.py` 是通用执行封装
- 为知笔记已于 2026-10-14 卸载（Win 客户端 + NAS 容器/镜像）；**数据目录 668M 暂留** `/volume2/docker/wiznote`（唯一副本，用户未最终确认删）
- iOS 构建流水线参照巢记：`D:\ezbookkeeping-ios\.github\workflows\build-ios-ipa.yml`（TrollStore 未签名 IPA，`CODE_SIGNING_ALLOWED=NO` + `codesign -s -`，Release 自动发 gh release，保留最近 20 个）

## 三、本工程结构（D:\trilium-mobile）

```
capacitor.config.ts      appId=com.hhxxc.trilium，appName=Trilium，纯打包应用（非远程壳）
src/config.js            默认服务器地址（31.198:18190 / 188.2:18190）、收件箱标题
src/api.js               ETAPI 客户端：login/token、getNote、getContent/putContent、
                         patchNote、createNote、searchNotes、recentNotes、ensureInbox、localStorage 缓存
src/App.vue              4 tab 容器 + 编辑器全屏路由
src/views/RecentView.vue 首页：最近 30 条 + 速记条（HTML 转义后写入收件箱）
src/views/TreeView.vue   面包屑层级浏览（childNoteIds 逐个拉取）
src/views/SearchView.vue 全文搜索
src/views/SettingsView.vue 服务器+密码登录（存 localStorage）
src/views/EditorView.vue 全屏编辑：改标题 + text/code 笔记改正文（PUT content 原样回写）
.github/workflows/build-ios-ipa.yml  push main 自动出 IPA（vite build → cap add/sync ios →
                         Info.plist 打 ATS 补丁(NSAllowsArbitraryLoads=true，因为服务器是 http)
                         → sharp 生成图标 → pod install → xcodebuild 归档 → 打包 IPA → gh release）
public/logo.svg          App 图标（青绿树形，workflow 里自动切全套尺寸）
```

## 四、ETAPI 要点（Trilium 0.106）

- 前缀 `/etapi`，鉴权头 `Authorization: <token>`（注意无 Bearer 前缀，代码里直接设了裸 token）
- `POST /etapi/auth/login {password}` → `{token}`；`POST /etapi/auth/logout`
- `GET /etapi/app-info`（含 appVersion）
- `GET /etapi/notes/{id}` → 含 `childNoteIds`、`parentBranchIds`；`GET/PUT /etapi/notes/{id}/content`
- `PATCH /etapi/notes/{id}`（title 等）；`POST /etapi/notes {parentNoteId,title,type,mime,content}`
- `GET /etapi/search-notes?search=...`（Trilium 搜索语法，`order by dateModified desc limit N` 可用）
- text 笔记的 content 是 HTML 字符串；冲突策略 v1 = 最后保存为准

## 五、已完成 / 下一步

已完成（2026-10-14）：
- 工程骨架全部写完，本地 `npm install` + `npm run build` 验证通过（1 秒构建）
- 仓库 https://github.com/hhxxc/trilium-mobile（私有），**构建成功**，Release `v1.0.00.20`（IPA 约 600KB，TrollStore 直接装）
- ⚠️ **推送通道时通时断**：`gh api` 一贯可用，但 `git push` / `git fetch` 常被本机代理挡（`CONNECT tunnel failed, response 502`）。
  - 推送失败时走 `gh api`：单文件用 `PUT /repos/.../contents/<path>`（更新需带 `sha`）；多文件建议一次用 Git Data API（blobs → trees → commits → PATCH refs/heads/main），不产生多条提交
  - 因此本地与远端可能分叉（内容一致、提交号不同）；网络恢复后 `git fetch && git reset --hard origin/main` 对齐
- ✅ `v1.0.00.21` 已构建（含 `build.target: es2019` + 速记条输入法守卫）
- ✅ **公开分发仓库 https://github.com/hhxxc/trilium-mobile-ipa（public，只放 IPA 成品，无源码/无历史）** → TrollStore 可直接 Install from URL，手机不用传文件
  - ⚠️ 主仓库保持私有：`HANDOFF.md` 含 NAS SSH 明文密码（历史提交 `4fb2350` 也有），公开即泄露 —— **要公开主库必须先脱敏 + 重写历史，并更换 NAS 密码**
- ⚠️ CI 的 `push.paths` 白名单**不含 `vite.config.js`**（含 `src/**`、`package.json`、`index.html` 等），只改 vite.config.js 不会触发构建——改动需带上 `src/` 下的文件或走 workflow_dispatch
- 调试记录：第一次构建失败 = 上传清单漏了 vite.config.js（vite 无 vue 插件直接报 .vue 解析错）；第二次失败 = capacitor.config.ts 需要 typescript → devDeps 已加 `typescript@^5.6.0`

下一步（按优先级）：
1. iPhone 上用 TrollStore 装 Release 里的 IPA → 打开 App → 设置页填 `http://192.168.31.198:18190`（或 188.2:18190）→ 登录（服务端当前无密码，ETAPI login 空 password 待验证；若不行先在 Trilium 设置个密码）
2. ✅ iOS 15 兼容：已在 vite.config.js 加 `build.target: 'es2019'`（2026-10-14）；并扫描过 dist——无 Object.hasOwn/structuredClone/error cause 等硬伤，唯一 `findLast(` 出自 Vue v-for 辅助对象的方法定义、本项目不调用（死代码）
3. ✅ 速记条 `@keyup.enter` 已加 onEnter 守卫（isComposing / keyCode 229），中文输入法回车上屏不再误保存
4. 增强：下拉刷新、左滑归档/改所属、图片笔记查看、分享扩展
5. 远期：离线编辑队列 + 同步冲突提示

## 六、用户习惯备忘

- 讨厌冗长输出；交付要自己先验证（「加不好别完成任务，自己测啊」）
- 手机 = iPhone iOS 15（不升级）；电脑 Windows（thinkbook16），常在异地（Tailscale/星空）
- 主项目是环食药侦数智侦查平台（工作中），笔记内容多为工作记录

## 七、分发与更新（NAS 通道，2026-10-14 建）

**为什么要 NAS**：手机在国内直连 GitHub（含 objects.githubusercontent.com）会超时，TrollStore 填 GitHub
原链不可靠（巢记踩过）。所以 IPA 统一发到 NAS，走自有域名直下。

- **固定下载地址**（TrollStore 长期只填这一个；更新 = 用同一地址再 Install 一次，数据保留）：
  `https://ezbookx.x.ddnsto.com/api/nestkeep/trilium-mobile.ipa`
- **发布命令**（每次出新 IPA 后执行）：
  ```
  C:/Python314/python.exe scripts/nas_publish_trilium.py \
      --ipa builds/trilium-mobile-vX.Y.ZZ.NN-trollstore.ipa --name trilium-mobile.ipa
  ```
  - 必须用 `C:/Python314/python.exe`（managed python 无 paramiko）
  - 凭据读 `scripts/nas_config_local.py`（已 gitignore）；无该文件时回退环境变量 `NAS_SSH_PASS` / `NAS_CRED_FILE`
  - 脚本会上传 + 校验 NAS 侧 sha256
- NAS 落地目录 `/volume2/docker/ezbk/nestkeep/`（与巢记共用），由 ezbookkeeping 后端**无鉴权**路由
  `/api/nestkeep/<文件名>` 下发
  - ⚠️ 该路由只放行 `*.ipa` 与 `latest.json`；trilium 自己的清单（如 latest-trilium.json）需后端加路由才能下发
- **待做（对齐巢记的完整更新体验）**：
  1. App 内检查更新：读清单 → 下载 IPA → `UIDocumentInteractionController` 交给 TrollStore（巢记已实现，可照搬）
  2. CI 自动发布到 NAS：巢记走 Docker Hub 镜像 + NAS cron 拉取（因 NAS 不能直连 GitHub）；目前本项目为手动跑发布脚本
