import SwiftUI
import SwiftData
import MapKit

struct FahrtenListe: View {
    @Query(sort: \Fahrt.start, order: .reverse) private var fahrten: [Fahrt]
    @Environment(\.modelContext) private var context

    private func gesamt(_ art: FahrtArt) -> Double {
        fahrten.filter { $0.art == art }.reduce(0) { $0 + $1.distanzMeter }
    }

    var body: some View {
        NavigationStack {
            List {
                if !fahrten.isEmpty {
                    Section {
                        ForEach(FahrtArt.allCases) { art in
                            let strecke = gesamt(art)
                            if strecke > 0 {
                                LabeledContent {
                                    Text(Format.km(strecke))
                                } label: {
                                    Label(art.name, systemImage: art.symbol).foregroundStyle(art.farbe)
                                }
                            }
                        }
                    }
                }
                Section {
                    ForEach(fahrten) { fahrt in
                        NavigationLink {
                            FahrtDetail(fahrt: fahrt)
                        } label: {
                            FahrtZeile(fahrt: fahrt)
                        }
                        .disabled(fahrt.status == .aufnahme)
                    }
                    .onDelete { stellen in
                        for i in stellen where fahrten[i].status != .aufnahme {
                            context.delete(fahrten[i])
                        }
                        try? context.save()
                    }
                }
            }
            .navigationTitle("Strecken")
            .overlay {
                if fahrten.isEmpty {
                    ContentUnavailableView("Noch keine Strecken",
                                           systemImage: "car",
                                           description: Text("Tippe auf der Karte auf „Start“ oder lass die Automatik laufen."))
                }
            }
        }
    }
}

struct FahrtZeile: View {
    let fahrt: Fahrt

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: fahrt.art.symbol)
                .foregroundStyle(fahrt.art.farbe)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(fahrt.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                    .font(.headline)
                Text("\(Format.km(fahrt.distanzMeter)) · \(Format.dauer(fahrt.dauer))")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if fahrt.quelle == "google" {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary).font(.caption)
            }
            StatusMarke(status: fahrt.status)
        }
    }
}

struct StatusMarke: View {
    let status: FahrtStatus

    var body: some View {
        let (text, farbe): (String, Color) = switch status {
        case .aufnahme: ("Läuft", .red)
        case .wartet: ("Wartet", .orange)
        case .fertig: ("Auf Straße", .teal)
        case .fehler: ("Fehler", .red)
        }
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(farbe.opacity(0.15), in: Capsule())
            .foregroundStyle(farbe)
    }
}

struct FahrtDetail: View {
    let fahrt: Fahrt
    @EnvironmentObject private var recorder: FahrtRecorder
    @EnvironmentObject private var abgleich: Abgleich
    @State private var rohZeigen = false
    @State private var gpxDatei: URL?

    var body: some View {
        let roh = fahrt.rohKoordinaten
        let spur = fahrt.spur
        VStack(spacing: 0) {
            Map(initialPosition: .automatic) {
                if let spur, spur.count > 1 {
                    MapPolyline(coordinates: spur)
                        .stroke(fahrt.art.farbe, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
                if rohZeigen || spur == nil, roh.count > 1 {
                    MapPolyline(coordinates: roh)
                        .stroke(Color.orange, style: StrokeStyle(lineWidth: 2, dash: [4, 5]))
                }
                if let erster = roh.first {
                    Marker("Start", systemImage: "flag", coordinate: erster).tint(.green)
                }
                if let letzter = roh.last {
                    Marker("Ziel", systemImage: "flag.checkered", coordinate: letzter).tint(.red)
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))

            List {
                LabeledContent("Art") { Label(fahrt.art.name, systemImage: fahrt.art.symbol) }
                LabeledContent("Strecke", value: Format.km(fahrt.distanzMeter))
                if fahrt.quelle == "google" {
                    LabeledContent("Quelle", value: "Google-Zeitachse")
                }
                LabeledContent("Dauer", value: Format.dauer(fahrt.dauer))
                LabeledContent("Status") { StatusMarke(status: fahrt.status) }
                if let fehler = fahrt.fehlertext {
                    Text(fehler).font(.footnote).foregroundStyle(.secondary)
                }
                Toggle("Rohe GPS-Punkte zeigen", isOn: $rohZeigen)
                Button {
                    guard let container = recorder.container else { return }
                    Task { await abgleich.eineAbgleichen(fahrt, container: container) }
                } label: {
                    Label("Erneut auf Straße legen", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(abgleich.laeuft)
                if let gpxDatei {
                    ShareLink(item: gpxDatei) {
                        Label("Als GPX teilen", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .frame(height: 330)
        }
        .navigationTitle(fahrt.start.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .task { gpxDatei = try? GPX.datei(fuer: fahrt) }
    }
}
