import Foundation
import CoreLocation

/// Exportiert eine Fahrt als GPX-Datei (abgeglichene Spur und rohe Punkte mit Zeit).
enum GPX {
    static func datei(fuer fahrt: Fahrt) throws -> URL {
        let iso = ISO8601DateFormatter()
        var text = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Spurwerk" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata><time>\(iso.string(from: fahrt.start))</time></metadata>

        """
        if let spur = fahrt.spur, !spur.isEmpty {
            text += "  <trk><name>Spur (auf Straße)</name><trkseg>\n"
            for k in spur {
                text += "    <trkpt lat=\"\(k.latitude)\" lon=\"\(k.longitude)\"/>\n"
            }
            text += "  </trkseg></trk>\n"
        }
        text += "  <trk><name>GPS roh</name><trkseg>\n"
        for p in fahrt.punkte {
            let zeit = iso.string(from: Date(timeIntervalSince1970: p.zeit))
            text += "    <trkpt lat=\"\(p.lat)\" lon=\"\(p.lon)\"><time>\(zeit)</time></trkpt>\n"
        }
        text += "  </trkseg></trk>\n</gpx>\n"

        let namensformat = DateFormatter()
        namensformat.dateFormat = "yyyy-MM-dd_HH-mm"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Spurwerk_\(namensformat.string(from: fahrt.start)).gpx")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
