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

    init(start: Date) {
        self.start = start
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
    static func km(_ meter: Double) -> String {
        if meter < 1000 { return "\(Int(meter)) m" }
        return String(format: "%.1f km", meter / 1000).replacingOccurrences(of: ".", with: ",")
    }

    static func dauer(_ sekunden: TimeInterval) -> String {
        let min = Int(sekunden) / 60
        if min < 60 { return "\(min) min" }
        return "\(min / 60) h \(min % 60) min"
    }
}
