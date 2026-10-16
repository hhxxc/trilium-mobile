# -*- coding: utf-8 -*-
"""临时工具：上传任意文件到 NAS 任意远端路径（复用 nas_publish_trilium 的 SSH 通道）。
用法：python _upload_nas.py <本地文件> <远端绝对路径> [chmod]
"""
import sys
import os
import base64
import hashlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nas_publish_trilium as np

CHUNK = 16000

def upload_to(client, local_path, remote_path, mode="644"):
    with open(local_path, "rb") as f:
        raw = f.read()
    digest = hashlib.sha256(raw).hexdigest()
    b64 = base64.b64encode(raw).decode("ascii")
    np.run(client, ": > /tmp/_up.b64")
    for i in range(0, len(b64), CHUNK):
        np.run(client, "echo %s >> /tmp/_up.b64" % np.shq(b64[i:i + CHUNK]))
    out, err = np.run(client,
                      "base64 -d /tmp/_up.b64 > %s && rm -f /tmp/_up.b64 && "
                      "chmod %s %s && wc -c %s && sha256sum %s"
                      % (np.shq(remote_path), mode, np.shq(remote_path),
                         np.shq(remote_path), np.shq(remote_path)))
    print(out.strip())
    if err.strip():
        print("[stderr]", err.strip()[:200])
    return digest

def main():
    local, remote = sys.argv[1], sys.argv[2]
    mode = sys.argv[3] if len(sys.argv) > 3 else "644"
    user, PASSWORD, port, hosts = np.load_config()
    if not PASSWORD:
        print("缺少 NAS 密码")
        sys.exit(1)
    np.PASSWORD = PASSWORD  # run() 读模块级全局
    client, host = np.connect(user, PASSWORD, port, hosts)
    try:
        digest = upload_to(client, local, remote, mode)
        print("sha256:", digest[:16])
    finally:
        client.close()

if __name__ == "__main__":
    main()
