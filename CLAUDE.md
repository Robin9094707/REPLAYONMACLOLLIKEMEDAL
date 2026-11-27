# Simplex Suite – Projektübersicht für Claude

Der Nutzer spricht **Deutsch**; alle UI-Texte sind Deutsch. Builds laufen ausschließlich über **GitHub Actions** (kein Mac in der Sitzung) – Fehler werden über die CI-Logs gefunden (`gh api repos/robin9094707/replayonmaclollikemedal/actions/...`).

## Bestandteile

| Teil | Pfad | Technik |
|---|---|---|
| **Simplex Suite** (macOS-Menüleisten-App, ehem. „Simplex Recorder“) | `Sources/SimplexRecorder/` | Swift 5-Modus, SwiftPM, macOS 14+, Bundle-ID `com.simplex.recorder` (bleibt so, damit Einstellungen erhalten bleiben) |
| Virtueller Bildschirm (ObjC-Brücke) | `Sources/VirtualDisplayBridge/` | private `CGVirtualDisplay`-Klassen, per `NSClassFromString` geladen |
| **Simplex Remote** (iOS-App) | `iOS/SimplexRemote/`, `iOS/project.yml` | SwiftUI, iOS 17+, XcodeGen, Liquid Glass via `#if compiler(>=6.2)` + `glassEffect` |
| **Relay-Server** | `server/relay.py` | Python 3 + aiohttp, für CubeCoders AMP („Python App Runner“) |
| Fertige Dateien zum Download | `downloads/` | DMG/ZIP/IPA/relay.py – nach jedem Release aktualisieren |

## macOS-App – wichtige Module
- `Core/ReplayEngine.swift` + `ReplayBuffer.swift`: ScreenCaptureKit → VideoToolbox (HEVC/H.264) → Ringpuffer im RAM; separater Audio-Stream (ganzer Systemton) mit Watchdog; Audio wird beim Empfang tief kopiert.
- `Core/ClipExporter.swift`: Clip schreiben (Video passthrough, Audio AAC, Spuren parallel per `requestMediaDataWhenReady`).
- `App/AppState.swift`: Zentrale Steuerung; Puffer wird bei Spielende/Spielwechsel verworfen (`discardBuffer`).
- `Core/GameDetector.swift`: Spielerkennung (Minecraft Java über Fenstertitel, Steam, Kategorie, eigene Regeln).
- `Core/ScreenRecorder.swift`: klassische Bildschirm-/Bereichsaufnahme (⌥⇧R).
- `Views/ClipEditor.swift`: eingebauter Player mit Zuschneiden (AVPlayerView).
- `Suite/*`: Dashboard-Daten (SystemMonitor, Temperatur via IOHID), Taskmanager, Cleaner/Deinstaller, Launcher (Windows-Taste), Windows-Tastatur (CGEvent-Tap), Rotes-X-beendet, Dock-Vorschau.
- `App/GameWindowAssistant.swift`: Fenster an Ränder einrasten (Spiele oder alle Apps).
- `Remote/*`: RemoteAgent (WebSocket zum Relay, E2E AES-GCM, Status, Streaming H.264 mit Frame-Acks + adaptiver Bitrate), InputInjector (CGEvent), RemoteActions, ClipUploader (H.264-Umwandlung, Upload, Links).
- `Core/LaunchAgentManager.swift`: LaunchAgent mit `KeepAlive=true`; nur „Beenden“ im eigenen Menü stoppt die App.
- Berechtigungen nach Updates: App ist ad-hoc signiert → TCC-Einträge (Bildschirmaufnahme, Bedienungshilfen) werden nach Updates per `tccutil reset` automatisch erneuert.

## Protokoll Mac ↔ Relay ↔ iPhone
- Binärframes: `[kind u8][AES-GCM combined]`, kind 1 = Steuer-JSON, 2 = Video, 3 = Status. Server → iPhone zusätzlich `[kind][len][macID]…`.
- Der Relay leitet iPhone-Befehle nur an den „attached“ Mac weiter → iPhone sendet vor jedem Befehl automatisch `attach`.
- Videopaket: `[flags][seq u64][w u16][h u16]([sps][pps] bei Keyframe)[AVCC]`; iPhone sendet `{"t":"ack","seq":n}`.
- Server 1.1: Clip-API (`/api/clips`, `/api/storage`, öffentliche `/c/{id}`, `/v/{id}.mp4`, `/t/{id}.jpg` mit OpenGraph für Discord). Konfiguration `simplex_relay.json` (password, max_storage_gb, public_url).

## Build & Auslieferung
- Workflow `.github/workflows/build.yml`: Jobs `mac` (macos-15-intel, `scripts/build_app.sh`, Universal-Binary, ad-hoc signiert), `ios` (wählt neuestes Xcode, XcodeGen, unsignierte IPA), `server` (Syntaxcheck). arm64-Runner hatten Kapazitätsprobleme → Intel-Runner.
- Nach erfolgreichem Build: Artefakte herunterladen, in `downloads/` ersetzen (alte Versionen entfernen), committen, Dateien dem Nutzer schicken.
- Releases kann diese Sitzungsart nicht anlegen; ein Tag `v*` lässt die CI ein Release bauen.
