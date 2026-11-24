import Foundation
import SwiftData

/// Liest einen Export der Google-Maps-Zeitachse und macht daraus Spurwerk-Strecken.
///
/// Unterstützt die drei bekannten Formate:
/// - iPhone-Export aus der Google-Maps-App („location-history.json“, Punkte als „geo:52.4,13.4“)
/// - Android-/Geräte-Export („Timeline.json“ mit „semanticSegments“, Punkte als „52.4°, 13.4°“)
/// - alter Takeout-Export („Semantic Location History“ mit „timelineObjects“ und latitudeE7)
enum GoogleImport {

    struct Strecke {
        var art: FahrtArt
        var start: Date
        var ende: Date
        var distanz: Double
        var punkte: [Punkt]
    }

    struct Ergebnis {
        var neu = 0
        var doppelt = 0
        var uebersprungen = 0
    }

    private struct ZeitPunkt {
        var lat: Double
        var lon: Double
        var zeit: Date
    }

    private struct Aktivitaet {
        var art: FahrtArt
        var start: Date
        var ende: Date
        var distanz: Double
        var punkte: [ZeitPunkt]
    }

    // MARK: - Einlesen

    static func lesen(_ daten: Data) throws -> [Strecke] {
        let json = try JSONSerialization.jsonObject(with: daten)
        var aktivitaeten: [Aktivitaet] = []
        var pfad: [ZeitPunkt] = []

        if let liste = json as? [[String: Any]] {
            // iPhone-Format: Liste aus Aktivitäten, Besuchen und Pfad-Stücken
            for eintrag in liste { segmentLesen(eintrag, &aktivitaeten, &pfad) }
        } else if let objekt = json as? [String: Any] {
            if let segmente = objekt["semanticSegments"] as? [[String: Any]] {
                for eintrag in segmente { segmentLesen(eintrag, &aktivitaeten, &pfad) }
            }
            if let alte = objekt["timelineObjects"] as? [[String: Any]] {
                for eintrag in alte {
                    if let seg = eintrag["activitySegment"] as? [String: Any] { altesSegmentLesen(seg, &aktivitaeten) }
                }
            }
        }

        // Pfad-Punkte den Aktivitäten zuordnen (nach Zeit)
        pfad.sort { $0.zeit < $1.zeit }
        var strecken: [Strecke] = []
        for var a in aktivitaeten {
            let innen = zwischen(pfad, a.start, a.ende)
            a.punkte.append(contentsOf: innen)
            a.punkte.sort { $0.zeit < $1.zeit }
            guard a.punkte.count >= 2 else { continue }
            let punkte = a.punkte.map {
                Punkt(lat: $0.lat, lon: $0.lon, zeit: $0.zeit.timeIntervalSince1970, genauigkeit: 50, tempo: -1)
            }
            let distanz = a.distanz > 0 ? a.distanz : luftlinie(punkte)
            let art = FahrtArt.plausibel(a.art, meter: distanz, sekunden: a.ende.timeIntervalSince(a.start))
            guard distanz >= art.mindestStrecke else { continue }
            strecken.append(Strecke(art: art, start: a.start, ende: a.ende, distanz: distanz, punkte: punkte))
        }
        return strecken.sorted { $0.start < $1.start }
    }

    /// Ein Eintrag im iPhone- oder Android-Format.
    private static func segmentLesen(_ e: [String: Any], _ aktivitaeten: inout [Aktivitaet], _ pfad: inout [ZeitPunkt]) {
        guard let start = datum(e["startTime"]) else { return }
        let ende = datum(e["endTime"]) ?? start

        if let tp = e["timelinePath"] as? [[String: Any]] {
            for p in tp {
                guard let (lat, lon) = koordinate(p["point"]) else { continue }
                var zeit = datum(p["time"])
                if zeit == nil, let versatz = zahl(p["durationMinutesOffsetFromStartTime"]) {
                    zeit = start.addingTimeInterval(versatz * 60)
                }
                pfad.append(ZeitPunkt(lat: lat, lon: lon, zeit: zeit ?? start))
            }
        }

        guard let akt = e["activity"] as? [String: Any] else { return }
        let top = akt["topCandidate"] as? [String: Any]
        guard let typ = top?["type"] as? String, let art = artAus(typ) else { return }

        var punkte: [ZeitPunkt] = []
        if let s = koordinate(akt["start"]) { punkte.append(ZeitPunkt(lat: s.0, lon: s.1, zeit: start)) }
        if let z = koordinate(akt["end"]) { punkte.append(ZeitPunkt(lat: z.0, lon: z.1, zeit: ende)) }
        let distanz = zahl(akt["distanceMeters"]) ?? zahl(akt["distance"]) ?? 0
        aktivitaeten.append(Aktivitaet(art: art, start: start, ende: ende, distanz: distanz, punkte: punkte))
    }

    /// Eintrag im alten Takeout-Format.
    private static func altesSegmentLesen(_ s: [String: Any], _ aktivitaeten: inout [Aktivitaet]) {
        let dauer = s["duration"] as? [String: Any]
        guard let start = datum(dauer?["startTimestamp"]) ?? datum(dauer?["startTimestampMs"]),
              let typ = s["activityType"] as? String, let art = artAus(typ) else { return }
        let ende = datum(dauer?["endTimestamp"]) ?? datum(dauer?["endTimestampMs"]) ?? start

        var punkte: [ZeitPunkt] = []
        if let s0 = e7(s["startLocation"]) { punkte.append(ZeitPunkt(lat: s0.0, lon: s0.1, zeit: start)) }
        // Rohpunkte mit Zeit sind am wertvollsten, sonst die Wegpunkte gleichmäßig über die Dauer verteilen
        if let roh = (s["simplifiedRawPath"] as? [String: Any])?["points"] as? [[String: Any]] {
            for p in roh {
                if let k = e7(p) {
                    punkte.append(ZeitPunkt(lat: k.0, lon: k.1, zeit: datum(p["timestamp"]) ?? datum(p["timestampMs"]) ?? start))
                }
            }
        } else if let wp = (s["waypointPath"] as? [String: Any])?["waypoints"] as? [[String: Any]] {
            let gesamt = ende.timeIntervalSince(start)
            for (i, p) in wp.enumerated() {
                if let k = e7(p) {
                    let anteil = Double(i + 1) / Double(wp.count + 1)
                    punkte.append(ZeitPunkt(lat: k.0, lon: k.1, zeit: start.addingTimeInterval(gesamt * anteil)))
                }
            }
        }
        if let z = e7(s["endLocation"]) { punkte.append(ZeitPunkt(lat: z.0, lon: z.1, zeit: ende)) }
        let distanz = zahl(s["distance"]) ?? 0
        aktivitaeten.append(Aktivitaet(art: art, start: start, ende: ende, distanz: distanz, punkte: punkte))
    }

    /// Besuchte Orte mit Namen („Zuhause“, „Arbeit“, gespeicherte Orte) – für die Namen der Halte.
    static func besuche(_ daten: Data) -> [OrtBesuch] {
        guard let json = try? JSONSerialization.jsonObject(with: daten) else { return [] }
        var ergebnis: [OrtBesuch] = []

        func merken(_ ort: (Double, Double)?, name: String?, typ: String?) {
            guard let ort else { return }
            var text = name?.trimmingCharacters(in: .whitespaces) ?? ""
            if text.isEmpty, let typ = typ?.lowercased() {
                if typ.contains("home") { text = "Zuhause" } else if typ.contains("work") { text = "Arbeit" }
            }
            guard !text.isEmpty else { return }
            ergebnis.append(OrtBesuch(lat: ort.0, lon: ort.1, name: text))
        }

        func neuerBesuch(_ e: [String: Any]) {
            guard let v = e["visit"] as? [String: Any], let top = v["topCandidate"] as? [String: Any] else { return }
            merken(koordinate(top["placeLocation"]), name: top["name"] as? String, typ: top["semanticType"] as? String)
        }

        if let liste = json as? [[String: Any]] {
            liste.forEach(neuerBesuch)
        } else if let objekt = json as? [String: Any] {
            (objekt["semanticSegments"] as? [[String: Any]])?.forEach(neuerBesuch)
            for e in (objekt["timelineObjects"] as? [[String: Any]]) ?? [] {
                guard let pv = e["placeVisit"] as? [String: Any], let ort = pv["location"] as? [String: Any] else { continue }
                merken(e7(ort), name: ort["name"] as? String, typ: ort["semanticType"] as? String)
            }
        }
        return ergebnis
    }

    // MARK: - Speichern

    static func speichern(_ strecken: [Strecke], in context: ModelContext) -> Ergebnis {
        var ergebnis = Ergebnis()
        let vorhanden = (try? context.fetch(FetchDescriptor<Fahrt>())) ?? []
        var belegt = Set(vorhanden.map { "\($0.artText)-\(Int($0.start.timeIntervalSince1970 / 120))" })

        for s in strecken {
            let schluessel = "\(s.art.rawValue)-\(Int(s.start.timeIntervalSince1970 / 120))"
            if belegt.contains(schluessel) {
                ergebnis.doppelt += 1
                continue
            }
            belegt.insert(schluessel)
            let fahrt = Fahrt(start: s.start, art: s.art)
            fahrt.ende = s.ende
            fahrt.punkte = s.punkte
            fahrt.distanzMeter = s.distanz
            fahrt.quelle = "google"
            fahrt.dichte = mittlererAbstand(s.punkte)
            fahrt.status = .wartet
            context.insert(fahrt)
            ergebnis.neu += 1
            if ergebnis.neu % 200 == 0 { try? context.save() }
        }
        try? context.save()
        return ergebnis
    }

    // MARK: - Hilfen

    private static func artAus(_ typ: String) -> FahrtArt? {
        let t = typ.lowercased().replacingOccurrences(of: "_", with: " ")
        if t.contains("passenger vehicle") || t.contains("driving") || t.contains("taxi") || t.contains("motor") || t == "car" || t.contains(" car") {
            return .auto
        }
        if t.contains("walk") || t.contains("running") || t.contains("hiking") || t.contains("on foot") { return .fuss }
        if t.contains("cycl") || t.contains("bik") { return .rad }
        return nil // Bus, Bahn, Flug usw. werden nicht übernommen
    }

    /// Erkennt „geo:52.4,13.4“, „52.4°, 13.4°“ und {"latLng": "..."}.
    private static func koordinate(_ wert: Any?) -> (Double, Double)? {
        if let dict = wert as? [String: Any] {
            if let ll = dict["latLng"] { return koordinate(ll) }
            if let la = zahl(dict["latitude"]), let lo = zahl(dict["longitude"]) { return (la, lo) }
            return e7(dict)
        }
        guard let text = wert as? String else { return nil }
        let zahlen = text
            .replacingOccurrences(of: "geo:", with: "")
            .split(whereSeparator: { ",° ".contains($0) })
            .compactMap { Double($0) }
        guard zahlen.count >= 2, abs(zahlen[0]) <= 90, abs(zahlen[1]) <= 180 else { return nil }
        return (zahlen[0], zahlen[1])
    }

    private static func e7(_ wert: Any?) -> (Double, Double)? {
        guard let d = wert as? [String: Any] else { return nil }
        let la = zahl(d["latitudeE7"]) ?? zahl(d["latE7"])
        let lo = zahl(d["longitudeE7"]) ?? zahl(d["lngE7"])
        guard let la, let lo else { return nil }
        return (la / 1e7, lo / 1e7)
    }

    private static func zahl(_ wert: Any?) -> Double? {
        if let n = wert as? NSNumber { return n.doubleValue }
        if let s = wert as? String { return Double(s) }
        return nil
    }

    private static let isoMitBruch: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    private static func datum(_ wert: Any?) -> Date? {
        if let s = wert as? String {
            if let ms = Double(s), s.count >= 12 { return Date(timeIntervalSince1970: ms / 1000) }
            return isoMitBruch.date(from: s) ?? iso.date(from: s)
        }
        if let n = wert as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue / 1000) }
        return nil
    }

    private static func zwischen(_ pfad: [ZeitPunkt], _ von: Date, _ bis: Date) -> [ZeitPunkt] {
        // binäre Suche nach dem ersten Punkt ab „von“
        var lo = 0, hi = pfad.count
        while lo < hi {
            let mitte = (lo + hi) / 2
            if pfad[mitte].zeit < von { lo = mitte + 1 } else { hi = mitte }
        }
        var ergebnis: [ZeitPunkt] = []
        var i = lo
        while i < pfad.count, pfad[i].zeit <= bis {
            ergebnis.append(pfad[i])
            i += 1
        }
        return ergebnis
    }

    private static func luftlinie(_ punkte: [Punkt]) -> Double {
        var summe = 0.0
        for i in 1..<punkte.count {
            let a = punkte[i - 1], b = punkte[i]
            let dLat = (b.lat - a.lat) * 111_320
            let dLon = (b.lon - a.lon) * 111_320 * cos(a.lat * .pi / 180)
            summe += (dLat * dLat + dLon * dLon).squareRoot()
        }
        return summe
    }
}
