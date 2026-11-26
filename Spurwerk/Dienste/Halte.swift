import Foundation
import SwiftUI
import CoreLocation
import MapKit

/// Ein Aufenthalt zwischen zwei Strecken.
/// Parken: von einer Autofahrt bis zur nächsten Autofahrt (dazwischen darf man zu Fuß unterwegs sein).
/// Halt: Pause nach einer Fuß- oder Radstrecke, bevor die nächste Strecke beginnt.
struct Halt: Identifiable, Hashable, Sendable {
    let nachFahrt: UUID
    let lat: Double
    let lon: Double
    let von: Date
    let bis: Date?          // nil = dauert noch an (Auto steht noch)
    let parken: Bool

    var id: String { "\(nachFahrt.uuidString)-\(parken)" }
    /// Kurzer Halt zwischen zwei Wegen zu Fuß/Rad (Kaffee, Einkauf …)
    var pause: Bool { !parken && bis != nil && dauer < 60 * 60 }
    var koordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
    var dauer: TimeInterval { (bis ?? Date()).timeIntervalSince(von) }

    var titel: String {
        if parken { return bis != nil && dauer < 15 * 60 ? "Kurzer Halt" : "Geparkt" }
        return pause ? "Pause" : "Aufenthalt"
    }

    var zeitText: String {
        let de = Locale(identifier: "de_DE")
        let uhr = Date.FormatStyle.dateTime.hour().minute().locale(de)
        let tag = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.twoDigits).hour().minute().locale(de)
        guard let bis else { return "seit \(von.formatted(Calendar.current.isDateInToday(von) ? uhr : tag)) · \(Format.dauer(dauer))" }
        let gleicherTag = Calendar.current.isDate(von, inSameDayAs: bis)
        let a = von.formatted(gleicherTag ? uhr : tag)
        let b = bis.formatted(gleicherTag ? uhr : tag)
        return "\(a)–\(b) · \(Format.dauer(dauer))"
    }

    /// Strecken-Kurzform, aus der die Halte berechnet werden.
    struct Stueck: Sendable {
        let id: UUID
        let art: FahrtArt
        let start: Date
        let ende: Date
        let startLat: Double
        let startLon: Double
        let zielLat: Double
        let zielLon: Double
    }

    static func meter(_ aLat: Double, _ aLon: Double, _ bLat: Double, _ bLon: Double) -> Double {
        let dy = (bLat - aLat) * 111_320
        let dx = (bLon - aLon) * 111_320 * cos(aLat * .pi / 180)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Leitet alle Halte aus den Strecken ab (nach Startzeit sortiert übergeben).
    static func berechnen(_ s: [Stueck]) -> [Halt] {
        var halte: [Halt] = []
        // Für jede Autofahrt die nächste Autofahrt finden
        var naechstesAuto = [Int?](repeating: nil, count: s.count)
        var letztes: Int?
        for i in stride(from: s.count - 1, through: 0, by: -1) {
            naechstesAuto[i] = letztes
            if s[i].art == .auto { letztes = i }
        }
        for i in s.indices {
            let a = s[i]
            if a.art == .auto {
                let bis = naechstesAuto[i].map { s[$0].start }
                if let j = naechstesAuto[i] {
                    let d = s[j].start.timeIntervalSince(a.ende)
                    guard d >= 3 * 60, d <= 30 * 86_400 else { continue }
                    // Die nächste Autofahrt muss dort losgehen, wo das Auto stand – sonst fehlt
                    // dazwischen nur ein Stück Aufzeichnung, und es war kein Parken.
                    guard meter(a.zielLat, a.zielLon, s[j].startLat, s[j].startLon) <= 1000 else { continue }
                }
                halte.append(Halt(nachFahrt: a.id, lat: a.zielLat, lon: a.zielLon, von: a.ende, bis: bis, parken: true))
            } else if i + 1 < s.count {
                let d = s[i + 1].start.timeIntervalSince(a.ende)
                guard d >= 2 * 60, d <= 2 * 86_400 else { continue }
                guard meter(a.zielLat, a.zielLon, s[i + 1].startLat, s[i + 1].startLon) <= 500 else { continue }
                halte.append(Halt(nachFahrt: a.id, lat: a.zielLat, lon: a.zielLon, von: a.ende, bis: s[i + 1].start, parken: false))
            }
        }
        return ohneDoppelte(halte)
    }

    /// Ein Aufenthalt, der in die Parkzeit am selben Ort fällt, wird nicht extra gezeigt
    /// (z. B. Auto geparkt, zu Fuß unterwegs, wieder am Auto) – das Parken sagt schon alles.
    private static func ohneDoppelte(_ halte: [Halt]) -> [Halt] {
        let parken = halte.filter(\.parken).sorted { $0.von < $1.von }
        guard !parken.isEmpty else { return halte }
        return halte.filter { h in
            guard !h.parken else { return true }
            // letztes Parken, das vor diesem Aufenthalt begann
            var lo = 0, hi = parken.count
            while lo < hi {
                let m = (lo + hi) / 2
                if parken[m].von <= h.von { lo = m + 1 } else { hi = m }
            }
            for k in stride(from: lo - 1, through: max(0, lo - 3), by: -1) {
                let p = parken[k]
                let ende = p.bis ?? .distantFuture
                let hEnde = h.bis ?? h.von
                if ende >= hEnde.addingTimeInterval(-60),
                   meter(p.lat, p.lon, h.lat, h.lon) <= 100 {
                    return false
                }
            }
            return true
        }
    }
}

/// Ein bekannter Ort aus der Google-Zeitachse („Zuhause“, „Arbeit“, Name eines Ladens …).
struct OrtBesuch: Codable, Sendable {
    let lat: Double
    let lon: Double
    let name: String
}

/// Ortsnamen für Halte: zuerst bekannte Orte aus Google, sonst Straße per Apple-Geocoder.
/// Ergebnisse werden auf dem iPhone gespeichert, damit jede Adresse nur einmal nachgeschlagen wird.
@MainActor
final class OrtNamen: ObservableObject {
    static let shared = OrtNamen()

    @Published private(set) var version = 0
    private var namen: [String: String] = [:]
    private var besuche: [OrtBesuch] = []
    private var offen: [(String, CLLocationCoordinate2D)] = []
    private var laeuft = false
    private var speichernGeplant = false
    private let geocoder = CLGeocoder()

    private struct Datei: Codable {
        var namen: [String: String]
        var besuche: [OrtBesuch]
    }

    private static var dateiURL: URL {
        let ordner = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        return ordner.appendingPathComponent("ortnamen.json")
    }

    init() {
        if let d = try? Data(contentsOf: Self.dateiURL), let datei = try? JSONDecoder().decode(Datei.self, from: d) {
            namen = datei.namen
            besuche = datei.besuche
        }
    }

    private static func schluessel(_ lat: Double, _ lon: Double) -> String {
        String(format: "%.4f,%.4f", lat, lon)
    }

    func name(_ lat: Double, _ lon: Double) -> String? {
        if let b = bekannterOrt(lat, lon) { return b }
        let n = namen[Self.schluessel(lat, lon)]
        return (n?.isEmpty ?? true) ? nil : n
    }

    /// Sucht den Namen im Hintergrund, falls er noch fehlt (höchstens etwa ein Ort pro Sekunde).
    func anfragen(_ lat: Double, _ lon: Double) {
        let k = Self.schluessel(lat, lon)
        guard namen[k] == nil, bekannterOrt(lat, lon) == nil, !offen.contains(where: { $0.0 == k }) else { return }
        offen.append((k, CLLocationCoordinate2D(latitude: lat, longitude: lon)))
        if offen.count > 40 { offen.removeFirst(offen.count - 40) }
        if !laeuft { abarbeiten() }
    }

    /// Orte aus einem Google-Import übernehmen.
    func hinzufuegen(_ neu: [OrtBesuch]) {
        guard !neu.isEmpty else { return }
        var bekannt = Set(besuche.map { Self.schluessel($0.lat, $0.lon) })
        for b in neu where bekannt.insert(Self.schluessel(b.lat, b.lon)).inserted {
            besuche.append(b)
        }
        version &+= 1
        orteVersion &+= 1
        speichern()
    }

    /// Zählt hoch, wenn neue Google-Orte dazukommen (dann Halte neu einrasten).
    @Published private(set) var orteVersion = 0

    private func bekannterOrt(_ lat: Double, _ lon: Double) -> String? {
        let kx = cos(lat * .pi / 180) * 111_320
        var bester: (Double, String)?
        for b in besuche {
            let dy = (b.lat - lat) * 111_320
            guard abs(dy) < 120 else { continue }
            let dx = (b.lon - lon) * kx
            let d = dx * dx + dy * dy
            if !b.name.isEmpty, d < 120 * 120, d < (bester?.0 ?? .infinity) { bester = (d, b.name) }
        }
        return bester?.1
    }

    private func abarbeiten() {
        laeuft = true
        Task {
            var fehlschlaege = 0
            while let (k, ort) = offen.popLast() {
                do {
                    let marken = try await geocoder.reverseGeocodeLocation(
                        CLLocation(latitude: ort.latitude, longitude: ort.longitude),
                        preferredLocale: Locale(identifier: "de_DE"))
                    namen[k] = marken.first.map(Self.text) ?? ""
                    fehlschlaege = 0
                    version &+= 1
                    speichern()
                    try? await Task.sleep(for: .milliseconds(1200))
                } catch {
                    // meist zu viele Anfragen – kurz warten und später weitermachen
                    fehlschlaege += 1
                    if fehlschlaege >= 3 { offen.removeAll(); break }
                    offen.append((k, ort))
                    try? await Task.sleep(for: .seconds(20))
                }
            }
            laeuft = false
        }
    }

    private static func text(_ p: CLPlacemark) -> String {
        if let strasse = p.thoroughfare {
            return p.subThoroughfare.map { "\(strasse) \($0)" } ?? strasse
        }
        return p.name ?? p.locality ?? ""
    }

    private func speichern() {
        guard !speichernGeplant else { return }
        speichernGeplant = true
        Task {
            try? await Task.sleep(for: .seconds(3))
            speichernGeplant = false
            if let d = try? JSONEncoder().encode(Datei(namen: namen, besuche: besuche)) {
                try? d.write(to: Self.dateiURL, options: .atomic)
            }
        }
    }
}

// MARK: - Darstellung

extension Halt {
    static let parkFarbe = Color(red: 0.52, green: 0.72, blue: 0.92)
    static let haltFarbe = Color(red: 0.94, green: 0.62, blue: 0.15)
}

/// Rundes „P“ fürs Parken, Pause-Symbol für Halte.
struct HaltSymbol: View {
    let parken: Bool
    var pause = false

    var body: some View {
        if parken {
            Text("P")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color(red: 0.11, green: 0.23, blue: 0.36)))
                .overlay(Circle().strokeBorder(Halt.parkFarbe, lineWidth: 1.5))
        } else if pause {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 15))
                .foregroundStyle(Halt.haltFarbe)
                .frame(width: 22, height: 22)
        } else {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Halt.haltFarbe)
        }
    }
}

struct HaltZeile: View {
    let halt: Halt
    var eingerueckt = false
    @ObservedObject private var namen = OrtNamen.shared

    var body: some View {
        let name = namen.name(halt.lat, halt.lon)
        HStack(spacing: 12) {
            if eingerueckt { ParkEinzug() }
            HaltSymbol(parken: halt.parken, pause: halt.pause)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(name.map { "\(halt.titel) · \($0)" } ?? halt.titel)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(halt.zeitText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .listRowBackground((halt.parken ? Halt.parkFarbe : Halt.haltFarbe).opacity(0.08))
        .task { namen.anfragen(halt.lat, halt.lon) }
    }
}

/// Senkrechte Linie in Park-Farbe: diese Zeile war, während das Auto stand.
struct ParkEinzug: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Halt.parkFarbe.opacity(0.7))
            .frame(width: 3)
            .padding(.vertical, -12)
            .padding(.leading, 2)
    }
}

/// Kartenmarker für einen Halt.
final class HaltMarke: NSObject, MKAnnotation {
    let halt: Halt
    let coordinate: CLLocationCoordinate2D
    @objc dynamic var title: String?
    @objc dynamic var subtitle: String?

    init(_ halt: Halt, name: String?) {
        self.halt = halt
        self.coordinate = halt.koordinate
        self.title = name.map { "\(halt.titel) · \($0)" } ?? halt.titel
        self.subtitle = halt.zeitText
    }

    @MainActor static let bildParken: UIImage = bild(parken: true)
    @MainActor static let bildHalt: UIImage = bild(parken: false)

    private static func bild(parken: Bool) -> UIImage {
        let groesse: CGFloat = parken ? 24 : 16
        return UIGraphicsImageRenderer(size: CGSize(width: groesse, height: groesse)).image { _ in
            let rect = CGRect(x: 1, y: 1, width: groesse - 2, height: groesse - 2)
            let kreis = UIBezierPath(ovalIn: rect)
            if parken {
                UIColor(red: 0.11, green: 0.23, blue: 0.36, alpha: 1).setFill()
                kreis.fill()
                UIColor(red: 0.52, green: 0.72, blue: 0.92, alpha: 1).setStroke()
                kreis.lineWidth = 1.5
                kreis.stroke()
                let text = NSAttributedString(string: "P", attributes: [
                    .font: UIFont.systemFont(ofSize: 13, weight: .bold),
                    .foregroundColor: UIColor.white,
                ])
                let g = text.size()
                text.draw(at: CGPoint(x: (groesse - g.width) / 2, y: (groesse - g.height) / 2))
            } else {
                UIColor(red: 0.94, green: 0.62, blue: 0.15, alpha: 1).setFill()
                kreis.fill()
                UIColor.black.withAlphaComponent(0.5).setStroke()
                kreis.lineWidth = 1.5
                kreis.stroke()
            }
        }
    }
}
