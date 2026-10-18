# Trilium Mobile

Trilium 笔记的 iOS 伴侣端 —— **SwiftUI 原生 App**（iOS 15.1+，数据走 Trilium ETAPI）。
给「桌面端很重、手机上没有官方客户端」的场景补一个趁手的移动端：列表优先、拇指区操作、离线可读可写。

## 功能

**浏览与检索**
- 首页三态：最近（按今天/昨天/本周/更早分组）/ 收藏 / 目录
- 左滑抽屉出目录树（整行可点、展开状态记忆）；列表行带正文摘要
- 全文搜索（400ms 防抖 + 历史词条）

**阅读**
- 原生渲染：富文本 / 代码 / 图片（双指缩放、长按存相册）/ 附件（QuickLook）/ Mermaid
- 大纲跳转、四档字号、阅读进度记忆、笔记内链接 App 内打开、上下篇
- 代码块一键复制、导出 HTML 分享

**整理**
- 收藏（`bookmarked` 标签）、移动到其他目录、克隆到多处
- 左滑操作 + 长按菜单，删除带级联提示

**离线**
- 内容 / 附件 / 元数据三路缓存，断网可看
- 写操作失败进离线队列，联网自动补交

**安全**
- Face ID / 设备密码锁（切后台即锁）
- ETAPI token 存 Keychain（写失败自动降级到 UserDefaults）

**更新**
- 启动静默检查 → 后台 URLSession 下载（切后台/锁屏不中断，进度落盘）
- 常驻下载页 + 列表顶部进度条；下载源失败自动换 GitHub Releases 兜底

**连接**
- 主备服务器地址自动互换：公网走不通就切内网，token 不失效不用重登

## 工程结构

| 路径 | 说明 |
|---|---|
| `ios-app/` | SwiftUI 工程；`gen_pbxproj.py` 生成 `.xcodeproj`，**增删 Swift 文件必须重跑** |
| `scripts/nas/` | NAS 侧运维：`trilium_autosync.sh` 拉最新 IPA + 每日证书/接口健康自检 |
| `.github/workflows/` | 云端出包（ad-hoc 签名，TrollStore 安装） |

## 构建与分发

推送 `main`（改动 `ios-app/**`）自动构建并发语义版本 Release。NAS 每 5 分钟同步清单与 IPA，
手机端「设置 → 软件更新」即可安装。

公网证书故障时的内网通道：

```
App 连接   http://192.168.31.198:18190
IPA 安装   http://192.168.31.198:9180/api/nestkeep/trilium-mobile.ipa
```

架构细节与踩坑记录见 [HANDOFF.md](HANDOFF.md)。
