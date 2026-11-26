import SwiftUI
import SwiftData
import MapKit

struct FahrtenListe: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var recorder: FahrtRecorder
    @EnvironmentObject private var abgleich: Abgleich
    @ObservedObject private var zeit = ZeitFilter.shared
    @ObservedObject private var cache = SpurCache.shared

    @State private var fahrten: [Fahrt] = []
    @State private var grenze = 150
    @State private var artFilter: FahrtArt?
    @State private var aendernFrage: FahrtArt?

    /// Lädt nur die sichtbare Seite – nie alle Strecken auf einmal.
    private func laden() {
        let (von, bis) = zeit.bereich
        var d: FetchDescriptor<Fahrt>
        if let a = artFilter?.rawValue {
            d = FetchDescriptor(predicate: #Predicate { $0.start >= von && $0.start < bis && $0.artText == a },
                                sortBy: [SortDescriptor(\.start, order: .reverse)])
        } else {
            d = FetchDescriptor(predicate: #Predicate { $0.start >= von && $0.start < bis },
                                sortBy: [SortDescriptor(\.start, order: .reverse)])
        }
        d.fetchLimit = grenze
        fahrten = (try? context.fetch(d)) ?? []
    }

    /// Alle Strecken im aktuellen Zeitraum/Filter auf eine andere Art umstellen.
    private func alleAendern(zu neu: FahrtArt) {
        let (von, bis) = zeit.bereich
        let a = artFilter?.rawValue ?? ""
        let d = FetchDescriptor<Fahrt>(predicate: #Predicate { $0.start >= von && $0.start < bis && $0.artText == a })
        let alle = (try? context.fetch(d)) ?? []
        for f in alle { f.artAendern(neu) }
        try? context.save()
        abgleich.geaendert()
        artFilter = neu
        laden()
        if let c = recorder.container { Task { await abgleich.ausstehendeAbgleichen(container: c) } }
    }

    @State private var buch = false

    var body: some View {
        NavigationStack {
            Group {
                if buch { FahrtenbuchView() } else { streckenListe }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("Ansicht", selection: $buch) {
                    Text("Strecken").tag(false)
                    Text("Fahrtenbuch").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.bar)
            }
        }
    }

    private var streckenListe: some View {
            List {
                Section {
                    ZeitLeiste()
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                Section {
                    ForEach(FahrtArt.allCases) { art in
                        let km = cache.summen[art] ?? 0
                        if km > 0 {
                            Button {
                                artFilter = artFilter == art ? nil : art
                            } label: {
                                LabeledContent {
                                    Text("\(Format.km(km)) · \(Format.anzahl(cache.anzahl[art] ?? 0))")
                                } label: {
                                    Label(art.name, systemImage: artFilter == art ? "checkmark.circle.fill" : art.symbol)
                                        .foregroundStyle(art.farbe)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } footer: {
                    Text(artFilter == nil ? "Art antippen, um nur diese Strecken zu zeigen." : "Nur \(artFilter!.name) – zum Aufheben noch einmal antippen.")
                }
                Section {
                    ForEach(fahrten) { fahrt in
                        // Was nach dieser Strecke kam: geparkt oder Aufenthalt (neueste oben, also darüber)
                        if let halt = cache.halteNach[fahrt.id],
                           artFilter == nil || (halt.parken ? artFilter == .auto : artFilter != .auto) {
                            HaltZeile(halt: halt)
                                .deleteDisabled(true)
                        }
                        NavigationLink {
                            FahrtDetail(fahrt: fahrt)
                        } label: {
                            FahrtZeile(fahrt: fahrt)
                        }
                        .disabled(fahrt.status == .aufnahme)
                    }
                    .onDelete { stellen in
                        var weg: [UUID] = []
                        for i in stellen where fahrten[i].status != .aufnahme {
                            weg.append(fahrten[i].id)
                            context.delete(fahrten[i])
                        }
                        try? context.save()
                        abgleich.loeschen(weg)
                        abgleich.geaendert()
                        laden()
                    }
                    if fahrten.count == grenze {
                        Button("Mehr laden") {
                            grenze += 150
                            laden()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("Strecken")
            .toolbar {
                if let artFilter {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            ForEach(FahrtArt.allCases.filter { $0 != artFilter }) { ziel in
                                Button {
                                    aendernFrage = ziel
                                } label: {
                                    Label("Alle zu \(ziel.name)", systemImage: ziel.symbol)
                                }
                            }
                        } label: {
                            Label("Alle ändern", systemImage: "arrow.triangle.swap")
                        }
                    }
                }
            }
            .confirmationDialog("Alle Strecken umstellen?",
                                isPresented: Binding(get: { aendernFrage != nil }, set: { if !$0 { aendernFrage = nil } }),
                                titleVisibility: .visible) {
                if let ziel = aendernFrage, let quelle = artFilter {
                    Button("\(Format.anzahl(cache.anzahl[quelle] ?? 0)) Strecken zu \(ziel.name)") { alleAendern(zu: ziel) }
                }
            } message: {
                Text("Gilt für alle \(artFilter?.name ?? "")-Strecken in „\(zeit.text)“. Sie werden danach neu auf die Straße gelegt.")
            }
            .overlay {
                if fahrten.isEmpty {
                    ContentUnavailableView("Keine Strecken",
                                           systemImage: "car",
                                           description: Text("In diesem Zeitraum gibt es keine Strecken."))
                }
            }
            .onAppear { laden() }
            .onChange(of: zeit.schluessel) { _, _ in grenze = 150; laden() }
            .onChange(of: artFilter) { _, _ in grenze = 150; laden() }
            .onChange(of: abgleich.version) { _, _ in laden() }
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
                Text(fahrt.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year().hour().minute().locale(Locale(identifier: "de_DE"))))
                    .font(.headline)
                Text("\(Format.km(fahrt.distanzMeter)) · \(Format.dauer(fahrt.dauer))\(fahrt.geschaetzt ? " · geschätzt" : "")")
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
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var recorder: FahrtRecorder
    @EnvironmentObject private var abgleich: Abgleich
    @State private var rohZeigen = false
    @State private var gpxDatei: URL?
    @State private var korrigieren = false

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
                Picker("Art", selection: Binding(get: { fahrt.art }, set: { neu in
                    fahrt.artAendern(neu)
                    try? context.save()
                    abgleich.geaendert()
                    if let c = recorder.container { Task { await abgleich.ausstehendeAbgleichen(container: c) } }
                })) {
                    ForEach(FahrtArt.allCases) { Label($0.name, systemImage: $0.symbol).tag($0) }
                }
                if fahrt.geschaetzt {
                    LabeledContent("Genauigkeit", value: "geschätzt (Punkte alle \(Int(fahrt.dichte)) m)")
                }
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
                Button {
                    korrigieren = true
                } label: {
                    Label("Strecke korrigieren", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
                .disabled(fahrt.status == .aufnahme)
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
        .sheet(isPresented: $korrigieren) {
            StreckeKorrigierenView(fahrt: fahrt)
        }
    }
}
