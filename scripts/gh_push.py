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
import subprocess
import sys
from datetime import datetime, timedelta, timezone


def run(cmd, binary=False, input_text=None):
    r = subprocess.run(cmd, capture_output=True, text=not binary, input=input_text)
    if r.returncode != 0:
        raise SystemExit("命令失败: %s\n%s" % (" ".join(cmd), r.stderr))
    return r.stdout


def git(*args, **kw):
    return run(["git"] + list(args), **kw)


def gh_api(path, payload=None, method=None):
    cmd = ["gh", "api"]
    if method:
        cmd += ["-X", method]
    cmd.append(path)
    if payload is None:
        return run(cmd).strip()
    cmd += ["--input", "-"]
    out = run(cmd, input_text=json.dumps(payload))
    return out


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
    ap = argparse.ArgumentParser()
    ap.add_argument("--branch", default=None, help="分支名，默认取当前分支")
    args = ap.parse_args()
    branch = args.branch or git("rev-parse", "--abbrev-ref", "HEAD").strip()
    slug = repo_slug()
    local_head = git("rev-parse", "HEAD").strip()

    # 远端当前 head（空仓库或无该分支时为 None）
    try:
        remote_head = json.loads(
            gh_api("/repos/%s/commits/%s" % (slug, branch)))["sha"]
    except SystemExit:
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
        for line in git("ls-tree", "-r", csha).splitlines():
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

    # 更新引用
    if remote_head:
        gh_api("/repos/%s/git/refs/heads/%s" % (slug, branch),
               {"sha": parent, "force": False}, method="PATCH")
    else:
        gh_api("/repos/%s/git/refs" % slug,
               {"ref": "refs/heads/%s" % branch, "sha": parent}, method="POST")
    print("已推送 → 远端 %s = 本地 %s ✓" % (branch, parent[:7]))


if __name__ == "__main__":
    sys.exit(main())
