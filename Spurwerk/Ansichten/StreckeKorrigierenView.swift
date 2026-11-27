import SwiftUI
import MapKit

/// Fehlendes Stück am Anfang oder Ende einer Strecke selbst einzeichnen
/// (Punkte antippen, der NUC legt die Straße dazwischen) oder falsche Teile löschen.
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
    // Löschen-Modus
    @State private var markA: Int?
    @State private var markB: Int?
    @State private var schnitt: String?   // "vorne", "hinten", "mitte"

    private var loeschen: Bool { wo == "loeschen" }
    private var neuZeichnen: Bool { wo == "neu" }

    private var linie: [CLLocationCoordinate2D] {
        if let s = fahrt.spur, s.count > 1 { return s }
        return fahrt.rohKoordinaten
    }

    /// Wo das neue Stück an die Strecke anschließt
    private var anker: CLLocationCoordinate2D? {
        loeschen || neuZeichnen ? nil : (wo == "anfang" ? linie.first : linie.last)
    }

    private func koord(_ i: Int) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: fahrt.punkte[i].lat, longitude: fahrt.punkte[i].lon)
    }

    /// Bleibt der Punkt mit dieser Zeit stehen? (gleiche Regel wie auf dem NUC)
    private func behalten(_ t: Double) -> Bool {
        guard let schnitt, let a = markA else { return true }
        let ta = fahrt.punkte[a].zeit
        switch schnitt {
        case "vorne": return t >= ta
        case "hinten": return t <= ta
        default:
            guard let b = markB else { return true }
            let tb = fahrt.punkte[b].zeit
            return t <= min(ta, tb) || t >= max(ta, tb)
        }
    }

    /// Die Teile, die gelöscht würden (zusammenhängende Stücke, rot angezeigt)
    private var wegStuecke: [[CLLocationCoordinate2D]] {
        guard schnitt != nil else { return [] }
        var stuecke: [[CLLocationCoordinate2D]] = []
        var aktuell: [CLLocationCoordinate2D] = []
        for (i, p) in fahrt.punkte.enumerated() {
            if !behalten(p.zeit) {
                if aktuell.isEmpty, i > 0 { aktuell.append(koord(i - 1)) }
                aktuell.append(koord(i))
            } else if !aktuell.isEmpty {
                aktuell.append(koord(i))
                stuecke.append(aktuell); aktuell = []
            }
        }
        if aktuell.count > 1 { stuecke.append(aktuell) }
        return stuecke
    }

    private var wegLaenge: Double {
        wegStuecke.reduce(0) { summe, st in
            summe + zip(st, st.dropFirst()).reduce(0) {
                $0 + CLLocation(latitude: $1.0.latitude, longitude: $1.0.longitude)
                    .distance(from: CLLocation(latitude: $1.1.latitude, longitude: $1.1.longitude))
            }
        }
    }

    private var wegAnzahl: Int { fahrt.punkte.filter { !behalten($0.zeit) }.count }

    /// Nächster aufgezeichneter Punkt zur angetippten Stelle
    private func naechster(_ c: CLLocationCoordinate2D) -> Int? {
        guard !fahrt.punkte.isEmpty else { return nil }
        let k = cos(c.latitude * .pi / 180)
        var best = 0, bestD = Double.infinity
        for (i, p) in fahrt.punkte.enumerated() {
            let d = pow(p.lat - c.latitude, 2) + pow((p.lon - c.longitude) * k, 2)
            if d < bestD { bestD = d; best = i }
        }
        return best
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Wo fehlt etwas?", selection: $wo) {
                    Text("Anfang +").tag("anfang")
                    Text("Ende +").tag("ende")
                    Text("Neu").tag("neu")
                    Text("Löschen").tag("loeschen")
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                MapReader { proxy in
                    Map(position: $position) {
                        if linie.count > 1 {
                            MapPolyline(coordinates: linie)
                                .stroke(fahrt.art.farbe.opacity(neuZeichnen ? 0.35 : 1), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                        }
                        if form.count > 1 {
                            MapPolyline(coordinates: form)
                                .stroke(Color.orange, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round, dash: [8, 6]))
                        }
                        ForEach(Array(wegStuecke.enumerated()), id: \.offset) { _, st in
                            MapPolyline(coordinates: st)
                                .stroke(Color.red, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round, dash: [9, 6]))
                        }
                        ForEach(Array([markA, markB].compactMap { $0 }.enumerated()), id: \.offset) { n, i in
                            Annotation("", coordinate: koord(i)) {
                                Text(n == 0 ? "A" : "B")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 24, height: 24)
                                    .background(Circle().fill(Color.black.opacity(0.8)))
                            }
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
                        guard let c = proxy.convert(stelle, from: .local) else { return }
                        if loeschen {
                            guard let i = naechster(c) else { return }
                            if markA == nil || markB != nil {
                                markA = i; markB = nil; schnitt = nil
                            } else if i != markA {
                                markB = i; schnitt = "mitte"
                            }
                            fehler = nil
                            return
                        }
                        guard tipps.count < (neuZeichnen ? 80 : 25) else { return }
                        tipps.append(c)
                        vorschau()
                    }
                    .overlay(alignment: .top) {
                        Text(loeschen
                             ? "Tippe 1 oder 2 Stellen auf der Linie"
                             : neuZeichnen
                             ? (fahrt.art == .fuss ? "Tippe deinen ganzen Weg – wird genau so übernommen"
                                                   : "Tippe deinen ganzen Weg auf die Straßen, Start bis Ziel")
                             : wo == "anfang"
                             ? "Tippe deinen Weg vom Start bis zur Linie"
                             : "Tippe deinen Weg von der Linie bis zum Ziel")
                            .font(.footnote)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.black.opacity(0.7), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(.top, 10)
                    }
                }

                if loeschen {
                    loeschenLeiste
                } else {
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
                            .disabled(loeschen ? (schnitt == nil || server == nil) : (form.count < 2 || rechnet || server == nil))
                    }
                }
            }
            .onChange(of: wo) { _, _ in
                tipps = []
                markA = nil; markB = nil; schnitt = nil
                vorschau()
            }
            .task {
                server = await abgleich.erreichbarerSpurServer()
                if server == nil { fehler = "NUC nicht erreichbar – Tailscale an?" }
            }
        }
    }

    private var loeschenLeiste: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let fehler {
                Text(fehler).font(.footnote).foregroundStyle(.red)
            } else if markA == nil {
                Text("Tippe auf die Stelle, wo es falsch wird").font(.subheadline.weight(.medium))
            } else if schnitt == nil {
                Text("Was soll weg? Oder tippe eine zweite Stelle (B) an").font(.subheadline.weight(.medium))
            } else {
                Text("Wird gelöscht: \(Format.km(wegLaenge)) · \(wegAnzahl) Punkte")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.red)
            }
            if markA != nil {
                HStack(spacing: 8) {
                    if markB == nil {
                        wahl("Davor löschen", "vorne")
                        wahl("Danach löschen", "hinten")
                    } else {
                        wahl("Zwischen A und B löschen", "mitte")
                    }
                    Button {
                        markA = nil; markB = nil; schnitt = nil
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .padding(8)
                            .background(Circle().strokeBorder(Color.secondary.opacity(0.5)))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    private func wahl(_ titel: String, _ art: String) -> some View {
        Button {
            schnitt = schnitt == art ? nil : art
        } label: {
            Text(titel)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(schnitt == art ? Color.red.opacity(0.18) : Color(.secondarySystemBackground)))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(schnitt == art ? Color.red : Color.clear))
                .foregroundStyle(schnitt == art ? Color.red : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func anfrage(vorschau: Bool) -> [String: Any] {
        if neuZeichnen {
            return ["id": fahrt.id.uuidString, "neu": tipps.map { [$0.latitude, $0.longitude] }, "vorschau": vorschau]
        }
        return ["id": fahrt.id.uuidString, "wo": wo,
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

    private func kuerzen() {
        guard let server, let schnitt, let a = markA else { return }
        var inhalt: [String: Any] = ["id": fahrt.id.uuidString, "kuerzen": schnitt, "zeit": fahrt.punkte[a].zeit]
        if let b = markB { inhalt["bis"] = fahrt.punkte[b].zeit }
        let bleiben = fahrt.punkte.filter { behalten($0.zeit) }
        guard bleiben.count >= 2 else {
            fehler = "Danach wäre von der Strecke nichts mehr übrig"
            return
        }
        let weg = wegLaenge
        speichert = true
        Task {
            do {
                _ = try await SyncArbeiter.senden(inhalt, an: server.appendingPathComponent("api/korrigieren"))
                fahrt.punkte = bleiben
                if let erster = bleiben.first { fahrt.start = Date(timeIntervalSince1970: erster.zeit) }
                if let letzter = bleiben.last { fahrt.ende = Date(timeIntervalSince1970: letzter.zeit) }
                fahrt.distanzMeter = max(0, fahrt.distanzMeter - weg)
                fahrt.status = .wartet
                fahrt.mussHoch = false   // der NUC hat schon gekürzt
                try? context.save()
                abgleich.geaendert()
                dismiss()
            } catch {
                fehler = error.localizedDescription
                speichert = false
            }
        }
    }

    private func uebernehmen() {
        if loeschen { kuerzen(); return }
        guard let server else { return }
        let inhalt = anfrage(vorschau: false)
        speichert = true
        Task {
            do {
                let r = try await SyncArbeiter.senden(inhalt, an: server.appendingPathComponent("api/korrigieren"))
                let alle = (r["punkte"] as? [[Double]]) ?? []
                if neuZeichnen {
                    // Ganze Strecke ersetzt – der NUC hat die Linie schon fertig
                    let neu = alle.filter { $0.count > 2 }
                        .map { Punkt(lat: $0[0], lon: $0[1], zeit: $0[2], genauigkeit: 10, tempo: -1) }
                    guard neu.count > 1 else { throw SyncArbeiter.Fehler(text: "Zu wenige Punkte") }
                    fahrt.punkte = neu
                    fahrt.spur = Self.koordinaten(r["form"])
                    fahrt.spurVersion += 1
                    fahrt.start = Date(timeIntervalSince1970: neu[0].zeit)
                    fahrt.ende = Date(timeIntervalSince1970: neu[neu.count - 1].zeit)
                    fahrt.distanzMeter = r["laenge"] as? Double ?? fahrt.distanzMeter
                    fahrt.status = .fertig
                    fahrt.fehlertext = nil
                    fahrt.mussHoch = false
                    try? context.save()
                    abgleich.geaendert()
                    dismiss()
                    return
                }
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
