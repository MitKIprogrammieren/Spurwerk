import Foundation
import SwiftData
import CoreLocation

/// Gleicht die Strecken mit dem Spurwerk-Server auf dem NUC ab:
/// neue und geänderte Strecken hochladen, fertig berechnete Linien abholen.
/// Läuft in einem eigenen Datenbank-Kontext im Hintergrund.
@ModelActor
actor SyncArbeiter {

    struct Fehler: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    /// Lädt alle Strecken hoch, die der Server noch nicht (aktuell) hat. Gibt die Anzahl zurück.
    func hochladen(server: URL, fortschritt: @Sendable (Int, Int) async -> Void) async throws -> Int {
        let bekannt = Set((try await Self.holen(server.appendingPathComponent("api/bekannt"))["ids"] as? [String]) ?? [])
        let beschreibung = FetchDescriptor<Fahrt>(predicate: #Predicate { $0.mussHoch == true && $0.statusText != "aufnahme" })
        let ids = try modelContext.fetchIdentifiers(beschreibung)
        guard !ids.isEmpty else { return 0 }

        var gesendet = 0
        var stapel: [[String: Any]] = []
        var modelle: [Fahrt] = []

        func abschicken() async throws {
            guard !stapel.isEmpty else { return }
            _ = try await Self.senden(["strecken": stapel], an: server.appendingPathComponent("api/hochladen"))
            for m in modelle { m.mussHoch = false }
            try? modelContext.save()
            gesendet += stapel.count
            stapel = []
            modelle = []
            await fortschritt(gesendet, ids.count)
        }

        for id in ids {
            guard let f = modelContext.model(for: id) as? Fahrt else { continue }
            var e: [String: Any] = [
                "id": f.id.uuidString,
                "art": f.artText,
                "start": f.start.timeIntervalSince1970,
                "ende": (f.ende ?? f.start).timeIntervalSince1970,
                "distanz": f.distanzMeter,
                "quelle": f.quelle,
                "punkte": f.punkte.map { [$0.lat, $0.lon, $0.zeit] }
            ]
            if f.status == .fertig, let spur = f.spur {
                // Schon auf dem iPhone abgeglichen – der NUC muss nicht noch einmal rechnen
                e["spur"] = spur.map { [$0.latitude, $0.longitude] }
            } else if bekannt.contains(f.id.uuidString) {
                e["neu_abgleichen"] = true
            }
            stapel.append(e)
            modelle.append(f)
            if stapel.count >= 100 { try await abschicken() }
        }
        try await abschicken()
        return gesendet
    }

    /// Holt die Linien ab, die der NUC seit dem letzten Mal fertig berechnet hat.
    func abholen(server: URL, seit: Double) async throws -> (anzahl: Int, stand: Double) {
        var stand = seit
        var anzahl = 0
        while true {
            var teile = URLComponents(url: server.appendingPathComponent("api/abholen"), resolvingAgainstBaseURL: false)!
            teile.queryItems = [URLQueryItem(name: "seit", value: String(stand))]
            let liste = (try await Self.holen(teile.url!)["strecken"] as? [[String: Any]]) ?? []
            if liste.isEmpty { break }
            for e in liste {
                if let g = e["geaendert"] as? Double { stand = max(stand, g) }
                guard let text = e["id"] as? String, let uuid = UUID(uuidString: text) else { continue }
                var suche = FetchDescriptor<Fahrt>(predicate: #Predicate { $0.id == uuid })
                suche.fetchLimit = 1
                guard let f = try modelContext.fetch(suche).first else { continue }
                if f.mussHoch { continue }                 // hier geändert, aber noch nicht hochgeladen
                let fertig = (e["status"] as? String) == "fertig"
                if fertig && f.status == .fertig { continue } // hatten wir schon
                if fertig, let s = e["spur"] as? String {
                    f.spur = Polyline.dekodieren(s, faktor: 1e6)
                    f.status = .fertig
                    f.fehlertext = nil
                } else if !fertig {
                    f.status = .fehler
                    f.fehlertext = e["fehler"] as? String
                }
                anzahl += 1
            }
            try? modelContext.save()
            if liste.count < 500 { break }
        }
        return (anzahl, stand)
    }

    // MARK: - Netz

    static func holen(_ url: URL) async throws -> [String: Any] {
        var anfrage = URLRequest(url: url)
        anfrage.timeoutInterval = 60
        let (daten, antwort) = try await URLSession.shared.data(for: anfrage)
        guard (antwort as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: daten) as? [String: Any] else {
            throw Fehler(text: "Spurwerk-Server antwortet nicht richtig")
        }
        return json
    }

    static func senden(_ inhalt: [String: Any], an url: URL) async throws -> [String: Any] {
        var anfrage = URLRequest(url: url)
        anfrage.httpMethod = "POST"
        anfrage.setValue("application/json", forHTTPHeaderField: "Content-Type")
        anfrage.httpBody = try JSONSerialization.data(withJSONObject: inhalt)
        anfrage.timeoutInterval = 180
        let (daten, antwort) = try await URLSession.shared.data(for: anfrage)
        guard (antwort as? HTTPURLResponse)?.statusCode == 200 else {
            let text = (try? JSONSerialization.jsonObject(with: daten) as? [String: Any])?["error"] as? String
            throw Fehler(text: text ?? "Hochladen fehlgeschlagen")
        }
        return (try? JSONSerialization.jsonObject(with: daten) as? [String: Any]) ?? [:]
    }
}

/// Einmalige Nacharbeit nach dem Update: Dichte berechnen und falsch erkannte Google-„Fahrräder“ korrigieren.
@ModelActor
actor Wartung {
    func einmalig() -> Int {
        let ids = (try? modelContext.fetchIdentifiers(FetchDescriptor<Fahrt>())) ?? []
        var korrigiert = 0
        var n = 0
        for id in ids {
            guard let f = modelContext.model(for: id) as? Fahrt, f.status != .aufnahme else { continue }
            if f.dichte == 0 { f.dichte = mittlererAbstand(f.punkte) }
            if f.quelle == "google" && f.art == .rad {
                let neu = FahrtArt.plausibel(.rad, meter: f.distanzMeter, sekunden: f.dauer)
                if neu != .rad {
                    f.artAendern(neu)
                    korrigiert += 1
                }
            }
            n += 1
            if n % 300 == 0 { try? modelContext.save() }
        }
        try? modelContext.save()
        return korrigiert
    }
}
