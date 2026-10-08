"""探测 Blender MCP addon（默认 127.0.0.1:9876）是否就绪。

Blender MCP 的协议：TCP + 单行 JSON。
  {"type": "<cmd>", "params": {...}}
这个脚本只做只读探测，不修改 Blender 场景。
"""
import json
import socket
import sys

HOST, PORT = "127.0.0.1", 9876


def send(cmd: dict, timeout: float = 15.0) -> dict:
    s = socket.create_connection((HOST, PORT), timeout=timeout)
    s.settimeout(timeout)
    s.sendall((json.dumps(cmd) + "\n").encode("utf-8"))
    buf = b""
    while True:
        try:
            chunk = s.recv(65536)
        except socket.timeout:
            break
        if not chunk:
            break
        buf += chunk
        try:
            return json.loads(buf.decode("utf-8"))
        except json.JSONDecodeError:
            continue
    s.close()
    return {"status": "error", "raw": buf.decode("utf-8", "replace")[:2000]}


def main() -> int:
    for cmd in ({"type": "get_scene_info", "params": {}},
                {"type": "get_blender_version", "params": {}}):
        print(f"--- {cmd['type']} ---")
        try:
            resp = send(cmd)
            print(json.dumps(resp, ensure_ascii=False, indent=2)[:1500])
        except Exception as e:  # noqa: BLE001
            print(f"[连接失败] {type(e).__name__}: {e}")
            return 1
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
