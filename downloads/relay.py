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

Clips (optional, "clips_enabled" in the config):
            POST   /api/clips             upload a clip (Bearer password)
            POST   /api/clips/{id}/thumb  upload its preview image
            GET    /api/clips             list (Bearer password)
            DELETE /api/clips/{id}        delete (Bearer password)
            GET    /api/storage           used / limit / free space
            GET    /c/{id}                public share page (Discord/WhatsApp preview)
            GET    /v/{id}.mp4            public video stream (range requests)
            GET    /t/{id}.jpg            public preview image
         Shared clips are NOT end-to-end encrypted – anyone with the link can watch them.
         "max_storage_gb" limits the space, "public_url" (e.g. https://remote.example.com)
         is used for share links (otherwise derived from the request).
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

VERSION = "1.1.0"
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
            "clips_enabled": True,
            "max_storage_gb": 20,
            "public_url": "",
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

    @property
    def clips_enabled(self) -> bool:
        self.reload()
        return bool(self.data.get("clips_enabled", True))

    @property
    def max_storage_bytes(self) -> int:
        self.reload()
        return int(float(self.data.get("max_storage_gb", 20)) * 1024 ** 3)

    @property
    def public_url(self) -> str:
        self.reload()
        return str(self.data.get("public_url", "")).rstrip("/")

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
<p>Server läuft · Version {VERSION}</p><p><b>{len(relay.macs)}</b> Mac(s) online · <b>{len(relay.clients)}</b> App(s) verbunden · <b>{len(clip_store.clips)}</b> Clip(s)</p>
<p style="opacity:.6">Alle Inhalte sind Ende-zu-Ende verschlüsselt.</p></div></body></html>"""
    return web.Response(text=html, content_type="text/html")


async def health(_: web.Request) -> web.Response:
    return web.Response(text="ok")



# --------------------------------------------------------------------------- clips

CLIPS_DIR = os.environ.get("SIMPLEX_CLIPS", os.path.join(BASE_DIR, "clips"))
CLIP_ID_CHARS = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"


class ClipStore:
    """Clips on disk plus a small JSON index."""

    def __init__(self, directory: str) -> None:
        self.dir = directory
        os.makedirs(self.dir, exist_ok=True)
        self.index_path = os.path.join(self.dir, "index.json")
        self.clips: Dict[str, dict] = {}
        self._load()

    def _load(self) -> None:
        try:
            with open(self.index_path, "r", encoding="utf-8") as fh:
                self.clips = {c["id"]: c for c in json.load(fh)}
        except (OSError, ValueError, KeyError):
            self.clips = {}
        # Drop entries whose file vanished.
        self.clips = {k: v for k, v in self.clips.items() if os.path.exists(self.video_path(k))}

    def save(self) -> None:
        tmp = self.index_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(sorted(self.clips.values(), key=lambda c: c["created"], reverse=True), fh, indent=1)
        os.replace(tmp, self.index_path)

    def new_id(self) -> str:
        while True:
            cid = "".join(secrets.choice(CLIP_ID_CHARS) for _ in range(10))
            if cid not in self.clips:
                return cid

    def video_path(self, cid: str) -> str:
        return os.path.join(self.dir, f"{cid}.mp4")

    def thumb_path(self, cid: str) -> str:
        return os.path.join(self.dir, f"{cid}.jpg")

    def used_bytes(self) -> int:
        total = 0
        for cid in self.clips:
            for path in (self.video_path(cid), self.thumb_path(cid)):
                try:
                    total += os.path.getsize(path)
                except OSError:
                    pass
        return total

    def delete(self, cid: str) -> bool:
        if cid not in self.clips:
            return False
        for path in (self.video_path(cid), self.thumb_path(cid)):
            try:
                os.remove(path)
            except OSError:
                pass
        del self.clips[cid]
        self.save()
        return True


clip_store = ClipStore(CLIPS_DIR)


def bearer_ok(request: web.Request) -> bool:
    header = request.headers.get("Authorization", "")
    token = header[7:] if header.lower().startswith("bearer ") else request.query.get("key", "")
    return password_ok(token)


def base_url(request: web.Request) -> str:
    if config.public_url:
        return config.public_url
    proto = request.headers.get("X-Forwarded-Proto", request.scheme)
    host = request.headers.get("X-Forwarded-Host", request.host)
    return f"{proto}://{host}"


def clip_json(request: web.Request, clip: dict) -> dict:
    base = base_url(request)
    data = dict(clip)
    data["url"] = f"{base}/v/{clip['id']}.mp4"
    data["shareUrl"] = f"{base}/c/{clip['id']}"
    data["thumbUrl"] = f"{base}/t/{clip['id']}.jpg" if clip.get("thumb") else None
    return data


def storage_info() -> dict:
    used = clip_store.used_bytes()
    try:
        st = os.statvfs(clip_store.dir)
        disk_free = st.f_bavail * st.f_frsize
        disk_total = st.f_blocks * st.f_frsize
    except (OSError, AttributeError):
        disk_free = disk_total = 0
    return {"used": used, "limit": config.max_storage_bytes, "count": len(clip_store.clips),
            "diskFree": disk_free, "diskTotal": disk_total, "enabled": config.clips_enabled}


def require_auth(handler):
    async def wrapper(request: web.Request) -> web.StreamResponse:
        if not bearer_ok(request):
            await asyncio.sleep(1.0)
            return web.json_response({"error": "Falsches Passwort"}, status=401)
        return await handler(request)
    return wrapper


@require_auth
async def api_upload(request: web.Request) -> web.Response:
    if not config.clips_enabled:
        return web.json_response({"error": "Clips sind auf diesem Server deaktiviert"}, status=403)
    length = request.content_length or 0
    info = storage_info()
    if length and info["used"] + length > info["limit"]:
        return web.json_response({"error": "Speicherlimit des Servers erreicht", **info}, status=507)

    cid = clip_store.new_id()
    path = clip_store.video_path(cid)
    tmp = path + ".part"
    written = 0
    try:
        with open(tmp, "wb") as fh:
            async for chunk in request.content.iter_chunked(1 << 16):
                written += len(chunk)
                if info["used"] + written > info["limit"]:
                    raise web.HTTPInsufficientStorage(text="Speicherlimit erreicht")
                fh.write(chunk)
        if written == 0:
            raise web.HTTPBadRequest(text="Leere Datei")
        os.replace(tmp, path)
    except web.HTTPException as exc:
        try:
            os.remove(tmp)
        except OSError:
            pass
        return web.json_response({"error": exc.text or "Upload fehlgeschlagen"}, status=exc.status)

    h = request.headers
    def num(key: str, default: float = 0) -> float:
        try:
            return float(h.get(key, default))
        except ValueError:
            return default
    from urllib.parse import unquote
    clip = {
        "id": cid,
        "name": unquote(h.get("X-Clip-Name", "Clip"))[:120],
        "game": unquote(h.get("X-Clip-Game", ""))[:80],
        "mac": unquote(h.get("X-Clip-Mac", ""))[:80],
        "duration": num("X-Clip-Duration"),
        "width": int(num("X-Clip-Width", 1920)),
        "height": int(num("X-Clip-Height", 1080)),
        "size": written,
        "created": time.time(),
        "views": 0,
        "thumb": False,
    }
    clip_store.clips[cid] = clip
    clip_store.save()
    log.info("Clip hochgeladen: %s (%s, %.1f MB)", clip["name"], cid, written / 1e6)
    return web.json_response(clip_json(request, clip), status=201)


@require_auth
async def api_thumb(request: web.Request) -> web.Response:
    cid = request.match_info["cid"]
    clip = clip_store.clips.get(cid)
    if not clip:
        return web.json_response({"error": "Unbekannter Clip"}, status=404)
    data = await request.read()
    if not data or len(data) > 4 * 1024 * 1024:
        return web.json_response({"error": "Ungültiges Vorschaubild"}, status=400)
    with open(clip_store.thumb_path(cid), "wb") as fh:
        fh.write(data)
    clip["thumb"] = True
    clip_store.save()
    return web.json_response(clip_json(request, clip))


@require_auth
async def api_list(request: web.Request) -> web.Response:
    clips = sorted(clip_store.clips.values(), key=lambda c: c["created"], reverse=True)
    return web.json_response({"clips": [clip_json(request, c) for c in clips], "storage": storage_info()})


@require_auth
async def api_delete(request: web.Request) -> web.Response:
    ok = clip_store.delete(request.match_info["cid"])
    return web.json_response({"deleted": ok, "storage": storage_info()}, status=200 if ok else 404)


@require_auth
async def api_storage(_: web.Request) -> web.Response:
    return web.json_response(storage_info())


async def public_video(request: web.Request) -> web.StreamResponse:
    cid = request.match_info["cid"]
    if cid not in clip_store.clips:
        raise web.HTTPNotFound()
    # FileResponse handles Range requests → instant seeking/streaming in every player.
    return web.FileResponse(clip_store.video_path(cid), headers={
        "Content-Type": "video/mp4", "Cache-Control": "public, max-age=86400", "Accept-Ranges": "bytes"})


async def public_thumb(request: web.Request) -> web.StreamResponse:
    cid = request.match_info["cid"]
    path = clip_store.thumb_path(cid)
    if cid not in clip_store.clips or not os.path.exists(path):
        raise web.HTTPNotFound()
    return web.FileResponse(path, headers={"Content-Type": "image/jpeg", "Cache-Control": "public, max-age=86400"})


def esc(text: str) -> str:
    import html as _html
    return _html.escape(str(text), quote=True)


async def share_page(request: web.Request) -> web.Response:
    cid = request.match_info["cid"]
    clip = clip_store.clips.get(cid)
    if not clip:
        raise web.HTTPNotFound(text="Clip nicht gefunden")
    clip["views"] = int(clip.get("views", 0)) + 1
    clip_store.save()
    data = clip_json(request, clip)
    title = clip["game"] + " – Clip" if clip.get("game") else clip["name"]
    when = time.strftime("%d.%m.%Y %H:%M", time.localtime(clip["created"]))
    duration = int(round(clip.get("duration", 0)))
    thumb_tags = ""
    if data["thumbUrl"]:
        thumb_tags = (f'<meta property="og:image" content="{esc(data["thumbUrl"])}">'
                      f'<meta name="twitter:image" content="{esc(data["thumbUrl"])}">')
    page = f"""<!doctype html><html lang="de"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{esc(title)}</title>
<meta property="og:site_name" content="Simplex Clips">
<meta property="og:type" content="video.other">
<meta property="og:title" content="{esc(title)}">
<meta property="og:description" content="{duration} s · {esc(when)}">
<meta property="og:url" content="{esc(data['shareUrl'])}">
<meta property="og:video" content="{esc(data['url'])}">
<meta property="og:video:url" content="{esc(data['url'])}">
<meta property="og:video:secure_url" content="{esc(data['url'])}">
<meta property="og:video:type" content="video/mp4">
<meta property="og:video:width" content="{clip.get('width', 1920)}">
<meta property="og:video:height" content="{clip.get('height', 1080)}">
<meta name="twitter:card" content="player">
<meta name="twitter:title" content="{esc(title)}">
<meta name="twitter:player" content="{esc(data['url'])}">
<meta name="twitter:player:width" content="{clip.get('width', 1920)}">
<meta name="twitter:player:height" content="{clip.get('height', 1080)}">
<meta name="theme-color" content="#8f7cff">
{thumb_tags}
<style>
:root{{color-scheme:dark}}
body{{margin:0;min-height:100vh;font-family:-apple-system,BlinkMacSystemFont,system-ui,sans-serif;color:#f2f2f7;
background:radial-gradient(60vw 60vw at 10% 0%,#4b2fbf55,transparent),radial-gradient(60vw 60vw at 100% 80%,#d9346b44,transparent),#0b0b12;
display:flex;align-items:center;justify-content:center;padding:24px;box-sizing:border-box}}
.card{{width:min(1100px,100%);background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.12);
border-radius:28px;padding:14px;backdrop-filter:blur(30px);-webkit-backdrop-filter:blur(30px);box-shadow:0 30px 80px #0008}}
video{{width:100%;border-radius:18px;background:#000;display:block;max-height:78vh}}
.meta{{display:flex;flex-wrap:wrap;gap:12px;align-items:center;justify-content:space-between;padding:14px 8px 4px}}
h1{{font-size:20px;margin:0}} .sub{{opacity:.65;font-size:14px;margin-top:4px}}
a.btn{{color:#fff;text-decoration:none;background:#8f7cff;padding:10px 18px;border-radius:999px;font-weight:600;font-size:14px}}
</style></head><body><div class="card">
<video src="{esc(data['url'])}" controls autoplay playsinline preload="metadata" {('poster="' + esc(data['thumbUrl']) + '"') if data['thumbUrl'] else ''}></video>
<div class="meta"><div><h1>🎬 {esc(title)}</h1><div class="sub">{duration} Sekunden · {esc(when)}{(' · ' + esc(clip['mac'])) if clip.get('mac') else ''}</div></div>
<a class="btn" href="{esc(data['url'])}" download>Herunterladen</a></div></div></body></html>"""
    return web.Response(text=page, content_type="text/html")


def build_app() -> web.Application:
    app = web.Application(client_max_size=MAX_MESSAGE)
    app.router.add_get("/", index)
    app.router.add_get("/health", health)
    app.router.add_get("/ws", ws_handler)
    app.router.add_post("/api/clips", api_upload)
    app.router.add_get("/api/clips", api_list)
    app.router.add_post("/api/clips/{cid}/thumb", api_thumb)
    app.router.add_delete("/api/clips/{cid}", api_delete)
    app.router.add_get("/api/storage", api_storage)
    app.router.add_get("/c/{cid}", share_page)
    app.router.add_get(r"/v/{cid}.mp4", public_video)
    app.router.add_get(r"/t/{cid}.jpg", public_thumb)
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
    print(f"  Clips:     {'an' if config.clips_enabled else 'aus'} · max. {config.max_storage_bytes / 1024 ** 3:.0f} GB · {CLIPS_DIR}")
    print(banner, flush=True)
    web.run_app(build_app(), host=config.host, port=config.port, ssl_context=ctx, print=None)


if __name__ == "__main__":
    main()
