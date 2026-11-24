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

/// Alle Strecken einer Art und eines Zustands, zusammengefasst zu EINER Kartenlinie.
/// So bleibt die Karte auch mit Tausenden importierten Strecken flüssig.
struct SpurGruppe {
    let art: FahrtArt
    let abgeglichen: Bool
    let schluessel: String          // ändert sich, sobald sich der Inhalt ändert
    let linien: [MKPolyline]
}

/// Liest die Strecken im Hintergrund und baut daraus die Kartenlinien und die Tageswerte.
@MainActor
final class SpurCache: ObservableObject {
    @Published private(set) var gruppen: [SpurGruppe] = []
    @Published private(set) var heute: [FahrtArt: Double] = [:]

    private struct Eintrag {
        let kennung: String
        let art: FahrtArt
        let abgeglichen: Bool
        let linie: MKPolyline
    }

    private struct Roh: @unchecked Sendable {
        let id: UUID
        let kennung: String
        let art: FahrtArt
        let abgeglichen: Bool
        let daten: Data
    }

    private var eintraege: [UUID: Eintrag] = [:]
    private var laeuft = false
    private var nochmal = false

    func aktualisieren(container: ModelContainer?) {
        guard let container else { return }
        if laeuft { nochmal = true; return }
        laeuft = true

        let context = container.mainContext
        let alle = (try? context.fetch(FetchDescriptor<Fahrt>())) ?? []

        // Tageswerte (billig, nur Zahlen)
        let kalender = Calendar.current
        var tag: [FahrtArt: Double] = [:]
        var gueltig = Set<UUID>()
        var neu: [Roh] = []
        for f in alle where f.status != .aufnahme {
            if kalender.isDateInToday(f.start) { tag[f.art, default: 0] += f.distanzMeter }
            gueltig.insert(f.id)
            let kennung = "\(f.statusText)-\(f.artText)"
            if eintraege[f.id]?.kennung == kennung { continue }
            // Nur geänderte Strecken werden gelesen – die Daten liegen extern und werden erst jetzt geladen
            let abgeglichen = f.status == .fertig && f.spurDaten != nil
            let daten = abgeglichen ? (f.spurDaten ?? Data()) : f.rohDaten
            neu.append(Roh(id: f.id, kennung: kennung, art: f.art, abgeglichen: abgeglichen, daten: daten))
        }
        heute = tag
        eintraege = eintraege.filter { gueltig.contains($0.key) }

        Task.detached(priority: .utility) {
            var fertig: [(UUID, Eintrag)] = []
            for r in neu {
                let punkte = r.abgeglichen ? Koordinaten.ausDaten(r.daten) : Self.rohPunkte(r.daten)
                guard punkte.count > 1 else { continue }
                let einfach = Vereinfachen.linie(punkte, toleranzMeter: 4)
                let linie = MKPolyline(coordinates: einfach, count: einfach.count)
                fertig.append((r.id, Eintrag(kennung: r.kennung, art: r.art, abgeglichen: r.abgeglichen, linie: linie)))
            }
            await MainActor.run {
                for (id, e) in fertig { self.eintraege[id] = e }
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
        var gruppen: [SpurGruppe] = []
        for art in FahrtArt.allCases {
            for abgeglichen in [false, true] {
                let teil = eintraege.filter { $0.value.art == art && $0.value.abgeglichen == abgeglichen }
                guard !teil.isEmpty else { continue }
                // Schlüssel aus Anzahl + Inhalt, damit nur geänderte Gruppen neu gezeichnet werden
                var hasher = Hasher()
                for id in teil.keys.sorted(by: { $0.uuidString < $1.uuidString }) { hasher.combine(id) }
                let schluessel = "\(art.rawValue)-\(abgeglichen)-\(teil.count)-\(hasher.finalize())"
                gruppen.append(SpurGruppe(art: art, abgeglichen: abgeglichen, schluessel: schluessel,
                                          linien: teil.values.map(\.linie)))
            }
        }
        self.gruppen = gruppen
    }

    nonisolated private static func rohPunkte(_ daten: Data) -> [CLLocationCoordinate2D] {
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
    @StateObject private var cache = SpurCache()
    @State private var filter: FahrtArt?

    var body: some View {
        SpurKarte(gruppen: cache.gruppen.filter { filter == nil || $0.art == filter },
                  live: recorder.livePunkte,
                  liveArt: recorder.art)
            .ignoresSafeArea(edges: .top)
            .safeAreaInset(edge: .top) {
                ArtFilter(auswahl: $filter)
                    .padding(.horizontal, 16)
            }
            .safeAreaInset(edge: .bottom) {
                TagesKarte(heute: cache.heute)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
            .onAppear { cache.aktualisieren(container: recorder.container) }
            .onChange(of: abgleich.version) { _, _ in cache.aktualisieren(container: recorder.container) }
            .onChange(of: recorder.nimmtAuf) { _, _ in cache.aktualisieren(container: recorder.container) }
    }
}

/// Die Karte selbst – direkt mit MapKit, damit Tausende Strecken als wenige Linien gezeichnet werden.
struct SpurKarte: UIViewRepresentable {
    let gruppen: [SpurGruppe]
    let live: [CLLocationCoordinate2D]
    let liveArt: FahrtArt

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
    }

    final class Koordinator: NSObject, MKMapViewDelegate {
        private struct Stil { let art: FahrtArt; let abgeglichen: Bool; let schein: Bool; let live: Bool }
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
                stile[ObjectIdentifier(schein)] = Stil(art: g.art, abgeglichen: g.abgeglichen, schein: true, live: false)
                stile[ObjectIdentifier(kern)] = Stil(art: g.art, abgeglichen: g.abgeglichen, schein: false, live: false)
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
                    stile[ObjectIdentifier(schein)] = Stil(art: liveArt, abgeglichen: true, schein: true, live: true)
                    stile[ObjectIdentifier(kern)] = Stil(art: liveArt, abgeglichen: true, schein: false, live: true)
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
                r.strokeColor = stil.art.uiFarbe.withAlphaComponent(stil.abgeglichen ? 0.28 : 0.15)
                r.lineWidth = 12
            } else {
                r.strokeColor = stil.art.uiHell
                r.lineWidth = stil.abgeglichen ? 3.5 : 2.5
                if !stil.abgeglichen { r.lineDashPattern = [5, 6] }
            }
            return r
        }
    }
}

/// Untere Karte: heutige Kilometer und der runde Aufnahmeknopf.
struct TagesKarte: View {
    let heute: [FahrtArt: Double]
    @EnvironmentObject private var recorder: FahrtRecorder
    @EnvironmentObject private var abgleich: Abgleich

    private func wert(_ art: FahrtArt) -> Double {
        var summe = heute[art] ?? 0
        if recorder.nimmtAuf && recorder.art == art { summe += recorder.liveDistanz }
        return summe
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Capsule()
                .fill(.secondary.opacity(0.5))
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity)

            HStack(alignment: .firstTextBaseline) {
                Text("Heute").font(.headline)
                Spacer()
                Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).locale(Locale(identifier: "de_DE"))))
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
                        Text(abgleich.laeuft
                             ? (abgleich.meldung ?? "Lege Strecken auf die Straße …")
                             : (recorder.automatik ? "Automatik an · lange drücken für Fuß/Rad" : "Lange drücken für Fuß/Rad"))
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
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
