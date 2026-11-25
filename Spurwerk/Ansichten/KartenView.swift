import SwiftUI
import SwiftData
import MapKit

extension FahrtArt {
    /// Grundfarbe (Schein, Symbole): Auto türkis, zu Fuß lila, Fahrrad korallrot.
    var farbe: Color { Color(uiColor: uiFarbe) }
    var hell: Color { Color(uiColor: uiHell) }

    var uiFarbe: UIColor {
        switch self {
        case .auto: UIColor(red: 0.11, green: 0.62, blue: 0.46, alpha: 1)
        case .fuss: UIColor(red: 0.50, green: 0.47, blue: 0.87, alpha: 1)
        case .rad: UIColor(red: 0.85, green: 0.35, blue: 0.19, alpha: 1)
        }
    }

    /// Hellere Farbe für den Kern der Linie – leuchtet auf der gedämpften Karte.
    var uiHell: UIColor {
        switch self {
        case .auto: UIColor(red: 0.36, green: 0.79, blue: 0.65, alpha: 1)
        case .fuss: UIColor(red: 0.69, green: 0.66, blue: 0.93, alpha: 1)
        case .rad: UIColor(red: 0.94, green: 0.60, blue: 0.48, alpha: 1)
        }
    }

    /// Dunkle Kachelfarbe für die Tageskarte.
    var kachel: Color {
        switch self {
        case .auto: Color(red: 0.13, green: 0.21, blue: 0.18)
        case .fuss: Color(red: 0.18, green: 0.17, blue: 0.27)
        case .rad: Color(red: 0.25, green: 0.16, blue: 0.13)
        }
    }
}

/// Strecken einer Art und eines Zustands in einem Kartenbereich – zusammengefasst zu EINER Kartenlinie.
/// Kleine Bereiche sorgen dafür, dass MapKit beim Verschieben nur die Linien zeichnet, die wirklich zu sehen sind.
struct SpurGruppe: @unchecked Sendable {
    let art: FahrtArt
    let abgeglichen: Bool
    let geschaetzt: Bool
    let schluessel: String          // ändert sich, sobald sich der Inhalt ändert
    let linien: [MKPolyline]
}

/// Liest die Strecken im Hintergrund und baut daraus Kartenlinien, Halte und Summen für den gewählten Zeitraum.
@MainActor
final class SpurCache: ObservableObject {
    static let shared = SpurCache()

    /// Linien für die nahe Ansicht (genau)
    @Published private(set) var gruppenFein: [SpurGruppe] = []
    /// Linien für die weite Ansicht: grob vereinfacht und ohne doppelte Straßen
    @Published private(set) var gruppenGrob: [SpurGruppe] = []
    /// Kilometer je Art im gewählten Zeitraum (ohne laufende Aufnahme)
    @Published private(set) var summen: [FahrtArt: Double] = [:]
    @Published private(set) var anzahl: [FahrtArt: Int] = [:]
    /// Ausschnitt, der alle Strecken des Zeitraums zeigt
    @Published private(set) var ausschnitt: MKMapRect?
    @Published private(set) var geladen = false
    /// Zählt hoch, sobald die Linien für einen neuen Zeitraum fertig sind
    @Published private(set) var fertigNr = 0
    /// Halte und Parkplätze im Zeitraum (für die Karte, höchstens 1.500)
    @Published private(set) var halte: [Halt] = []
    /// Halt direkt nach einer Strecke (für die Liste)
    @Published private(set) var halteNach: [UUID: Halt] = [:]
    /// Das Auto steht noch hier (letzte Autofahrt, höchstens drei Tage her)
    @Published private(set) var autoSteht: Halt?

    struct Eintrag: @unchecked Sendable {
        let kennung: String
        let art: FahrtArt
        let abgeglichen: Bool
        let geschaetzt: Bool
        let start: Date
        let ende: Date
        let distanz: Double
        let linie: MKPolyline
        let fein: [CLLocationCoordinate2D]
        let grob: [CLLocationCoordinate2D]
        let anfang: CLLocationCoordinate2D
        let ziel: CLLocationCoordinate2D
    }

    private struct Roh: @unchecked Sendable {
        let id: UUID
        let kennung: String
        let art: FahrtArt
        let abgeglichen: Bool
        let geschaetzt: Bool
        let start: Date
        let ende: Date
        let distanz: Double
        let daten: Data
        let roh: Data
    }

    private var eintraege: [UUID: Eintrag] = [:]
    private var alleHalte: [Halt] = []
    private var laeuft = false
    private var nochmal = false
    private var von = Date.distantPast
    private var bis = Date.distantFuture
    private var artFilter: FahrtArt?
    private var bauNr = 0

    /// Zeitraum oder Art geändert – nur neu gruppieren, nichts neu laden.
    func filtern(von: Date, bis: Date, art: FahrtArt?) {
        self.von = von
        self.bis = bis
        self.artFilter = art
        gruppenBauen()
    }

    func aktualisieren(container: ModelContainer?) {
        guard let container else { return }
        if laeuft { nochmal = true; return }
        laeuft = true
        let bekannt = eintraege.mapValues(\.kennung)

        Task.detached(priority: .utility) {
            // Eigener Datenbank-Kontext im Hintergrund – die Oberfläche bleibt frei
            let context = ModelContext(container)
            let alle = (try? context.fetch(FetchDescriptor<Fahrt>())) ?? []
            var gueltig = Set<UUID>()
            var neu: [Roh] = []
            for f in alle where f.status != .aufnahme {
                gueltig.insert(f.id)
                let abgeglichen = f.status == .fertig && f.spurDaten != nil
                let kennung = "\(f.statusText)-\(f.artText)-\(f.geschaetzt)-\(Int(f.distanzMeter))-\(Int(f.ende?.timeIntervalSince1970 ?? 0))-\(f.spurVersion)"
                if bekannt[f.id] == kennung { continue }
                let daten = abgeglichen ? (f.spurDaten ?? Data()) : f.rohDaten
                neu.append(Roh(id: f.id, kennung: kennung, art: f.art, abgeglichen: abgeglichen,
                               geschaetzt: f.geschaetzt, start: f.start, ende: f.ende ?? f.start,
                               distanz: f.distanzMeter, daten: daten, roh: abgeglichen ? f.rohDaten : Data()))
            }
            var fertig: [(UUID, Eintrag)] = []
            fertig.reserveCapacity(neu.count)
            for r in neu {
                let punkte = r.abgeglichen ? Koordinaten.ausDaten(r.daten) : SpurCache.rohPunkte(r.daten)
                guard punkte.count > 1 else { continue }
                // Für Halte und Parkplätze zählen die echten Aufzeichnungspunkte: Der Straßenabgleich
                // zieht das Ende sonst gern auf die nächste Straße, z. B. die Autobahn neben dem Haus.
                let echt = r.abgeglichen ? SpurCache.rohPunkte(r.roh) : punkte
                guard let anfang = echt.first ?? punkte.first, let ziel = echt.last ?? punkte.last else { continue }
                let einfach = Vereinfachen.linie(punkte, toleranzMeter: 5)
                let linie = MKPolyline(coordinates: einfach, count: einfach.count)
                let grob = Vereinfachen.linie(einfach, toleranzMeter: 35)
                fertig.append((r.id, Eintrag(kennung: r.kennung, art: r.art, abgeglichen: r.abgeglichen,
                                             geschaetzt: r.geschaetzt, start: r.start, ende: r.ende,
                                             distanz: r.distanz, linie: linie, fein: einfach, grob: grob, anfang: anfang, ziel: ziel)))
            }
            let gueltigFest = gueltig
            await MainActor.run {
                self.eintraege = self.eintraege.filter { gueltigFest.contains($0.key) }
                for (id, e) in fertig { self.eintraege[id] = e }
                self.haltePruefen()
                self.geladen = true
                self.gruppenBauen()
                self.laeuft = false
                if self.nochmal {
                    self.nochmal = false
                    self.aktualisieren(container: container)
                }
            }
        }
    }

    /// Neue Google-Orte: Halte neu berechnen und einrasten.
    func halteNeu() {
        haltePruefen()
        gruppenBauen()
    }

    /// Halte aus allen Strecken ableiten (unabhängig vom Zeitraum).
    private func haltePruefen() {
        let stuecke = eintraege
            .map { Halt.Stueck(id: $0.key, art: $0.value.art, start: $0.value.start, ende: $0.value.ende,
                               startLat: $0.value.anfang.latitude, startLon: $0.value.anfang.longitude,
                               zielLat: $0.value.ziel.latitude, zielLon: $0.value.ziel.longitude) }
            .sorted { $0.start < $1.start }
        alleHalte = Halt.berechnen(stuecke)
        var nach: [UUID: Halt] = [:]
        for h in alleHalte { nach[h.nachFahrt] = h }
        halteNach = nach
        if let letzter = alleHalte.last(where: { $0.parken && $0.bis == nil }),
           letzter.von > Date().addingTimeInterval(-3 * 86_400) {
            autoSteht = letzter
        } else {
            autoSteht = nil
        }
    }

    private func gruppenBauen() {
        bauNr += 1
        let nr = bauNr
        let von = von, bis = bis, artFilter = artFilter
        let auswahl = eintraege.filter { $0.value.start >= von && $0.value.start < bis }

        var summen: [FahrtArt: Double] = [:]
        var anzahl: [FahrtArt: Int] = [:]
        for e in auswahl.values {
            summen[e.art, default: 0] += e.distanz
            anzahl[e.art, default: 0] += 1
        }
        self.summen = summen
        self.anzahl = anzahl

        // Halte im Zeitraum: Parken beim Auto, Halte bei Fuß/Rad
        let jetzt = Date()
        var sichtbar = alleHalte.filter { h in
            h.von < bis && (h.bis ?? jetzt) > von &&
            (artFilter == nil || (h.parken ? artFilter == .auto : artFilter != .auto))
        }
        if sichtbar.count > 1500 { sichtbar = Array(sichtbar.suffix(1500)) }
        halte = sichtbar

        let liste = auswahl.filter { artFilter == nil || $0.value.art == artFilter }.map { ($0.key, $0.value) }
        Task.detached(priority: .userInitiated) {
            let fein = SpurCache.feinBauen(liste)
            let grob = SpurCache.grobBauen(liste)
            var rect = MKMapRect.null
            for (_, e) in liste { rect = rect.union(e.linie.boundingMapRect) }
            let ergebnis = rect
            await MainActor.run {
                guard nr == self.bauNr else { return }   // inzwischen anderer Zeitraum gewählt
                self.gruppenFein = fein
                self.gruppenGrob = grob
                self.ausschnitt = ergebnis.isNull ? nil : ergebnis
                self.fertigNr &+= 1
            }
        }
    }

    /// Genaue Linien: doppelte Straßenstücke fallen weg (Raster etwa 25 m), der Rest wird in
    /// Kacheln von etwa 7 × 7 km aufgeteilt, damit MapKit nur zeichnet, was zu sehen ist.
    nonisolated static func feinBauen(_ liste: [(UUID, Eintrag)]) -> [SpurGruppe] {
        entdoppeln(liste.map(\.1), punkte: \.fein, gLat: 0.00023, gLon: 0.00037, kachel: (0.1, 0.06), praefix: "f")
    }

    /// Weite Ansicht: grob vereinfacht, Raster etwa 120 m, eine Gruppe je Art und Zustand.
    nonisolated static func grobBauen(_ liste: [(UUID, Eintrag)]) -> [SpurGruppe] {
        entdoppeln(liste.map(\.1), punkte: \.grob, gLat: 0.0011, gLon: 0.0018, kachel: nil, praefix: "g")
    }

    /// Wer 500-mal dieselbe Straße fährt, bekommt sie nur einmal gezeichnet: Die Karte wird in ein
    /// Raster geteilt; Abschnitte, deren Rasterfelder schon von einer anderen Strecke derselben Art
    /// belegt sind, fallen weg. Fertig abgeglichene Strecken haben Vorrang vor geschätzten und rohen.
    nonisolated static func entdoppeln(_ eintraege: [Eintrag], punkte: KeyPath<Eintrag, [CLLocationCoordinate2D]>,
                                       gLat: Double, gLon: Double, kachel: (Double, Double)?, praefix: String) -> [SpurGruppe] {
        func rang(_ e: Eintrag) -> Int { e.abgeglichen ? (e.geschaetzt ? 1 : 0) : 2 }
        let sortiert = eintraege.sorted { rang($0) == rang($1) ? $0.start > $1.start : rang($0) < rang($1) }

        var belegt: [FahrtArt: Set<Int64>] = [:]
        var teile: [String: (art: FahrtArt, abgeglichen: Bool, geschaetzt: Bool, linien: [MKPolyline], punkte: Int)] = [:]
        var eigene: [Int64] = []
        var lauf: [CLLocationCoordinate2D] = []

        for e in sortiert {
            let p = e[keyPath: punkte]
            guard p.count > 1 else { continue }
            // Menge herausnehmen, damit sie beim Ergänzen nicht jedes Mal kopiert wird
            var schon = belegt.removeValue(forKey: e.art) ?? []
            eigene.removeAll(keepingCapacity: true)
            lauf.removeAll(keepingCapacity: true)
            let basis = "\(praefix)-\(e.art.rawValue)-\(e.abgeglichen)-\(e.geschaetzt)"

            func abschliessen() {
                if lauf.count > 1 {
                    var s = basis
                    if let (kx, ky) = kachel {
                        s += "-\(Int((lauf[0].longitude / kx).rounded(.down)))-\(Int((lauf[0].latitude / ky).rounded(.down)))"
                    }
                    if teile[s] == nil { teile[s] = (e.art, e.abgeglichen, e.geschaetzt, [], 0) }
                    teile[s]!.linien.append(MKPolyline(coordinates: lauf, count: lauf.count))
                    teile[s]!.punkte += lauf.count
                }
                lauf.removeAll(keepingCapacity: true)
            }

            for i in 1..<p.count {
                let a = p[i - 1], b = p[i]
                let schritte = min(2000, max(1, Int(max(abs(b.latitude - a.latitude) / gLat,
                                                        abs(b.longitude - a.longitude) / gLon).rounded(.up))))
                var neu = false
                for k in 0...schritte {
                    let t = Double(k) / Double(schritte)
                    let la = a.latitude + (b.latitude - a.latitude) * t
                    let lo = a.longitude + (b.longitude - a.longitude) * t
                    let feld = Int64((la / gLat).rounded(.down)) * 10_000_000 + Int64((lo / gLon).rounded(.down) + 5_000_000)
                    eigene.append(feld)
                    if !neu, !schon.contains(feld) { neu = true }
                }
                if neu {
                    if lauf.isEmpty { lauf.append(a) }
                    lauf.append(b)
                } else {
                    abschliessen()
                }
            }
            abschliessen()
            schon.formUnion(eigene)
            belegt[e.art] = schon
        }
        return teile.compactMap { schluessel, t in
            guard !t.linien.isEmpty else { return nil }
            var hasher = Hasher()
            for l in t.linien.prefix(50) { hasher.combine(l.coordinate.latitude); hasher.combine(l.coordinate.longitude) }
            return SpurGruppe(art: t.art, abgeglichen: t.abgeglichen, geschaetzt: t.geschaetzt,
                              schluessel: "\(schluessel)-\(t.linien.count)-\(t.punkte)-\(hasher.finalize())", linien: t.linien)
        }
    }

    nonisolated static func rohPunkte(_ daten: Data) -> [CLLocationCoordinate2D] {
        let liste = (try? JSONDecoder().decode([Punkt].self, from: daten)) ?? []
        return liste.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }
}

/// Douglas-Peucker: wirft Punkte weg, die auf der Karte keinen sichtbaren Unterschied machen.
enum Vereinfachen {
    static func linie(_ p: [CLLocationCoordinate2D], toleranzMeter: Double) -> [CLLocationCoordinate2D] {
        guard p.count > 2 else { return p }
        let kx = cos((p[0].latitude) * .pi / 180) * 111_320
        let ky = 111_320.0
        let tol2 = toleranzMeter * toleranzMeter
        var behalten = [Bool](repeating: false, count: p.count)
        behalten[0] = true
        behalten[p.count - 1] = true
        var stapel = [(0, p.count - 1)]
        while let (a, b) = stapel.popLast() {
            guard b > a + 1 else { continue }
            let ax = p[a].longitude * kx, ay = p[a].latitude * ky
            let bx = p[b].longitude * kx, by = p[b].latitude * ky
            let dx = bx - ax, dy = by - ay
            let len2 = max(dx * dx + dy * dy, 1e-9)
            var maxD = 0.0, maxI = a
            for i in (a + 1)..<b {
                let px = p[i].longitude * kx, py = p[i].latitude * ky
                let t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / len2))
                let qx = ax + t * dx - px, qy = ay + t * dy - py
                let d = qx * qx + qy * qy
                if d > maxD { maxD = d; maxI = i }
            }
            if maxD > tol2 {
                behalten[maxI] = true
                stapel.append((a, maxI))
                stapel.append((maxI, b))
            }
        }
        return p.indices.filter { behalten[$0] }.map { p[$0] }
    }
}

struct KartenView: View {
    @EnvironmentObject private var recorder: FahrtRecorder
    @EnvironmentObject private var abgleich: Abgleich
    @ObservedObject private var cache = SpurCache.shared
    @ObservedObject private var zeit = ZeitFilter.shared
    @ObservedObject private var namen = OrtNamen.shared
    @State private var filter: FahrtArt?
    @State private var zoomNr = 0
    @State private var zoomWunsch = false
    @State private var fokusNr = 0
    @State private var fokus: CLLocationCoordinate2D?

    private func filtern(zoomen: Bool) {
        let b = zeit.bereich
        // Gezoomt wird erst, wenn die Linien des neuen Zeitraums im Hintergrund fertig sind
        if zoomen { zoomWunsch = true }
        cache.filtern(von: b.von, bis: b.bis, art: filter)
    }

    var body: some View {
        SpurKarte(fein: cache.gruppenFein,
                  grob: cache.gruppenGrob,
                  halte: cache.halte,
                  live: recorder.livePunkte,
                  liveArt: recorder.art,
                  zoomNr: zoomNr,
                  zoomRect: cache.ausschnitt,
                  fokusNr: fokusNr,
                  fokus: fokus)
            .ignoresSafeArea(edges: .top)
            .safeAreaInset(edge: .top) {
                VStack(spacing: 8) {
                    ArtFilter(auswahl: $filter)
                    ZeitLeiste()
                }
                .padding(.horizontal, 16)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    if let steht = cache.autoSteht, !recorder.nimmtAuf {
                        Button {
                            fokus = steht.koordinate
                            fokusNr += 1
                        } label: {
                            HStack(spacing: 8) {
                                HaltSymbol(parken: true)
                                Text("Auto steht seit \(steht.von.formatted(.dateTime.hour().minute().locale(Locale(identifier: "de_DE"))))"
                                     + (namen.name(steht.lat, steht.lon).map { " · \($0)" } ?? ""))
                                    .font(.footnote.weight(.medium))
                                    .lineLimit(1)
                            }
                            .padding(.leading, 5).padding(.trailing, 12).padding(.vertical, 5)
                            .background(Capsule().fill(Color(red: 0.08, green: 0.13, blue: 0.19).opacity(0.95)))
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 6)
                        .task(id: steht.id) { namen.anfragen(steht.lat, steht.lon) }
                    }
                    TagesKarte()
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
            .onAppear {
                filtern(zoomen: false)
                cache.aktualisieren(container: recorder.container)
            }
            .onChange(of: zeit.schluessel) { _, _ in filtern(zoomen: true) }
            .onChange(of: filter) { _, _ in filtern(zoomen: false) }
            .onChange(of: cache.fertigNr) { _, _ in
                if zoomWunsch { zoomWunsch = false; zoomNr += 1 }
            }
            .onChange(of: abgleich.version) { _, _ in cache.aktualisieren(container: recorder.container) }
            .onChange(of: recorder.nimmtAuf) { _, _ in cache.aktualisieren(container: recorder.container) }
    }
}

/// Wie eine Linie gezeichnet wird: weicher Schein und heller Kern in EINEM Durchgang.
struct LinienStil {
    var schein: UIColor?
    var scheinBreite: CGFloat = 12
    var kern: UIColor
    var kernBreite: CGFloat
    var gestrichelt = false

    func zeichnen(_ pfad: CGPath, zoom: MKZoomScale, in ctx: CGContext) {
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if let schein {
            ctx.addPath(pfad)
            ctx.setStrokeColor(schein.cgColor)
            ctx.setLineWidth(scheinBreite / zoom)
            ctx.strokePath()
        }
        ctx.addPath(pfad)
        ctx.setStrokeColor(kern.cgColor)
        ctx.setLineWidth(kernBreite / zoom)
        if gestrichelt { ctx.setLineDash(phase: 0, lengths: [5 / zoom, 6 / zoom]) }
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
    }
}

final class LeuchtMultiRenderer: MKMultiPolylineRenderer {
    var stil = LinienStil(kern: .white, kernBreite: 3)
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        if path == nil { createPath() }
        guard let pfad = path else { return }
        stil.zeichnen(pfad, zoom: zoomScale, in: context)
    }
}

final class LeuchtRenderer: MKPolylineRenderer {
    var stil = LinienStil(kern: .white, kernBreite: 3)
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        if path == nil { createPath() }
        guard let pfad = path else { return }
        stil.zeichnen(pfad, zoom: zoomScale, in: context)
    }
}

/// Die Karte selbst – direkt mit MapKit, damit Tausende Strecken als wenige Linien gezeichnet werden.
struct SpurKarte: UIViewRepresentable {
    let fein: [SpurGruppe]
    let grob: [SpurGruppe]
    var halte: [Halt] = []
    let live: [CLLocationCoordinate2D]
    let liveArt: FahrtArt
    var zoomNr: Int = 0
    var zoomRect: MKMapRect?
    var fokusNr: Int = 0
    var fokus: CLLocationCoordinate2D?

    func makeCoordinator() -> Koordinator { Koordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let karte = MKMapView()
        karte.delegate = context.coordinator
        let stil = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        stil.pointOfInterestFilter = .excludingAll
        karte.preferredConfiguration = stil
        karte.showsUserLocation = true
        karte.showsCompass = true
        karte.userTrackingMode = .follow
        karte.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier)
        let knopf = MKUserTrackingButton(mapView: karte)
        knopf.translatesAutoresizingMaskIntoConstraints = false
        knopf.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.85)
        knopf.layer.cornerRadius = 10
        karte.addSubview(knopf)
        NSLayoutConstraint.activate([
            knopf.trailingAnchor.constraint(equalTo: karte.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            knopf.topAnchor.constraint(equalTo: karte.safeAreaLayoutGuide.topAnchor, constant: 70),
        ])
        return karte
    }

    func updateUIView(_ karte: MKMapView, context: Context) {
        let k = context.coordinator
        k.fein = fein
        k.grob = grob
        k.linienAnwenden(karte)
        k.liveAnwenden(karte, live: live, liveArt: liveArt)
        k.halteAnwenden(karte, halte)
        k.zoomen(karte, nr: zoomNr, rect: zoomRect)
        k.fokussieren(karte, nr: fokusNr, ort: fokus)
    }

    @MainActor
    final class Koordinator: NSObject, MKMapViewDelegate {
        var fein: [SpurGruppe] = []
        var grob: [SpurGruppe] = []
        /// Weite Ansicht (mehr als etwa 15 km sichtbar) → grobe Linien ohne Doppelungen
        private var weit = false
        private var aktuell: [String: MKOverlay] = [:]
        private var stile: [ObjectIdentifier: LinienStil] = [:]
        private var liveOverlay: MKOverlay?
        private var liveAnzahl = 0
        private var marken: [String: HaltMarke] = [:]
        private var letzterZoom = 0
        private var letzterFokus = 0

        func zoomen(_ karte: MKMapView, nr: Int, rect: MKMapRect?) {
            guard nr != letzterZoom else { return }
            letzterZoom = nr
            guard let rect, !rect.isNull else { return }
            karte.userTrackingMode = .none
            let mindest = 3000.0  // nicht weiter hineinzoomen als ca. 3 km
            var r = rect
            if r.size.width < mindest { r = r.insetBy(dx: -(mindest - r.size.width) / 2, dy: 0) }
            if r.size.height < mindest { r = r.insetBy(dx: 0, dy: -(mindest - r.size.height) / 2) }
            karte.setVisibleMapRect(r, edgePadding: UIEdgeInsets(top: 160, left: 40, bottom: 300, right: 40), animated: true)
        }

        func fokussieren(_ karte: MKMapView, nr: Int, ort: CLLocationCoordinate2D?) {
            guard nr != letzterFokus, let ort else { return }
            letzterFokus = nr
            karte.userTrackingMode = .none
            karte.setRegion(MKCoordinateRegion(center: ort, latitudinalMeters: 700, longitudinalMeters: 700), animated: true)
            if let m = marken.values.first(where: { $0.halt.bis == nil && $0.halt.parken }) {
                karte.selectAnnotation(m, animated: true)
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let neu = mapView.region.span.latitudeDelta > 0.14
            guard neu != weit else { return }
            weit = neu
            linienAnwenden(mapView)
        }

        func linienAnwenden(_ karte: MKMapView) {
            let gruppen = weit ? grob : fein
            let gewuenscht = Set(gruppen.map(\.schluessel))
            var weg: [MKOverlay] = []
            for (schluessel, o) in aktuell where !gewuenscht.contains(schluessel) {
                weg.append(o)
                stile[ObjectIdentifier(o)] = nil
                aktuell[schluessel] = nil
            }
            if !weg.isEmpty { karte.removeOverlays(weg) }
            // Gebrochene (geschätzte, rohe) Linien unten, fertige oben
            var neu: [(Int, MKOverlay)] = []
            for g in gruppen where aktuell[g.schluessel] == nil {
                let o = MKMultiPolyline(g.linien)
                let art = g.art
                var stil = LinienStil(kern: art.uiHell, kernBreite: weit ? 2.5 : 3.5)
                if g.abgeglichen {
                    stil.schein = art.uiFarbe.withAlphaComponent(g.geschaetzt ? 0.12 : 0.28)
                    stil.kern = art.uiHell.withAlphaComponent(g.geschaetzt ? 0.5 : 1)
                } else {
                    stil.schein = nil
                    stil.kern = art.uiHell.withAlphaComponent(0.8)
                    stil.kernBreite = 2.5
                    stil.gestrichelt = true
                }
                if weit { stil.scheinBreite = 9 }
                stile[ObjectIdentifier(o)] = stil
                aktuell[g.schluessel] = o
                neu.append((g.abgeglichen && !g.geschaetzt ? 1 : 0, o))
            }
            for (_, o) in neu.sorted(by: { $0.0 < $1.0 }) {
                if (o as? MKMultiPolyline).map({ stile[ObjectIdentifier($0)]?.schein == nil }) == true {
                    karte.insertOverlay(o, at: 0, level: .aboveRoads)
                } else {
                    karte.addOverlay(o, level: .aboveRoads)
                }
            }
        }

        func liveAnwenden(_ karte: MKMapView, live: [CLLocationCoordinate2D], liveArt: FahrtArt) {
            guard live.count != liveAnzahl else { return }
            if let alt = liveOverlay {
                karte.removeOverlay(alt)
                stile[ObjectIdentifier(alt)] = nil
            }
            liveOverlay = nil
            liveAnzahl = live.count
            guard live.count > 1 else { return }
            let o = MKPolyline(coordinates: live, count: live.count)
            stile[ObjectIdentifier(o)] = LinienStil(schein: liveArt.uiFarbe.withAlphaComponent(0.35), scheinBreite: 16,
                                                   kern: .white, kernBreite: 4)
            karte.addOverlay(o, level: .aboveLabels)
            liveOverlay = o
        }

        func halteAnwenden(_ karte: MKMapView, _ halte: [Halt]) {
            let gewuenscht = Dictionary(halte.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let weg = marken.filter { gewuenscht[$0.key] == nil || gewuenscht[$0.key]!.bis != $0.value.halt.bis }
            if !weg.isEmpty {
                karte.removeAnnotations(Array(weg.values))
                for k in weg.keys { marken[k] = nil }
            }
            var neu: [HaltMarke] = []
            for (id, h) in gewuenscht where marken[id] == nil {
                let m = HaltMarke(h, name: OrtNamen.shared.name(h.lat, h.lon))
                marken[id] = m
                neu.append(m)
            }
            if !neu.isEmpty { karte.addAnnotations(neu) }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let cluster = annotation as? MKClusterAnnotation {
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier,
                                                              for: cluster) as? MKMarkerAnnotationView
                v?.markerTintColor = UIColor(red: 0.11, green: 0.23, blue: 0.36, alpha: 1)
                v?.glyphText = "\(cluster.memberAnnotations.count)"
                v?.displayPriority = .defaultLow
                return v
            }
            guard let marke = annotation as? HaltMarke else { return nil }
            let kennung = marke.halt.parken ? "parken" : "halt"
            let v = mapView.dequeueReusableAnnotationView(withIdentifier: kennung)
                ?? MKAnnotationView(annotation: marke, reuseIdentifier: kennung)
            v.annotation = marke
            v.image = marke.halt.parken ? HaltMarke.bildParken : HaltMarke.bildHalt
            v.canShowCallout = true
            v.clusteringIdentifier = "halt"
            v.collisionMode = .circle
            v.displayPriority = marke.halt.bis == nil ? .required : (marke.halt.parken ? .defaultHigh : .defaultLow)
            return v
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let marke = view.annotation as? HaltMarke else { return }
            let h = marke.halt
            Task { @MainActor in
                OrtNamen.shared.anfragen(h.lat, h.lon)
                for _ in 0..<8 {
                    if let n = OrtNamen.shared.name(h.lat, h.lon) {
                        marke.title = "\(h.titel) · \(n)"
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let stil = stile[ObjectIdentifier(overlay)] else { return MKOverlayRenderer(overlay: overlay) }
            if let multi = overlay as? MKMultiPolyline {
                let r = LeuchtMultiRenderer(multiPolyline: multi)
                r.stil = stil
                return r
            }
            if let einzel = overlay as? MKPolyline {
                let r = LeuchtRenderer(polyline: einzel)
                r.stil = stil
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

/// Untere Karte: Kilometer im gewählten Zeitraum und der runde Aufnahmeknopf.
struct TagesKarte: View {
    @EnvironmentObject private var recorder: FahrtRecorder
    @EnvironmentObject private var abgleich: Abgleich
    @ObservedObject private var cache = SpurCache.shared
    @ObservedObject private var zeit = ZeitFilter.shared

    private func wert(_ art: FahrtArt) -> Double {
        var summe = cache.summen[art] ?? 0
        if recorder.nimmtAuf && recorder.art == art && zeit.enthaeltJetzt { summe += recorder.liveDistanz }
        return summe
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Capsule()
                .fill(.secondary.opacity(0.5))
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity)

            HStack(alignment: .firstTextBaseline) {
                Text(zeit.text).font(.headline).lineLimit(1)
                Spacer()
                let n = cache.anzahl.values.reduce(0, +)
                Text(cache.geladen ? "\(Format.anzahl(n)) Strecken" : "Lade …")
                    .font(.caption).foregroundStyle(.secondary)
            }

            let arten = FahrtArt.allCases.filter { $0 != .rad || wert(.rad) > 0 }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(arten) { art in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(art.name, systemImage: art.symbol)
                            .font(.caption)
                            .foregroundStyle(art.hell)
                        Text(Format.km(wert(art)))
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(art.kachel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }

            HStack(spacing: 14) {
                AufnahmeKnopf()
                VStack(alignment: .leading, spacing: 2) {
                    if recorder.nimmtAuf, let start = recorder.startZeit {
                        Text("\(recorder.art.name) · läuft").font(.subheadline.weight(.semibold))
                        HStack(spacing: 6) {
                            Text(start, style: .timer).monospacedDigit()
                            Text("·")
                            Text(Format.km(recorder.liveDistanz)).monospacedDigit()
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Aufnahme starten").font(.subheadline.weight(.semibold))
                        Text(abgleich.meldung ?? (recorder.automatik ? "Automatik an · lange drücken für Fuß/Rad" : "Lange drücken für Fuß/Rad"))
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 16)
        // kein Glas-Effekt: Unschärfe über der Karte kostet bei jeder Bewegung viel Rechenzeit
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.96), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

/// Runder Knopf: tippen = Auto starten, lange drücken = Art wählen, während der Aufnahme = Stopp.
struct AufnahmeKnopf: View {
    @EnvironmentObject private var recorder: FahrtRecorder
    @State private var puls = false

    var body: some View {
        Group {
            if recorder.nimmtAuf {
                Button {
                    recorder.beenden()
                } label: {
                    ZStack {
                        Circle().fill(Color.red.opacity(0.25))
                            .scaleEffect(puls ? 1.25 : 1)
                            .opacity(puls ? 0 : 1)
                        Circle().fill(Color.red)
                        RoundedRectangle(cornerRadius: 4).fill(.white).frame(width: 18, height: 18)
                    }
                }
                .accessibilityLabel("Aufnahme beenden")
                .onAppear {
                    withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { puls = true }
                }
                .onDisappear { puls = false }
            } else {
                Menu {
                    ForEach(FahrtArt.allCases) { art in
                        Button {
                            recorder.starten(art)
                        } label: {
                            Label(art.name, systemImage: art.symbol)
                        }
                    }
                } label: {
                    ZStack {
                        Circle().fill(FahrtArt.auto.farbe)
                        Circle().strokeBorder(FahrtArt.auto.hell.opacity(0.5), lineWidth: 4)
                        Circle().fill(.white).frame(width: 18, height: 18)
                    }
                } primaryAction: {
                    recorder.starten(.auto)
                }
                .accessibilityLabel("Aufnahme starten")
            }
        }
        .frame(width: 58, height: 58)
        .sensoryFeedback(.impact, trigger: recorder.nimmtAuf)
    }
}

/// Schwebende Leiste oben: alle Strecken oder nur eine Art.
struct ArtFilter: View {
    @Binding var auswahl: FahrtArt?

    var body: some View {
        HStack(spacing: 4) {
            knopf(nil, text: "Alle", symbol: nil)
            ForEach(FahrtArt.allCases) { art in
                knopf(art, text: art == .fuss ? "Fuß" : (art == .rad ? "Rad" : art.name), symbol: art.symbol)
            }
        }
        .padding(5)
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.94), in: Capsule())
    }

    private func knopf(_ art: FahrtArt?, text: String, symbol: String?) -> some View {
        let aktiv = auswahl == art
        return Button {
            withAnimation(.snappy) { auswahl = art }
        } label: {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol) }
                Text(text)
            }
            .font(.caption.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 32)
            .foregroundStyle(aktiv ? Color.black : (art?.hell ?? Color.primary))
            .background(aktiv ? (art?.hell ?? Color.white) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
