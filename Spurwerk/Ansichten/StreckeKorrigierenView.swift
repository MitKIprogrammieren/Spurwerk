import SwiftUI
import MapKit

/// Fehlendes Stück am Anfang oder Ende einer Strecke selbst einzeichnen:
/// Punkte entlang des echten Wegs antippen, der NUC legt die Straße dazwischen.
struct StreckeKorrigierenView: View {
    let fahrt: Fahrt
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var abgleich: Abgleich

    @State private var wo = "anfang"
    @State private var tipps: [CLLocationCoordinate2D] = []
    @State private var form: [CLLocationCoordinate2D] = []
    @State private var laenge: Double = 0
    @State private var namen: [String] = []
    @State private var fehler: String?
    @State private var rechnet = false
    @State private var speichert = false
    @State private var server: URL?
    @State private var anfrageNr = 0
    @State private var position: MapCameraPosition = .automatic

    private var linie: [CLLocationCoordinate2D] {
        if let s = fahrt.spur, s.count > 1 { return s }
        return fahrt.rohKoordinaten
    }

    /// Wo das neue Stück an die Strecke anschließt
    private var anker: CLLocationCoordinate2D? { wo == "anfang" ? linie.first : linie.last }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Wo fehlt etwas?", selection: $wo) {
                    Text("Anfang ergänzen").tag("anfang")
                    Text("Ende ergänzen").tag("ende")
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                MapReader { proxy in
                    Map(position: $position) {
                        if linie.count > 1 {
                            MapPolyline(coordinates: linie)
                                .stroke(fahrt.art.farbe, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                        }
                        if form.count > 1 {
                            MapPolyline(coordinates: form)
                                .stroke(Color.orange, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round, dash: [8, 6]))
                        }
                        if let anker {
                            Annotation("", coordinate: anker) {
                                Circle().fill(.white).frame(width: 12, height: 12)
                                    .overlay(Circle().stroke(fahrt.art.farbe, lineWidth: 3))
                            }
                        }
                        ForEach(Array(tipps.enumerated()), id: \.offset) { i, p in
                            Annotation("", coordinate: p) {
                                Text("\(i + 1)")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.black)
                                    .frame(width: 24, height: 24)
                                    .background(Circle().fill(Color.orange))
                            }
                        }
                    }
                    .mapStyle(.standard(pointsOfInterest: .excludingAll))
                    .onTapGesture { stelle in
                        guard let c = proxy.convert(stelle, from: .local), tipps.count < 25 else { return }
                        tipps.append(c)
                        vorschau()
                    }
                    .overlay(alignment: .top) {
                        Text(wo == "anfang"
                             ? "Tippe deinen Weg vom Start bis zur Linie"
                             : "Tippe deinen Weg von der Linie bis zum Ziel")
                            .font(.footnote)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.black.opacity(0.7), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(.top, 10)
                    }
                }

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let fehler {
                            Text(fehler).font(.footnote).foregroundStyle(.red)
                        } else if tipps.isEmpty {
                            Text("Noch keine Punkte").font(.subheadline.weight(.medium))
                        } else {
                            Text("\(tipps.count) Punkte · \(Format.km(laenge))").font(.subheadline.weight(.medium))
                            Text(namen.joined(separator: " → "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer()
                    if rechnet { ProgressView().padding(.trailing, 6) }
                    Button {
                        if !tipps.isEmpty { tipps.removeLast() }
                        vorschau()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .padding(8)
                            .background(Circle().strokeBorder(Color.secondary.opacity(0.5)))
                    }
                    .disabled(tipps.isEmpty)
                }
                .padding()
            }
            .navigationTitle("Strecke korrigieren")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if speichert {
                        ProgressView()
                    } else {
                        Button("Fertig") { uebernehmen() }
                            .disabled(form.count < 2 || rechnet || server == nil)
                    }
                }
            }
            .onChange(of: wo) { _, _ in
                tipps = []
                vorschau()
            }
            .task {
                server = await abgleich.erreichbarerSpurServer()
                if server == nil { fehler = "NUC nicht erreichbar – Tailscale an?" }
            }
        }
    }

    private func anfrage(vorschau: Bool) -> [String: Any] {
        ["id": fahrt.id.uuidString, "wo": wo,
         "punkte": tipps.map { [$0.latitude, $0.longitude] }, "vorschau": vorschau]
    }

    private static func koordinaten(_ wert: Any?) -> [CLLocationCoordinate2D] {
        ((wert as? [[Double]]) ?? []).compactMap { $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil }
    }

    /// Nach jedem Tipp die Straße neu berechnen lassen (ältere Antworten werden verworfen).
    private func vorschau() {
        anfrageNr += 1
        let nr = anfrageNr
        guard !tipps.isEmpty, let server else {
            form = []; laenge = 0; namen = []
            return
        }
        let inhalt = anfrage(vorschau: true)
        rechnet = true
        Task {
            do {
                let r = try await SyncArbeiter.senden(inhalt, an: server.appendingPathComponent("api/korrigieren"))
                guard nr == anfrageNr else { return }
                form = Self.koordinaten(r["form"])
                laenge = r["laenge"] as? Double ?? 0
                namen = r["namen"] as? [String] ?? []
                fehler = nil
            } catch {
                guard nr == anfrageNr else { return }
                fehler = error.localizedDescription
            }
            if nr == anfrageNr { rechnet = false }
        }
    }

    private func uebernehmen() {
        guard let server else { return }
        let inhalt = anfrage(vorschau: false)
        speichert = true
        Task {
            do {
                let r = try await SyncArbeiter.senden(inhalt, an: server.appendingPathComponent("api/korrigieren"))
                let alle = (r["punkte"] as? [[Double]]) ?? []
                let alt = fahrt.punkte
                let zusatz = max(0, alle.count - alt.count)
                func punkt(_ q: [Double]) -> Punkt {
                    Punkt(lat: q[0], lon: q[1], zeit: q.count > 2 ? q[2] : 0, genauigkeit: 20, tempo: -1)
                }
                let neu = wo == "anfang"
                    ? alle.prefix(zusatz).filter { $0.count > 2 }.map(punkt) + alt
                    : alt + alle.suffix(zusatz).filter { $0.count > 2 }.map(punkt)
                fahrt.punkte = neu
                if let erster = neu.first { fahrt.start = Date(timeIntervalSince1970: erster.zeit) }
                if let letzter = neu.last { fahrt.ende = Date(timeIntervalSince1970: letzter.zeit) }
                fahrt.distanzMeter += r["laenge"] as? Double ?? 0
                fahrt.status = .wartet
                fahrt.mussHoch = false   // der NUC hat die neuen Punkte schon
                try? context.save()
                abgleich.geaendert()
                dismiss()
            } catch {
                fehler = error.localizedDescription
                speichert = false
            }
        }
    }
}
