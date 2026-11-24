#!/usr/bin/env python3
"""Spurwerk-Server – speichert alle Strecken, legt sie mit Valhalla auf die Straße und zeigt sie im Browser.

Das iPhone lädt neue Strecken hoch (/api/hochladen) und holt fertige Linien ab (/api/abholen).
Der Abgleich läuft hier im Hintergrund, das iPhone muss dafür nicht offen sein.
"""
import json
import math
import os
import sqlite3
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(os.environ.get("PORT", "8088"))
DB = os.environ.get("SPURWERK_DB", "/data/spurwerk.sqlite")
VALHALLA = os.environ.get("VALHALLA", "http://192.168.1.30:8002").rstrip("/")
TOKEN = os.environ.get("SPURWERK_TOKEN", "")
HERE = os.path.dirname(os.path.abspath(__file__))
PROFIL = {"auto": "auto", "fuss": "pedestrian", "rad": "bicycle"}
MINDEST = {"auto": 300, "fuss": 150, "rad": 200}

_lokal = threading.local()


def db():
    c = getattr(_lokal, "c", None)
    if c is None:
        c = sqlite3.connect(DB, timeout=30)
        c.row_factory = sqlite3.Row
        c.execute("PRAGMA journal_mode=WAL")
        _lokal.c = c
    return c


def einrichten():
    os.makedirs(os.path.dirname(DB), exist_ok=True)
    db().executescript("""
        CREATE TABLE IF NOT EXISTS strecken(
            id TEXT PRIMARY KEY, art TEXT, start REAL, ende REAL, distanz REAL, quelle TEXT,
            status TEXT, fehler TEXT, punkte TEXT, spur TEXT, fein TEXT, grob TEXT,
            dichte REAL, geaendert REAL);
        CREATE INDEX IF NOT EXISTS i_start ON strecken(start);
        CREATE INDEX IF NOT EXISTS i_status ON strecken(status);
        CREATE INDEX IF NOT EXISTS i_geaendert ON strecken(geaendert);
    """)
    spalten = {r[1] for r in db().execute("PRAGMA table_info(strecken)")}
    if "ziel_lat" not in spalten:   # Endpunkt jeder Strecke – für Halte und Parkplätze
        db().execute("ALTER TABLE strecken ADD COLUMN ziel_lat REAL")
        db().execute("ALTER TABLE strecken ADD COLUMN ziel_lon REAL")
    if "start_lat" not in spalten:
        db().execute("ALTER TABLE strecken ADD COLUMN start_lat REAL")
        db().execute("ALTER TABLE strecken ADD COLUMN start_lon REAL")
        db().execute("UPDATE strecken SET ziel_lat=NULL")
    # Abgleich, der beim letzten Beenden mitten drin war, neu anstoßen
    db().execute("UPDATE strecken SET status='wartet' WHERE status='laeuft'")
    db().commit()


# ---------------------------------------------------------------- Geometrie

def abstand(a, b):
    """Meter zwischen zwei (lat, lon)."""
    dlat = (b[0] - a[0]) * 111320
    dlon = (b[1] - a[1]) * 111320 * math.cos(math.radians(a[0]))
    return math.hypot(dlat, dlon)


def vereinfachen(p, tol):
    """Douglas-Peucker in Metern, ohne Rekursion."""
    if len(p) < 3:
        return p
    kx = math.cos(math.radians(p[0][0])) * 111320
    xy = [(q[1] * kx, q[0] * 111320) for q in p]
    behalten = [False] * len(p)
    behalten[0] = behalten[-1] = True
    stapel = [(0, len(p) - 1)]
    tol2 = tol * tol
    while stapel:
        a, b = stapel.pop()
        if b <= a + 1:
            continue
        ax, ay = xy[a]
        bx, by = xy[b]
        dx, dy = bx - ax, by - ay
        l2 = max(dx * dx + dy * dy, 1e-9)
        best, bi = 0.0, a
        for i in range(a + 1, b):
            px, py = xy[i]
            t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / l2))
            qx, qy = ax + t * dx - px, ay + t * dy - py
            d = qx * qx + qy * qy
            if d > best:
                best, bi = d, i
        if best > tol2:
            behalten[bi] = True
            stapel += [(a, bi), (bi, b)]
    return [q for q, k in zip(p, behalten) if k]


def kodieren(p, faktor=1e5):
    out, plat, plon = [], 0, 0
    for lat, lon in p:
        la, lo = int(round(lat * faktor)), int(round(lon * faktor))
        for v in (la - plat, lo - plon):
            v = ~(v << 1) if v < 0 else v << 1
            while v >= 0x20:
                out.append(chr((0x20 | (v & 0x1F)) + 63))
                v >>= 5
            out.append(chr(v + 63))
        plat, plon = la, lo
    return "".join(out)


def dekodieren(s, faktor=1e6):
    i, lat, lon, out = 0, 0, 0, []
    while i < len(s):
        werte = []
        for _ in range(2):
            r = sh = 0
            while True:
                b = ord(s[i]) - 63
                i += 1
                r |= (b & 0x1F) << sh
                sh += 5
                if b < 0x20:
                    break
            werte.append(~(r >> 1) if r & 1 else r >> 1)
        lat += werte[0]
        lon += werte[1]
        out.append((lat / faktor, lon / faktor))
    return out


def mittlerer_abstand(p):
    if len(p) < 2:
        return 0
    return sum(abstand(p[i - 1], p[i]) for i in range(1, len(p))) / (len(p) - 1)


# ---------------------------------------------------------------- Valhalla

def valhalla(pfad, daten, timeout=120):
    req = urllib.request.Request(VALHALLA + pfad, data=json.dumps(daten).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            antwort = json.loads(r.read())
    except urllib.error.HTTPError as e:
        try:
            fehler = json.loads(e.read()).get("error")
        except Exception:  # noqa: BLE001
            fehler = None
        raise RuntimeError(fehler or f"Valhalla meldet {e.code}") from None
    linie = []
    for leg in antwort.get("trip", {}).get("legs", []):
        linie += dekodieren(leg.get("shape", ""))
    if not linie:
        raise RuntimeError("Keine Linie erhalten")
    return linie


def ausduennen(punkte, mindest):
    """punkte: [[lat, lon, zeit], …]"""
    if not punkte:
        return []
    out = [punkte[0]]
    for p in punkte[1:]:
        if abstand(out[-1], p) >= mindest:
            out.append(p)
    if out[-1] is not punkte[-1]:
        out.append(punkte[-1])
    return out


def abgleichen(punkte, art):
    duenn = ausduennen(punkte, 15 if art == "auto" else 6)
    if len(duenn) < 2:
        raise RuntimeError("Zu wenige GPS-Punkte")
    luecke = mittlerer_abstand(duenn)
    sparsam = luecke > 150
    ergebnis, fehlgeschlagen, stuecke, start = [], 0, 0, 0
    while start < len(duenn) - 1:
        ende = min(start + 2000, len(duenn))
        teil = duenn[start:ende]
        stuecke += 1
        try:
            linie = valhalla("/trace_route", {
                "shape": [{"lat": p[0], "lon": p[1], "time": int(p[2])} for p in teil],
                "costing": PROFIL.get(art, "auto"), "shape_match": "map_snap",
                "use_timestamps": not sparsam, "directions_type": "none",
                "trace_options": {"search_radius": 60 if sparsam else (40 if art == "auto" else 25),
                                  "gps_accuracy": 30 if sparsam else 10,
                                  "breakage_distance": 10000 if sparsam else 3000,
                                  "interpolation_distance": 10}})
        except RuntimeError:
            linie = None
            if sparsam:
                try:
                    linie = routen(teil, art)
                except RuntimeError:
                    linie = None
            if linie is None:
                fehlgeschlagen += 1
                linie = [(p[0], p[1]) for p in teil]
        if ergebnis and linie:
            linie = linie[1:]
        ergebnis += linie
        start = ende - 1
    if fehlgeschlagen == stuecke:
        raise RuntimeError("Keine Straße gefunden")
    return ergebnis, luecke


def routen(teil, art):
    """Weg zwischen lückenhaften Punkten über /route (max. 20 Punkte pro Anfrage)."""
    linie, start = [], 0
    while start < len(teil) - 1:
        ende = min(start + 20, len(teil))
        stueck = teil[start:ende]
        orte = [{"lat": p[0], "lon": p[1], "radius": 50,
                 "type": "break" if i in (0, len(stueck) - 1) else "through"} for i, p in enumerate(stueck)]
        l = valhalla("/route", {"locations": orte, "costing": PROFIL.get(art, "auto"), "directions_type": "none"}, 60)
        if linie and l:
            l = l[1:]
        linie += l
        start = ende - 1
    return linie


def speichere_spur(sid, spur, dichte=None):
    fein = kodieren(vereinfachen(spur, 4))
    grob = kodieren(vereinfachen(spur, 35))
    db().execute("UPDATE strecken SET status='fertig', fehler=NULL, spur=?, fein=?, grob=?, dichte=COALESCE(?, dichte), geaendert=? WHERE id=?",
                 (kodieren(spur, 1e6), fein, grob, dichte, time.time(), sid))
    db().commit()


_stand = {"laeuft": False, "fertig_seit_start": 0, "fehler": None}


def arbeiter():
    """Legt wartende Strecken nacheinander auf die Straße – neueste zuerst."""
    while True:
        try:
            z = db().execute("SELECT id, art, punkte FROM strecken WHERE status='wartet' ORDER BY start DESC LIMIT 1").fetchone()
            if not z:
                _stand["laeuft"] = False
                time.sleep(10)
                continue
            _stand["laeuft"] = True
            db().execute("UPDATE strecken SET status='laeuft' WHERE id=?", (z["id"],))
            db().commit()
            punkte = json.loads(z["punkte"] or "[]")
            try:
                spur, dichte = abgleichen(punkte, z["art"])
                speichere_spur(z["id"], spur, dichte)
                _stand["fertig_seit_start"] += 1
                _stand["fehler"] = None
            except urllib.error.URLError as e:
                # Valhalla nicht erreichbar: zurückstellen und später erneut versuchen
                db().execute("UPDATE strecken SET status='wartet' WHERE id=?", (z["id"],))
                db().commit()
                _stand["fehler"] = f"Valhalla nicht erreichbar ({e.reason})"
                time.sleep(30)
            except Exception as e:  # noqa: BLE001
                db().execute("UPDATE strecken SET status='fehler', fehler=?, geaendert=? WHERE id=?",
                             (str(e)[:300], time.time(), z["id"]))
                db().commit()
        except Exception as e:  # noqa: BLE001
            _stand["fehler"] = str(e)
            time.sleep(5)


# ---------------------------------------------------------------- Daten für App und Browser

def hochladen(liste):
    n = 0
    for s in liste:
        sid = str(s.get("id", ""))
        art = s.get("art") if s.get("art") in PROFIL else "auto"
        if not sid:
            continue
        punkte = [[float(p[0]), float(p[1]), float(p[2]) if len(p) > 2 else 0.0] for p in s.get("punkte", [])]
        dichte = mittlerer_abstand(punkte) if punkte else None
        alt = db().execute("SELECT status FROM strecken WHERE id=?", (sid,)).fetchone()
        db().execute("""INSERT INTO strecken(id, art, start, ende, distanz, quelle, status, punkte, dichte, geaendert)
                        VALUES(?,?,?,?,?,?,?,?,?,?)
                        ON CONFLICT(id) DO UPDATE SET art=excluded.art, start=excluded.start, ende=excluded.ende,
                        distanz=excluded.distanz, quelle=excluded.quelle, punkte=excluded.punkte, dichte=excluded.dichte,
                        ziel_lat=NULL, ziel_lon=NULL, start_lat=NULL, start_lon=NULL""",
                     (sid, art, float(s.get("start", 0)), float(s.get("ende", s.get("start", 0))),
                      float(s.get("distanz", 0)), s.get("quelle", "app"), "wartet", json.dumps(punkte), dichte, time.time()))
        if s.get("spur"):
            # Schon auf dem iPhone abgeglichen – nicht noch einmal rechnen
            speichere_spur(sid, [(float(p[0]), float(p[1])) for p in s["spur"]])
        elif s.get("neu_abgleichen") or not alt or alt["status"] in ("fehler",):
            db().execute("UPDATE strecken SET status='wartet' WHERE id=?", (sid,))
        n += 1
    db().commit()
    return n


def zeile_meta(z):
    return {"id": z["id"], "art": z["art"], "start": z["start"], "ende": z["ende"], "distanz": z["distanz"],
            "quelle": z["quelle"], "status": z["status"],
            "geschaetzt": bool(z["dichte"] and z["dichte"] > 150)}


def bereich(q):
    von = float(q.get("von", ["0"])[0] or 0)
    bis = float(q.get("bis", ["1e12"])[0] or 1e12)
    arten = [a for a in q.get("art", [""])[0].split(",") if a in PROFIL]
    sql, args = "start >= ? AND start < ?", [von, bis]
    if arten:
        sql += " AND art IN (%s)" % ",".join("?" * len(arten))
        args += arten
    return sql, args


def halte_alle():
    """Halte wie in der App: Parken von einer Autofahrt bis zur nächsten, Aufenthalt nach Fuß-/Radstrecken."""
    fehlend = db().execute("SELECT id, punkte FROM strecken WHERE ziel_lat IS NULL").fetchall()
    if fehlend:
        neu = []
        for z in fehlend:
            p = json.loads(z["punkte"] or "[]")
            if p:
                neu.append((p[-1][0], p[-1][1], p[0][0], p[0][1], z["id"]))
        db().executemany("UPDATE strecken SET ziel_lat=?, ziel_lon=?, start_lat=?, start_lon=? WHERE id=?", neu)
        db().commit()
    s = db().execute("SELECT id, art, start, ende, ziel_lat, ziel_lon, start_lat, start_lon FROM strecken "
                     "WHERE ziel_lat IS NOT NULL ORDER BY start").fetchall()
    naechstes_auto = [None] * len(s)
    letztes = None
    for i in range(len(s) - 1, -1, -1):
        naechstes_auto[i] = letztes
        if s[i]["art"] == "auto":
            letztes = i
    halte = []
    for i, a in enumerate(s):
        if a["art"] == "auto":
            j = naechstes_auto[i]
            bis = s[j]["start"] if j is not None else None
            if j is not None and not (180 <= bis - a["ende"] <= 30 * 86400
                                      and abstand((a["ziel_lat"], a["ziel_lon"]), (s[j]["start_lat"], s[j]["start_lon"])) <= 1000):
                continue  # zu kurz, zu lang oder nächste Fahrt beginnt woanders → kein Parken
            halte.append({"id": a["id"], "p": 1, "lat": a["ziel_lat"], "lon": a["ziel_lon"], "von": a["ende"], "bis": bis})
        elif i + 1 < len(s):
            d = s[i + 1]["start"] - a["ende"]
            if 300 <= d <= 2 * 86400 and abstand((a["ziel_lat"], a["ziel_lon"]), (s[i + 1]["start_lat"], s[i + 1]["start_lon"])) <= 500:
                halte.append({"id": a["id"], "p": 0, "lat": a["ziel_lat"], "lon": a["ziel_lon"], "von": a["ende"], "bis": s[i + 1]["start"]})
    return halte


def status():
    zahlen = {r["status"]: r["n"] for r in db().execute("SELECT status, COUNT(*) n FROM strecken GROUP BY status")}
    return {"zahlen": zahlen, "gesamt": sum(zahlen.values()), "laeuft": _stand["laeuft"],
            "fehler": _stand["fehler"], "valhalla": VALHALLA}


# ---------------------------------------------------------------- HTTP

class Handler(BaseHTTPRequestHandler):
    server_version = "Spurwerk/1.0"

    def log_message(self, *a):
        pass

    def _send(self, code, payload, ctype="application/json; charset=utf-8"):
        body = payload if isinstance(payload, bytes) else json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _erlaubt(self):
        if not TOKEN:
            return True
        q = parse_qs(urlparse(self.path).query)
        return self.headers.get("X-Token") == TOKEN or q.get("token", [""])[0] == TOKEN

    def do_GET(self):
        url = urlparse(self.path)
        q = parse_qs(url.query)
        try:
            if url.path in ("/", "/index.html"):
                with open(os.path.join(HERE, "index.html"), "rb") as f:
                    return self._send(200, f.read(), "text/html; charset=utf-8")
            if not self._erlaubt():
                return self._send(401, {"error": "Token fehlt"})
            if url.path == "/api/status":
                return self._send(200, status())
            if url.path == "/api/strecken":
                sql, args = bereich(q)
                grenze = min(int(q.get("limit", ["200"])[0]), 2000)
                versatz = int(q.get("offset", ["0"])[0])
                zeilen = db().execute(f"SELECT id, art, start, ende, distanz, quelle, status, dichte FROM strecken WHERE {sql} ORDER BY start DESC LIMIT ? OFFSET ?",
                                      args + [grenze, versatz]).fetchall()
                return self._send(200, {"strecken": [zeile_meta(z) for z in zeilen]})
            if url.path == "/api/summen":
                sql, args = bereich(q)
                out = {}
                for z in db().execute(f"SELECT art, COUNT(*) n, SUM(distanz) d, SUM(ende-start) t FROM strecken WHERE {sql} GROUP BY art", args):
                    out[z["art"]] = {"anzahl": z["n"], "meter": z["d"] or 0, "sekunden": z["t"] or 0}
                return self._send(200, out)
            if url.path == "/api/linien":
                sql, args = bereich(q)
                spalte = "grob" if q.get("grob", ["0"])[0] == "1" else "fein"
                linien = []
                for z in db().execute(f"SELECT id, art, status, dichte, {spalte} g, punkte FROM strecken WHERE {sql}", args):
                    if z["g"]:
                        linien.append({"id": z["id"], "a": z["art"], "s": z["g"], "f": 1,
                                       "x": 1 if (z["dichte"] or 0) > 150 else 0})
                    else:  # noch nicht abgeglichen: rohe Punkte (gestrichelt)
                        p = [(x[0], x[1]) for x in json.loads(z["punkte"] or "[]")]
                        if len(p) > 1:
                            linien.append({"id": z["id"], "a": z["art"], "s": kodieren(vereinfachen(p, 35 if spalte == "grob" else 8)), "f": 0, "x": 0})
                return self._send(200, {"linien": linien})
            if url.path == "/api/halte":
                von = float(q.get("von", ["0"])[0] or 0)
                bis = float(q.get("bis", ["1e12"])[0] or 1e12)
                arten = [a for a in q.get("art", [""])[0].split(",") if a in PROFIL]
                jetzt = time.time()
                out = [h for h in halte_alle() if h["von"] < bis and (h["bis"] or jetzt) > von
                       and (not arten or ("auto" in arten if h["p"] else any(a != "auto" for a in arten)))]
                return self._send(200, {"halte": out[-3000:]})
            if url.path == "/api/abholen":
                seit = float(q.get("seit", ["0"])[0] or 0)
                zeilen = db().execute("SELECT id, status, fehler, spur, geaendert FROM strecken WHERE geaendert > ? AND status IN ('fertig','fehler') ORDER BY geaendert LIMIT 500",
                                      (seit,)).fetchall()
                return self._send(200, {"strecken": [{"id": z["id"], "status": z["status"], "fehler": z["fehler"],
                                                      "spur": z["spur"], "geaendert": z["geaendert"]} for z in zeilen]})
            if url.path == "/api/bekannt":
                return self._send(200, {"ids": [z[0] for z in db().execute("SELECT id FROM strecken")]})
            return self._send(404, {"error": "Unbekannt"})
        except Exception as e:  # noqa: BLE001
            return self._send(500, {"error": str(e)})

    def do_POST(self):
        url = urlparse(self.path)
        try:
            if not self._erlaubt():
                return self._send(401, {"error": "Token fehlt"})
            laenge = int(self.headers.get("Content-Length", "0"))
            daten = json.loads(self.rfile.read(laenge) or b"{}")
            if url.path == "/api/hochladen":
                return self._send(200, {"ok": True, "anzahl": hochladen(daten.get("strecken", []))})
            if url.path == "/api/linien_fein":
                ids = [str(x) for x in daten.get("ids", [])][:600]
                linien = []
                for z in db().execute("SELECT id, fein FROM strecken WHERE fein IS NOT NULL AND id IN (%s)" % ",".join("?" * len(ids)), ids) if ids else []:
                    linien.append({"id": z["id"], "s": z["fein"]})
                return self._send(200, {"linien": linien})
            if url.path == "/api/neu_abgleichen":
                ids = [str(x) for x in daten.get("ids", [])]
                db().executemany("UPDATE strecken SET status='wartet' WHERE id=?", [(i,) for i in ids])
                db().commit()
                return self._send(200, {"ok": True})
            if url.path == "/api/loeschen":
                ids = [str(x) for x in daten.get("ids", [])]
                db().executemany("DELETE FROM strecken WHERE id=?", [(i,) for i in ids])
                db().commit()
                return self._send(200, {"ok": True})
            return self._send(404, {"error": "Unbekannt"})
        except Exception as e:  # noqa: BLE001
            return self._send(500, {"error": str(e)})


if __name__ == "__main__":
    einrichten()
    threading.Thread(target=arbeiter, daemon=True).start()
    print(f"Spurwerk-Server auf Port {PORT}, Valhalla {VALHALLA}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
