import SwiftUI
import SwiftData
import CoreLocation

/// Wofür eine Autofahrt war – nur für den eigenen Überblick.
enum Zweck: String, CaseIterable, Identifiable {
    case arbeit, privat, dienstlich
    var id: String { rawValue }

    var name: String {
        switch self {
        case .arbeit: "Arbeit"
        case .privat: "Privat"
        case .dienstlich: "Dienstlich"
        }
    }

    var farbe: Color {
        switch self {
        case .arbeit: Color(red: 0.52, green: 0.72, blue: 0.92)
        case .privat: Color(red: 0.36, green: 0.79, blue: 0.65)
        case .dienstlich: Color(red: 0.94, green: 0.62, blue: 0.15)
        }
    }
}

/// Rechnet den Tachostand für jeden Zeitpunkt aus: ein eingegebener Stand plus/minus die gefahrenen Kilometer.
struct TachoRechner {
    private let enden: [Date]
    private let summen: [Double]      // Meter bis einschließlich Fahrt i
    let stand: Double?                // eingegebener Tachostand in km
    let zeit: Date

    init(fahrten: [(ende: Date, distanz: Double)]) {
        var e: [Date] = [], s: [Double] = [], laufend = 0.0
        for f in fahrten {
            laufend += f.distanz
            e.append(f.ende)
            s.append(laufend)
        }
        enden = e
        summen = s
        let d = UserDefaults.standard
        stand = d.object(forKey: "tachoStand") as? Double
        zeit = Date(timeIntervalSince1970: d.double(forKey: "tachoZeit"))
    }

    /// Meter aller Autofahrten, die bis zu diesem Zeitpunkt geendet haben
    private func meter(bis d: Date) -> Double {
        var lo = 0, hi = enden.count
        while lo < hi {
            let mitte = (lo + hi) / 2
            if enden[mitte] <= d { lo = mitte + 1 } else { hi = mitte }
        }
        return lo == 0 ? 0 : summen[lo - 1]
    }

    func km(bei d: Date) -> Double? {
        guard let stand else { return nil }
        return stand + (meter(bis: d) - meter(bis: zeit)) / 1000
    }

    static func setzen(_ km: Double) {
        UserDefaults.standard.set(km, forKey: "tachoStand")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "tachoZeit")
    }
}

struct FahrtenbuchView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var abgleich: Abgleich
    @ObservedObject private var cache = SpurCache.shared
    @ObservedObject private var namen = OrtNamen.shared

    @State private var monat = Calendar.current.dateInterval(of: .month, for: Date())!.start
    @State private var fahrten: [Fahrt] = []
    @State private var vorschlaege: [String: Zweck] = [:]
    @State private var tacho = TachoRechner(fahrten: [])
    @State private var tachoEingabe = false
    @State private var tachoText = ""
    @State private var notizFahrt: Fahrt?
    @State private var notizText = ""
    @State private var export: URL?

    private static let de = Locale(identifier: "de_DE")

    private var monatEnde: Date { Calendar.current.date(byAdding: .month, value: 1, to: monat)! }

    private func laden() {
        let von = monat, bis = monatEnde, auto = FahrtArt.auto.rawValue
        let d = FetchDescriptor<Fahrt>(predicate: #Predicate { $0.start >= von && $0.start < bis && $0.artText == auto },
                                       sortBy: [SortDescriptor(\.start, order: .reverse)])
        fahrten = ((try? context.fetch(d)) ?? []).filter { $0.status != .aufnahme }

        // Vorschläge: gleiche Strecke (Start und Ziel je ~100 m) schon einmal zugeordnet
        let mitZweck = (try? context.fetch(FetchDescriptor<Fahrt>(predicate: #Predicate { $0.zweck != "" }))) ?? []
        var v: [String: Zweck] = [:]
        for f in mitZweck.sorted(by: { $0.start < $1.start }) {
            if let k = streckenSchluessel(f), let z = Zweck(rawValue: f.zweck) { v[k] = z }
        }
        vorschlaege = v
        tacho = TachoRechner(fahrten: cache.autoKilometer())
        exportBauen()
    }

    private func streckenSchluessel(_ f: Fahrt) -> String? {
        guard let a = cache.anfangZiel(f.id) else { return nil }
        func r(_ x: Double) -> Int { Int((x * 1000).rounded()) }
        return "\(r(a.0.latitude)),\(r(a.0.longitude))-\(r(a.1.latitude)),\(r(a.1.longitude))"
    }

    private func setzen(_ f: Fahrt, _ z: Zweck?) {
        f.zweck = z?.rawValue ?? ""
        try? context.save()
        laden()
    }

    private func ort(_ c: CLLocationCoordinate2D?) -> String {
        guard let c else { return "?" }
        return namen.name(c.latitude, c.longitude) ?? "…"
    }

    // MARK: - Ansicht

    var body: some View {
        List {
            Section {
                HStack {
                    Button { monat = Calendar.current.date(byAdding: .month, value: -1, to: monat)! } label: {
                        Image(systemName: "chevron.left")
                    }
                    Spacer()
                    Text(monat.formatted(.dateTime.month(.wide).year().locale(Self.de)))
                        .font(.headline)
                    Spacer()
                    Button { monat = Calendar.current.date(byAdding: .month, value: 1, to: monat)! } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(monatEnde > Date())
                }
                .buttonStyle(.borderless)
            }

            Section { uebersicht }

            ForEach(tage, id: \.0) { tag, liste in
                Section(tag.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Self.de))) {
                    ForEach(liste) { zeile($0) }
                }
            }

            if fahrten.isEmpty {
                Text("Keine Autofahrten in diesem Monat.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Fahrtenbuch")
        .toolbar {
            if let export {
                ShareLink(item: export) { Image(systemName: "square.and.arrow.up") }
            }
        }
        .onAppear { laden() }
        .onChange(of: monat) { _, _ in laden() }
        .onChange(of: abgleich.version) { _, _ in laden() }
        .onChange(of: namen.version) { _, _ in exportBauen() }
        .alert("Tachostand", isPresented: $tachoEingabe) {
            TextField("z. B. 87412", text: $tachoText).keyboardType(.numberPad)
            Button("Speichern") {
                if let km = Double(tachoText.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")) {
                    TachoRechner.setzen(km)
                    laden()
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Was zeigt dein Tacho gerade? Daraus rechnet die App den Stand für jede Fahrt.")
        }
        .alert("Notiz", isPresented: Binding(get: { notizFahrt != nil }, set: { if !$0 { notizFahrt = nil } })) {
            TextField("z. B. Kunde Meier, Baumarkt", text: $notizText)
            Button("Speichern") {
                notizFahrt?.notiz = notizText.trimmingCharacters(in: .whitespaces)
                try? context.save()
                notizFahrt = nil
                laden()
            }
            Button("Abbrechen", role: .cancel) { notizFahrt = nil }
        }
    }

    private var tage: [(Date, [Fahrt])] {
        let gruppen = Dictionary(grouping: fahrten) { Calendar.current.startOfDay(for: $0.start) }
        return gruppen.keys.sorted(by: >).map { ($0, gruppen[$0]!) }
    }

    private var uebersicht: some View {
        let gesamt = fahrten.reduce(0) { $0 + $1.distanzMeter }
        var jeZweck: [Zweck?: Double] = [:]
        for f in fahrten { jeZweck[Zweck(rawValue: f.zweck), default: 0] += f.distanzMeter }
        let reihen: [(Zweck?, Double)] = Zweck.allCases.map { ($0, jeZweck[$0] ?? 0) } + [(nil, jeZweck[nil] ?? 0)]

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gesamt · \(fahrten.count) Fahrten").font(.caption).foregroundStyle(FahrtArt.auto.farbe)
                    Text(Format.km(gesamt)).font(.title3.weight(.semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(FahrtArt.auto.farbe.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

                Button {
                    tachoText = tacho.km(bei: Date()).map { String(Int($0.rounded())) } ?? ""
                    tachoEingabe = true
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tacho jetzt").font(.caption).foregroundStyle(.secondary)
                        if let km = tacho.km(bei: Date()) {
                            Text("\(Format.anzahl(Int(km.rounded()))) km").font(.title3.weight(.semibold))
                        } else {
                            Text("Eingeben").font(.title3.weight(.semibold)).foregroundStyle(.tint)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }

            if gesamt > 0 {
                GeometryReader { g in
                    HStack(spacing: 0) {
                        ForEach(reihen, id: \.0?.rawValue) { z, m in
                            Rectangle()
                                .fill(z?.farbe ?? Color.secondary.opacity(0.35))
                                .frame(width: g.size.width * m / gesamt)
                        }
                    }
                }
                .frame(height: 8)
                .clipShape(Capsule())

                FlowZeile(reihen.filter { $0.1 > 0 }.map { z, m in
                    (z?.farbe ?? .secondary, "\(z?.name ?? "Offen") \(Format.km(m))")
                })
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func zeile(_ f: Fahrt) -> some View {
        let uhr = Date.FormatStyle.dateTime.hour().minute().locale(Self.de)
        let az = cache.anfangZiel(f.id)
        let zweck = Zweck(rawValue: f.zweck)
        let vorschlag = zweck == nil ? streckenSchluessel(f).flatMap { vorschlaege[$0] } : nil

        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("\(f.start.formatted(uhr)) – \((f.ende ?? f.start).formatted(uhr))")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(Format.km(f.distanzMeter)).font(.subheadline.weight(.semibold))
            }
            Text("\(ort(az?.0)) → \(ort(az?.1))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack {
                Menu {
                    ForEach(Zweck.allCases) { z in
                        Button { setzen(f, z) } label: {
                            Label(z.name, systemImage: zweck == z ? "checkmark" : "circle")
                        }
                    }
                    Divider()
                    Button { notizText = f.notiz; notizFahrt = f } label: { Label("Notiz …", systemImage: "square.and.pencil") }
                    if zweck != nil {
                        Button(role: .destructive) { setzen(f, nil) } label: { Label("Zurücksetzen", systemImage: "xmark") }
                    }
                } label: {
                    ZweckChip(zweck: zweck, vorschlag: vorschlag, notiz: f.notiz)
                }
                if let vorschlag {
                    Button("Übernehmen") { setzen(f, vorschlag) }
                        .font(.caption.weight(.medium))
                        .buttonStyle(.borderless)
                }
                Spacer()
                if let ende = tacho.km(bei: f.ende ?? f.start) {
                    let start = ende - f.distanzMeter / 1000
                    Text("\(Format.anzahl(Int(start.rounded()))) → \(Format.anzahl(Int(ende.rounded())))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .task {
            if let az {
                namen.anfragen(az.0.latitude, az.0.longitude)
                namen.anfragen(az.1.latitude, az.1.longitude)
            }
        }
    }

    // MARK: - Export als Tabelle (CSV für Numbers/Excel)

    private func exportBauen() {
        guard !fahrten.isEmpty else { export = nil; return }
        let tag = Date.FormatStyle.dateTime.day(.twoDigits).month(.twoDigits).year().locale(Self.de)
        let uhr = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Self.de)
        func feld(_ s: String) -> String { "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" }
        func zahl(_ x: Double, _ stellen: Int) -> String {
            x.formatted(.number.precision(.fractionLength(stellen)).grouping(.never).locale(Self.de))
        }
        var zeilen = ["Datum;Beginn;Ende;Start;Ziel;km;Zweck;Notiz;Tacho Beginn;Tacho Ende"]
        for f in fahrten.reversed() {
            let az = cache.anfangZiel(f.id)
            let tachoEnde = tacho.km(bei: f.ende ?? f.start)
            zeilen.append([
                f.start.formatted(tag), f.start.formatted(uhr), (f.ende ?? f.start).formatted(uhr),
                feld(ort(az?.0)), feld(ort(az?.1)), zahl(f.distanzMeter / 1000, 1),
                Zweck(rawValue: f.zweck)?.name ?? "", feld(f.notiz),
                tachoEnde.map { zahl($0 - f.distanzMeter / 1000, 0) } ?? "", tachoEnde.map { zahl($0, 0) } ?? "",
            ].joined(separator: ";"))
        }
        let k = Calendar.current.dateComponents([.year, .month], from: monat)
        let name = String(format: "Fahrtenbuch-%04d-%02d.csv", k.year ?? 0, k.month ?? 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        // Mit BOM, damit Excel die Umlaute richtig liest
        let text = "\u{FEFF}" + zeilen.joined(separator: "\r\n")
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
        export = url
    }
}

/// Zweck-Etikett einer Fahrt; ohne Zweck gestrichelt, mit Vorschlag als Hinweis.
struct ZweckChip: View {
    let zweck: Zweck?
    let vorschlag: Zweck?
    let notiz: String

    var body: some View {
        let text = zweck.map { notiz.isEmpty ? $0.name : "\($0.name) · \(notiz)" }
            ?? (vorschlag.map { "\($0.name)?" } ?? "Zweck wählen")
        Text(text)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .foregroundStyle(zweck?.farbe ?? .secondary)
            .background {
                if let zweck {
                    Capsule().fill(zweck.farbe.opacity(0.16))
                } else {
                    Capsule().strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
    }
}

/// Einfache Legende: farbiger Punkt plus Text, nebeneinander.
struct FlowZeile: View {
    let eintraege: [(Color, String)]
    init(_ e: [(Color, String)]) { eintraege = e }

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(eintraege.enumerated()), id: \.offset) { _, e in
                HStack(spacing: 4) {
                    Circle().fill(e.0).frame(width: 8, height: 8)
                    Text(e.1).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
