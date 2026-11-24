# 🧰 Simplex Suite

**Die Werkzeugkiste für deinen Mac: Replay-Recorder wie Medal, Taskmanager, Aufräumen & Deinstallieren, App-Starter, Windows-Tastatur, Fenster-Assistent und Dock-Vorschauen.**

(Früher „Simplex Recorder“. Einstellungen werden übernommen.)
Die App läuft unauffällig in der Menüleiste und nimmt im Hintergrund auf, sobald ein Spiel läuft (z. B. **Minecraft Java Edition**). Ein Tastendruck speichert die **letzten 30 Sekunden** als Clip.

## Suite-Werkzeuge

| | |
|---|---|
| 🧰 **Dashboard in der Menüleiste** | Werkzeug-Symbol, ein Klick zeigt CPU, Temperatur, RAM und freien Speicher als Anzeigen, die Clip-Steuerung, Schnellzugriffe und alle aktiven Apps mit Verbrauch. Einzelne Apps beenden oder **alle auf einmal** |
| 📊 **Taskmanager** | Sortierbare Tabelle (CPU, Speicher, Prozesse), Verlaufskurven, Hintergrundprozesse, Beenden und Sofort-Beenden |
| 🗑 **Aufräumen & Deinstallieren** | Programme **restlos** entfernen (Einstellungen, Caches, Container, Startobjekte; Apple-Apps sind geschützt), **große Dateien** finden, Caches, Logs, Xcode-Daten, Papierkorb und alte Installer sicher löschen |
| 🔎 **App-Starter** | **Windows-Taste antippen** öffnet ein Startmenü mit allen Apps und Suche |
| ⌨️ **Windows-Tastatur** | **Strg+C/V/X/A/Z/Y/S/F …** wirken wie ⌘, dazu Pos1/Ende und Strg+Pfeiltasten. Ausgenommen sind Terminals, VMs und Spiele |
| ❌ **Rotes X beendet** | Wird das letzte Fenster geschlossen, beendet sich die App ganz (mit Ausnahmen, z. B. Musik) |
| 🪟 **Dock-Vorschau** | Fenster-Miniaturen beim Darüberfahren im Dock, Klick holt das Fenster nach vorne |
| 🪄 **Fenster-Assistent** | Fenster an den Rand ziehen, um sie einzurasten. Wahlweise nur für Spiele oder für alle Programme |

Systemzugriff: **Bildschirmaufnahme** (Clips, Dock-Vorschau) und **Bedienungshilfen** (Tastatur, Fenster, rotes X, Dock).

## Clip-Funktionen

| | |
|---|---|
| 🎮 **Automatische Spielerkennung** | Minecraft Java (auch über Prism, Lunar, CurseForge …), Steam- und Epic-Spiele, Apps der Kategorie „Spiele“, bekannte Engines. Eigene Regeln: „Immer aufnehmen“ oder „Nie aufnehmen“ |
| 🪟 **Nur das Spielfenster** | Standard-Modus: Nur das Spielfenster wird aufgenommen, egal wo es liegt oder was darüber ist. Die Titelleiste wird weggeschnitten, Vollbild und Größenänderung laufen ohne Unterbrechung |
| ⌨️ **Globale Tastenkürzel** | **⌥⇧S** = Clip, **⌥⇧L** = langer Clip (z. B. 2 min), **⌥⇧X** = Screenshot, **⌥⇧P** = Pause. Frei belegbar und auch im Vollbild nutzbar |
| 🪄 **Fenster-Assistent** | Spielfenster an den oberen Rand ziehen: Es füllt den Bildschirm, Menüleiste und Dock bleiben sichtbar. Linker/rechter Rand ergibt eine Bildschirmhälfte, **⌥⇧F** passt ein bzw. stellt wieder her. Braucht die Bedienungshilfen-Berechtigung |
| 🎬 **Start-Animation** | Einblendung „Clipping aktiv“, sobald ein Spiel erkannt wurde |
| 🎯 **Ein-/Ausschließen** | Aktuelles Programm direkt im Menüleisten-Menü als Spiel markieren oder ausschließen. Auf der Spiele-Seite: Suche, Umschalter und „Programm hinzufügen“ |
| ✨ **Einblendung im Spiel** | Kleine Einblendung „Clip gespeichert“ über dem Spiel, die selbst nicht aufgenommen wird |
| 🎚 **Qualitäts-Voreinstellungen** | Sparsam · Ausgewogen · Maximal · Butterweich (120 FPS) |
| 📋 **Komfort** | Clip automatisch in die Zwischenablage (für Discord), im Finder zeigen, Puffer-Timer in der Menüleiste |
| ⚡️ **Effizient** | ScreenCaptureKit + Hardware-Encoder (HEVC/H.264). Der Puffer liegt im RAM, die SSD wird nicht dauerhaft beschrieben. Ohne laufendes Spiel wird nichts aufgenommen |
| 💾 **Speicherort frei wählbar** | z. B. die externe Festplatte, mit Speicheranzeige (Clips / andere Daten / frei). Optional automatisches Aufräumen alter Clips |
| 🔁 **Bleibt aktiv** | Autostart beim Anmelden. Egal ob ⌘Q, „Sofort beenden“ oder Absturz: launchd startet die App nach wenigen Sekunden neu. Nur „Simplex Recorder beenden“ im eigenen Menü stoppt sie bis zur nächsten Anmeldung |
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
- **ClipExporter**: Jede Spur wird parallel geschrieben. Video wird ohne Neukodierung in eine `.mp4` kopiert und ist damit sofort fertig. Audio wird zu AAC kodiert.
- **LaunchAgent** (`~/Library/LaunchAgents/com.simplex.recorder.agent.plist`): `RunAtLoad` für den Autostart, `KeepAlive = true` für den Neustart nach jedem Beenden. Protokoll: `~/Library/Logs/SimplexRecorder/agent.log`.

### Komplett entfernen

```bash
launchctl bootout gui/$(id -u)/com.simplex.recorder.agent
rm ~/Library/LaunchAgents/com.simplex.recorder.agent.plist
rm -rf "/Applications/Simplex Recorder.app"
defaults delete com.simplex.recorder
```

Systemvoraussetzung: **macOS 14 Sonoma oder neuer** (Apple Silicon & Intel).
