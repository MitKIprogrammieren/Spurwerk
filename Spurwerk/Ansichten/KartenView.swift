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
    /// Auto türkis, zu Fuß lila, Fahrrad korallrot.
    var farbe: Color {
        switch self {
        case .auto: Color(red: 0.11, green: 0.62, blue: 0.46)
        case .fuss: Color(red: 0.50, green: 0.47, blue: 0.87)
        case .rad: Color(red: 0.85, green: 0.35, blue: 0.19)
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

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $kamera) {
                UserAnnotation()
                ForEach(cache.linien.filter { filter == nil || $0.art == filter }) { linie in
                    if linie.abgeglichen {
                        MapPolyline(coordinates: linie.punkte)
                            .stroke(linie.art.farbe, style: StrokeStyle(lineWidth: linie.art == .auto ? 4 : 3, lineCap: .round, lineJoin: .round))
                    } else {
                        MapPolyline(coordinates: linie.punkte)
                            .stroke(linie.art.farbe.opacity(0.6), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [4, 5]))
                    }
                }
                if recorder.livePunkte.count > 1 {
                    MapPolyline(coordinates: recorder.livePunkte)
                        .stroke(recorder.art.farbe, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapScaleView()
            }

            AufnahmeLeiste()
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
        .safeAreaInset(edge: .top) {
            ArtFilter(auswahl: $filter)
                .padding(.horizontal)
        }
        .onAppear { cache.aktualisieren(fahrten) }
        .onChange(of: aenderungen) { _, _ in cache.aktualisieren(fahrten) }
    }
}

struct AufnahmeLeiste: View {
    @EnvironmentObject private var recorder: FahrtRecorder
    @EnvironmentObject private var abgleich: Abgleich

    var body: some View {
        HStack(spacing: 14) {
            if recorder.nimmtAuf, let start = recorder.startZeit {
                Image(systemName: recorder.art.symbol)
                    .font(.title3)
                    .foregroundStyle(recorder.art.farbe)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(recorder.art.name) · Aufnahme läuft").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(start, style: .timer).monospacedDigit()
                        Text("·")
                        Text(Format.km(recorder.liveDistanz))
                    }
                    .font(.headline)
                }
                Spacer()
                Button {
                    recorder.beenden()
                } label: {
                    Label("Stopp", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(recorder.automatik ? "Automatik an" : "Automatik aus")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(abgleich.laeuft ? "Lege Fahrten auf die Straße …" : "Bereit")
                        .font(.headline)
                }
                Spacer()
                Menu {
                    ForEach(FahrtArt.allCases) { art in
                        Button {
                            recorder.starten(art)
                        } label: {
                            Label(art.name, systemImage: art.symbol)
                        }
                    }
                } label: {
                    Label("Start", systemImage: "record.circle")
                } primaryAction: {
                    recorder.starten(.auto)
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Kleine Leiste oben auf der Karte: alle Strecken oder nur eine Art.
struct ArtFilter: View {
    @Binding var auswahl: FahrtArt?

    var body: some View {
        HStack(spacing: 8) {
            knopf(nil, text: "Alle", symbol: "square.stack.3d.up")
            ForEach(FahrtArt.allCases) { art in
                knopf(art, text: art.name, symbol: art.symbol)
            }
        }
        .padding(6)
        .background(.regularMaterial, in: Capsule())
    }

    private func knopf(_ art: FahrtArt?, text: String, symbol: String) -> some View {
        let aktiv = auswahl == art
        return Button {
            auswahl = art
        } label: {
            Image(systemName: symbol)
                .font(.subheadline)
                .frame(width: 44, height: 30)
                .foregroundStyle(aktiv ? Color.white : (art?.farbe ?? Color.primary))
                .background(aktiv ? (art?.farbe ?? Color.teal) : Color.clear, in: Capsule())
        }
        .accessibilityLabel(text)
    }
}
