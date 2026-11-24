import Foundation
import SwiftData
import CoreLocation

/// Legt aufgenommene Fahrten auf die echten Straßen (Map-Matching über Valhalla auf dem NUC).
@MainActor
final class Abgleich: ObservableObject {
    static let shared = Abgleich()

    static let standardHeim = "http://192.168.1.30:8002"
    static let standardUnterwegs = "http://nuc-schichtlohn.tail293912.ts.net:8002"
    static let standardSpurHeim = "http://192.168.1.30:8084"
    static let standardSpurUnterwegs = "http://nuc-schichtlohn.tail293912.ts.net:8084"

    @Published private(set) var laeuft = false
    @Published private(set) var meldung: String?

    var serverListe: [String] {
        let d = UserDefaults.standard
        let heim = d.string(forKey: "serverHeim") ?? Self.standardHeim
        let unterwegs = d.string(forKey: "serverUnterwegs") ?? Self.standardUnterwegs
        return [heim, unterwegs].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Spurwerk-Server auf dem NUC (speichert alles und gleicht selbst ab).
    func erreichbarerSpurServer() async -> URL? {
        let d = UserDefaults.standard
        let liste = [d.string(forKey: "spurHeim") ?? Self.standardSpurHeim,
                     d.string(forKey: "spurUnterwegs") ?? Self.standardSpurUnterwegs]
        for text in liste.map({ $0.trimmingCharacters(in: .whitespaces) }) where !text.isEmpty {
            guard let url = URL(string: text) else { continue }
            var anfrage = URLRequest(url: url.appendingPathComponent("api/status"))
            anfrage.timeoutInterval = 4
            if let (_, antwort) = try? await URLSession.shared.data(for: anfrage),
               (antwort as? HTTPURLResponse)?.statusCode == 200 {
                return url
            }
        }
        return nil
    }

    /// Mit dem NUC abgleichen: hochladen, fertige Linien abholen, Stand anzeigen.
    private func mitServer(_ server: URL, container: ModelContainer) async {
        let sync = SyncArbeiter(modelContainer: container)
        do {
            let hoch = try await sync.hochladen(server: server) { n, gesamt in
                await MainActor.run { Abgleich.shared.meldung = "Lade Strecken auf den NUC … \(Format.anzahl(n)) von \(Format.anzahl(gesamt))" }
            }
            let seit = UserDefaults.standard.double(forKey: "abgeholtBis")
            let (geholt, stand) = try await sync.abholen(server: server, seit: seit)
            UserDefaults.standard.set(stand, forKey: "abgeholtBis")
            if hoch > 0 || geholt > 0 { geaendert() }
            if let s = try? await SyncArbeiter.holen(server.appendingPathComponent("api/status")),
               let z = s["zahlen"] as? [String: Int] {
                let gesamt = z.values.reduce(0, +), fertig = z["fertig"] ?? 0
                let offen = (z["wartet"] ?? 0) + (z["laeuft"] ?? 0)
                meldung = offen > 0
                    ? "NUC legt Strecken auf die Straße: \(Format.anzahl(fertig)) von \(Format.anzahl(gesamt))"
                    : "Alle \(Format.anzahl(gesamt)) Strecken auf dem NUC abgeglichen"
            }
        } catch {
            meldung = "NUC: \(error.localizedDescription)"
        }
    }

    /// Strecke auch auf dem NUC löschen (wenn erreichbar).
    func loeschen(_ ids: [UUID]) {
        Task {
            guard let server = await erreichbarerSpurServer() else { return }
            _ = try? await SyncArbeiter.senden(["ids": ids.map(\.uuidString)], an: server.appendingPathComponent("api/loeschen"))
        }
    }

    /// Erster Server, der antwortet – erst Heimnetz, dann Tailscale.
    func erreichbarerServer() async -> URL? {
        for text in serverListe {
            guard let url = URL(string: text) else { continue }
            var anfrage = URLRequest(url: url.appendingPathComponent("status"))
            anfrage.timeoutInterval = 4
            if let (_, antwort) = try? await URLSession.shared.data(for: anfrage),
               (antwort as? HTTPURLResponse)?.statusCode == 200 {
                return url
            }
        }
        return nil
    }

    func verbindungTesten() async {
        meldung = "Prüfe Verbindung …"
        if let url = await erreichbarerServer() {
            meldung = "Verbunden mit \(url.host ?? url.absoluteString)"
        } else {
            meldung = "Kein Server erreichbar"
        }
    }

    /// Wird bei jeder gespeicherten Änderung hochgezählt – die Karte lädt dann nach.
    @Published private(set) var version = 0

    func geaendert() { version &+= 1 }

    func ausstehendeAbgleichen(container: ModelContainer, auchFehler: Bool = false) async {
        guard !laeuft else { return }
        laeuft = true
        defer { laeuft = false; geaendert() }

        // Ist der Spurwerk-Server da, rechnet der NUC – das iPhone lädt nur hoch und holt ab.
        if let spur = await erreichbarerSpurServer() {
            if auchFehler {
                // Strecken ohne Straße noch einmal an den NUC geben
                let d = FetchDescriptor<Fahrt>(predicate: #Predicate { $0.statusText == "fehler" })
                for f in (try? container.mainContext.fetch(d)) ?? [] { f.status = .wartet; f.mussHoch = true }
                try? container.mainContext.save()
            }
            await mitServer(spur, container: container)
            return
        }

        // Sonst wie bisher selbst über Valhalla abgleichen.
        // Lesen und Speichern passiert in einem eigenen Hintergrund-Kontext – die Oberfläche bleibt frei
        let arbeiter = AbgleichArbeiter(modelContainer: container)
        let offen = await arbeiter.offeneIDs(auchFehler: auchFehler)
        guard !offen.isEmpty else {
            meldung = "Alle Strecken sind abgeglichen"
            return
        }
        guard let server = await erreichbarerServer() else {
            meldung = "\(offen.count) Strecke(n) warten – Server gerade nicht erreichbar"
            return
        }

        let client = ValhallaClient(basis: server)
        var geschafft = 0
        var letzteAnzeige = Date()
        for (nr, id) in offen.enumerated() {
            if nr % 10 == 0 { meldung = "Lege Strecken auf die Straße … \(nr + 1) von \(offen.count)" }
            guard let (punkte, art) = await arbeiter.punkte(id) else { continue }
            do {
                let spur = try await client.abgleichen(punkte, art: art)
                await arbeiter.ergebnis(id, spur: spur, fehler: nil)
                geschafft += 1
            } catch {
                await arbeiter.ergebnis(id, spur: nil, fehler: error.localizedDescription)
            }
            // Karte höchstens alle 30 Sekunden auffrischen
            if Date().timeIntervalSince(letzteAnzeige) > 30 {
                await arbeiter.sichern()
                letzteAnzeige = Date()
                geaendert()
            }
        }
        await arbeiter.sichern()
        meldung = "\(geschafft) von \(offen.count) Strecken abgeglichen"
    }

    func eineAbgleichen(_ fahrt: Fahrt, container: ModelContainer) async {
        fahrt.status = .wartet
        fahrt.mussHoch = true
        try? container.mainContext.save()
        await ausstehendeAbgleichen(container: container)
    }
}

/// Arbeitet mit einem eigenen Datenbank-Kontext im Hintergrund.
@ModelActor
actor AbgleichArbeiter {
    private var ungesichert = 0

    func offeneIDs(auchFehler: Bool) -> [PersistentIdentifier] {
        let wartet = FetchDescriptor<Fahrt>(predicate: #Predicate { $0.statusText == "wartet" },
                                            sortBy: [SortDescriptor(\.start, order: .reverse)])
        var ids = (try? modelContext.fetchIdentifiers(wartet)) ?? []
        if auchFehler {
            let fehler = FetchDescriptor<Fahrt>(predicate: #Predicate { $0.statusText == "fehler" })
            ids += (try? modelContext.fetchIdentifiers(fehler)) ?? []
        }
        return ids
    }

    func punkte(_ id: PersistentIdentifier) -> ([Punkt], FahrtArt)? {
        guard let f = modelContext.model(for: id) as? Fahrt else { return nil }
        return (f.punkte, f.art)
    }

    func ergebnis(_ id: PersistentIdentifier, spur: [CLLocationCoordinate2D]?, fehler: String?) {
        guard let f = modelContext.model(for: id) as? Fahrt else { return }
        if let spur {
            f.spur = spur
            f.status = .fertig
            f.fehlertext = nil
        } else {
            f.status = .fehler
            f.fehlertext = fehler
        }
        ungesichert += 1
        if ungesichert >= 25 { sichern() }
    }

    func sichern() {
        try? modelContext.save()
        ungesichert = 0
    }
}

struct ValhallaClient {
    let basis: URL

    struct Fehler: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    /// Valhalla verträgt keine beliebig langen Spuren – darum in Stücken mit 1 Punkt Überlappung.
    private let stueckGroesse = 2000

    func abgleichen(_ punkte: [Punkt], art: FahrtArt) async throws -> [CLLocationCoordinate2D] {
        let duenn = Self.ausduennen(punkte, abstand: art == .auto ? 15 : 6)
        guard duenn.count >= 2 else { throw Fehler(text: "Zu wenige GPS-Punkte") }
        // Importierte Google-Daten haben oft nur alle paar hundert Meter einen Punkt.
        // Dann lässt Valhalla die Lücken über das Straßennetz routen statt sie zu verbinden.
        let luecke = Self.mittlererAbstand(duenn)
        let duennBesetzt = luecke > 150

        var ergebnis: [CLLocationCoordinate2D] = []
        var fehlgeschlagen = 0
        var stuecke = 0
        var start = 0
        while start < duenn.count - 1 {
            let ende = min(start + stueckGroesse, duenn.count)
            let teil = Array(duenn[start..<ende])
            stuecke += 1
            var linie: [CLLocationCoordinate2D]
            do {
                linie = try await teilAbgleichen(teil, art: art, duennBesetzt: duennBesetzt)
            } catch where duennBesetzt {
                // Lückenhafte Daten (z. B. Google): Weg zwischen den Punkten über das Straßennetz routen
                do {
                    linie = try await teilRouten(teil, art: art)
                } catch {
                    fehlgeschlagen += 1
                    linie = teil.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                }
            } catch {
                // Stück ließ sich nicht zuordnen (z. B. Tiefgarage, Fähre): rohe Punkte behalten
                fehlgeschlagen += 1
                linie = teil.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            }
            if !ergebnis.isEmpty && !linie.isEmpty { linie.removeFirst() }
            ergebnis.append(contentsOf: linie)
            start = ende - 1
        }
        if fehlgeschlagen == stuecke { throw Fehler(text: "Keine Straße gefunden") }
        return ergebnis
    }

    private func teilAbgleichen(_ teil: [Punkt], art: FahrtArt, duennBesetzt: Bool) async throws -> [CLLocationCoordinate2D] {
        let anfrageDaten: [String: Any] = [
            "shape": teil.map { ["lat": $0.lat, "lon": $0.lon, "time": Int($0.zeit)] },
            "costing": art.valhallaProfil,
            "shape_match": "map_snap",
            "use_timestamps": !duennBesetzt,
            "directions_type": "none",
            "trace_options": [
                "search_radius": duennBesetzt ? 60 : (art == .auto ? 40 : 25),
                "gps_accuracy": duennBesetzt ? 30 : 10,
                "breakage_distance": duennBesetzt ? 10000 : 3000,
                "interpolation_distance": 10
            ]
        ]
        var anfrage = URLRequest(url: basis.appendingPathComponent("trace_route"))
        anfrage.httpMethod = "POST"
        anfrage.setValue("application/json", forHTTPHeaderField: "Content-Type")
        anfrage.httpBody = try JSONSerialization.data(withJSONObject: anfrageDaten)
        anfrage.timeoutInterval = 120

        let (daten, antwort) = try await URLSession.shared.data(for: anfrage)
        let json = try? JSONSerialization.jsonObject(with: daten) as? [String: Any]
        guard (antwort as? HTTPURLResponse)?.statusCode == 200,
              let trip = json?["trip"] as? [String: Any],
              let legs = trip["legs"] as? [[String: Any]] else {
            throw Fehler(text: (json?["error"] as? String) ?? "Unerwartete Antwort vom Server")
        }
        var linie: [CLLocationCoordinate2D] = []
        for leg in legs {
            if let shape = leg["shape"] as? String {
                linie.append(contentsOf: Polyline.dekodieren(shape, faktor: 1e6))
            }
        }
        return linie
    }

    /// Berechnet den Weg zwischen den Punkten mit /route (höchstens 20 Punkte pro Anfrage).
    private func teilRouten(_ teil: [Punkt], art: FahrtArt) async throws -> [CLLocationCoordinate2D] {
        var linie: [CLLocationCoordinate2D] = []
        var start = 0
        while start < teil.count - 1 {
            let ende = min(start + 20, teil.count)
            let stueck = Array(teil[start..<ende])
            let anfrageDaten: [String: Any] = [
                "locations": stueck.enumerated().map { i, p in
                    ["lat": p.lat, "lon": p.lon, "type": (i == 0 || i == stueck.count - 1) ? "break" : "through", "radius": 50]
                },
                "costing": art.valhallaProfil,
                "directions_type": "none"
            ]
            var anfrage = URLRequest(url: basis.appendingPathComponent("route"))
            anfrage.httpMethod = "POST"
            anfrage.setValue("application/json", forHTTPHeaderField: "Content-Type")
            anfrage.httpBody = try JSONSerialization.data(withJSONObject: anfrageDaten)
            anfrage.timeoutInterval = 60
            let (daten, antwort) = try await URLSession.shared.data(for: anfrage)
            let json = try? JSONSerialization.jsonObject(with: daten) as? [String: Any]
            guard (antwort as? HTTPURLResponse)?.statusCode == 200,
                  let trip = json?["trip"] as? [String: Any],
                  let legs = trip["legs"] as? [[String: Any]] else {
                throw Fehler(text: (json?["error"] as? String) ?? "Kein Weg gefunden")
            }
            var teilLinie: [CLLocationCoordinate2D] = []
            for leg in legs {
                if let shape = leg["shape"] as? String {
                    teilLinie.append(contentsOf: Polyline.dekodieren(shape, faktor: 1e6))
                }
            }
            if !linie.isEmpty && !teilLinie.isEmpty { teilLinie.removeFirst() }
            linie.append(contentsOf: teilLinie)
            start = ende - 1
        }
        return linie
    }

    static func mittlererAbstand(_ punkte: [Punkt]) -> Double {
        guard punkte.count > 1 else { return 0 }
        var summe = 0.0
        for i in 1..<punkte.count {
            let a = CLLocation(latitude: punkte[i - 1].lat, longitude: punkte[i - 1].lon)
            let b = CLLocation(latitude: punkte[i].lat, longitude: punkte[i].lon)
            summe += a.distance(from: b)
        }
        return summe / Double(punkte.count - 1)
    }

    static func ausduennen(_ punkte: [Punkt], abstand: Double) -> [Punkt] {
        guard var letzter = punkte.first else { return [] }
        var ergebnis = [letzter]
        for p in punkte.dropFirst() {
            let a = CLLocation(latitude: letzter.lat, longitude: letzter.lon)
            let b = CLLocation(latitude: p.lat, longitude: p.lon)
            if a.distance(from: b) >= abstand {
                ergebnis.append(p)
                letzter = p
            }
        }
        if let ende = punkte.last, ergebnis.last?.zeit != ende.zeit {
            ergebnis.append(ende)
        }
        return ergebnis
    }
}

/// Dekodiert Googles/Valhallas „encoded polyline“ (Valhalla nutzt 6 Nachkommastellen).
enum Polyline {
    static func dekodieren(_ text: String, faktor: Double) -> [CLLocationCoordinate2D] {
        let bytes = Array(text.utf8)
        var index = 0
        var lat = 0
        var lon = 0
        var ergebnis: [CLLocationCoordinate2D] = []

        func naechsterWert() -> Int? {
            var ergebnis = 0
            var verschiebung = 0
            while index < bytes.count {
                let b = Int(bytes[index]) - 63
                index += 1
                ergebnis |= (b & 0x1F) << verschiebung
                verschiebung += 5
                if b < 0x20 {
                    return (ergebnis & 1) != 0 ? ~(ergebnis >> 1) : (ergebnis >> 1)
                }
            }
            return nil
        }

        while index < bytes.count {
            guard let dLat = naechsterWert(), let dLon = naechsterWert() else { break }
            lat += dLat
            lon += dLon
            ergebnis.append(CLLocationCoordinate2D(latitude: Double(lat) / faktor, longitude: Double(lon) / faktor))
        }
        return ergebnis
    }
}
