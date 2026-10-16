# NAS 侧自动同步（trilium-mobile）

定时从 GitHub Releases 拉最新 IPA，刷新 nestkeep 清单 —— **不再需要手动发版**。

## 为什么这么做（先例）

同目录 `nestkeep_autosync.sh`（巢记）已在跑同样的模式：**NAS 定时去源头拉最新产物**。
区别只是巢记从 Docker Hub 镜像解包，trilium-mobile 从 GitHub Releases 下载。

原来每次发版要手动跑 `nas_publish_trilium.py`，现在 CI 出包后 NAS 自己会在几分钟内拉走。

## 关键设计：不走 GitHub API

NAS 出口 IP 是共享的，匿名调 `api.github.com` 常年 **403 限流**
（实测 `API rate limit exceeded for 50.7.250.107`）。所以脚本刻意绕开 API，
只用两个**永久地址**：

| 用途 | 地址 |
|---|---|
| 取最新 tag | `HEAD https://github.com/<repo>/releases/latest/download/trilium-mobile.ipa` → 从 `Location` 头解析 |
| 下载产物 | `GET  同上地址` → 302 后即最新资产 |

两个都不需要 API、不需要 token。

## 文件（NAS 上）

| 路径 | 作用 |
|---|---|
| `/volume2/docker/ezbk/trilium_autosync.sh` | 主脚本（仓库 `scripts/nas/trilium_autosync.sh`） |
| `/volume2/docker/ezbk/trilium_autosync.log` | 运行日志（只留最近 500 行） |
| `/volume2/docker/ezbk/.tl_autosync_last_tag` | 已同步的 tag 基线（比对用） |
| `/volume2/docker/ezbk/.tl_autosync.lock` | 单实例锁（>10 分钟视为陈旧自动接管） |
| `/volume2/docker/ezbk/.tl_autosync_failcount` | 连续失败计数（成功即删） |
| `/volume2/docker/ezbk/trilium.local.sh` | 可选个人覆盖（**不要提交**） |

产出落在 `/volume2/docker/ezbk/nestkeep/`：

- `trilium-mobile.ipa` —— 固定名，TrollStore / App 内更新都指向它
- `trilium-mobile-<tag>.ipa` —— 带版本号的副本，便于回滚审计（保留最近 5 个）
- `latest-trilium.json` —— 更新清单 `{version, ipaUrl}`

## 定时

写在 `/etc/crontab`（群晖上这个文件 root 只读，需要 `sudo -n`）：

```
*/5	*	*	*	*	root	/bin/sh /volume2/docker/ezbk/trilium_autosync.sh > /dev/null 2>&1
```

对照：巢记 `nestkeep_autosync.sh` 是 `*/2`。trilium 构建频率低，用 5 分钟足够。

## 常用操作

```sh
# 手动跑一轮
sudo -n sh /volume2/docker/ezbk/trilium_autosync.sh
tail -20 /volume2/docker/ezbk/trilium_autosync.log

# 强制重新拉取（清基线，下一轮 cron 会当成"有新版本"）
sudo -n rm -f /volume2/docker/ezbk/.tl_autosync_last_tag

# 看当前同步到哪个版本
cat /volume2/docker/ezbk/.tl_autosync_last_tag
cat /volume2/docker/ezbk/nestkeep/latest-trilium.json
```

## 行为约定

- **已是最新 → 静默退出**，不写日志（避免日志被刷满）
- **网络不通 → 静默跳过**，不计失败（NAS 常短暂断网，不该报错）
- **下载失败 → 重试 3 次**，仍失败才计一次失败
- **下载完成后校验 zip 头**（`PK`），防半截文件污染发布目录
- **清单与 IPA 用临时文件 + `mv` 原子替换**，避免客户端下到半截
- **失败告警**：连续 3 次、之后每满 30 次发一次；恢复时发一条（走 NAS 本机 Apprise）

## 与手动发版的关系

`nas_publish_trilium.py` 仍然可用，两者**同目录、按文件覆盖，不会打架**：

- 手动发版：本地构建 → 上传（可指定任意 IPA）
- 自动同步：NAS 自己从 Releases 拉（只认 CI 出来的最新版）

谁后跑谁生效。日常发版走自动同步即可；要发一个不在 GitHub 上的临时包时才用手动。
