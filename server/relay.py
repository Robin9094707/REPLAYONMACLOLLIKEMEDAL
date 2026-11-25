#!/usr/bin/env python3
"""
Simplex Remote Relay
====================

Tiny WebSocket relay that connects the Simplex Suite (Mac) with the Simplex Remote
iPhone app – from anywhere. Everything between Mac and iPhone is end-to-end encrypted
(AES-GCM, key from the pairing QR code). This server only forwards bytes and can
neither see the screen nor read keystrokes or passwords.

Start:   python3 relay.py
Config:  simplex_relay.json (created on first start, next to this file)
         - "password": access password for Macs and iPhones (generated, change any time –
                       the file is re-read on every login, no restart needed)
         - "port":     listening port (or environment variable PORT)
         - "tls_cert"/"tls_key": optional paths for HTTPS directly in this script
                       (otherwise put it behind a reverse proxy with your domain)

Endpoints:  GET /        status page
            GET /health  "ok"
            WS  /ws      Mac + iPhone connections
"""

from __future__ import annotations

import asyncio
import hmac
import json
import logging
import os
import secrets
import ssl
import sys
import time
from dataclasses import dataclass, field
from typing import Dict, Optional, Set

try:
    from aiohttp import WSMsgType, web
except ImportError:  # pragma: no cover
    print("Bitte zuerst installieren:  pip install aiohttp", file=sys.stderr)
    raise

VERSION = "1.0.0"
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.environ.get("SIMPLEX_CONFIG", os.path.join(BASE_DIR, "simplex_relay.json"))
MAX_MESSAGE = 16 * 1024 * 1024
KIND_STATUS = 0x03

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("simplex-relay")


# --------------------------------------------------------------------------- config

class Config:
    """Loads simplex_relay.json and re-reads it whenever the file changes."""

    def __init__(self, path: str) -> None:
        self.path = path
        self._mtime = 0.0
        self.data: dict = {}
        self._ensure()
        self.reload()

    def _ensure(self) -> None:
        if os.path.exists(self.path):
            return
        data = {
            "password": secrets.token_urlsafe(18),
            "host": "0.0.0.0",
            "port": int(os.environ.get("PORT", "8765")),
            "tls_cert": "",
            "tls_key": "",
        }
        with open(self.path, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2)
        try:
            os.chmod(self.path, 0o600)
        except OSError:
            pass
        log.info("Neue Konfiguration erstellt: %s", self.path)

    def reload(self) -> None:
        try:
            mtime = os.path.getmtime(self.path)
        except OSError:
            return
        if mtime == self._mtime:
            return
        try:
            with open(self.path, "r", encoding="utf-8") as fh:
                self.data = json.load(fh)
            self._mtime = mtime
            if self._mtime:
                log.info("Konfiguration geladen")
        except (OSError, ValueError) as exc:
            log.error("Konfiguration fehlerhaft (%s) – behalte alte Werte", exc)

    @property
    def password(self) -> str:
        self.reload()
        return str(self.data.get("password", ""))

    @property
    def host(self) -> str:
        return os.environ.get("HOST", str(self.data.get("host", "0.0.0.0")))

    @property
    def port(self) -> int:
        return int(os.environ.get("PORT", self.data.get("port", 8765)))

    def ssl_context(self) -> Optional[ssl.SSLContext]:
        cert, key = self.data.get("tls_cert"), self.data.get("tls_key")
        if not cert or not key:
            return None
        ctx = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        ctx.load_cert_chain(cert, key)
        return ctx


# --------------------------------------------------------------------------- state

@dataclass(eq=False)
class MacConn:
    mac_id: str
    name: str
    ws: web.WebSocketResponse
    since: float = field(default_factory=time.time)
    last_status: Optional[bytes] = None  # encrypted status frame (opaque)


@dataclass(eq=False)
class ClientConn:
    ws: web.WebSocketResponse
    subscriptions: Set[str] = field(default_factory=set)
    attached: Optional[str] = None


class Relay:
    def __init__(self) -> None:
        self.macs: Dict[str, MacConn] = {}
        self.last_seen: Dict[str, float] = {}
        self.names: Dict[str, str] = {}
        self.clients: Set[ClientConn] = set()

    # ----- helpers

    def presence(self, mac_id: str) -> dict:
        mac = self.macs.get(mac_id)
        return {
            "type": "presence",
            "mac": mac_id,
            "online": mac is not None,
            "name": self.names.get(mac_id, ""),
            "since": mac.since if mac else None,
            "lastSeen": self.last_seen.get(mac_id),
        }

    def watchers(self, mac_id: str) -> Set[ClientConn]:
        return {c for c in self.clients if mac_id in c.subscriptions}

    def attached(self, mac_id: str) -> Set[ClientConn]:
        return {c for c in self.clients if c.attached == mac_id}

    async def notify_mac_counts(self, mac_id: str) -> None:
        mac = self.macs.get(mac_id)
        if not mac:
            return
        await safe_send_json(mac.ws, {
            "type": "clients",
            "attached": len(self.attached(mac_id)),
            "watching": len(self.watchers(mac_id)),
        })

    async def broadcast_presence(self, mac_id: str) -> None:
        msg = self.presence(mac_id)
        for client in list(self.watchers(mac_id)):
            await safe_send_json(client.ws, msg)

    @staticmethod
    def wrap(mac_id: str, frame: bytes) -> bytes:
        """Frames to clients carry the sender: [kind][len][mac id][sealed payload]."""
        mid = mac_id.encode("utf-8")[:255]
        return bytes([frame[0], len(mid)]) + mid + frame[1:]


relay = Relay()
config = Config(CONFIG_PATH)


async def safe_send_json(ws: web.WebSocketResponse, msg: dict) -> None:
    if ws.closed:
        return
    try:
        await ws.send_json(msg)
    except (ConnectionResetError, RuntimeError):
        pass


async def safe_send_bytes(ws: web.WebSocketResponse, data: bytes) -> None:
    if ws.closed:
        return
    try:
        await ws.send_bytes(data)
    except (ConnectionResetError, RuntimeError):
        pass


def password_ok(given: str) -> bool:
    expected = config.password
    return bool(expected) and hmac.compare_digest(str(given).encode(), expected.encode())


# --------------------------------------------------------------------------- handlers

async def ws_handler(request: web.Request) -> web.WebSocketResponse:
    ws = web.WebSocketResponse(heartbeat=20, max_msg_size=MAX_MESSAGE, compress=False)
    await ws.prepare(request)
    peer = request.headers.get("X-Forwarded-For", request.remote)

    # First message must be the hello with the password.
    try:
        first = await asyncio.wait_for(ws.receive(), timeout=15)
    except asyncio.TimeoutError:
        await ws.close(code=4000, message=b"timeout")
        return ws
    if first.type != WSMsgType.TEXT:
        await ws.close(code=4000, message=b"hello expected")
        return ws
    try:
        hello = json.loads(first.data)
    except ValueError:
        await ws.close(code=4000, message=b"bad hello")
        return ws

    if not password_ok(hello.get("password", "")):
        log.warning("Falsches Passwort von %s", peer)
        await asyncio.sleep(1.5)  # slow down guessing
        await safe_send_json(ws, {"type": "error", "code": "auth", "message": "Falsches Server-Passwort"})
        await ws.close(code=4001, message=b"auth")
        return ws

    role = hello.get("role")
    if role == "mac":
        await handle_mac(ws, hello, peer)
    elif role == "client":
        await handle_client(ws, hello, peer)
    else:
        await ws.close(code=4000, message=b"unknown role")
    return ws


async def handle_mac(ws: web.WebSocketResponse, hello: dict, peer: str) -> None:
    mac_id = str(hello.get("mac", ""))[:64]
    if not mac_id:
        await ws.close(code=4000, message=b"mac id missing")
        return
    name = str(hello.get("name", "Mac"))[:80]

    old = relay.macs.get(mac_id)
    if old is not None:
        await old.ws.close(code=4002, message=b"replaced")

    mac = MacConn(mac_id=mac_id, name=name, ws=ws)
    relay.macs[mac_id] = mac
    relay.names[mac_id] = name
    relay.last_seen[mac_id] = time.time()
    log.info("Mac verbunden: %s (%s) von %s", name, mac_id[:8], peer)
    await safe_send_json(ws, {"type": "welcome", "server": VERSION})
    await relay.broadcast_presence(mac_id)
    await relay.notify_mac_counts(mac_id)

    try:
        async for msg in ws:
            relay.last_seen[mac_id] = time.time()
            if msg.type == WSMsgType.BINARY:
                data: bytes = msg.data
                if not data:
                    continue
                wrapped = Relay.wrap(mac_id, data)
                if data[0] == KIND_STATUS:
                    mac.last_status = data
                    targets = relay.watchers(mac_id) | relay.attached(mac_id)
                else:
                    targets = relay.attached(mac_id)
                for client in list(targets):
                    await safe_send_bytes(client.ws, wrapped)
            elif msg.type == WSMsgType.TEXT:
                try:
                    payload = json.loads(msg.data)
                except ValueError:
                    continue
                if payload.get("type") == "name":
                    relay.names[mac_id] = mac.name = str(payload.get("name", name))[:80]
                    await relay.broadcast_presence(mac_id)
            elif msg.type == WSMsgType.ERROR:
                break
    finally:
        if relay.macs.get(mac_id) is mac:
            del relay.macs[mac_id]
            relay.last_seen[mac_id] = time.time()
            log.info("Mac getrennt: %s", name)
            await relay.broadcast_presence(mac_id)


async def handle_client(ws: web.WebSocketResponse, hello: dict, peer: str) -> None:
    client = ClientConn(ws=ws, subscriptions={str(m)[:64] for m in hello.get("macs", []) if m})
    relay.clients.add(client)
    log.info("App verbunden von %s (%d Macs abonniert)", peer, len(client.subscriptions))

    await safe_send_json(ws, {
        "type": "welcome",
        "server": VERSION,
        "macs": [relay.presence(m) for m in client.subscriptions],
    })
    for mac_id in client.subscriptions:
        mac = relay.macs.get(mac_id)
        if mac and mac.last_status:
            await safe_send_bytes(ws, Relay.wrap(mac_id, mac.last_status))
        await relay.notify_mac_counts(mac_id)

    try:
        async for msg in ws:
            if msg.type == WSMsgType.BINARY:
                target = client.attached and relay.macs.get(client.attached)
                if target and msg.data:
                    await safe_send_bytes(target.ws, msg.data)
            elif msg.type == WSMsgType.TEXT:
                try:
                    payload = json.loads(msg.data)
                except ValueError:
                    continue
                kind = payload.get("type")
                if kind == "attach":
                    previous = client.attached
                    client.attached = str(payload.get("mac", ""))[:64] or None
                    if client.attached:
                        client.subscriptions.add(client.attached)
                    for mac_id in {previous, client.attached} - {None}:
                        await relay.notify_mac_counts(mac_id)
                    await safe_send_json(ws, {"type": "attached", "mac": client.attached,
                                              "online": client.attached in relay.macs})
                elif kind == "detach":
                    previous, client.attached = client.attached, None
                    if previous:
                        await relay.notify_mac_counts(previous)
                elif kind == "subscribe":
                    client.subscriptions = {str(m)[:64] for m in payload.get("macs", []) if m}
                    await safe_send_json(ws, {"type": "welcome", "server": VERSION,
                                              "macs": [relay.presence(m) for m in client.subscriptions]})
                    for mac_id in client.subscriptions:
                        await relay.notify_mac_counts(mac_id)
                elif kind == "ping":
                    await safe_send_json(ws, {"type": "pong", "t": payload.get("t")})
            elif msg.type == WSMsgType.ERROR:
                break
    finally:
        relay.clients.discard(client)
        for mac_id in client.subscriptions | ({client.attached} if client.attached else set()):
            await relay.notify_mac_counts(mac_id)
        log.info("App getrennt (%s)", peer)


async def index(_: web.Request) -> web.Response:
    html = f"""<!doctype html><html lang="de"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Simplex Relay</title>
<style>body{{font-family:-apple-system,system-ui,sans-serif;background:#0b0b12;color:#eee;display:grid;place-items:center;height:100vh;margin:0}}
.card{{background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.12);border-radius:24px;padding:32px 40px;text-align:center}}
b{{color:#8f7cff}}</style></head><body><div class="card"><h1>🧰 Simplex Relay</h1>
<p>Server läuft · Version {VERSION}</p><p><b>{len(relay.macs)}</b> Mac(s) online · <b>{len(relay.clients)}</b> App(s) verbunden</p>
<p style="opacity:.6">Alle Inhalte sind Ende-zu-Ende verschlüsselt.</p></div></body></html>"""
    return web.Response(text=html, content_type="text/html")


async def health(_: web.Request) -> web.Response:
    return web.Response(text="ok")


def build_app() -> web.Application:
    app = web.Application(client_max_size=MAX_MESSAGE)
    app.router.add_get("/", index)
    app.router.add_get("/health", health)
    app.router.add_get("/ws", ws_handler)
    return app


def main() -> None:
    ctx = config.ssl_context()
    scheme = "https" if ctx else "http"
    banner = "=" * 62
    print(banner)
    print(f"  Simplex Relay {VERSION}")
    print(f"  Adresse:   {scheme}://{config.host}:{config.port}   (WebSocket: /ws)")
    print(f"  Passwort:  {config.password}")
    print(f"  Ändern in: {config.path}")
    print(banner, flush=True)
    web.run_app(build_app(), host=config.host, port=config.port, ssl_context=ctx, print=None)


if __name__ == "__main__":
    main()
