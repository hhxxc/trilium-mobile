# -*- coding: utf-8 -*-
"""用 GitHub Git Data API 推送本地提交（本机 git push 常被代理挡：CONNECT 502）。

为什么不用 git push：本机代理会拦 git 传输，而 gh api 稳定可用。
本脚本的关键点是**保持提交哈希一致**：逐级校验 blob/tree/commit 的 sha 与本地相同，
这样远端与本地始终同源，日后网络恢复后 `git push` 仍然可用。

用法（在仓库根目录）：
    python scripts/gh_push.py                 # 推当前分支到 origin
    python scripts/gh_push.py --branch main

前置：gh 已登录；本地已 commit 好要推的内容。
"""

import argparse
import base64
import json
import os
import socket
import ssl
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone


# ---------------------------------------------------------------------------
# 网络：本机 DNS 经常解析超时（但直连 IP 可通），gh CLI 因此报 Bad Gateway。
# 这里优先用 urllib 直连已知可用 IP（等价 curl --resolve），失败才回退 gh CLI。
# 可用 IP 可用 `curl --resolve api.github.com:443:<ip> https://api.github.com` 探测。
# ---------------------------------------------------------------------------
GITHUB_IP = os.environ.get("GH_API_IP", "140.82.113.6")
_CODELOAD_IP = os.environ.get("GH_CODELOAD_IP", "140.82.113.9")

_orig_getaddrinfo = socket.getaddrinfo


def _install_dns_override():
    """把 GitHub 域名解析到已知 IP，绕开本机坏掉的 DNS。"""
    hosts = {"api.github.com": GITHUB_IP, "codeload.github.com": _CODELOAD_IP}

    def patched(host, port, *a, **k):
        if host in hosts:
            fam = socket.AF_INET
            return [(fam, socket.SOCK_STREAM, 6, "", (hosts[host], port))]
        return _orig_getaddrinfo(host, port, *a, **k)

    socket.getaddrinfo = patched


def _no_proxy_env():
    """清掉代理环境变量：本机代理会拦 git/API 请求（502），直连更可靠。"""
    for k in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY",
              "ALL_PROXY", "all_proxy"):
        os.environ.pop(k, None)


def _gh_token():
    r = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True)
    tok = (r.stdout or "").strip()
    if not tok or r.returncode != 0:
        raise SystemExit("拿不到 GitHub token（先 gh auth login）")
    return tok


def _http(path, method="GET", payload=None):
    """直连 GitHub REST API，返回解析后的 JSON（或原始文本）。"""
    url = path if path.startswith("http") else "https://api.github.com" + path
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "token " + _gh_token())
    req.add_header("User-Agent", "trilium-mobile-push")
    req.add_header("Accept", "application/vnd.github+json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    ctx = ssl.create_default_context()
    with urllib.request.urlopen(req, timeout=30, context=ctx) as r:
        body = r.read().decode("utf-8")
    if not body:
        return ""
    try:
        return json.loads(body)
    except json.JSONDecodeError:
        return body


def run(cmd, binary=False, input_text=None):
    # 非二进制输出强制 UTF-8：Windows 默认用本地编码（GBK）解码，
    # git 的 UTF-8 中文路径会解坏 → 上传成乱码路径
    enc = {} if binary else {"encoding": "utf-8", "errors": "replace"}
    r = subprocess.run(cmd, capture_output=True, text=not binary, input=input_text, **enc)
    if r.returncode != 0:
        raise SystemExit("命令失败: %s\n%s" % (" ".join(cmd), r.stderr))
    return r.stdout


def git(*args, **kw):
    return run(["git"] + list(args), **kw)


def gh_cli_api(path, payload=None, method=None):
    """走 gh CLI（它自己解决 DNS/代理，实测最稳）。"""
    cmd = ["gh", "api"]
    if method:
        cmd += ["-X", method]
    cmd.append(path)
    if payload is None:
        return run(cmd).strip()
    cmd += ["--input", "-"]
    return run(cmd, input_text=json.dumps(payload))


def gh_api(path, payload=None, method=None):
    """GitHub API 调用。优先直连 IP（绕开坏 DNS 和代理），**任何**失败都回退 gh CLI。
    ⚠️ 2026-10-19：硬编码的 GITHUB_IP 会过期，过期后直连拿到 HTTP 400
    （"malformed request"，其实是打到了错误的节点）。以前 HTTP 错误直接退出，
    于是一旦 IP 过期推送就彻底废了 —— HTTP 错误也必须回退。"""
    try:
        result = _http(path, method=method or "GET", payload=payload)
        return result if isinstance(result, str) else json.dumps(result)
    except urllib.error.HTTPError as e:
        sys.stderr.write("直连返回 HTTP %s，回退 gh CLI…\n" % e.code)
        return gh_cli_api(path, payload, method)
    except Exception as e:  # noqa: BLE001 —— 回退到 gh CLI
        sys.stderr.write("直连失败（%s），回退 gh CLI…\n" % e)
        return gh_cli_api(path, payload, method)


def repo_slug():
    url = git("remote", "get-url", "origin").strip()
    for p in ("https://github.com/", "git@github.com:"):
        if url.startswith(p):
            return url[len(p):].removesuffix(".git")
    raise SystemExit("无法从 origin 解析仓库：%s" % url)


def iso(epoch, offset):
    sign = 1 if offset[0] == "+" else -1
    tz = timezone(timedelta(hours=int(offset[1:3]), minutes=int(offset[3:5])) * sign)
    s = datetime.fromtimestamp(epoch, tz).strftime("%Y-%m-%dT%H:%M:%S%z")
    return s[:-2] + ":" + s[-2:]


def ident(line):
    name, rest = line.split(" <", 1)
    email, rest = rest.split("> ", 1)
    epoch, offset = rest.split()
    return {"name": name, "email": email, "date": iso(int(epoch), offset)}


def main():
    _no_proxy_env()
    _install_dns_override()

    ap = argparse.ArgumentParser()
    ap.add_argument("--branch", default=None, help="分支名，默认取当前分支")
    args = ap.parse_args()
    branch = args.branch or git("rev-parse", "--abbrev-ref", "HEAD").strip()
    slug = repo_slug()
    local_head = git("rev-parse", "HEAD").strip()

    # 仓库为空时 Git Data API 会 409，先用 Contents API 造一次提交激活
    repo = json.loads(gh_api("/repos/%s" % slug))
    is_empty = repo.get("isEmpty")
    if is_empty:
        gh_api("/repos/%s/contents/README.md" % slug, {
            "message": "chore: 初始化仓库",
            "content": base64.b64encode(b"# trilium-mobile\n").decode("ascii"),
        }, method="PUT")
        print("仓库为空，已建立引导提交以激活 API（随后会被顶替）")

    # 远端当前 head（空仓库或无该分支时为 None）
    try:
        remote_head = json.loads(
            gh_api("/repos/%s/commits/%s" % (slug, branch)))["sha"]
    except SystemExit:
        remote_head = None

    # 远端 head 若不在本地（引导提交、或远端历史被重写），无法确定推送范围 → 以本地为准整体重建
    if remote_head:
        exists = subprocess.run(["git", "cat-file", "-e", remote_head + "^{commit}"],
                                capture_output=True).returncode == 0
        if not exists:
            print("远端 head %s 本地没有（引导提交或历史被重写）→ 以本地为准重建"
                  % remote_head[:7])
            remote_head = None

    if remote_head == local_head:
        print("已是最新，无需推送（%s）" % local_head[:7])
        return

    # 待推送提交（从旧到新）。远端 head 必须已存在于本地，否则无法确定范围
    rng = ("%s..HEAD" % remote_head) if remote_head else "HEAD"
    commits = git("rev-list", "--reverse", rng).split()
    if not commits:
        raise SystemExit("本地没有相对远端的新提交；若远端已重写历史，请先 fetch 对齐")
    print("待推送 %d 个提交：%s → %s" % (len(commits), commits[0][:7], commits[-1][:7]))

    prev_entries = set()
    parent = remote_head
    for csha in commits:
        raw = git("cat-file", "commit", csha)
        headers, _, message = raw.partition("\n\n")
        author = committer = None
        for line in headers.splitlines():
            if line.startswith("author "):
                author = ident(line[7:])
            elif line.startswith("committer "):
                committer = ident(line[10:])
        tree_sha = git("rev-parse", "%s^{tree}" % csha).strip()

        entries = []
        # -z：NUL 分隔且永不加引号——默认模式会把中文等非 ASCII 路径
        # 显示成带引号的八进制转义串（"docs/\345...），当字面路径上传就炸 tree
        for line in git("ls-tree", "-r", "-z", csha).split("\0"):
            if not line:
                continue
            meta, path = line.split("\t", 1)
            mode, _type, sha = meta.split()
            entries.append((path, mode, sha))

        # 只上传相对上一层新增/变更的 blob（同 sha 的内容天然去重）
        for path, mode, sha in entries:
            key = (path, sha)
            if key in prev_entries:
                continue
            content = git("cat-file", "blob", sha, binary=True)
            res = json.loads(gh_api("/repos/%s/git/blobs" % slug, {
                "content": base64.b64encode(content).decode("ascii"),
                "encoding": "base64"}, method="POST"))
            if res["sha"] != sha:
                raise SystemExit("blob 不一致 %s：本地 %s 远端 %s" % (path, sha[:7], res["sha"][:7]))
        prev_entries = {(p, s) for p, _m, s in entries}

        tree_res = json.loads(gh_api("/repos/%s/git/trees" % slug, {
            "tree": [{"path": p, "mode": m, "type": "blob", "sha": s} for p, m, s in entries],
        }, method="POST"))
        if tree_res["sha"] != tree_sha:
            raise SystemExit("tree 不一致：本地 %s 远端 %s" % (tree_sha[:7], tree_res["sha"][:7]))

        payload = {"message": message, "tree": tree_sha, "author": author, "committer": committer}
        if parent:
            payload["parents"] = [parent]
        commit_res = json.loads(gh_api("/repos/%s/git/commits" % slug, payload, method="POST"))
        if commit_res["sha"] != csha:
            raise SystemExit("commit 不一致：本地 %s 远端 %s（元数据或时间戳不同）" % (csha[:7], commit_res["sha"][:7]))
        parent = csha
        print("  ✓ %s %s" % (csha[:7], message.splitlines()[0][:60]))

    # 更新引用：正常快进；分支不存在（如刚引导过）则强制指向我们的根提交
    if remote_head:
        gh_api("/repos/%s/git/refs/heads/%s" % (slug, branch),
               {"sha": parent, "force": False}, method="PATCH")
    else:
        try:
            gh_api("/repos/%s/git/refs/heads/%s" % (slug, branch),
                   {"sha": parent, "force": True}, method="PATCH")
        except SystemExit:
            gh_api("/repos/%s/git/refs" % slug,
                   {"ref": "refs/heads/%s" % branch, "sha": parent}, method="POST")
    print("已推送 → 远端 %s = 本地 %s ✓" % (branch, parent[:7]))


if __name__ == "__main__":
    sys.exit(main())
