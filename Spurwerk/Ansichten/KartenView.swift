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

/// Strecken einer Art, eines Zustands und eines Jahres – zusammengefasst zu EINER Kartenlinie.
/// So bleibt die Karte auch mit Tausenden Strecken flüssig, und bei Änderungen wird nur ein Jahr neu gezeichnet.
struct SpurGruppe {
    let art: FahrtArt
    let abgeglichen: Bool
    let geschaetzt: Bool
    let schluessel: String          // ändert sich, sobald sich der Inhalt ändert
    let linien: [MKPolyline]
}

/// Liest die Strecken im Hintergrund und baut daraus Kartenlinien und Summen für den gewählten Zeitraum.
@MainActor
final class SpurCache: ObservableObject {
    static let shared = SpurCache()

    @Published private(set) var gruppen: [SpurGruppe] = []
    /// Kilometer je Art im gewählten Zeitraum (ohne laufende Aufnahme)
    @Published private(set) var summen: [FahrtArt: Double] = [:]
    @Published private(set) var anzahl: [FahrtArt: Int] = [:]
    /// Ausschnitt, der alle Strecken des Zeitraums zeigt
    @Published private(set) var ausschnitt: MKMapRect?
    @Published private(set) var geladen = false

    private struct Eintrag {
        let kennung: String
        let art: FahrtArt
        let abgeglichen: Bool
        let geschaetzt: Bool
        let start: Date
        let distanz: Double
        let linie: MKPolyline
    }

    private struct Roh: @unchecked Sendable {
        let id: UUID
        let kennung: String
        let art: FahrtArt
        let abgeglichen: Bool
        let geschaetzt: Bool
        let start: Date
        let distanz: Double
        let daten: Data
    }

    private var eintraege: [UUID: Eintrag] = [:]
    private var laeuft = false
    private var nochmal = false
    private var von = Date.distantPast
    private var bis = Date.distantFuture
    private var artFilter: FahrtArt?

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
                let kennung = "\(f.statusText)-\(f.artText)-\(f.geschaetzt)-\(Int(f.distanzMeter))"
                if bekannt[f.id] == kennung { continue }
                let daten = abgeglichen ? (f.spurDaten ?? Data()) : f.rohDaten
                neu.append(Roh(id: f.id, kennung: kennung, art: f.art, abgeglichen: abgeglichen,
                               geschaetzt: f.geschaetzt, start: f.start, distanz: f.distanzMeter, daten: daten))
            }
            var fertig: [(UUID, Eintrag)] = []
            fertig.reserveCapacity(neu.count)
            for r in neu {
                let punkte = r.abgeglichen ? Koordinaten.ausDaten(r.daten) : SpurCache.rohPunkte(r.daten)
                guard punkte.count > 1 else { continue }
                let einfach = Vereinfachen.linie(punkte, toleranzMeter: 5)
                let linie = MKPolyline(coordinates: einfach, count: einfach.count)
                fertig.append((r.id, Eintrag(kennung: r.kennung, art: r.art, abgeglichen: r.abgeglichen,
                                             geschaetzt: r.geschaetzt, start: r.start, distanz: r.distanz, linie: linie)))
            }
            let gueltigFest = gueltig
            await MainActor.run {
                self.eintraege = self.eintraege.filter { gueltigFest.contains($0.key) }
                for (id, e) in fertig { self.eintraege[id] = e }
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

    private func gruppenBauen() {
        let kalender = Calendar.current
        var summen: [FahrtArt: Double] = [:]
        var anzahl: [FahrtArt: Int] = [:]
        var teile: [String: (art: FahrtArt, abgeglichen: Bool, geschaetzt: Bool, ids: [UUID], linien: [MKPolyline])] = [:]
        var rect = MKMapRect.null

        for (id, e) in eintraege where e.start >= von && e.start < bis {
            summen[e.art, default: 0] += e.distanz
            anzahl[e.art, default: 0] += 1
            if let artFilter, e.art != artFilter { continue }
            let jahr = kalender.component(.year, from: e.start)
            let s = "\(e.art.rawValue)-\(e.abgeglichen)-\(e.geschaetzt)-\(jahr)"
            teile[s, default: (e.art, e.abgeglichen, e.geschaetzt, [], [])].ids.append(id)
            teile[s]!.linien.append(e.linie)
            rect = rect.union(e.linie.boundingMapRect)
        }

        gruppen = teile.map { schluessel, t in
            var hasher = Hasher()
            for id in t.ids.sorted(by: { $0.uuidString < $1.uuidString }) { hasher.combine(id) }
            return SpurGruppe(art: t.art, abgeglichen: t.abgeglichen, geschaetzt: t.geschaetzt,
                              schluessel: "\(schluessel)-\(t.ids.count)-\(hasher.finalize())", linien: t.linien)
        }
        self.summen = summen
        self.anzahl = anzahl
        ausschnitt = rect.isNull ? nil : rect
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
    @State private var filter: FahrtArt?
    @State private var zoomNr = 0

    private func filtern(zoomen: Bool) {
        let b = zeit.bereich
        cache.filtern(von: b.von, bis: b.bis, art: filter)
        if zoomen { zoomNr += 1 }
    }

    var body: some View {
        SpurKarte(gruppen: cache.gruppen,
                  live: recorder.livePunkte,
                  liveArt: recorder.art,
                  zoomNr: zoomNr,
                  zoomRect: cache.ausschnitt)
            .ignoresSafeArea(edges: .top)
            .safeAreaInset(edge: .top) {
                VStack(spacing: 8) {
                    ArtFilter(auswahl: $filter)
                    ZeitLeiste()
                }
                .padding(.horizontal, 16)
            }
            .safeAreaInset(edge: .bottom) {
                TagesKarte()
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
            .onAppear {
                filtern(zoomen: false)
                cache.aktualisieren(container: recorder.container)
            }
            .onChange(of: zeit.schluessel) { _, _ in filtern(zoomen: true) }
            .onChange(of: filter) { _, _ in filtern(zoomen: false) }
            .onChange(of: abgleich.version) { _, _ in cache.aktualisieren(container: recorder.container) }
            .onChange(of: recorder.nimmtAuf) { _, _ in cache.aktualisieren(container: recorder.container) }
    }
}

/// Die Karte selbst – direkt mit MapKit, damit Tausende Strecken als wenige Linien gezeichnet werden.
struct SpurKarte: UIViewRepresentable {
    let gruppen: [SpurGruppe]
    let live: [CLLocationCoordinate2D]
    let liveArt: FahrtArt
    var zoomNr: Int = 0
    var zoomRect: MKMapRect?

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
        context.coordinator.anwenden(karte, gruppen: gruppen, live: live, liveArt: liveArt)
        context.coordinator.zoomen(karte, nr: zoomNr, rect: zoomRect)
    }

    final class Koordinator: NSObject, MKMapViewDelegate {
        private struct Stil { let art: FahrtArt; let abgeglichen: Bool; let geschaetzt: Bool; let schein: Bool; let live: Bool }
        private var letzterZoom = 0

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
        private var aktuell: [String: [MKOverlay]] = [:]
        private var stile: [ObjectIdentifier: Stil] = [:]
        private var liveOverlays: [MKOverlay] = []
        private var liveAnzahl = 0

        func anwenden(_ karte: MKMapView, gruppen: [SpurGruppe], live: [CLLocationCoordinate2D], liveArt: FahrtArt) {
            let gewuenscht = Set(gruppen.map(\.schluessel))
            for (schluessel, overlays) in aktuell where !gewuenscht.contains(schluessel) {
                karte.removeOverlays(overlays)
                overlays.forEach { stile[ObjectIdentifier($0)] = nil }
                aktuell[schluessel] = nil
            }
            for g in gruppen where aktuell[g.schluessel] == nil {
                let schein = MKMultiPolyline(g.linien)
                let kern = MKMultiPolyline(g.linien)
                stile[ObjectIdentifier(schein)] = Stil(art: g.art, abgeglichen: g.abgeglichen, geschaetzt: g.geschaetzt, schein: true, live: false)
                stile[ObjectIdentifier(kern)] = Stil(art: g.art, abgeglichen: g.abgeglichen, geschaetzt: g.geschaetzt, schein: false, live: false)
                // Erst alle Scheine, dann die Kerne darüber
                karte.insertOverlay(schein, at: 0, level: .aboveRoads)
                karte.addOverlay(kern, level: .aboveRoads)
                aktuell[g.schluessel] = [schein, kern]
            }

            if live.count != liveAnzahl {
                karte.removeOverlays(liveOverlays)
                liveOverlays.forEach { stiles in stile[ObjectIdentifier(stiles)] = nil }
                liveOverlays = []
                liveAnzahl = live.count
                if live.count > 1 {
                    let schein = MKPolyline(coordinates: live, count: live.count)
                    let kern = MKPolyline(coordinates: live, count: live.count)
                    stile[ObjectIdentifier(schein)] = Stil(art: liveArt, abgeglichen: true, geschaetzt: false, schein: true, live: true)
                    stile[ObjectIdentifier(kern)] = Stil(art: liveArt, abgeglichen: true, geschaetzt: false, schein: false, live: true)
                    karte.addOverlays([schein, kern], level: .aboveLabels)
                    liveOverlays = [schein, kern]
                }
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let stil = stile[ObjectIdentifier(overlay)] else { return MKOverlayRenderer(overlay: overlay) }
            let r: MKOverlayPathRenderer
            if let multi = overlay as? MKMultiPolyline {
                r = MKMultiPolylineRenderer(multiPolyline: multi)
            } else if let einzel = overlay as? MKPolyline {
                r = MKPolylineRenderer(polyline: einzel)
            } else {
                return MKOverlayRenderer(overlay: overlay)
            }
            r.lineCap = .round
            r.lineJoin = .round
            if stil.live {
                r.strokeColor = stil.schein ? stil.art.uiFarbe.withAlphaComponent(0.35) : .white
                r.lineWidth = stil.schein ? 16 : 4
            } else if stil.schein {
                r.strokeColor = stil.art.uiFarbe.withAlphaComponent(stil.abgeglichen ? (stil.geschaetzt ? 0.12 : 0.28) : 0.15)
                r.lineWidth = 12
            } else {
                // geschätzte Google-Strecken blasser
                r.strokeColor = stil.art.uiHell.withAlphaComponent(stil.geschaetzt ? 0.5 : 1)
                r.lineWidth = stil.abgeglichen ? 3.5 : 2.5
                if !stil.abgeglichen { r.lineDashPattern = [5, 6] }
            }
            return r
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
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
        .background(.ultraThinMaterial, in: Capsule())
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
