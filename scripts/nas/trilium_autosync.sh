#!/bin/sh
# trilium-mobile 自动同步：定时从 GitHub Releases 拉最新 IPA → 刷新 nestkeep 清单
#
# 背景 / 先例：同目录的 nestkeep_autosync.sh（巢记）定时从 Docker Hub 镜像解包发布；
# 本脚本是同一模式的 GitHub Releases 版本 —— trilium-mobile 的 CI 每次构建都会
# `gh release create vX.Y.ZZ.NN trilium-mobile.ipa`，这里就是把它自动拉到 NAS。
#
# ★ 刻意不走 GitHub API：NAS 出口 IP 是共享的，匿名调 API 常年 403 限流
#   （实测 "API rate limit exceeded for 50.7.250.107"）。
#   改用两个「永久地址」，无需 API、无需 token：
#     1) HEAD /releases/latest/download/<asset>  → 302，从 Location 头解析出 tag 名
#     2) GET  /releases/latest/download/<asset>  → 直接下到最新资产
#
# 与手动发版脚本 nas_publish_trilium.py 不冲突：同目录、按文件覆盖，谁先谁后都行。
#
# 手动检查： sh /volume2/docker/ezbk/trilium_autosync.sh && tail trilium_autosync.log
#
set -u

# 个人覆盖：同目录 trilium.local.sh（已 gitignore）可定义 TL_DATA_DIR 等
LOCAL_OVERRIDE="$(cd "$(dirname "$0")" && pwd)/trilium.local.sh"
[ -f "$LOCAL_OVERRIDE" ] && . "$LOCAL_OVERRIDE"

REPO="${TL_REPO:-hhxxc/trilium-mobile}"
DATA_DIR="${TL_DATA_DIR:-/volume2/docker/ezbk/nestkeep}"
STATE_DIR="${TL_STATE_DIR:-/volume2/docker/ezbk}"
DIGEST_FILE="$STATE_DIR/.tl_autosync_last_tag"
LOG="$STATE_DIR/trilium_autosync.log"
LOCK="$STATE_DIR/.tl_autosync.lock"
IPA_NAME="trilium-mobile.ipa"
MANIFEST="latest-trilium.json"
ASSET_URL="https://github.com/${REPO}/releases/latest/download/${IPA_NAME}"
PUBLIC_BASE="${TL_PUBLIC_BASE:-https://ezbookx.x.ddnsto.com/api/nestkeep}"
KEEP_IPA="${TL_KEEP_IPA:-5}"

# 告警：走 NAS 本机 Apprise API（与巢记同一通道，脚本零凭据）。失败静默，不影响主流程。
APPRISE_URL="${TL_APPRISE_URL:-http://localhost:8082/notify/8b}"
FAIL_FILE="$STATE_DIR/.tl_autosync_failcount"

ts() { date +"%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(ts)] $1" >> "$LOG"; }

notify() { # $1=标题 $2=正文 $3=类型(warning|info)
    [ -n "$APPRISE_URL" ] || return 0
    local tmp
    tmp=$(mktemp)
    printf '{"title":"%s","body":"%s","type":"%s","format":"text"}' "$1" "$2" "${3:-warning}" > "$tmp"
    curl -s -m 30 -X POST "$APPRISE_URL" -H "Content-Type: application/json" -d @"$tmp" >/dev/null 2>&1
    rm -f "$tmp"
}

mark_fail() { # $1=失败原因（不含引号/反斜杠）
    local count=0
    [ -f "$FAIL_FILE" ] && count=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
    count=$((count + 1))
    echo "$count" > "$FAIL_FILE"
    log "FAIL($count): $1"
    if [ "$count" -eq 3 ] || [ $((count % 30)) -eq 0 ]; then
        notify "trilium-mobile 自动同步失败" "$1（连续第 ${count} 次）" warning
    fi
}

mark_ok() {
    if [ -f "$FAIL_FILE" ]; then
        local prev
        prev=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
        rm -f "$FAIL_FILE"
        [ "$prev" -gt 0 ] && notify "trilium-mobile 自动同步已恢复" "此前连续失败 ${prev} 次，现已正常" info
    fi
}

# 单实例：上一次还没跑完就跳过本轮
if [ -e "$LOCK" ]; then
    if [ -n "$(find "$LOCK" -mmin +10 2>/dev/null)" ]; then
        log "WARN: 发现陈旧锁，接管"
        rm -f "$LOCK"
    else
        exit 0
    fi
fi
: > "$LOCK"
trap 'rm -f "$LOCK"' EXIT INT TERM

mkdir -p "$DATA_DIR" "$STATE_DIR"

# ---- 每日健康自检（证书到期 / 接口不可达 / IPA 分发异常 → Apprise 告警）----
# 背景：2026-10-17 ddnsto 通配证书到期，公网 API 和 IPA 分发同时挂掉，全靠人肉发现。
# 频率：本脚本每 5 分钟被 DSM 唤起，这里用日期戳把真正的检查压成「每天一次」。
HEALTH_STAMP="$STATE_DIR/.tl_health_date"
HEALTH_HOST="${TL_HEALTH_HOST:-dsm920-ddsnto-trilium-notes.x.ddnsto.com}"
HEALTH_ASSET_HOST="${TL_HEALTH_ASSET_HOST:-ezbookx.x.ddnsto.com}"
HEALTH_LAN_IPA="${TL_HEALTH_LAN_IPA:-http://192.168.31.198:9180/api/nestkeep/trilium-mobile.ipa}"

cert_state() { # $1=host → ok | warn | expired | unknown
    cert=$(echo | timeout 15 openssl s_client -connect "$1:443" -servername "$1" 2>/dev/null \
           | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p')
    if [ -z "$cert" ]; then
        echo unknown
        return 0
    fi
    if printf '%s\n' "$cert" | openssl x509 -noout -checkend 0 >/dev/null 2>&1; then
        if printf '%s\n' "$cert" | openssl x509 -noout -checkend 604800 >/dev/null 2>&1; then
            echo ok
        else
            echo warn
        fi
    else
        echo expired
    fi
}

health_check() {
    today=$(date +%Y-%m-%d)
    if [ -f "$HEALTH_STAMP" ] && [ "$(cat "$HEALTH_STAMP" 2>/dev/null)" = "$today" ]; then
        return 0
    fi
    echo "$today" > "$HEALTH_STAMP"
    problems=""

    for h in "$HEALTH_HOST" "$HEALTH_ASSET_HOST"; do
        case "$(cert_state "$h")" in
            expired) problems="$problems 证书已过期:$h;" ;;
            warn)    problems="$problems 证书7天内到期:$h;" ;;
            unknown) problems="$problems 证书探测失败:$h;" ;;
        esac
    done

    code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "https://$HEALTH_HOST/etapi/app-info" 2>/dev/null)
    case "$code" in
        200|401|403) ;;
        *) problems="$problems 公网接口异常(HTTP $code);" ;;
    esac

    code=$(curl -s -o /dev/null -m 15 -w '%{http_code}' "$HEALTH_LAN_IPA" 2>/dev/null)
    [ "$code" = "200" ] || problems="$problems 内网IPA异常(HTTP $code);"

    if [ -n "$problems" ]; then
        log "HEALTH:$problems"
        notify "trilium-mobile 健康告警" "$problems（每日自检，详见 trilium_autosync.log）" warning
    else
        log "HEALTH: 证书与接口全部正常"
    fi
}

health_check


# 1. 取最新 tag：HEAD 不跟随重定向，从 Location 头解析
LOC=$(curl -sI -m 30 -H "User-Agent: trilium-autosync" "$ASSET_URL" 2>/dev/null \
      | grep -i '^location:' | tr -d '\r' | sed 's/^[Ll]ocation: *//')

REMOTE_TAG=$(echo "$LOC" | sed -n 's#.*/releases/download/\([^/]*\)/.*#\1#p')
REMOTE_VER=$(echo "$REMOTE_TAG" | sed 's/^v//')

if [ -z "$REMOTE_TAG" ]; then
    # 网络不通：静默跳过，下轮重试（不打 FAIL，避免刷告警）
    log "WARN: 查询 GitHub Releases 失败，跳过本次"
    exit 0
fi

# 2. 与基线比对
LAST=""
[ -f "$DIGEST_FILE" ] && LAST=$(cat "$DIGEST_FILE" 2>/dev/null || echo "")

if [ "$REMOTE_TAG" = "$LAST" ] && [ -f "$DATA_DIR/$IPA_NAME" ]; then
    exit 0   # 已是最新，静默
fi

[ -z "$LAST" ] && log "初始化：最新 release $REMOTE_TAG，开始首次拉取" \
              || log "发现新版本：$REMOTE_TAG（旧：$LAST），开始同步"

# 3. 下载 IPA（国内直连 release-assets 可能慢，给足超时并重试 3 次）
TMP_IPA="$DATA_DIR/.${IPA_NAME}.tmp"
dl_ok=0
for try in 1 2 3; do
    if curl -sL -m 240 -H "User-Agent: trilium-autosync" -o "$TMP_IPA" "$ASSET_URL" 2>/dev/null; then
        if head -c 2 "$TMP_IPA" 2>/dev/null | grep -q "PK"; then   # IPA 本质是 zip
            dl_ok=1
            break
        fi
    fi
    log "WARN: 第 $try 次下载失败，重试"
    sleep 5
done

if [ "$dl_ok" -ne 1 ]; then
    rm -f "$TMP_IPA"
    mark_fail "IPA 下载失败（3 次重试均未成功）"
    exit 1
fi

# 4. 落地：IPA 就位 + 刷新清单（原子替换，避免半截文件被下载到）
mv -f "$TMP_IPA" "$DATA_DIR/$IPA_NAME"
chmod 644 "$DATA_DIR/$IPA_NAME" 2>/dev/null

# 留一份带版本号的副本，便于回滚与审计
cp -f "$DATA_DIR/$IPA_NAME" "$DATA_DIR/trilium-mobile-${REMOTE_TAG}.ipa" 2>/dev/null

TMP_MAN="$DATA_DIR/.${MANIFEST}.tmp"
printf '{"version": "%s", "ipaUrl": "%s/%s", "releaseUrl": "https://github.com/%s/releases/tag/v%s"}\n' \
    "$REMOTE_VER" "$PUBLIC_BASE" "$IPA_NAME" "$REPO" "$REMOTE_VER" > "$TMP_MAN"
mv -f "$TMP_MAN" "$DATA_DIR/$MANIFEST"
chmod 644 "$DATA_DIR/$MANIFEST" 2>/dev/null

# 4b. 同步维护 manifest-trilium.ipa：内容与 latest-trilium.json 相同、后缀 .ipa。
#  原因：iOS 原生层（HttpRequestHandler.buildResponse）对 content-type 含 application/json
#  的响应强制 tryParseJson，失败时把错误描述当 data 返回（手机网络路径上实测被污染）。
#  .ipa 后缀 → ezbookkeeping 按 application/zip 下发 → 原生走 arraybuffer/base64 分支，
#  JS 端拿到原始字节自己解码，全程绕开原生 JSON 解析。
MANIFEST_AS_IPA="manifest-trilium.ipa"
TMP_MI="$DATA_DIR/.${MANIFEST_AS_IPA}.tmp"
printf '{"version": "%s", "ipaUrl": "%s/%s", "releaseUrl": "https://github.com/%s/releases/tag/v%s"}\n' \
    "$REMOTE_VER" "$PUBLIC_BASE" "$IPA_NAME" "$REPO" "$REMOTE_VER" > "$TMP_MI"
mv -f "$TMP_MI" "$DATA_DIR/$MANIFEST_AS_IPA"
chmod 644 "$DATA_DIR/$MANIFEST_AS_IPA" 2>/dev/null

# 5. 清理：只保留最近 N 个带版本号的副本（trilium-mobile.ipa 固定名不动）
ls -t "$DATA_DIR"/trilium-mobile-v*.ipa 2>/dev/null | tail -n +$((KEEP_IPA + 1)) | xargs -r rm -f

# 6. 完成
echo "$REMOTE_TAG" > "$DIGEST_FILE"
mark_ok
log "同步完成：$REMOTE_TAG → $DATA_DIR/$IPA_NAME（$(wc -c < "$DATA_DIR/$IPA_NAME") 字节），清单 version=$REMOTE_VER"

# 日志只留最近 500 行
tail -n 500 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
