# Trilium Mobile

Trilium 笔记的手机伴侣端 —— **SwiftUI 原生 App**（iOS 15.1+，走 Trilium ETAPI）。

- 外壳纯 SwiftUI：最近笔记 / 速记到收件箱 / 笔记树 / 全文搜索 / 设置
- 编辑器：WKWebView 加载服务端 Trilium 页面（表格 / 代码 / 图片完整支持）
- 应用内更新：检查更新 → 下载 IPA → 系统分享面板选 TrollStore 一键安装

## 工程结构

- `ios-app/` —— SwiftUI 工程（`gen_pbxproj.py` 生成 `.xcodeproj`，增删 Swift 文件重跑脚本即可）
- `scripts/nas/` —— NAS 自动同步（拉 GitHub Releases 最新 IPA → 刷新更新清单）
- `.github/workflows/build-native-ios.yml` —— 云端出包（ad-hoc 签名，TrollStore 安装）

## 构建

推送 `main`（改动 `ios-app/**`）自动构建 IPA 并发语义版本 Release；NAS 侧几分钟内自动同步，手机端「检查更新」即可一键安装。

架构与交接文档见 [HANDOFF.md](HANDOFF.md)。
