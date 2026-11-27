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

Endpoints:  GET /        Simplex Clips web app (gallery, player, upload – login with the password)
            GET /status  status page
            GET /health  "ok"
            WS  /ws      Mac + iPhone connections

Clips (optional, "clips_enabled" in the config):
            POST   /api/clips             upload a clip (Bearer password, X-Clip-Hash for de-duplication)
            GET    /api/clips/hash/{sha}  is this file already on the server? (skip the upload)
            POST   /api/clips/{id}/thumb  upload its preview image
            GET    /api/clips             list + ids deleted recently ("deleted"), so every device
                                          removes them as well
            PATCH  /api/clips/{id}        rename
            DELETE /api/clips/{id}        delete (Bearer password)
            POST   /api/clips/delete      delete several {"ids": [...]}
            GET    /api/events            live events (Server-Sent Events, ?key=password)
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

VERSION = "1.2.0"
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


async def status_page(_: web.Request) -> web.Response:
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
TOMBSTONE_DAYS = 180
UPLOAD_CHUNK = 1 << 20  # 1 MB – fewer syscalls, full speed on fast links


class ClipStore:
    """Clips on disk plus a small JSON index and a list of recently deleted ids
    ("tombstones") so the Mac and every iPhone remove deleted clips as well."""

    def __init__(self, directory: str) -> None:
        self.dir = directory
        os.makedirs(self.dir, exist_ok=True)
        self.index_path = os.path.join(self.dir, "index.json")
        self.deleted_path = os.path.join(self.dir, "deleted.json")
        self.clips: Dict[str, dict] = {}
        self.deleted: Dict[str, float] = {}
        self._load()

    def _load(self) -> None:
        try:
            with open(self.index_path, "r", encoding="utf-8") as fh:
                self.clips = {c["id"]: c for c in json.load(fh)}
        except (OSError, ValueError, KeyError):
            self.clips = {}
        # Drop entries whose file vanished, and leftovers of aborted uploads.
        self.clips = {k: v for k, v in self.clips.items() if os.path.exists(self.video_path(k))}
        for name in os.listdir(self.dir):
            if name.endswith(".part"):
                try:
                    os.remove(os.path.join(self.dir, name))
                except OSError:
                    pass
        try:
            with open(self.deleted_path, "r", encoding="utf-8") as fh:
                self.deleted = {str(k): float(v) for k, v in json.load(fh).items()}
        except (OSError, ValueError, AttributeError):
            self.deleted = {}
        self._prune_tombstones()

    def _prune_tombstones(self) -> None:
        cutoff = time.time() - TOMBSTONE_DAYS * 86400
        self.deleted = {k: v for k, v in self.deleted.items() if v >= cutoff}

    def save(self) -> None:
        tmp = self.index_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(sorted(self.clips.values(), key=lambda c: c["created"], reverse=True), fh, indent=1)
        os.replace(tmp, self.index_path)

    def save_deleted(self) -> None:
        self._prune_tombstones()
        tmp = self.deleted_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(self.deleted, fh)
        os.replace(tmp, self.deleted_path)

    def new_id(self) -> str:
        while True:
            cid = "".join(secrets.choice(CLIP_ID_CHARS) for _ in range(10))
            if cid not in self.clips and cid not in self.deleted:
                return cid

    def by_hash(self, sha: str) -> Optional[dict]:
        if not sha:
            return None
        return next((c for c in self.clips.values() if c.get("hash") == sha), None)

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
        self.deleted[cid] = time.time()
        self.save()
        self.save_deleted()
        return True


clip_store = ClipStore(CLIPS_DIR)


# ----- live events (Mac + iPhone over their WebSocket, browsers over SSE)

event_queues: Set[asyncio.Queue] = set()


async def broadcast_clip_event(event: str, ids: list) -> None:
    msg = {"type": "clips", "event": event, "ids": ids, "count": len(clip_store.clips)}
    sockets = [m.ws for m in relay.macs.values()] + [c.ws for c in relay.clients]
    for ws in sockets:
        await safe_send_json(ws, msg)
    for queue in list(event_queues):
        try:
            queue.put_nowait(msg)
        except asyncio.QueueFull:
            pass


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
    data["thumbUrl"] = f"{base}/t/{clip['id']}.jpg?v={int(clip.get('thumbVersion', 1))}" if clip.get("thumb") else None
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
    from urllib.parse import unquote
    h = request.headers
    sha = h.get("X-Clip-Hash", "").strip().lower()[:64]
    existing = clip_store.by_hash(sha)
    if existing:
        # Same file is already here – answer instantly, nothing stored twice.
        await request.release()
        return web.json_response({**clip_json(request, existing), "duplicate": True}, status=201)

    length = request.content_length or 0
    info = storage_info()
    if length and info["used"] + length > info["limit"]:
        await request.release()
        return web.json_response({"error": "Speicherlimit des Servers erreicht", **info}, status=507)

    cid = clip_store.new_id()
    path = clip_store.video_path(cid)
    tmp = path + ".part"
    written = 0
    loop = asyncio.get_running_loop()
    try:
        fh = open(tmp, "wb", buffering=UPLOAD_CHUNK)
        try:
            pending = None
            async for chunk in request.content.iter_chunked(UPLOAD_CHUNK):
                written += len(chunk)
                if info["used"] + written > info["limit"]:
                    raise web.HTTPInsufficientStorage(text="Speicherlimit erreicht")
                # Write in a thread while the next chunk is received.
                if pending is not None:
                    await pending
                pending = loop.run_in_executor(None, fh.write, chunk)
            if pending is not None:
                await pending
        finally:
            fh.close()
        if written == 0:
            raise web.HTTPBadRequest(text="Leere Datei")
        if length and written < length:
            raise web.HTTPBadRequest(text="Upload unvollständig")
        os.replace(tmp, path)
    except (web.HTTPException, ConnectionResetError, asyncio.CancelledError) as exc:
        try:
            os.remove(tmp)
        except OSError:
            pass
        if isinstance(exc, asyncio.CancelledError):
            raise
        status = exc.status if isinstance(exc, web.HTTPException) else 400
        text = exc.text if isinstance(exc, web.HTTPException) else "Verbindung abgebrochen"
        return web.json_response({"error": text or "Upload fehlgeschlagen"}, status=status)

    def num(key: str, default: float = 0) -> float:
        try:
            return float(h.get(key, default))
        except ValueError:
            return default
    clip = {
        "id": cid,
        "name": unquote(h.get("X-Clip-Name", "Clip"))[:120],
        "game": unquote(h.get("X-Clip-Game", ""))[:80],
        "mac": unquote(h.get("X-Clip-Mac", ""))[:80],
        "source": unquote(h.get("X-Clip-Source", ""))[:64],
        "hash": sha,
        "duration": num("X-Clip-Duration"),
        "width": int(num("X-Clip-Width", 1920)),
        "height": int(num("X-Clip-Height", 1080)),
        "size": written,
        "created": num("X-Clip-Created", 0) or time.time(),
        "uploaded": time.time(),
        "views": 0,
        "thumb": False,
    }
    clip_store.clips[cid] = clip
    clip_store.save()
    log.info("Clip hochgeladen: %s (%s, %.1f MB)", clip["name"], cid, written / 1e6)
    await broadcast_clip_event("added", [cid])
    return web.json_response(clip_json(request, clip), status=201)


@require_auth
async def api_by_hash(request: web.Request) -> web.Response:
    clip = clip_store.by_hash(request.match_info["sha"].lower())
    if not clip:
        return web.json_response({"exists": False}, status=404)
    return web.json_response({**clip_json(request, clip), "exists": True})


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
    clip["thumbVersion"] = int(clip.get("thumbVersion", 0)) + 1
    clip_store.save()
    await broadcast_clip_event("updated", [cid])
    return web.json_response(clip_json(request, clip))


@require_auth
async def api_list(request: web.Request) -> web.Response:
    clips = sorted(clip_store.clips.values(), key=lambda c: c["created"], reverse=True)
    return web.json_response({"clips": [clip_json(request, c) for c in clips],
                              "deleted": sorted(clip_store.deleted.keys()),
                              "storage": storage_info(), "server": VERSION})


@require_auth
async def api_rename(request: web.Request) -> web.Response:
    cid = request.match_info["cid"]
    clip = clip_store.clips.get(cid)
    if not clip:
        return web.json_response({"error": "Unbekannter Clip"}, status=404)
    try:
        body = await request.json()
    except ValueError:
        return web.json_response({"error": "Ungültige Anfrage"}, status=400)
    if "name" in body:
        clip["name"] = str(body["name"]).strip()[:120] or clip["name"]
    if "game" in body:
        clip["game"] = str(body["game"]).strip()[:80]
    clip_store.save()
    await broadcast_clip_event("updated", [cid])
    return web.json_response(clip_json(request, clip))


@require_auth
async def api_delete(request: web.Request) -> web.Response:
    cid = request.match_info["cid"]
    ok = clip_store.delete(cid)
    if ok:
        log.info("Clip gelöscht: %s", cid)
        await broadcast_clip_event("deleted", [cid])
    return web.json_response({"deleted": ok, "storage": storage_info()}, status=200 if ok else 404)


@require_auth
async def api_delete_many(request: web.Request) -> web.Response:
    try:
        ids = [str(i) for i in (await request.json()).get("ids", [])][:500]
    except (ValueError, AttributeError):
        return web.json_response({"error": "Ungültige Anfrage"}, status=400)
    done = [cid for cid in ids if clip_store.delete(cid)]
    if done:
        log.info("%d Clips gelöscht", len(done))
        await broadcast_clip_event("deleted", done)
    return web.json_response({"deleted": done, "storage": storage_info()})


@require_auth
async def api_storage(_: web.Request) -> web.Response:
    return web.json_response(storage_info())


@require_auth
async def api_events(request: web.Request) -> web.StreamResponse:
    resp = web.StreamResponse(headers={"Content-Type": "text/event-stream", "Cache-Control": "no-cache",
                                       "X-Accel-Buffering": "no"})
    await resp.prepare(request)
    queue: asyncio.Queue = asyncio.Queue(maxsize=100)
    event_queues.add(queue)
    try:
        await resp.write(b"retry: 3000\n\n")
        while True:
            try:
                msg = await asyncio.wait_for(queue.get(), timeout=25)
                await resp.write(f"data: {json.dumps(msg)}\n\n".encode())
            except asyncio.TimeoutError:
                await resp.write(b": ping\n\n")
    except (ConnectionResetError, RuntimeError, asyncio.CancelledError):
        pass
    finally:
        event_queues.discard(queue)
    return resp


async def public_video(request: web.Request) -> web.StreamResponse:
    cid = request.match_info["cid"]
    clip = clip_store.clips.get(cid)
    if not clip:
        raise web.HTTPNotFound()
    headers = {"Content-Type": "video/mp4", "Cache-Control": "public, max-age=604800, immutable",
               "Accept-Ranges": "bytes"}
    if request.query.get("dl"):
        from urllib.parse import quote
        name = (clip.get("name") or cid).replace('"', "")
        headers["Content-Disposition"] = f"attachment; filename*=UTF-8''{quote(name)}.mp4"
    # FileResponse uses sendfile + Range requests → instant seeking/streaming in every player.
    return web.FileResponse(clip_store.video_path(cid), headers=headers, chunk_size=UPLOAD_CHUNK)


async def public_thumb(request: web.Request) -> web.StreamResponse:
    cid = request.match_info["cid"]
    path = clip_store.thumb_path(cid)
    if cid not in clip_store.clips or not os.path.exists(path):
        raise web.HTTPNotFound()
    return web.FileResponse(path, headers={"Content-Type": "image/jpeg", "Cache-Control": "public, max-age=604800"})


def esc(text: str) -> str:
    import html as _html
    return _html.escape(str(text), quote=True)


def fill(template: str, **values: str) -> str:
    for key, value in values.items():
        template = template.replace("{{" + key + "}}", value)
    return template


async def share_page(request: web.Request) -> web.Response:
    cid = request.match_info["cid"]
    clip = clip_store.clips.get(cid)
    if not clip:
        return web.Response(text=fill(NOT_FOUND_HTML), content_type="text/html", status=404)
    # Count real visits, not the link preview bots of Discord & Co.
    agent = request.headers.get("User-Agent", "").lower()
    if not any(bot in agent for bot in ("bot", "discord", "whatsapp", "telegram", "slack", "facebookexternalhit", "twitter")):
        clip["views"] = int(clip.get("views", 0)) + 1
        clip_store.save()
    data = clip_json(request, clip)
    title = clip.get("name") or "Clip"
    if clip.get("game") and clip["game"] not in title:
        title = f"{title} · {clip['game']}"
    duration = int(round(clip.get("duration", 0)))
    thumb_tags = ""
    if data["thumbUrl"]:
        thumb_tags = (f'<meta property="og:image" content="{esc(data["thumbUrl"])}">'
                      f'<meta name="twitter:image" content="{esc(data["thumbUrl"])}">')
    page = fill(
        SHARE_HTML,
        TITLE=esc(title),
        NAME=esc(clip.get("name") or "Clip"),
        GAME=esc(clip.get("game") or "Clip"),
        MAC=esc(clip.get("mac") or "Simplex"),
        INITIAL=esc((clip.get("mac") or "S")[:1].upper()),
        DURATION=str(duration),
        DURATION_TEXT=f"{duration // 60}:{duration % 60:02d}",
        VIEWS=str(int(clip.get("views", 0))),
        CREATED=str(float(clip.get("created", 0))),
        WIDTH=str(int(clip.get("width", 1920))),
        HEIGHT=str(int(clip.get("height", 1080))),
        URL=esc(data["url"]),
        SHARE_URL=esc(data["shareUrl"]),
        POSTER=('poster="' + esc(data["thumbUrl"]) + '"') if data["thumbUrl"] else "",
        THUMB_TAGS=thumb_tags,
    )
    return web.Response(text=page, content_type="text/html")


async def web_app(_: web.Request) -> web.Response:
    return web.Response(text=fill(WEB_APP_HTML, VERSION=VERSION), content_type="text/html",
                        headers={"Cache-Control": "no-cache"})


async def manifest(_: web.Request) -> web.Response:
    return web.json_response({
        "name": "Simplex Clips", "short_name": "Clips", "start_url": "/", "display": "standalone",
        "background_color": "#07070b", "theme_color": "#07070b",
        "icons": [{"src": "/icon.svg", "sizes": "any", "type": "image/svg+xml"}],
    })


async def icon(_: web.Request) -> web.Response:
    return web.Response(text=ICON_SVG, content_type="image/svg+xml",
                        headers={"Cache-Control": "public, max-age=604800"})


def build_app() -> web.Application:
    app = web.Application(client_max_size=MAX_MESSAGE)
    app.router.add_get("/", web_app)
    app.router.add_get("/app", web_app)
    app.router.add_get("/status", status_page)
    app.router.add_get("/health", health)
    app.router.add_get("/manifest.json", manifest)
    app.router.add_get("/icon.svg", icon)
    app.router.add_get("/ws", ws_handler)
    app.router.add_post("/api/clips", api_upload)
    app.router.add_get("/api/clips", api_list)
    app.router.add_post("/api/clips/delete", api_delete_many)
    app.router.add_get("/api/clips/hash/{sha}", api_by_hash)
    app.router.add_post("/api/clips/{cid}/thumb", api_thumb)
    app.router.add_patch("/api/clips/{cid}", api_rename)
    app.router.add_delete("/api/clips/{cid}", api_delete)
    app.router.add_get("/api/storage", api_storage)
    app.router.add_get("/api/events", api_events)
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
    print(f"  Web-App:   {scheme}://{config.host}:{config.port}/   (Login mit dem Passwort)")
    print(f"  Passwort:  {config.password}")
    print(f"  Ändern in: {config.path}")
    print(f"  Clips:     {'an' if config.clips_enabled else 'aus'} · max. {config.max_storage_bytes / 1024 ** 3:.0f} GB · {CLIPS_DIR}")
    print(banner, flush=True)
    web.run_app(build_app(), host=config.host, port=config.port, ssl_context=ctx, print=None)


# --------------------------------------------------------------------------- web templates

ICON_SVG = r'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#7c5cff"/><stop offset="1" stop-color="#ff4d8d"/></linearGradient></defs><rect width="64" height="64" rx="16" fill="url(#g)"/><circle cx="32" cy="32" r="14" fill="none" stroke="#fff" stroke-width="5"/><circle cx="32" cy="32" r="6" fill="#fff"/></svg>'''

BASE_CSS = r'''
:root{--bg:#07070b;--bg2:#0e0e15;--card:#12121b;--card2:#171723;--line:rgba(255,255,255,.08);--line2:rgba(255,255,255,.14);
--text:#f4f4f8;--mute:#9b9bb0;--dim:#6b6b80;--a1:#7c5cff;--a2:#ff4d8d;--ok:#3ddc97;--bad:#ff5a6a;
--grad:linear-gradient(135deg,var(--a1),var(--a2));--r:16px;color-scheme:dark}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
[hidden]{display:none!important}
html,body{margin:0;background:var(--bg);color:var(--text);font-family:Inter,ui-sans-serif,-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
-webkit-font-smoothing:antialiased;font-feature-settings:"cv11","ss01"}
a{color:inherit}
button{font:inherit;color:inherit;cursor:pointer;border:0;background:none}
.logo{display:flex;align-items:center;gap:10px;font-weight:800;letter-spacing:-.02em;font-size:18px;text-decoration:none}
.logo i{width:30px;height:30px;border-radius:9px;background:var(--grad);display:grid;place-items:center;box-shadow:0 6px 20px #7c5cff55}
.logo i:after{content:"";width:12px;height:12px;border-radius:50%;border:3px solid #fff;box-shadow:inset 0 0 0 2px transparent}
.logo span b{background:var(--grad);-webkit-background-clip:text;background-clip:text;color:transparent}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;height:40px;padding:0 16px;border-radius:12px;font-weight:650;font-size:14px;
background:var(--card2);border:1px solid var(--line);transition:transform .15s,background .15s,border-color .15s;white-space:nowrap;text-decoration:none}
.btn:hover{background:#1f1f2e;border-color:var(--line2)}
.btn:active{transform:scale(.97)}
.btn.primary{background:var(--grad);border:0;box-shadow:0 8px 24px #7c5cff40}
.btn.primary:hover{filter:brightness(1.08)}
.btn.danger{color:#ff8e99}
.btn.danger:hover{background:#ff5a6a22;border-color:#ff5a6a55}
.btn svg{width:18px;height:18px}
.ic{width:40px;padding:0}
.toast{position:fixed;left:50%;bottom:28px;transform:translate(-50%,30px);opacity:0;pointer-events:none;z-index:99;
background:#1c1c29f2;border:1px solid var(--line2);backdrop-filter:blur(20px);-webkit-backdrop-filter:blur(20px);padding:12px 18px;border-radius:14px;
font-weight:600;font-size:14px;transition:.3s cubic-bezier(.2,.9,.3,1.2);box-shadow:0 20px 50px #000a}
.toast.show{opacity:1;transform:translate(-50%,0)}
'''

ICONS_JS = r'''
const I={
link:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10 13a5 5 0 0 0 7.5.5l3-3a5 5 0 0 0-7-7l-1.7 1.7"/><path d="M14 11a5 5 0 0 0-7.5-.5l-3 3a5 5 0 0 0 7 7l1.7-1.7"/></svg>',
dl:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v12m0 0 5-5m-5 5-5-5M4 21h16"/></svg>',
trash:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h18M8 6V4h8v2m-9 0 1 14h8l1-14"/></svg>',
eye:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12Z"/><circle cx="12" cy="12" r="3"/></svg>',
up:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 21V9m0 0-5 5m5-5 5 5M4 3h16"/></svg>',
x:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M6 6l12 12M18 6 6 18"/></svg>',
l:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="m15 18-6-6 6-6"/></svg>',
r:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="m9 18 6-6-6-6"/></svg>',
ext:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14 4h6v6M20 4l-9 9M19 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1h5"/></svg>',
play:'<svg viewBox="0 0 24 24" fill="currentColor"><path d="M8 5.5v13a1 1 0 0 0 1.5.9l10.4-6.5a1 1 0 0 0 0-1.8L9.5 4.6A1 1 0 0 0 8 5.5Z"/></svg>',
check:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="m5 12 5 5 9-10"/></svg>',
search:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>',
out:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M15 4h4a1 1 0 0 1 1 1v14a1 1 0 0 1-1 1h-4M10 17l-5-5 5-5M5 12h12"/></svg>',
full:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5"/></svg>',
sel:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="5"/><path d="m8 12 3 3 5-6"/></svg>'};
const rtf=new Intl.RelativeTimeFormat('de',{numeric:'auto'});
function ago(ts){const s=(ts*1000-Date.now())/1000,a=Math.abs(s);
 if(a<60)return 'gerade eben';if(a<3600)return rtf.format(Math.round(s/60),'minute');if(a<86400)return rtf.format(Math.round(s/3600),'hour');
 if(a<86400*30)return rtf.format(Math.round(s/86400),'day');if(a<86400*365)return rtf.format(Math.round(s/86400/30),'month');return rtf.format(Math.round(s/86400/365),'year')}
function dur(s){s=Math.round(s||0);return Math.floor(s/60)+':'+String(s%60).padStart(2,'0')}
function bytes(b){if(!b)return '0 B';const u=['B','KB','MB','GB','TB'];let i=Math.min(4,Math.floor(Math.log(b)/Math.log(1024)));return (b/1024**i).toFixed(i>2?1:0).replace('.',',')+' '+u[i]}
function toast(t){const e=document.getElementById('toast');e.textContent=t;e.classList.add('show');clearTimeout(e._t);e._t=setTimeout(()=>e.classList.remove('show'),2200)}
async function copy(t){try{await navigator.clipboard.writeText(t)}catch(_){const a=document.createElement('textarea');a.value=t;document.body.appendChild(a);a.select();document.execCommand('copy');a.remove()}toast('Link kopiert – einfach in Discord einfügen')}
'''

NOT_FOUND_HTML = r'''<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Clip nicht gefunden</title><link rel="icon" href="/icon.svg"><style>''' + BASE_CSS + r'''
body{min-height:100vh;display:grid;place-items:center;text-align:center;padding:24px;
background:radial-gradient(800px 500px at 50% -10%,#7c5cff30,transparent),var(--bg)}
h1{font-size:28px;margin:22px 0 8px;letter-spacing:-.02em}p{color:var(--mute);margin:0 0 24px}
</style></head><body><div><div class="logo" style="justify-content:center"><i></i><span>Simplex <b>Clips</b></span></div>
<h1>Dieser Clip ist nicht mehr da</h1><p>Er wurde gelöscht oder der Link ist falsch.</p></div></body></html>'''

SHARE_HTML = r'''<!doctype html><html lang="de"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>{{TITLE}} – Simplex Clips</title>
<link rel="icon" href="/icon.svg">
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap" rel="stylesheet">
<meta property="og:site_name" content="Simplex Clips">
<meta property="og:type" content="video.other">
<meta property="og:title" content="{{TITLE}}">
<meta property="og:description" content="{{GAME}} · {{DURATION}} s · aufgenommen von {{MAC}}">
<meta property="og:url" content="{{SHARE_URL}}">
<meta property="og:video" content="{{URL}}">
<meta property="og:video:url" content="{{URL}}">
<meta property="og:video:secure_url" content="{{URL}}">
<meta property="og:video:type" content="video/mp4">
<meta property="og:video:width" content="{{WIDTH}}">
<meta property="og:video:height" content="{{HEIGHT}}">
<meta name="twitter:card" content="player">
<meta name="twitter:title" content="{{TITLE}}">
<meta name="twitter:player" content="{{URL}}">
<meta name="twitter:player:width" content="{{WIDTH}}">
<meta name="twitter:player:height" content="{{HEIGHT}}">
<meta name="theme-color" content="#07070b">
{{THUMB_TAGS}}
<style>''' + BASE_CSS + r'''
body{min-height:100vh;background:radial-gradient(1100px 600px at 15% -10%,#7c5cff2e,transparent 60%),radial-gradient(900px 500px at 100% 0%,#ff4d8d1f,transparent 60%),var(--bg)}
nav{position:sticky;top:0;z-index:5;display:flex;align-items:center;justify-content:space-between;gap:12px;padding:14px max(20px,env(safe-area-inset-left));
background:linear-gradient(#07070bdd,#07070b99);backdrop-filter:blur(18px);-webkit-backdrop-filter:blur(18px);border-bottom:1px solid var(--line)}
main{max-width:1320px;margin:0 auto;padding:28px 20px 60px}
.stage{position:relative;border-radius:20px;overflow:hidden;background:#000;box-shadow:0 40px 120px #000c,0 0 0 1px var(--line);aspect-ratio:{{WIDTH}}/{{HEIGHT}};max-height:72vh;max-width:calc(72vh * {{WIDTH}} / {{HEIGHT}});margin:0 auto}
.stage:before{content:"";position:absolute;inset:-40%;background:var(--grad);filter:blur(120px);opacity:.18;z-index:-1}
video{width:100%;height:100%;display:block;background:#000;object-fit:contain}
.info{display:flex;flex-wrap:wrap;gap:18px;align-items:flex-start;justify-content:space-between;margin-top:22px}
h1{font-size:clamp(22px,3vw,30px);line-height:1.15;margin:0;letter-spacing:-.025em;font-weight:800}
.row{display:flex;align-items:center;gap:12px;margin-top:14px;flex-wrap:wrap;color:var(--mute);font-size:14px}
.av{width:38px;height:38px;border-radius:50%;background:var(--grad);display:grid;place-items:center;font-weight:800;color:#fff}
.who b{color:var(--text);display:block;font-size:15px}
.chip{display:inline-flex;align-items:center;gap:6px;padding:6px 12px;border-radius:999px;background:#ffffff0d;border:1px solid var(--line);font-weight:600;font-size:13px;color:var(--text)}
.chip svg{width:15px;height:15px;opacity:.75}
.acts{display:flex;gap:10px;flex-wrap:wrap}
footer{margin-top:48px;text-align:center;color:var(--dim);font-size:13px}
@media(max-width:640px){main{padding:0 0 40px}.stage{border-radius:0;max-height:none}.info{padding:0 16px}.acts{width:100%}.acts .btn{flex:1}footer{padding:0 16px}}
</style></head><body>
<nav><a class="logo" href="/"><i></i><span>Simplex <b>Clips</b></span></a>
<button class="btn" id="copyTop"><span class="i-link"></span>Link kopieren</button></nav>
<main>
<div class="stage"><video id="v" src="{{URL}}" controls autoplay playsinline preload="auto" {{POSTER}}></video></div>
<div class="info">
 <div style="min-width:0;flex:1 1 420px">
  <h1>{{NAME}}</h1>
  <div class="row">
   <div class="av">{{INITIAL}}</div><div class="who"><b>{{MAC}}</b><span id="when"></span></div>
   <span class="chip">🎮 {{GAME}}</span>
   <span class="chip"><span class="i-eye"></span>{{VIEWS}} Aufrufe</span>
   <span class="chip">⏱ {{DURATION_TEXT}}</span>
  </div>
 </div>
 <div class="acts">
  <button class="btn primary" id="copy"><span class="i-link"></span>Link kopieren</button>
  <a class="btn" href="{{URL}}?dl=1"><span class="i-dl"></span>Herunterladen</a>
 </div>
</div>
<footer>Aufgenommen mit Simplex Suite · Instant Replay für den Mac</footer>
</main>
<div class="toast" id="toast"></div>
<script>''' + ICONS_JS + r'''
document.querySelectorAll('[class^="i-"]').forEach(e=>{e.outerHTML=I[e.className.slice(2)]});
document.getElementById('when').textContent=ago({{CREATED}});
const share=location.href.split('?')[0];
document.getElementById('copy').onclick=()=>copy(share);
document.getElementById('copyTop').onclick=()=>copy(share);
const v=document.getElementById('v');v.volume=.8;
v.play().catch(()=>{v.muted=true;v.play().catch(()=>{})});
</script></body></html>'''

WEB_APP_HTML = r'''<!doctype html><html lang="de"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>Simplex Clips</title>
<link rel="icon" href="/icon.svg"><link rel="manifest" href="/manifest.json">
<meta name="theme-color" content="#07070b"><meta name="apple-mobile-web-app-capable" content="yes">
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap" rel="stylesheet">
<style>''' + BASE_CSS + r'''
body{min-height:100vh;overflow-x:hidden}
.glow{position:fixed;inset:0;pointer-events:none;z-index:0;background:radial-gradient(900px 520px at 8% -8%,#7c5cff26,transparent 60%),radial-gradient(800px 480px at 105% 10%,#ff4d8d18,transparent 60%)}
/* login */
#login{position:relative;z-index:1;min-height:100vh;display:grid;place-items:center;padding:24px}
.lcard{width:min(420px,100%);background:#0f0f17cc;border:1px solid var(--line);border-radius:24px;padding:34px 30px;backdrop-filter:blur(30px);-webkit-backdrop-filter:blur(30px);box-shadow:0 40px 120px #000c}
.lcard h1{font-size:28px;letter-spacing:-.03em;margin:26px 0 6px}.lcard p{color:var(--mute);margin:0 0 22px;font-size:15px;line-height:1.5}
.field{width:100%;height:48px;border-radius:14px;background:#0a0a10;border:1px solid var(--line2);color:var(--text);padding:0 16px;font:inherit;font-size:15px;outline:none;transition:border-color .2s,box-shadow .2s}
.field:focus{border-color:#7c5cffaa;box-shadow:0 0 0 4px #7c5cff26}
.lcard .btn{width:100%;height:48px;margin-top:12px;font-size:15px}
.err{color:#ff8e99;font-size:14px;min-height:20px;margin-top:10px}
/* shell */
#app{position:relative;z-index:1}
header.top{position:sticky;top:0;z-index:20;display:flex;align-items:center;gap:14px;height:68px;padding:0 max(22px,env(safe-area-inset-left));
background:#07070bcc;backdrop-filter:blur(22px) saturate(1.4);-webkit-backdrop-filter:blur(22px) saturate(1.4);border-bottom:1px solid var(--line)}
.search{flex:1;max-width:560px;margin:0 auto;position:relative}
.search svg{position:absolute;left:14px;top:50%;width:18px;height:18px;transform:translateY(-50%);color:var(--dim)}
.search input{width:100%;height:42px;border-radius:12px;background:#ffffff0a;border:1px solid var(--line);color:var(--text);padding:0 14px 0 42px;font:inherit;font-size:14px;outline:none;transition:.2s}
.search input:focus{background:#ffffff10;border-color:#7c5cff88}
.layout{display:grid;grid-template-columns:250px 1fr;min-height:calc(100vh - 68px)}
aside{position:sticky;top:68px;height:calc(100vh - 68px);overflow:auto;padding:22px 14px;border-right:1px solid var(--line);display:flex;flex-direction:column;gap:4px}
aside h4{font-size:11px;text-transform:uppercase;letter-spacing:.12em;color:var(--dim);margin:14px 12px 6px;font-weight:700}
.nav{display:flex;align-items:center;gap:10px;height:40px;padding:0 12px;border-radius:11px;color:var(--mute);font-weight:600;font-size:14px;text-align:left;width:100%;transition:.15s}
.nav:hover{background:#ffffff08;color:var(--text)}
.nav.on{background:#7c5cff1f;color:#fff}
.nav .n{margin-left:auto;font-size:12px;color:var(--dim);font-weight:600}
.nav .dot{width:8px;height:8px;border-radius:50%;background:var(--grad);flex:none}
.stor{margin-top:auto;padding:16px;border-radius:16px;background:var(--card);border:1px solid var(--line)}
.stor b{font-size:13px}.stor small{display:block;color:var(--mute);font-size:12px;margin-top:8px}
.bar{height:7px;border-radius:9px;background:#ffffff10;overflow:hidden;margin-top:10px}.bar i{display:block;height:100%;background:var(--grad);border-radius:9px;transition:width .6s}
main{padding:26px clamp(16px,3vw,40px) 120px;min-width:0}
.chips{display:none;gap:8px;overflow-x:auto;padding-bottom:6px;margin-bottom:14px;scrollbar-width:none}.chips::-webkit-scrollbar{display:none}
.chip{flex:none;height:36px;padding:0 14px;border-radius:999px;background:#ffffff0a;border:1px solid var(--line);font-weight:600;font-size:13px;color:var(--mute)}
.chip.on{background:#fff;color:#000;border-color:#fff}
/* hero */
.hero{display:grid;grid-template-columns:minmax(0,1.6fr) minmax(0,1fr);gap:26px;align-items:center;padding:18px;border-radius:26px;margin-bottom:34px;
background:linear-gradient(135deg,#15152166,#0d0d1466);border:1px solid var(--line);position:relative;overflow:hidden;cursor:pointer}
.hero:before{content:"";position:absolute;inset:0;background:var(--bgimg) center/cover;filter:blur(60px) saturate(1.6);opacity:.35;z-index:-1;transform:scale(1.2)}
.hero .th{border-radius:18px}
.hero h2{font-size:clamp(22px,2.6vw,34px);letter-spacing:-.03em;margin:10px 0 10px;line-height:1.1}
.tag{display:inline-flex;align-items:center;gap:6px;font-size:12px;font-weight:700;text-transform:uppercase;letter-spacing:.1em;color:#c9bcff}
.tag:before{content:"";width:7px;height:7px;border-radius:50%;background:var(--a2);box-shadow:0 0 12px var(--a2)}
.meta{color:var(--mute);font-size:14px;display:flex;gap:8px;flex-wrap:wrap;align-items:center}
.hero .acts{display:flex;gap:10px;margin-top:22px;flex-wrap:wrap}
/* toolbar + grid */
.tb{display:flex;align-items:center;gap:12px;margin-bottom:16px;flex-wrap:wrap}
.tb h3{font-size:22px;margin:0;letter-spacing:-.02em}.tb .cnt{color:var(--dim);font-weight:600}
.tb .sp{flex:1}
select.field{height:40px;width:auto;padding:0 12px;font-size:14px;border-radius:12px;background:#ffffff0a}
.day{font-size:14px;font-weight:700;color:var(--mute);margin:26px 2px 12px;display:flex;align-items:center;gap:10px}.day:after{content:"";flex:1;height:1px;background:var(--line)}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(min(270px,100%),1fr));gap:22px 18px}.grid>*,.hero>*{min-width:0}
.card{position:relative;cursor:pointer;border-radius:16px;outline:none}
.th{position:relative;aspect-ratio:16/9;border-radius:14px;overflow:hidden;background:#12121b;box-shadow:0 0 0 1px var(--line);transition:transform .25s cubic-bezier(.2,.8,.2,1),box-shadow .25s}
.th img,.th video{position:absolute;inset:0;width:100%;height:100%;object-fit:cover;display:block}
.th img{transition:opacity .3s}.th img[data-l]{opacity:0}
.th .ph{position:absolute;inset:0;display:grid;place-items:center;color:var(--dim);background:linear-gradient(135deg,#191926,#101018)}
.th .ph svg{width:34px;height:34px}
.th:after{content:"";position:absolute;inset:0;background:linear-gradient(transparent 55%,#000a);pointer-events:none}
.badge{position:absolute;right:9px;bottom:9px;z-index:2;font-size:12px;font-weight:700;padding:3px 8px;border-radius:8px;background:#000b;backdrop-filter:blur(8px);font-variant-numeric:tabular-nums}
.pl{position:absolute;inset:0;margin:auto;z-index:2;width:54px;height:54px;border-radius:50%;background:#ffffff26;backdrop-filter:blur(10px);display:grid;place-items:center;opacity:0;transform:scale(.8);transition:.25s}
.pl svg{width:22px;height:22px;margin-left:3px}
.card:hover .th,.card:focus-visible .th{transform:translateY(-3px);box-shadow:0 0 0 2px #7c5cffaa,0 18px 40px #000a}
.card:hover .pl{opacity:1;transform:none}.card.vid .pl{opacity:0}
.ci{display:flex;gap:10px;padding:12px 2px 0}
.ci .t{font-weight:700;font-size:15px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;letter-spacing:-.01em}
.ci .m{color:var(--mute);font-size:13px;margin-top:4px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ck{position:absolute;left:10px;top:10px;z-index:3;width:26px;height:26px;border-radius:50%;border:2px solid #fff;background:#0006;display:none;place-items:center}
.ck svg{width:15px;height:15px;opacity:0}
.selm .ck{display:grid}.card.sel .ck{background:var(--a1);border-color:var(--a1)}.card.sel .ck svg{opacity:1}
.card.sel .th{box-shadow:0 0 0 3px var(--a1)}
.empty{text-align:center;padding:90px 20px;color:var(--mute)}.empty h3{color:var(--text);font-size:22px;margin:18px 0 8px}
.empty .big{width:84px;height:84px;border-radius:26px;margin:0 auto;background:var(--grad);display:grid;place-items:center;box-shadow:0 20px 60px #7c5cff55}
.empty .big svg{width:38px;height:38px}
.skel{aspect-ratio:16/9;border-radius:14px;background:linear-gradient(90deg,#12121b,#1a1a26,#12121b);background-size:200% 100%;animation:sk 1.2s infinite}
@keyframes sk{to{background-position:-200% 0}}
/* selection bar */
#selbar{position:fixed;left:50%;bottom:24px;z-index:30;transform:translate(-50%,120px);transition:.35s cubic-bezier(.2,.9,.3,1.1);display:flex;align-items:center;gap:10px;
padding:10px 10px 10px 20px;border-radius:18px;background:#181826f0;border:1px solid var(--line2);backdrop-filter:blur(20px);box-shadow:0 20px 60px #000c;font-weight:700}
#selbar.show{transform:translate(-50%,0)}
/* theater */
#th{position:fixed;inset:0;z-index:50;display:none;background:#000000f2;backdrop-filter:blur(30px);-webkit-backdrop-filter:blur(30px)}
#th.show{display:flex;animation:fi .25s}
@keyframes fi{from{opacity:0}}
.tw{display:grid;grid-template-columns:minmax(0,1fr) 360px;width:100%;height:100%}
.tv{position:relative;display:grid;place-items:center;padding:24px;min-width:0;min-height:0}
.tv video{max-width:100%;max-height:calc(100vh - 48px);width:100%;border-radius:14px;background:#000;box-shadow:0 30px 100px #000}
.nb{position:absolute;top:50%;transform:translateY(-50%);width:48px;height:48px;border-radius:50%;background:#ffffff14;border:1px solid var(--line2);display:grid;place-items:center;z-index:2;transition:.2s}
.nb:hover{background:#ffffff26}.nb svg{width:22px;height:22px}.nb.p{left:18px}.nb.n{right:18px}.nb[disabled]{opacity:0;pointer-events:none}
.tx{position:absolute;top:18px;left:18px;z-index:3}
.tp{border-left:1px solid var(--line);background:#0b0b11;padding:26px 24px;overflow:auto;display:flex;flex-direction:column;gap:18px}
.tp h2{margin:0;font-size:24px;letter-spacing:-.02em;line-height:1.2;outline:none;border-radius:8px;padding:2px 4px;margin:-2px -4px}
.tp h2:focus{background:#ffffff0d;box-shadow:0 0 0 2px #7c5cff88}
.kv{display:grid;grid-template-columns:auto 1fr;gap:10px 16px;font-size:14px;padding:16px;border-radius:16px;background:var(--card);border:1px solid var(--line)}
.kv span{color:var(--mute)}.kv b{font-weight:600;text-align:right;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.tp .acts{display:grid;grid-template-columns:1fr 1fr;gap:10px}.tp .acts .btn.w{grid-column:1/-1}
.lnk{display:flex;gap:8px}.lnk input{flex:1;min-width:0;height:40px;font-size:13px}
.hint{color:var(--dim);font-size:12px;line-height:1.5}
/* upload */
#drop{position:fixed;inset:0;z-index:60;display:none;place-items:center;background:#07070be6;backdrop-filter:blur(10px)}
#drop.show{display:grid}
#drop div{padding:60px 80px;border-radius:30px;border:2px dashed #7c5cffaa;text-align:center;font-size:22px;font-weight:800;background:#7c5cff14}
#ups{position:fixed;right:20px;bottom:20px;z-index:40;display:flex;flex-direction:column;gap:10px;width:min(340px,calc(100vw - 40px))}
.up{padding:14px 16px;border-radius:16px;background:#181826f2;border:1px solid var(--line2);backdrop-filter:blur(20px);box-shadow:0 20px 50px #000a;font-size:13px;font-weight:600}
.up .bar{margin-top:10px}
.modal{position:fixed;inset:0;z-index:70;display:none;place-items:center;background:#000a;padding:20px}
.modal.show{display:grid;animation:fi .2s}
.modal .box{width:min(400px,100%);background:#14141f;border:1px solid var(--line2);border-radius:22px;padding:26px;box-shadow:0 40px 100px #000}
.modal h3{margin:0 0 8px;font-size:20px}.modal p{color:var(--mute);margin:0 0 22px;line-height:1.5;font-size:14px}
.modal .row{display:flex;gap:10px;justify-content:flex-end}
@media(max-width:1000px){.layout{grid-template-columns:1fr}aside{display:none}.chips{display:flex}.hero{grid-template-columns:1fr;padding:12px;gap:16px}
 .tw{grid-template-columns:1fr;grid-template-rows:auto 1fr;overflow:auto}.tv{padding:0;padding-top:env(safe-area-inset-top)}.tv video{border-radius:0;max-height:70vh}
 .tp{border-left:0;border-top:1px solid var(--line)}.nb{display:none}.tx{top:calc(12px + env(safe-area-inset-top));left:12px}}
@media(max-width:640px){header.top{gap:10px;padding:0 14px;height:62px}.top .logo span,.top .hide-s{display:none}.grid{grid-template-columns:repeat(2,minmax(0,1fr));gap:16px 10px}
 .ci .t{font-size:13px}.ci .m{font-size:12px}.badge{font-size:11px;right:6px;bottom:6px}main{padding:18px 12px 120px}.hero h2{font-size:22px}}
@media(max-width:380px){.grid{grid-template-columns:1fr}}
@media(prefers-reduced-motion:reduce){*{transition:none!important;animation:none!important}}
</style></head><body><div class="glow"></div>

<section id="login" hidden>
 <form class="lcard" id="lf">
  <div class="logo"><i></i><span>Simplex <b>Clips</b></span></div>
  <h1>Willkommen zurück</h1>
  <p>Melde dich mit dem Server-Passwort an. Es steht in <code>simplex_relay.json</code> und in der Simplex Suite unter Einstellungen → Remote.</p>
  <input class="field" id="pw" type="password" placeholder="Server-Passwort" autocomplete="current-password" autofocus>
  <button class="btn primary" type="submit">Anmelden</button>
  <div class="err" id="lerr"></div>
 </form>
</section>

<section id="app" hidden>
 <header class="top">
  <a class="logo" href="/"><i></i><span>Simplex <b>Clips</b></span></a>
  <label class="search"><span class="i-search"></span><input id="q" type="search" placeholder="Clips, Spiele, Macs durchsuchen …"></label>
  <button class="btn primary" id="upb"><span class="i-up"></span><span class="hide-s">Hochladen</span></button>
  <button class="btn ic" id="logout" title="Abmelden"><span class="i-out"></span></button>
  <input type="file" id="file" accept="video/mp4,video/quicktime,video/*" multiple hidden>
 </header>
 <div class="layout">
  <aside>
   <h4>Bibliothek</h4>
   <div id="side"></div>
   <div class="stor"><b>Server-Speicher</b><div class="bar"><i id="sbar" style="width:0"></i></div><small id="stxt">–</small></div>
  </aside>
  <main id="main">
   <div class="chips" id="chips"></div>
   <div id="hero"></div>
   <div class="tb"><h3 id="ttl">Alle Clips</h3><span class="cnt" id="cnt"></span><span class="sp"></span>
    <select class="field" id="sort"><option value="new">Neueste zuerst</option><option value="old">Älteste zuerst</option><option value="views">Meiste Aufrufe</option><option value="long">Längste</option><option value="big">Größte</option></select>
    <button class="btn" id="selb"><span class="i-sel"></span><span class="hide-s">Auswählen</span></button>
   </div>
   <div id="list"></div>
  </main>
 </div>
 <div id="selbar"><span id="seln">0 ausgewählt</span><button class="btn" id="selall">Alle</button><button class="btn danger" id="seldel"><span class="i-trash"></span>Löschen</button><button class="btn ic" id="selx"><span class="i-x"></span></button></div>
</section>

<div id="th"><div class="tw">
 <div class="tv"><button class="btn ic tx" id="tclose" title="Schließen (Esc)"><span class="i-x"></span></button>
  <button class="nb p" id="tprev" title="Vorheriger (←)"><span class="i-l"></span></button>
  <video id="tvid" controls playsinline autoplay preload="auto"></video>
  <button class="nb n" id="tnext" title="Nächster (→)"><span class="i-r"></span></button></div>
 <div class="tp">
  <div><span class="tag" id="tgame"></span><h2 id="tname" contenteditable="true" spellcheck="false" title="Zum Umbenennen klicken"></h2><div class="meta" id="tmeta" style="margin-top:8px"></div></div>
  <div class="lnk"><input class="field" id="tlink" readonly><button class="btn primary" id="tcopy"><span class="i-link"></span>Kopieren</button></div>
  <div class="acts">
   <a class="btn" id="tdl"><span class="i-dl"></span>Download</a>
   <a class="btn" id="topen" target="_blank" rel="noopener"><span class="i-ext"></span>Seite öffnen</a>
   <button class="btn" id="tfull"><span class="i-full"></span>Vollbild</button>
   <button class="btn danger" id="tdel"><span class="i-trash"></span>Löschen</button>
  </div>
  <div class="kv" id="tkv"></div>
  <div class="hint">Tastatur: ← → wechseln · F Vollbild · Entf löschen · Esc schließen.<br>Gelöschte Clips verschwinden automatisch auch vom Mac und vom iPhone.</div>
 </div>
</div></div>

<div id="drop"><div>Videos hier ablegen zum Hochladen</div></div>
<div id="ups"></div>
<div class="modal" id="modal"><div class="box"><h3 id="mt"></h3><p id="mp"></p><div class="row"><button class="btn" id="mno">Abbrechen</button><button class="btn danger" id="myes">Löschen</button></div></div></div>
<div class="toast" id="toast"></div>

<script>''' + ICONS_JS + r'''
const $=s=>document.querySelector(s);
function icons(root){root.querySelectorAll('[class^="i-"]').forEach(e=>{e.outerHTML=I[e.className.slice(2)]})}
icons(document);
let KEY=localStorage.getItem('simplex.key')||'';
const S={clips:[],storage:{},game:'Alle',q:'',sort:localStorage.getItem('simplex.sort')||'new',sel:new Set(),selm:false,vis:[],cur:-1};
$('#sort').value=S.sort;

async function api(path,opt={}){
 opt.headers=Object.assign({'Authorization':'Bearer '+KEY},opt.headers||{});
 const r=await fetch(path,opt);
 if(r.status===401){logout();throw new Error('auth')}
 return r;
}
function showLogin(){$('#app').hidden=true;$('#login').hidden=false;setTimeout(()=>$('#pw').focus(),50)}
function logout(){KEY='';localStorage.removeItem('simplex.key');if(window.ES)ES.close();showLogin()}
$('#logout').onclick=logout;
$('#lf').onsubmit=async e=>{e.preventDefault();$('#lerr').textContent='';KEY=$('#pw').value.trim();
 const r=await fetch('/api/storage',{headers:{'Authorization':'Bearer '+KEY}});
 if(r.ok){localStorage.setItem('simplex.key',KEY);start()}else{$('#lerr').textContent='Falsches Passwort';KEY=''}};

async function load(){
 try{const r=await api('/api/clips');const j=await r.json();S.clips=j.clips||[];S.storage=j.storage||{};
  const ids=new Set(S.clips.map(c=>c.id));S.sel.forEach(id=>{if(!ids.has(id))S.sel.delete(id)});render()}catch(e){}
}
function start(){
 $('#login').hidden=true;$('#app').hidden=false;
 $('#list').innerHTML='<div class="grid">'+'<div class="skel"></div>'.repeat(8)+'</div>';
 load();
 if(window.EventSource){window.ES=new EventSource('/api/events?key='+encodeURIComponent(KEY));
  let t;ES.onmessage=ev=>{clearTimeout(t);t=setTimeout(()=>{load();try{const m=JSON.parse(ev.data);
   if(m.event==='deleted'&&S.cur>=0&&m.ids.includes(S.vis[S.cur]?.id))closeT()}catch(_){}} ,250)}}
 setInterval(load,60000);
}

function games(){const m={};S.clips.forEach(c=>{const g=c.game||'Ohne Spiel';m[g]=(m[g]||0)+1});return Object.entries(m).sort((a,b)=>b[1]-a[1])}
function visible(){
 const q=S.q.toLowerCase();
 let v=S.clips.filter(c=>(S.game==='Alle'||(c.game||'Ohne Spiel')===S.game)&&(!q||[c.name,c.game,c.mac].join(' ').toLowerCase().includes(q)));
 const f={new:(a,b)=>b.created-a.created,old:(a,b)=>a.created-b.created,views:(a,b)=>(b.views||0)-(a.views||0),long:(a,b)=>b.duration-a.duration,big:(a,b)=>b.size-a.size}[S.sort];
 return v.sort(f);
}
function dayLabel(ts){const d=new Date(ts*1000),n=new Date();const a=new Date(n.getFullYear(),n.getMonth(),n.getDate()),b=new Date(d.getFullYear(),d.getMonth(),d.getDate());
 const diff=Math.round((a-b)/864e5);if(diff===0)return 'Heute';if(diff===1)return 'Gestern';if(diff<7)return d.toLocaleDateString('de-DE',{weekday:'long'});
 return d.toLocaleDateString('de-DE',{day:'numeric',month:'long',year:d.getFullYear()===n.getFullYear()?undefined:'numeric'})}
function esc(s){return String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}
function thumb(c){return c.thumbUrl?`<img loading="lazy" decoding="async" data-l src="${esc(c.thumbUrl)}" onload="this.removeAttribute('data-l')" alt="">`:`<div class="ph">${I.play}</div>`}

function render(){
 const gs=games(),all=S.clips.length;
 $('#side').innerHTML=`<button class="nav ${S.game==='Alle'?'on':''}" data-g="Alle"><span class="dot"></span>Alle Clips<span class="n">${all}</span></button>`+
  gs.map(([g,n])=>`<button class="nav ${S.game===g?'on':''}" data-g="${esc(g)}">🎮 <span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esc(g)}</span><span class="n">${n}</span></button>`).join('');
 $('#chips').innerHTML=[['Alle',all],...gs].map(([g,n])=>`<button class="chip ${S.game===g?'on':''}" data-g="${esc(g)}">${esc(g)} · ${n}</button>`).join('');
 document.querySelectorAll('[data-g]').forEach(b=>b.onclick=()=>{S.game=b.dataset.g;render();scrollTo({top:0,behavior:'smooth'})});
 const st=S.storage,pct=st.limit?Math.min(100,st.used/st.limit*100):0;
 $('#sbar').style.width=Math.max(2,pct)+'%';$('#stxt').textContent=`${bytes(st.used)} von ${bytes(st.limit)} · ${st.count||0} Clips`;
 S.vis=visible();
 $('#ttl').textContent=S.game==='Alle'?'Alle Clips':S.game;$('#cnt').textContent=S.vis.length+' Clips · '+bytes(S.vis.reduce((a,c)=>a+c.size,0));
 // hero: newest clip
 const h=!S.q&&S.sort==='new'&&S.vis[0];
 if(h){$('#hero').innerHTML=`<div class="hero" style="--bgimg:url('${esc(h.thumbUrl||'')}')"><div class="th">${thumb(h)}<div class="pl" style="opacity:1;transform:none">${I.play}</div><span class="badge">${dur(h.duration)}</span></div>
  <div><span class="tag">Neuester Clip</span><h2>${esc(h.name)}</h2><div class="meta"><span>🎮 ${esc(h.game||'Clip')}</span>·<span>${ago(h.created)}</span>·<span>${h.views||0} Aufrufe</span></div>
  <div class="acts"><button class="btn primary" data-a="play">${I.play}Abspielen</button><button class="btn" data-a="copy">${I.link}Link kopieren</button></div></div></div>`;
  const he=$('#hero .hero');he.onclick=e=>{const a=e.target.closest('[data-a]');if(a&&a.dataset.a==='copy'){e.stopPropagation();copy(h.shareUrl);return}openT(0)}}
 else $('#hero').innerHTML='';
 const list=$('#list');
 if(!S.vis.length){list.innerHTML=`<div class="empty"><div class="big">${I.play}</div><h3>${all?'Keine Treffer':'Noch keine Clips'}</h3><p>${all?'Versuch einen anderen Suchbegriff.':'Speichere am Mac einen Clip – er landet automatisch hier. Oder zieh ein Video in dieses Fenster.'}</p></div>`;return}
 let html='',last='',open=false;const byDay=S.sort==='new'||S.sort==='old';
 S.vis.forEach((c,i)=>{if(h&&i===0)return;const d=byDay?dayLabel(c.created):'';
  if(d!==last||!open){if(open)html+='</div>';if(d)html+=`<div class="day">${d}</div>`;html+='<div class="grid">';open=true;last=d}
  html+=`<div class="card ${S.sel.has(c.id)?'sel':''}" tabindex="0" data-i="${i}"><div class="th">${thumb(c)}<div class="pl">${I.play}</div><span class="badge">${dur(c.duration)}</span><span class="ck">${I.check}</span></div>
  <div class="ci"><div style="min-width:0"><div class="t">${esc(c.name)}</div><div class="m">${esc(c.game||'Clip')} · ${ago(c.created)} · ${c.views||0} Aufrufe</div></div></div></div>`});
 if(open)html+='</div>';
 list.innerHTML=html;list.classList.toggle('selm',S.selm);
 list.querySelectorAll('.card').forEach(el=>{const i=+el.dataset.i,c=S.vis[i];
  el.onclick=()=>{if(S.selm){S.sel.has(c.id)?S.sel.delete(c.id):S.sel.add(c.id);el.classList.toggle('sel');selbar()}else openT(i)};
  el.onkeydown=e=>{if(e.key==='Enter')el.click()};
  let t;el.onmouseenter=()=>{if(matchMedia('(hover:none)').matches)return;t=setTimeout(()=>{const v=document.createElement('video');v.muted=true;v.loop=true;v.playsInline=true;v.src=c.url+'#t=0.1';
   v.oncanplay=()=>el.classList.add('vid');el.querySelector('.th').appendChild(v);v.play().catch(()=>{})},280)};
  el.onmouseleave=()=>{clearTimeout(t);el.classList.remove('vid');el.querySelectorAll('video').forEach(v=>{v.pause();v.removeAttribute('src');v.load();v.remove()})}});
}
$('#q').oninput=e=>{S.q=e.target.value;render()};
$('#sort').onchange=e=>{S.sort=e.target.value;localStorage.setItem('simplex.sort',S.sort);render()};

/* selection */
function selbar(){$('#seln').textContent=S.sel.size+' ausgewählt';$('#selbar').classList.toggle('show',S.selm)}
$('#selb').onclick=()=>{S.selm=!S.selm;S.sel.clear();render();selbar()};
$('#selx').onclick=()=>{S.selm=false;S.sel.clear();render();selbar()};
$('#selall').onclick=()=>{S.vis.forEach(c=>S.sel.add(c.id));render();selbar()};
$('#seldel').onclick=async()=>{if(!S.sel.size)return;if(!await ask(`${S.sel.size} Clips löschen?`,'Sie werden vom Server, vom Mac und vom iPhone entfernt. Links funktionieren danach nicht mehr.'))return;
 const ids=[...S.sel];await api('/api/clips/delete',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ids})});
 S.clips=S.clips.filter(c=>!ids.includes(c.id));S.sel.clear();S.selm=false;selbar();render();toast(ids.length+' Clips gelöscht');load()};

function ask(t,p){return new Promise(res=>{$('#mt').textContent=t;$('#mp').textContent=p;$('#modal').classList.add('show');
 const done=v=>{$('#modal').classList.remove('show');res(v)};$('#myes').onclick=()=>done(true);$('#mno').onclick=()=>done(false);$('#myes').focus()})}

/* theater */
function openT(i){S.cur=i;const c=S.vis[i];if(!c)return;const v=$('#tvid');
 v.poster=c.thumbUrl||'';v.src=c.url;v.play().catch(()=>{});
 $('#tgame').textContent=c.game||'Clip';$('#tname').textContent=c.name;
 $('#tmeta').innerHTML=`<span>${ago(c.created)}</span>·<span>${I.eye.replace('<svg','<svg style="width:15px;height:15px;vertical-align:-3px"')} ${c.views||0}</span>`;
 $('#tlink').value=c.shareUrl;$('#tdl').href=c.url+'?dl=1';$('#topen').href=c.shareUrl;
 $('#tkv').innerHTML=`<span>Länge</span><b>${dur(c.duration)}</b><span>Auflösung</span><b>${c.width}×${c.height}</b><span>Größe</span><b>${bytes(c.size)}</b><span>Aufgenommen</span><b>${new Date(c.created*1000).toLocaleString('de-DE',{dateStyle:'medium',timeStyle:'short'})}</b><span>Von</span><b>${esc(c.mac||'–')}</b>`;
 $('#tprev').disabled=i<=0;$('#tnext').disabled=i>=S.vis.length-1;
 if(!$('#th').classList.contains('show')){$('#th').classList.add('show');document.body.style.overflow='hidden';history.pushState({t:1},'')}
}
function closeT(fromPop){const v=$('#tvid');v.pause();v.removeAttribute('src');v.load();$('#th').classList.remove('show');document.body.style.overflow='';S.cur=-1;if(!fromPop&&history.state&&history.state.t)history.back()}
window.onpopstate=()=>{if($('#th').classList.contains('show'))closeT(true)};
$('#tclose').onclick=()=>closeT();$('#tprev').onclick=()=>openT(S.cur-1);$('#tnext').onclick=()=>openT(S.cur+1);
$('#tcopy').onclick=()=>copy($('#tlink').value);
$('#tfull').onclick=()=>{const v=$('#tvid');(v.requestFullscreen||v.webkitEnterFullscreen||v.webkitRequestFullscreen).call(v)};
$('#tdel').onclick=async()=>{const c=S.vis[S.cur];if(!c)return;if(!await ask('Clip löschen?',`„${c.name}“ wird vom Server, vom Mac und vom iPhone entfernt.`))return;
 await api('/api/clips/'+c.id,{method:'DELETE'});S.clips=S.clips.filter(x=>x.id!==c.id);const i=S.cur;render();toast('Clip gelöscht');
 if(S.vis.length)openT(Math.min(i,S.vis.length-1));else closeT()};
const tn=$('#tname');tn.onkeydown=e=>{if(e.key==='Enter'){e.preventDefault();tn.blur()}e.stopPropagation()};
tn.onblur=async()=>{const c=S.vis[S.cur];const n=tn.textContent.trim();if(!c||!n||n===c.name)return;c.name=n;
 await api('/api/clips/'+c.id,{method:'PATCH',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:n})});toast('Umbenannt');render()};
document.addEventListener('keydown',e=>{if(!$('#th').classList.contains('show')||e.target.isContentEditable||e.target.tagName==='INPUT')return;
 if(e.key==='Escape')closeT();else if(e.key==='ArrowLeft'&&S.cur>0)openT(S.cur-1);else if(e.key==='ArrowRight'&&S.cur<S.vis.length-1)openT(S.cur+1);
 else if(e.key==='f'||e.key==='F')$('#tfull').click();else if(e.key==='Delete'||e.key==='Backspace')$('#tdel').click()});
let sx=0;$('.tv').addEventListener('touchstart',e=>{sx=e.touches[0].clientX},{passive:true});
$('.tv').addEventListener('touchend',e=>{const d=e.changedTouches[0].clientX-sx;if(Math.abs(d)>70){if(d<0&&S.cur<S.vis.length-1)openT(S.cur+1);if(d>0&&S.cur>0)openT(S.cur-1)}},{passive:true});

/* upload from the browser */
$('#upb').onclick=()=>$('#file').click();
$('#file').onchange=e=>{[...e.target.files].forEach(uploadFile);e.target.value=''};
let dc=0;addEventListener('dragenter',e=>{if(!KEY||!e.dataTransfer.types.includes('Files'))return;dc++;$('#drop').classList.add('show')});
addEventListener('dragleave',()=>{if(--dc<=0){dc=0;$('#drop').classList.remove('show')}});
addEventListener('dragover',e=>e.preventDefault());
addEventListener('drop',e=>{e.preventDefault();dc=0;$('#drop').classList.remove('show');[...e.dataTransfer.files].filter(f=>f.type.startsWith('video')).forEach(uploadFile)});
function meta(file){return new Promise(res=>{const v=document.createElement('video');v.muted=true;v.preload='auto';v.src=URL.createObjectURL(file);
 const fin=b=>{URL.revokeObjectURL(v.src);res(b)};
 v.onloadedmetadata=()=>{v.currentTime=Math.min(1,(v.duration||2)/2)};
 v.onseeked=()=>{const c=document.createElement('canvas'),s=Math.min(1,1280/v.videoWidth);c.width=v.videoWidth*s;c.height=v.videoHeight*s;
  c.getContext('2d').drawImage(v,0,0,c.width,c.height);c.toBlob(b=>fin({d:v.duration,w:v.videoWidth,h:v.videoHeight,thumb:b}),'image/jpeg',.82)};
 v.onerror=()=>fin({d:0,w:1920,h:1080,thumb:null})})}
async function uploadFile(file){
 const box=document.createElement('div');box.className='up';box.innerHTML=`<div>${esc(file.name)}</div><div class="bar"><i style="width:2%"></i></div>`;$('#ups').appendChild(box);
 const m=await meta(file);const enc=encodeURIComponent;
 const x=new XMLHttpRequest();x.open('POST','/api/clips');
 x.setRequestHeader('Authorization','Bearer '+KEY);x.setRequestHeader('Content-Type','video/mp4');
 x.setRequestHeader('X-Clip-Name',enc(file.name.replace(/\.[^.]+$/,'')));x.setRequestHeader('X-Clip-Game',enc('Upload'));x.setRequestHeader('X-Clip-Mac',enc('Browser'));
 x.setRequestHeader('X-Clip-Duration',String(m.d||0));x.setRequestHeader('X-Clip-Width',String(m.w));x.setRequestHeader('X-Clip-Height',String(m.h));
 x.setRequestHeader('X-Clip-Created',String((file.lastModified||Date.now())/1000));
 x.upload.onprogress=e=>{if(e.lengthComputable)box.querySelector('i').style.width=(e.loaded/e.total*100)+'%'};
 x.onload=async()=>{let j={};try{j=JSON.parse(x.responseText)}catch(_){}
  if(x.status===201){if(m.thumb&&!j.duplicate)await api('/api/clips/'+j.id+'/thumb',{method:'POST',headers:{'Content-Type':'image/jpeg'},body:m.thumb});
   box.firstChild.textContent='✓ '+file.name;setTimeout(()=>box.remove(),2500);load()}
  else{box.firstChild.textContent='✕ '+(j.error||'Fehler '+x.status);setTimeout(()=>box.remove(),6000)}};
 x.onerror=()=>{box.firstChild.textContent='✕ Verbindung abgebrochen';setTimeout(()=>box.remove(),6000)};
 x.send(file);
}

if(KEY)fetch('/api/storage',{headers:{'Authorization':'Bearer '+KEY}}).then(r=>r.ok?start():logout()).catch(()=>start());else showLogin();
</script></body></html>'''


if __name__ == "__main__":
    main()
