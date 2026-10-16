# -*- coding: utf-8 -*-
"""把构建好的 IPA 发布到 NAS 上的公开下载目录。

用途：手机在国内网络环境下直连 GitHub 常被墙（TrollStore 填 GitHub 原链会超时），
所以 IPA 统一放 NAS，经自有域名（ddnsto 穿透）无鉴权直下。

⚠️ 凭据一律不写进仓库（本仓库已 public）。按顺序取：
  1. 环境变量：NAS_SSH_PASS / NAS_SSH_USER / NAS_SSH_PORT / NAS_HOSTS / NAS_CRED_FILE
  2. NAS_CRED_FILE 指向的凭据文件（一行，空格分隔：IP 端口 用户 密码）
  3. scripts/nas_config.local.py（已 gitignore）里定义的同名小写变量

用法：
  python nas_publish_trilium.py --ipa ../builds/trilium-mobile-v1.0.00.21-trollstore.ipa \
      --name trilium-mobile.ipa
"""

import argparse
import base64
import hashlib
import json
import os
import sys
import tempfile

import paramiko

DATA_DIR = os.environ.get("NAS_TRILIUM_DIR", "/volume2/docker/ezbk/nestkeep")
PUBLIC_BASE = os.environ.get("NAS_PUBLIC_BASE", "https://ezbookx.x.ddnsto.com/api/nestkeep")
DEFAULT_HOSTS = ["100.95.218.4", "192.168.188.2", "192.168.31.198"]
# 单次 echo 的 base64 长度：远低于 Linux ARG_MAX（~128KB），又能把往返次数压到几十次
CHUNK = 16000


def load_config():
    """返回 (user, password, port, hosts)。"""
    user = os.environ.get("NAS_SSH_USER", "")
    password = os.environ.get("NAS_SSH_PASS", "")
    port = int(os.environ.get("NAS_SSH_PORT", "8122") or 8122)
    hosts = [h for h in os.environ.get("NAS_HOSTS", "").split(",") if h]

    # 本地私密配置覆盖（不提交）
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import nas_config_local as local  # noqa: F401
        user = getattr(local, "NAS_SSH_USER", user) or user
        password = getattr(local, "NAS_SSH_PASS", password) or password
        port = getattr(local, "NAS_SSH_PORT", port) or port
        hosts = getattr(local, "NAS_HOSTS", hosts) or hosts
    except ImportError:
        pass

    # 凭据文件：一行 4 字段
    cred_file = os.environ.get("NAS_CRED_FILE", "")
    if cred_file and os.path.isfile(cred_file):
        with open(cred_file, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 4 and not line.strip().startswith("#"):
                    hosts = hosts or [parts[0]]
                    port = int(parts[1])
                    user = user or parts[2]
                    password = password or parts[3]
                    break

    return user, password, port, hosts or DEFAULT_HOSTS


def shq(s):
    return "'" + s.replace("'", "'\\''") + "'"


def run(client, cmd, timeout=900):
    chan = client.exec_command(
        "echo '%s' | sudo -S -p '' bash -c %s" % (PASSWORD, shq(cmd)), timeout=timeout)
    out = chan[1].read().decode("utf-8", "replace")
    err = chan[2].read().decode("utf-8", "replace")
    return out, err


def connect(user, password, port, hosts):
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    for h in hosts:
        try:
            client.connect(h, port=port, username=user, password=password, timeout=12,
                           allow_agent=False, look_for_keys=False)
            print("已连接 %s" % h, flush=True)
            return client, h
        except Exception as e:  # noqa: BLE001
            print("  [%s] %s" % (h, e), flush=True)
    print("__FAIL__ 连不上 NAS")
    sys.exit(2)


def upload(client, local_path, remote_name):
    with open(local_path, "rb") as f:
        raw = f.read()
    digest = hashlib.sha256(raw).hexdigest()
    b64 = base64.b64encode(raw).decode("ascii")
    remote_path = "%s/%s" % (DATA_DIR.rstrip("/"), remote_name)

    run(client, "mkdir -p %s && : > /tmp/_ipa.b64" % shq(DATA_DIR))
    total = (len(b64) + CHUNK - 1) // CHUNK
    for i in range(0, len(b64), CHUNK):
        run(client, "echo %s >> /tmp/_ipa.b64" % shq(b64[i:i + CHUNK]))
        done = i // CHUNK + 1
        if done % 10 == 0 or done == total:
            print("  上传中 %d/%d" % (done, total), flush=True)

    out, err = run(client,
                   "base64 -d /tmp/_ipa.b64 > %s && rm -f /tmp/_ipa.b64 && "
                   "chmod 644 %s && ls -l %s && sha256sum %s"
                   % (shq(remote_path), shq(remote_path), shq(remote_path), shq(remote_path)))
    print(out.strip())
    if err.strip():
        print("[stderr] %s" % err.strip()[:300])
    return digest


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ipa", required=True, help="本地 IPA 路径")
    ap.add_argument("--name", default="trilium-mobile.ipa", help="NAS 上的文件名")
    ap.add_argument("--version", default="", help="IPA 版本号；给了就同步上传更新清单 latest-trilium.json")
    args = ap.parse_args()

    if not os.path.isfile(args.ipa):
        print("找不到 IPA: %s" % args.ipa)
        sys.exit(1)

    global PASSWORD
    user, PASSWORD, port, hosts = load_config()
    if not PASSWORD:
        print("缺少 NAS 密码：请设 NAS_SSH_PASS 或 NAS_CRED_FILE / scripts/nas_config_local.py")
        sys.exit(1)

    client, _ = connect(user, PASSWORD, port, hosts)
    try:
        digest = upload(client, args.ipa, args.name)
        if args.version:
            manifest = {
                "version": args.version,
                "ipaUrl": "%s/%s" % (PUBLIC_BASE.rstrip("/"), args.name),
                "releaseUrl": "https://github.com/hhxxc/trilium-mobile/releases/tag/v%s" % args.version,
            }
            tmp = os.path.join(tempfile.gettempdir(), "latest-trilium.json")
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(manifest, f, ensure_ascii=False)
            upload(client, tmp, "latest-trilium.json")
            os.remove(tmp)
            print("更新清单已发布: %s/latest-trilium.json" % PUBLIC_BASE.rstrip("/"))
    finally:
        client.close()

    print("\n本地 sha256 : %s" % digest)
    print("公开下载地址: %s/%s" % (PUBLIC_BASE.rstrip("/"), args.name))
    print("校验命令    : curl -sL -o /tmp/x.ipa -w '%%{http_code} %%{size_download}\\n' \\\n"
          "                %s/%s && sha256sum /tmp/x.ipa" % (PUBLIC_BASE.rstrip("/"), args.name))


if __name__ == "__main__":
    main()
