# Spurwerk

iPhone-App, die aufzeichnet, wo du gefahren und gelaufen bist – sauber auf Straßen und Wegen statt Zick-Zack-Linien.

- **Aufnahme:** Auto, zu Fuß oder Fahrrad – von Hand oder automatisch, sobald das iPhone erkennt, dass du fährst oder läufst (Standort „Immer“ nötig).
- **Fußwege** werden auf Geh-/Feldwege gelegt (Valhalla-Profil „pedestrian“), Autofahrten nur auf Straßen.
- **Auf die Straße legen:** Die rohen GPS-Punkte gehen an Valhalla auf dem Proxmox-NUC (Map-Matching mit OpenStreetMap).
  Erst Heimnetz (`http://192.168.1.30:8002`), sonst Tailscale. Ist nichts erreichbar, wartet die Fahrt.
- **Karte:** alle Fahrten übereinander (türkis = Auto, lila = zu Fuß, rot = Rad; gestrichelt = wartet noch auf Abgleich), oben filterbar.
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
