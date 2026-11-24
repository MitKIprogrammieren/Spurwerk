import Foundation
import SwiftData
import CoreLocation

/// Ein roher GPS-Punkt, so wie das iPhone ihn liefert.
struct Punkt: Codable {
    var lat: Double
    var lon: Double
    var zeit: Double          // Sekunden seit 1970
    var genauigkeit: Double   // Meter
    var tempo: Double         // m/s, -1 = unbekannt
}

enum FahrtStatus: String {
    case aufnahme   // läuft gerade
    case wartet     // fertig aufgenommen, noch nicht auf Straßen gelegt
    case fertig     // auf Straßen gelegt
    case fehler     // Abgleich fehlgeschlagen
}

/// Womit die Strecke zurückgelegt wurde – bestimmt Farbe und welche Wege Valhalla benutzen darf.
enum FahrtArt: String, CaseIterable, Identifiable {
    case auto, fuss, rad

    var id: String { rawValue }

    var name: String {
        switch self {
        case .auto: "Auto"
        case .fuss: "Zu Fuß"
        case .rad: "Fahrrad"
        }
    }

    var symbol: String {
        switch self {
        case .auto: "car.fill"
        case .fuss: "figure.walk"
        case .rad: "bicycle"
        }
    }

    /// Profil für Valhalla: Fußgänger dürfen Gehwege und Pfade, Autos nur Straßen.
    var valhallaProfil: String {
        switch self {
        case .auto: "auto"
        case .fuss: "pedestrian"
        case .rad: "bicycle"
        }
    }

    /// Kürzere Strecken werden verworfen (z. B. der Weg zum Briefkasten).
    var mindestStrecke: Double {
        switch self {
        case .auto: 300
        case .fuss: 150
        case .rad: 200
        }
    }
}

@Model
final class Fahrt {
    var id: UUID = UUID()
    var start: Date = Date()
    var ende: Date?
    @Attribute(.externalStorage) var rohDaten: Data = Data()
    @Attribute(.externalStorage) var spurDaten: Data?
    var distanzMeter: Double = 0
    var statusText: String = FahrtStatus.aufnahme.rawValue
    var fehlertext: String?
    var artText: String = "auto"
    /// „app“ = selbst aufgezeichnet, „google“ = aus der Google-Zeitachse importiert
    var quelle: String = "app"
    /// Mittlerer Abstand der GPS-Punkte in Metern (0 = noch nicht berechnet). Groß = lückenhaft = geschätzt.
    var dichte: Double = 0
    /// Muss (noch einmal) an den Spurwerk-Server geschickt werden.
    var mussHoch: Bool = true

    init(start: Date, art: FahrtArt = .auto) {
        self.start = start
        self.artText = art.rawValue
    }

    var art: FahrtArt {
        get { FahrtArt(rawValue: artText) ?? .auto }
        set { artText = newValue.rawValue }
    }

    var status: FahrtStatus {
        get { FahrtStatus(rawValue: statusText) ?? .fehler }
        set { statusText = newValue.rawValue }
    }

    var punkte: [Punkt] {
        get { (try? JSONDecoder().decode([Punkt].self, from: rohDaten)) ?? [] }
        set { rohDaten = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    /// Die auf Straßen gelegte Linie (nil, solange nicht abgeglichen).
    var spur: [CLLocationCoordinate2D]? {
        get { spurDaten.map(Koordinaten.ausDaten) }
        set { spurDaten = newValue.map(Koordinaten.zuDaten) }
    }

    var rohKoordinaten: [CLLocationCoordinate2D] {
        punkte.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    var dauer: TimeInterval {
        (ende ?? Date()).timeIntervalSince(start)
    }

    /// Lückenhafte Google-Strecke: der Weg zwischen den Punkten ist geschätzt.
    var geschaetzt: Bool { dichte > 150 }

    /// Art ändern: wird danach mit dem passenden Profil neu auf die Straße gelegt.
    func artAendern(_ neu: FahrtArt) {
        guard neu != art else { return }
        art = neu
        if status == .fertig || status == .fehler { status = .wartet }
        mussHoch = true
    }
}

extension FahrtArt {
    /// Google rät die Verkehrsmittel oft falsch (Stau oder Bus als „Fahrrad“).
    /// Fahrrad gilt nur bei 8–25 km/h – schneller ist Auto, langsamer zu Fuß.
    static func plausibel(_ art: FahrtArt, meter: Double, sekunden: Double) -> FahrtArt {
        guard art == .rad, sekunden > 0, meter > 0 else { return art }
        let kmh = meter / sekunden * 3.6
        if kmh > 25 { return .auto }
        if kmh < 8 { return .fuss }
        return .rad
    }
}

func mittlererAbstand(_ punkte: [Punkt]) -> Double {
    guard punkte.count > 1 else { return 0 }
    var summe = 0.0
    for i in 1..<punkte.count {
        let a = punkte[i - 1], b = punkte[i]
        let dLat = (b.lat - a.lat) * 111_320
        let dLon = (b.lon - a.lon) * 111_320 * cos(a.lat * .pi / 180)
        summe += (dLat * dLat + dLon * dLon).squareRoot()
    }
    return summe / Double(punkte.count - 1)
}

/// Speichert Koordinaten kompakt als Binärdaten (schneller als JSON).
enum Koordinaten {
    static func zuDaten(_ liste: [CLLocationCoordinate2D]) -> Data {
        var werte = [Double]()
        werte.reserveCapacity(liste.count * 2)
        for k in liste {
            werte.append(k.latitude)
            werte.append(k.longitude)
        }
        return werte.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func ausDaten(_ daten: Data) -> [CLLocationCoordinate2D] {
        var werte = [Double](repeating: 0, count: daten.count / MemoryLayout<Double>.size)
        _ = werte.withUnsafeMutableBytes { daten.copyBytes(to: $0) }
        var ergebnis = [CLLocationCoordinate2D]()
        ergebnis.reserveCapacity(werte.count / 2)
        var i = 0
        while i + 1 < werte.count {
            ergebnis.append(CLLocationCoordinate2D(latitude: werte[i], longitude: werte[i + 1]))
            i += 2
        }
        return ergebnis
    }
}

enum Format {
    private static let zahl: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        return f
    }()

    static func km(_ meter: Double) -> String {
        if meter < 1000 { return "\(Int(meter)) m" }
        let km = meter / 1000
        zahl.minimumFractionDigits = km < 1000 ? 1 : 0
        zahl.maximumFractionDigits = km < 1000 ? 1 : 0
        return (zahl.string(from: NSNumber(value: km)) ?? "\(Int(km))") + " km"
    }

    static func anzahl(_ n: Int) -> String {
        zahl.minimumFractionDigits = 0
        zahl.maximumFractionDigits = 0
        return zahl.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func dauer(_ sekunden: TimeInterval) -> String {
        let min = Int(sekunden) / 60
        if min < 60 { return "\(min) min" }
        return "\(min / 60) h \(min % 60) min"
    }
}
