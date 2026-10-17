# -*- coding: utf-8 -*-
"""临时诊断：查服务端 ETAPI Note 模型定义（不进 git）"""
import paramiko

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect("192.168.31.198", 8122, "hhxxc", "Huhai0912", timeout=10)

# SearchResponse 结构 + /etapi/notes 路由定义
cmd = r"""grep -n -A 15 'SearchResponse:' /tmp/etapi.yaml | head -25; echo ===; grep -n -B3 -A 25 '/etapi/notes:' /tmp/etapi.yaml | grep -A 25 'get:' | head -40"""
i, o, e = c.exec_command(cmd)
out = o.read().decode()
err = e.read().decode()
print(out if out.strip() else "ERR: " + err[:300])
c.close()
