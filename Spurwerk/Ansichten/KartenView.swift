import SwiftUI
import SwiftData
import MapKit

struct Linie: Identifiable {
    let id: UUID
    let punkte: [CLLocationCoordinate2D]
    let abgeglichen: Bool
    let art: FahrtArt
}

extension FahrtArt {
    /// Grundfarbe (Schein, Symbole): Auto türkis, zu Fuß lila, Fahrrad korallrot.
    var farbe: Color {
        switch self {
        case .auto: Color(red: 0.11, green: 0.62, blue: 0.46)
        case .fuss: Color(red: 0.50, green: 0.47, blue: 0.87)
        case .rad: Color(red: 0.85, green: 0.35, blue: 0.19)
        }
    }

    /// Hellere Farbe für den Kern der Linie – leuchtet auf der gedämpften Karte.
    var hell: Color {
        switch self {
        case .auto: Color(red: 0.36, green: 0.79, blue: 0.65)
        case .fuss: Color(red: 0.69, green: 0.66, blue: 0.93)
        case .rad: Color(red: 0.94, green: 0.60, blue: 0.48)
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

/// Hält die dekodierten Linien vor, damit die Karte nicht bei jedem GPS-Punkt alles neu rechnet.
@MainActor
final class SpurCache: ObservableObject {
    @Published private(set) var linien: [Linie] = []
    private var bekannt: [UUID: (kennung: String, linie: Linie)] = [:]

    func aktualisieren(_ fahrten: [Fahrt]) {
        var neu: [Linie] = []
        var naechste: [UUID: (kennung: String, linie: Linie)] = [:]
        for fahrt in fahrten where fahrt.status != .aufnahme {
            let kennung = "\(fahrt.statusText)-\(fahrt.artText)-\(fahrt.spurDaten?.count ?? 0)-\(fahrt.rohDaten.count)"
            if let alt = bekannt[fahrt.id], alt.kennung == kennung {
                neu.append(alt.linie)
                naechste[fahrt.id] = alt
                continue
            }
            let linie: Linie
            if fahrt.status == .fertig, let spur = fahrt.spur {
                linie = Linie(id: fahrt.id, punkte: spur, abgeglichen: true, art: fahrt.art)
            } else {
                linie = Linie(id: fahrt.id, punkte: fahrt.rohKoordinaten, abgeglichen: false, art: fahrt.art)
            }
            neu.append(linie)
            naechste[fahrt.id] = (kennung, linie)
        }
        bekannt = naechste
        linien = neu
    }
}

struct KartenView: View {
    @Query(sort: \Fahrt.start, order: .reverse) private var fahrten: [Fahrt]
    @EnvironmentObject private var recorder: FahrtRecorder
    @StateObject private var cache = SpurCache()
    @State private var kamera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var filter: FahrtArt?

    private var aenderungen: [String] {
        fahrten.map { "\($0.id)-\($0.statusText)-\($0.spurDaten?.count ?? 0)" }
    }

    private var sichtbar: [Linie] {
        cache.linien.filter { filter == nil || $0.art == filter }
    }

    var body: some View {
        Map(position: $kamera) {
            // 1. Schein: breite, durchsichtige Linie – wo du oft lang fährst, leuchtet es kräftiger
            ForEach(sichtbar) { linie in
                MapPolyline(coordinates: linie.punkte)
                    .stroke(linie.art.farbe.opacity(linie.abgeglichen ? 0.28 : 0.15),
                            style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round))
            }
            // 2. Kern: schmale, helle Linie (gestrichelt, solange noch nicht auf die Straße gelegt)
            ForEach(sichtbar) { linie in
                MapPolyline(coordinates: linie.punkte)
                    .stroke(linie.art.hell,
                            style: StrokeStyle(lineWidth: linie.abgeglichen ? 3.5 : 2.5,
                                               lineCap: .round, lineJoin: .round,
                                               dash: linie.abgeglichen ? [] : [5, 6]))
            }
            if recorder.livePunkte.count > 1 {
                MapPolyline(coordinates: recorder.livePunkte)
                    .stroke(recorder.art.farbe.opacity(0.35), style: StrokeStyle(lineWidth: 16, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: recorder.livePunkte)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            UserAnnotation()
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .safeAreaInset(edge: .top) {
            ArtFilter(auswahl: $filter)
                .padding(.horizontal, 16)
        }
        .safeAreaInset(edge: .bottom) {
            TagesKarte(fahrten: fahrten)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
        }
        .onAppear { cache.aktualisieren(fahrten) }
        .onChange(of: aenderungen) { _, _ in cache.aktualisieren(fahrten) }
    }
}

/// Untere Karte: heutige Kilometer und der runde Aufnahmeknopf.
struct TagesKarte: View {
    let fahrten: [Fahrt]
    @EnvironmentObject private var recorder: FahrtRecorder
    @EnvironmentObject private var abgleich: Abgleich

    private func heute(_ art: FahrtArt) -> Double {
        let kalender = Calendar.current
        var summe = fahrten
            .filter { $0.art == art && kalender.isDateInToday($0.start) && $0.status != .aufnahme }
            .reduce(0) { $0 + $1.distanzMeter }
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
                Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))
                    .font(.caption).foregroundStyle(.secondary)
            }

            let arten = FahrtArt.allCases.filter { $0 != .rad || heute(.rad) > 0 }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(arten) { art in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(art.name, systemImage: art.symbol)
                            .font(.caption)
                            .foregroundStyle(art.hell)
                        Text(Format.km(heute(art)))
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
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
                             ? "Lege Strecken auf die Straße …"
                             : (recorder.automatik ? "Automatik an · lange drücken für Fuß/Rad" : "Lange drücken für Fuß/Rad"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .animation(.snappy, value: recorder.liveDistanz)
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
