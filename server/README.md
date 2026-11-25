# 🛰 Simplex Relay – Server für den Remote-Zugang

Verbindet **Simplex Suite (Mac)** und **Simplex Remote (iPhone)** von überall. Der Server leitet nur weiter: Bildschirm, Eingaben, Zwischenablage und Passwörter sind **Ende-zu-Ende verschlüsselt** (AES-GCM, der Schlüssel steckt nur im QR-Code). Der Server kann nichts davon lesen.

## Dateien

| Datei | Zweck |
|---|---|
| `relay.py` | Der Server (Python 3.9+) |
| `requirements.txt` | Einzige Abhängigkeit: `aiohttp` |
| `simplex_relay.json` | Wird beim ersten Start erzeugt: **Passwort**, Port, optional TLS |

## Mit CubeCoders AMP („Python App Runner“)

1. Neue Instanz anlegen: **Generic → Python App Runner** (bzw. „Python Application“).
2. `relay.py` und `requirements.txt` in das App-Verzeichnis der Instanz hochladen.
3. In den Instanz-Einstellungen eintragen:
   - **Startdatei:** `relay.py`
   - **Requirements installieren:** aktivieren (`requirements.txt`)
   - **Port:** z. B. `8765`. Der Server liest auch die Umgebungsvariable `PORT`.
4. Instanz starten. In der Konsole steht:
   ```
   Simplex Relay 1.0.0
   Adresse:   http://0.0.0.0:8765   (WebSocket: /ws)
   Passwort:  Xy7…
   ```
5. **Passwort ändern:** `simplex_relay.json` bearbeiten. Das neue Passwort gilt sofort ohne Neustart. Danach Mac-App und iPhone mit dem neuen Passwort neu koppeln.

## HTTPS mit eigener Domain

Die Apps verbinden sich per `wss://deine-domain/ws`. Zwei Wege:

**A) Reverse Proxy (empfohlen)**, z. B. das nginx von AMP, Caddy oder Nginx Proxy Manager:

```nginx
server {
    server_name remote.deine-domain.de;
    location / {
        proxy_pass http://127.0.0.1:8765;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_read_timeout 3600s;
    }
    # + Let's-Encrypt-Zertifikat (certbot --nginx)
}
```

Mit Caddy reicht: `remote.deine-domain.de { reverse_proxy 127.0.0.1:8765 }`

**B) Direkt im Server:** In `simplex_relay.json` `tls_cert` und `tls_key` auf die Zertifikatsdateien setzen (z. B. `/etc/letsencrypt/live/<domain>/fullchain.pem` und `privkey.pem`).

## Verbinden

1. **Mac:** Simplex Suite → Einstellungen → **Remote** → Server-Adresse `https://remote.deine-domain.de` und Passwort eintragen → „Speichern & verbinden“.
2. **iPhone:** Simplex Remote → **+** → QR-Code vom Mac scannen. Fertig.

Im Browser zeigt `https://remote.deine-domain.de/` eine Statusseite, `…/health` antwortet mit `ok`.
