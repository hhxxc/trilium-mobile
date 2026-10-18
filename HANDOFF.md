# HANDOFF — Trilium 手机伴侣端（新会话必读）

> 本文件是跨会话交接文档：切空间/新开会话后，读完此文件即可继续开发，无需翻旧对话。

## 一、这是什么项目

用户（hhxxc）的 iPhone 是 **iOS 15.x（明确不升级）**，官方 Trilium 网页版在其 Safari 上报
`Object.hasOwn is not a function`（ES2022 语法，iOS 15.4 前不支持）——服务端已注入 polyfill 修好
（见下），但**移动端布局难用**（桌面版挤小屏）。用户决定自搓一个 Trilium 手机伴侣端。

**2026-10-17 重大转向：SwiftUI 原生 App**（不再是 Capacitor 网页壳）。
起因是网页壳里「更新按钮点击没用」——`navigator.share({files})` 文件分享在 WKWebView 沙箱里不可靠。
参照「巢记 NestKeep」原生工程（`D:\ezbk-native-wt\ios-app\NestKeep.xcodeproj`，已验证的路子）重构。

布局方案 D（原型见 2026-10-14 会话的 Visualizer）：
**首页=最近笔记卡片流 + 底部速记条（速记落「收件箱」）；底部 4 tab：最近/笔记树(面包屑)/搜索/设置；编辑器全屏。**
- 外壳纯 SwiftUI（最近/树/搜索/设置/登录）
- 编辑器：WKWebView 加载服务端 Trilium 页面（`#root/<noteId>`，表格/代码/图片完整支持）
- 数据访问：ETAPI REST（原生 URLSession）
- 应用内更新：抄巢记 UpdateChecker（并行查双源取最大版本 / 下载到 Caches / 系统分享面板选 TrollStore）
- 构建：GitHub Actions 出 IPA（ad-hoc 签名），语义版本 x.y.z（区别于旧网页壳四段 v1.0.00.x）

## 二、服务器与环境（关键事实）

- NAS Trilium 服务端：TriliumNext v0.106.0，compose 目录 `/volume2/docker/trilium`，端口 **18190**（2026-10-14 从 8080 改的）
  - 内网 `http://192.168.31.198:18190` / 星空 `http://192.168.188.2:18190` / Tailscale `http://100.95.218.4:18190`
  - ⚠️ **服务端已设密码**（2026-10-14 实测：ETAPI 空密码登录返回 401 `WRONG_PASSWORD`；早期写的"未设密码"已过时）
    → App 设置页必须填密码。syncVersion=39，用户已初始化并建了「Work」等笔记
  - **公网地址（ddnsto 映射）**：`https://dsm920-ddsnto-trilium-notes.x.ddnsto.com`
    - ⚠️ **只有 https(443) 通**，`http://` 打不通（走代理 502、直连失败）→ 地址必须写 `https://`
    - 证书可信（`ssl_verify_result=0`），iOS 不会拦；ddnsto 以群晖套件运行，运行日志 `/tmp/logs/ddnstoshell.log`
- **服务端升级安全（2026-10-15 加固）**——原则：**镜像由别人构建，拉新容器不能丢/不能破自己的配置**
    - 目录 `/volume2/docker/trilium/` 新增：`UPGRADE.md`（升级手册：改 tag→pull→up -d→refresh-patch→重启→验证/回滚）、
      `refresh-patch.sh`（从当前镜像重新生成 `patch/index.html` 并注入 iOS<15.4 polyfill，幂等）
    - `backup.sh` 扩展：除数据外新增**配置层备份** `config_*.tar.gz`（compose + patch + 脚本 + UPGRADE.md + cron 导出），
      与数据备份同为每日 04:30（/etc/crontab）、保留 14 天
    - 审计结论：`docker diff trilium` 仅 9 处无害改动（数据目录挂载、localtime、启动时改 passwd/group 属主），
      **无"只存在容器里"的配置** ✓；数据/配置全在宿主 bind mount + 备份里
    - ⚠️ **踩过的坑**：单文件 bind mount 绑定的是 **inode** —— 用 `mv` 替换 `patch/index.html` 后容器仍读旧内容，
      **必须 `docker restart trilium` 重新绑定**；绑定后用原地写入（`cat new > file`，保 inode）才能即时生效
    - ⚠️ 每日备份会**短暂停容器**（backup.sh 里 STOP_CONTAINER=1）；备份体积 ~100MB/天
      （document.db 55MB + Trilium 自带 backup-daily.db 55MB，含重复）
  - ⚠️ index.html 已打 iOS polyfill 补丁：宿主 `patch/index.html` 文件级挂载到容器 `/usr/src/app/public/index.html`，**升级容器时补丁会自动保留（挂载在 compose 里）**
- NAS SSH：`hhxxc@192.168.31.198:8122`（**密码见 `HANDOFF.local.md`**，该文件已 gitignore、不进仓库），异地走 Tailscale `100.95.218.4:8122`；工作区 `D:\nas-tools-backup\_nas_run.py` 是通用执行封装
- 为知笔记已于 2026-10-14 卸载（Win 客户端 + NAS 容器/镜像）；**数据目录 668M 暂留** `/volume2/docker/wiznote`（唯一副本，用户未最终确认删）
- iOS 构建流水线参照巢记：`D:\ezbookkeeping-ios\.github\workflows\build-ios-ipa.yml`（TrollStore 未签名 IPA，`CODE_SIGNING_ALLOWED=NO` + `codesign -s -`，Release 自动发 gh release，保留最近 20 个）

## 三、本工程结构（D:\trilium-mobile）

```
ios-app/                      SwiftUI 工程（原生 App，约 5000 行）
  TriliumMobile/
    TriliumMobileApp.swift    入口（@main）
    Core/AppConfig.swift      默认服务器地址/收件箱标题/仓库名
    Core/AppSettings.swift    服务器+token+备用地址持久化（token 走 Keychain，见下）
    Core/Keychain.swift       token 存 Keychain（失败自动回退 UserDefaults）
    Core/ETAPIClient.swift    ETAPI 客户端（原生 URLSession）+ 错误/解析诊断日志
    Core/NoteCache.swift      列表/正文/附件缓存（Caches 目录）+ 离线写入队列
    Core/UpdateChecker.swift  更新检测（并行查双源 / 后台 URLSession 下载 / 系统分享面板）
    Core/AppLogger.swift      诊断日志（内存 + UserDefaults，最多 200 条，设置页可看/复制）
    Models/Note.swift         笔记数据模型
    Views/RootView.swift      登录门禁 + 外壳容器（Tab 切换/抽屉/浮层都在这层）
    Views/LoginView.swift     服务器+密码登录（含证书/网络错误的中文提示）
    Views/NoteListView.swift  最近/收藏列表 + 搜索 + 速记 + 整理菜单
                              （内含 NoteIconBadge / NoteRow / ComposeView，949 行）
    Views/NoteDetailView.swift 阅读页 + 原生编辑器 + WKWebView
                              （内含 NativeEditorView / ContentWebView / WebEditorView /
                                FullWebView / ZoomableImageView / ShareSheet，1142 行）
    Views/TreeView.swift      目录树（递归折叠 + 展开状态持久化）
    Views/MoveTargetPicker.swift 移动/克隆的目标目录选择器
    Views/QuickLookView.swift 附件预览（QuickLook）
    Views/SettingsView.swift  连接/缓存/日志/检查更新/退出
    Views/UpdateView.swift    更新下载页（常驻进度）
    Resources/mermaid.min.js  Mermaid 渲染（注入阅读页）
    Info.plist                含 LSApplicationQueriesSchemes:apple-magnifier + ATS 放行 http
    TriliumMobile.entitlements 空（ad-hoc 签名）
    Assets.xcassets/          App 图标 + logo.svg
  ShareExtension/             分享扩展（Safari/微信存收件箱）
  gen_pbxproj.py              生成 .xcodeproj（Windows 上跑，增删 Swift 文件重跑同步）
  TriliumMobile.xcodeproj/    生成的工程文件（进 git）
.github/workflows/build-native-ios.yml  云端出包：生成工程 → 注入版本 → sharp 图标 → xcodebuild → 打包 IPA → 发版
scripts/gh_push.py           推送工具（走 GitHub Git Data API，绕开本机代理）
scripts/nas/                 NAS 自动同步（trilium_autosync.sh 拉 Release 最新 IPA + 刷新清单）
scripts/nas_publish_trilium.py 手动发版（备用）
public/logo.svg              已迁移到 ios-app/TriliumMobile/Assets.xcassets/logo.svg
```

## 四、ETAPI 要点（Trilium 0.106）

- 前缀 `/etapi`，鉴权头 `Authorization: <token>`（注意无 Bearer 前缀，代码里直接设了裸 token）
- **登录契约（2026-10-15 实测踩坑，务必记住）**：`POST /etapi/auth/login`，body `{ password, tokenName? }`
  → **201 返回 `{ authToken }`（不是 `token`！）**
  - 服务端实现：`if (!verifyPassword(password)) → 401 WRONG_PASSWORD`；通过则 `createToken()` → `res.status(201).json({ authToken })`
  - ⚠️ **只校验密码，不校验 TOTP/MFA** —— 服务端 `mfaMethod=totp` 也不挡 ETAPI 登录（网页登录才要验证码）
  - ⚠️ 失败过多 → **429 拉黑**（"Client IP has been blacklisted"，按客户端 IP，等待后自动恢复）
  - 🐛 曾经的 Bug：`src/api.js` 只读 `data.token` → 密码正确也存不进 token ⇒ **永久登录失败**。
    已修为 `data.authToken || data.token`（v1.0.00.02 起）
  - ⚠️ **Trilium 不记录 ETAPI 请求日志**（日志里只有 `/api/...` 同步请求）→ 别用服务端日志判断 App 是否连上；
    可看 ddnsto 隧道日志 `/tmp/logs/ddnstoshell.log` 里的 `new session ... url= http://192.168.31.198:18190`
  - 排查手段：容器内 ETAPI 规范 `/usr/src/app/assets/etapi.openapi.yaml`；
    服务端选项 `sqlite3 /volume2/docker/trilium/trilium-data/document.db "select name,value from options"`
- `POST /etapi/auth/logout`
- `GET /etapi/app-info`（含 appVersion）
- `GET /etapi/notes/{id}` → 含 `childNoteIds`、`parentBranchIds`；`GET/PUT /etapi/notes/{id}/content`
- `PATCH /etapi/notes/{id}`（title 等）；`POST /etapi/notes {parentNoteId,title,type,mime,content}`
- `GET /etapi/notes?search=...` —— ⚠️ **v0.106 没有 `/etapi/search-notes`**（旧版本文档写错过，导致列表永久空白）
  - `search` **必须非空**（空串 400 `'search' query parameter is mandatory`）；「匹配全部」写
    `note.noteId != 'zzz_no_match_zzz'`
  - 排序/分页走**独立参数**：`orderBy=dateModified&orderDirection=desc&limit=30`，
    **不能**把 `order by dateModified desc limit 30` 塞进 search（会被当全文词 → 永远搜不到）
  - 搜索响应**不含** `childNoteIds` / `parentNoteIds`（要建树必须逐条 `GET /etapi/notes/{id}` 补）
- text 笔记的 content 是 HTML 字符串；冲突策略 v1 = 最后保存为准

## 五、已完成 / 下一步

已完成（2026-10-14）：
- 工程骨架全部写完，本地 `npm install` + `npm run build` 验证通过（1 秒构建）
- 仓库 https://github.com/hhxxc/trilium-mobile（私有），**构建成功**，Release `v1.0.00.20`（IPA 约 600KB，TrollStore 直接装）
- ⚠️ **推送通道时通时断**：`gh api` 一贯可用，但 `git push` / `git fetch` 常被本机代理挡（`CONNECT tunnel failed, response 502`）。
  - **优先用 `python scripts/gh_push.py`**：走 gh api 推送本地提交，且逐级校验 blob/tree/commit 的 sha 与本地一致，
    所以远端与本地保持同源、不会分叉（验证过：推送后远端 sha == 本地 sha）
  - 单文件急改也可用 `PUT /repos/.../contents/<path>`（更新需带 `sha`），但那会产生新提交、可能与本地分叉
- ✅ `v1.0.00.21` 已构建（含 `build.target: es2019` + 速记条输入法守卫）
- ✅ **公开分发仓库 https://github.com/hhxxc/trilium-mobile-ipa（public，只放 IPA 成品，无源码/无历史）** → TrollStore 可直接 Install from URL，手机不用传文件
  - ⚠️ 主仓库保持私有：`HANDOFF.md` 含 NAS SSH 明文密码（历史提交 `4fb2350` 也有），公开即泄露 —— **要公开主库必须先脱敏 + 重写历史，并更换 NAS 密码**
- ⚠️ CI 的 `push.paths` 白名单**不含 `vite.config.js`**（含 `src/**`、`package.json`、`index.html` 等），只改 vite.config.js 不会触发构建——改动需带上 `src/` 下的文件或走 workflow_dispatch
- 调试记录：第一次构建失败 = 上传清单漏了 vite.config.js（vite 无 vue 插件直接报 .vue 解析错）；第二次失败 = capacitor.config.ts 需要 typescript → devDeps 已加 `typescript@^5.6.0`

下一步（按优先级）：
1. iPhone 上用 TrollStore 装 Release 里的 IPA → 打开 App → 设置页默认已填 ddnsto 公网地址 `https://dsm920-ddsnto-trilium-notes.x.ddnsto.com`（在家也可改内网 `http://192.168.31.198:18190` 更快）→ 填 Trilium 登录密码登录
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

## 八、2026-10-14 晚：删库重建（安全处置）

起因：主库转公开后，实测发现 **旧提交（改写历史前）仍能按 SHA 匿名取到明文 NAS 密码**
（`api.github.com/repos/.../commits/<旧sha>` → 200，`contents/HANDOFF.md?ref=<旧sha>` 里密码还在）。
`filter-branch` + force push 只能改引用，GitHub 上的旧对象不会消失 —— 唯一彻底的办法是新建仓库。

已做：
- 旧库改名 `hhxxc/trilium-mobile-old` 并**转私有**（匿名访问旧提交立即变 404，暴露已切断）
- 建同名新库 `hhxxc/trilium-mobile`（public），内容为**单个根提交 `a01b409`**，21 个文件，全历史 0 凭据
- 本地 `.git` 一并重建（旧本地历史同样含密码），且**本地与远端提交哈希完全一致**（`a01b409`）
- CI 在新库实测跑通：`workflow_dispatch` → 构建成功 → Release（见下）

⚠️ 两点注意：
1. **版本号归零**：workflow 用 `github.run_number` 生成版本，重建后 run_number 从 1 开始 →
   新库首个 Release 是 `v1.0.00.01`（早于旧的 `.21` 只是编号回归，不影响功能）。
   分发走 NAS 固定文件名 `trilium-mobile.ipa`，与版本号无关。
2. **旧库还没真正删掉**：`gh` token 缺 `delete_repo` 权限。要彻底删除，执行
   `gh auth refresh -h github.com -s delete_repo` 后 `gh repo delete hhxxc/trilium-mobile-old --yes`。
   当前它已是私有，凭据不再公开可达；但仍建议删掉（并顺手更换 NAS SSH 密码，毕竟曾公开约 20 分钟）。
