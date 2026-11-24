# 🎬 Simplex Recorder

**Replay-Recorder für macOS, ähnlich wie Medal unter Windows.**
Die App läuft unauffällig in der Menüleiste und nimmt im Hintergrund auf, sobald ein Spiel läuft (z. B. **Minecraft Java Edition**). Ein Tastendruck speichert die **letzten 30 Sekunden** als Clip.

## Funktionen

| | |
|---|---|
| 🎮 **Automatische Spielerkennung** | Minecraft Java (auch über Prism, Lunar, CurseForge …), Steam- und Epic-Spiele, Apps der Kategorie „Spiele“, bekannte Engines. Eigene Regeln: „Immer aufnehmen“ oder „Nie aufnehmen“ |
| ⌨️ **Globale Tastenkürzel** | Standard: **⌥⇧S** = Clip speichern, **⌥⇧P** = Pause. Frei belegbar, auch F-Tasten. Funktionieren auch im Vollbild |
| ⚡️ **Effizient** | ScreenCaptureKit + Hardware-Encoder (HEVC/H.264). Der Puffer liegt im RAM, die SSD wird nicht dauerhaft beschrieben. Ohne laufendes Spiel wird nichts aufgenommen |
| 💾 **Speicherort frei wählbar** | z. B. die externe Festplatte, mit Speicheranzeige (Clips / andere Daten / frei). Optional automatisches Aufräumen alter Clips |
| 🔁 **Bleibt aktiv** | Autostart beim Anmelden. Nach einem Absturz oder „Sofort beenden“ startet launchd die App automatisch neu. Über „Beenden“ im Menü bleibt sie aus |
| ⏸ **Ruhemodus** | Pausieren für 15 Min., 1 Std., 3 Std. oder unbegrenzt |
| 🔊 **Audio** | Spiel- und Systemton, optional Mikrofon (ab macOS 15) |
| 🎞 **Clip-Galerie** | Vorschaubilder, Filter nach Spiel, Drag & Drop in Discord, Kopieren, Papierkorb |
| ⚙️ **Viele Einstellungen** | Clip-Länge (10 s bis 5 min), 30/60/120 FPS, Auflösung, Codec, Bitrate, Aufnahmebereich, Mauszeiger, Sounds, Mitteilungen |

## Installation

1. Lade die neueste Version herunter:
   - Unter **Actions** → letzter erfolgreicher Lauf „Build macOS App“ → Artefakt `SimplexRecorder-…` (enthält `.dmg` und `.zip`), **oder**
   - unter **Releases**, sobald ein Tag `v1.0.0` existiert.
2. DMG öffnen und **Simplex Recorder** in den Ordner **Programme** ziehen.
3. Die App ist nicht von Apple notarisiert. Beim ersten Start: **Rechtsklick → Öffnen**, oder im Terminal:
   ```bash
   xattr -dr com.apple.quarantine "/Applications/Simplex Recorder.app"
   ```
4. Der Einrichtungsassistent führt durch die Bildschirmaufnahme-Erlaubnis, den Speicherort und den Autostart.

> **Hinweis:** Weil die App nur ad-hoc signiert ist, fragt macOS nach einem **Update** (neuer Build) eventuell erneut nach der Bildschirmaufnahme-Erlaubnis. In diesem Fall den alten Eintrag unter *Systemeinstellungen › Datenschutz & Sicherheit › Bildschirm- & Systemaudioaufnahme* entfernen und neu erlauben.

## Selbst bauen

Benötigt einen Mac mit Xcode 16 oder neuer:

```bash
./scripts/build_app.sh      # → dist/Simplex Recorder.app, .zip, .dmg
```

Jeder Push baut automatisch über GitHub Actions (`.github/workflows/build.yml`). Ein Tag wie `v1.0.0` erzeugt zusätzlich ein GitHub-Release:

```bash
git tag v1.0.0 && git push origin v1.0.0
```

## So funktioniert es

- **GameDetector**: prüft alle 3 Sekunden die Fensterliste (sehr günstig) und reagiert zusätzlich sofort auf App-Start und App-Wechsel.
- **ReplayEngine**: ScreenCaptureKit → VideoToolbox-Hardware-Encoder → Ringpuffer im RAM (1 Keyframe pro Sekunde).
- **ClipExporter**: Video wird ohne Neukodierung in eine `.mp4` kopiert und ist damit sofort fertig. Audio wird zu AAC kodiert.
- **LaunchAgent** (`~/Library/LaunchAgents/com.simplex.recorder.agent.plist`): `RunAtLoad` für den Autostart, `KeepAlive.SuccessfulExit = false` für den Neustart nach einem Absturz oder Zwangsbeenden.

### Komplett entfernen

```bash
launchctl bootout gui/$(id -u)/com.simplex.recorder.agent
rm ~/Library/LaunchAgents/com.simplex.recorder.agent.plist
rm -rf "/Applications/Simplex Recorder.app"
defaults delete com.simplex.recorder
```

Systemvoraussetzung: **macOS 14 Sonoma oder neuer** (Apple Silicon & Intel).
