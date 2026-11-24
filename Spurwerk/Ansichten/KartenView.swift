import SwiftUI
import SwiftData
import MapKit

struct Linie: Identifiable {
    let id: UUID
    let punkte: [CLLocationCoordinate2D]
    let abgeglichen: Bool
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
            let kennung = "\(fahrt.statusText)-\(fahrt.spurDaten?.count ?? 0)-\(fahrt.rohDaten.count)"
            if let alt = bekannt[fahrt.id], alt.kennung == kennung {
                neu.append(alt.linie)
                naechste[fahrt.id] = alt
                continue
            }
            let linie: Linie
            if fahrt.status == .fertig, let spur = fahrt.spur {
                linie = Linie(id: fahrt.id, punkte: spur, abgeglichen: true)
            } else {
                linie = Linie(id: fahrt.id, punkte: fahrt.rohKoordinaten, abgeglichen: false)
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

    private var aenderungen: [String] {
        fahrten.map { "\($0.id)-\($0.statusText)-\($0.spurDaten?.count ?? 0)" }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $kamera) {
                UserAnnotation()
                ForEach(cache.linien) { linie in
                    if linie.abgeglichen {
                        MapPolyline(coordinates: linie.punkte)
                            .stroke(Color.teal, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    } else {
                        MapPolyline(coordinates: linie.punkte)
                            .stroke(Color.orange.opacity(0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [4, 5]))
                    }
                }
                if recorder.livePunkte.count > 1 {
                    MapPolyline(coordinates: recorder.livePunkte)
                        .stroke(Color.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
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
                Circle().fill(.red).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Aufnahme läuft").font(.caption).foregroundStyle(.secondary)
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
                Button {
                    recorder.starten()
                } label: {
                    Label("Start", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
