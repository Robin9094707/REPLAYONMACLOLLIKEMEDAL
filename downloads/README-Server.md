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
   Simplex Relay 1.2.0
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
        client_max_body_size 2G;      # Clip-Uploads
        proxy_request_buffering off;  # große Uploads direkt durchreichen
    }
    # + Let's-Encrypt-Zertifikat (certbot --nginx)
}
```

Mit Caddy reicht: `remote.deine-domain.de { reverse_proxy 127.0.0.1:8765 }`

**B) Direkt im Server:** In `simplex_relay.json` `tls_cert` und `tls_key` auf die Zertifikatsdateien setzen (z. B. `/etc/letsencrypt/live/<domain>/fullchain.pem` und `privkey.pem`).

## Web-Galerie (neu in 1.2)

Unter `https://remote.deine-domain.de/` läuft jetzt **Simplex Clips** – eine Web-App im Stil von Medal:

- Anmelden mit dem Server-Passwort, danach alle Clips mit Vorschau beim Drüberfahren, Filter nach Spiel, Suche, Sortierung und Tages-Abschnitten.
- **Theater-Ansicht** mit großem Player, Vollbild, ←/→ zum Wechseln, Umbenennen per Klick, Link kopieren, Download.
- **Hochladen per Drag & Drop** direkt im Browser, Mehrfachauswahl zum Löschen.
- **Live:** Neue oder gelöschte Clips erscheinen sofort (Server-Sent Events), ohne Neuladen.
- **Überall gelöscht:** Löschst du einen Clip in der Web-App, am iPhone oder am Mac, verschwindet er überall – die Mac-App legt ihn in den Papierkorb. Der Server merkt sich gelöschte IDs 180 Tage (`clips/deleted.json`), ein neu aufgesetzter Server löscht also nie etwas auf dem Mac.
- **Schneller Upload:** Gleiche Dateien erkennt der Server am SHA-256 und speichert sie nie doppelt, große Uploads werden in 1-MB-Blöcken direkt auf die Platte gestreamt.

Die alte Statusseite liegt jetzt unter `/status`.

## Clips teilen

Die Mac-App kann Clips optional auf diesen Server hochladen. Jeder Clip bekommt einen Link wie `https://remote.deine-domain.de/c/Ab3xYz9KpQ`:

- **Im Browser** spielt der Link sofort ab, ohne Anmeldung, mit Vorspulen und Download.
- **Discord, WhatsApp, Telegram, iMessage** zeigen automatisch eine Vorschau, Discord spielt das Video direkt im Chat ab.
- **Verwalten:** In der iPhone-App unter **Clips** siehst du alle Clips mit Speicherverbrauch, kannst sie ansehen, teilen und löschen.

Einstellungen in `simplex_relay.json`:

| Schlüssel | Bedeutung |
|---|---|
| `clips_enabled` | `true` / `false`: Uploads erlauben |
| `max_storage_gb` | Maximaler Speicher für Clips (Standard 20) |
| `public_url` | Basis für Links, z. B. `https://remote.deine-domain.de`. Leer = automatisch aus der Anfrage |

Die Clips liegen im Ordner `clips/` neben `relay.py`. Im Reverse Proxy das Upload-Limit erhöhen, bei nginx z. B. `client_max_body_size 2G;`.
Geteilte Clips sind **nicht** Ende-zu-Ende verschlüsselt: Wer den Link kennt, kann sie ansehen.

## Verbinden

1. **Mac:** Simplex Suite → Einstellungen → **Remote** → Server-Adresse `https://remote.deine-domain.de` und Passwort eintragen → „Speichern & verbinden“.
2. **iPhone:** Simplex Remote → **+** → QR-Code vom Mac scannen. Fertig.

Im Browser zeigt `https://remote.deine-domain.de/` die Web-Galerie, `…/status` den Serverstatus, `…/health` antwortet mit `ok`.
