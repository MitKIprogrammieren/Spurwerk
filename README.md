# Spurwerk

iPhone-App, die aufzeichnet, welche Straßen du gefahren bist – sauber auf der Straße statt Zick-Zack-Linien.

- **Aufnahme:** von Hand oder automatisch, sobald das iPhone eine Autofahrt erkennt (Standort „Immer“ nötig).
- **Auf die Straße legen:** Die rohen GPS-Punkte gehen an Valhalla auf dem Proxmox-NUC (Map-Matching mit OpenStreetMap).
  Erst Heimnetz (`http://192.168.1.30:8002`), sonst Tailscale. Ist nichts erreichbar, wartet die Fahrt.
- **Karte:** alle Fahrten übereinander (türkis = auf der Straße, orange gestrichelt = wartet noch).
- **Export:** jede Fahrt als GPX.

## Bauen (Mac)

```
./bauen.sh
```

Ergebnis: `Spurwerk.ipa` → per AirDrop aufs iPhone → in SideStore mit „+“ hinzufügen.
Sobald das Projekt auf GitHub liegt, baut GitHub Actions die IPA bei jedem Push automatisch (Release „latest“).

## Kartendienst

`valhalla/compose.yaml` läuft auf dem NUC als Stack `spurwerk-valhalla`.
Test: `http://192.168.1.30:8002/status`
