import SwiftUI

enum Spanne: String, CaseIterable, Identifiable {
    case tag, woche, monat, jahr, alles
    var id: String { rawValue }
    var name: String {
        switch self {
        case .tag: "Tag"
        case .woche: "Woche"
        case .monat: "Monat"
        case .jahr: "Jahr"
        case .alles: "Alles"
        }
    }
}

/// Gewählter Zeitraum – gilt für Karte und Strecken gemeinsam.
@MainActor
final class ZeitFilter: ObservableObject {
    static let shared = ZeitFilter()

    @Published var spanne: Spanne {
        didSet {
            versatz = 0
            UserDefaults.standard.set(spanne.rawValue, forKey: "spanne")
        }
    }
    @Published var versatz = 0

    private let kalender: Calendar = {
        var k = Calendar(identifier: .gregorian)
        k.locale = Locale(identifier: "de_DE")
        k.firstWeekday = 2
        return k
    }()

    init() {
        spanne = Spanne(rawValue: UserDefaults.standard.string(forKey: "spanne") ?? "") ?? .tag
    }

    /// Ändert sich bei jedem anderen Zeitraum – für onChange.
    var schluessel: String { "\(spanne.rawValue)\(versatz)" }

    var kannVor: Bool { versatz < 0 && spanne != .alles }

    func zurueck() { if spanne != .alles { versatz -= 1 } }
    func vor() { if kannVor { versatz += 1 } }

    var bereich: (von: Date, bis: Date) {
        let heute = kalender.startOfDay(for: Date())
        switch spanne {
        case .tag:
            let von = kalender.date(byAdding: .day, value: versatz, to: heute)!
            return (von, kalender.date(byAdding: .day, value: 1, to: von)!)
        case .woche:
            let start = kalender.dateInterval(of: .weekOfYear, for: heute)!.start
            let von = kalender.date(byAdding: .weekOfYear, value: versatz, to: start)!
            return (von, kalender.date(byAdding: .weekOfYear, value: 1, to: von)!)
        case .monat:
            let start = kalender.dateInterval(of: .month, for: heute)!.start
            let von = kalender.date(byAdding: .month, value: versatz, to: start)!
            return (von, kalender.date(byAdding: .month, value: 1, to: von)!)
        case .jahr:
            let start = kalender.dateInterval(of: .year, for: heute)!.start
            let von = kalender.date(byAdding: .year, value: versatz, to: start)!
            return (von, kalender.date(byAdding: .year, value: 1, to: von)!)
        case .alles:
            return (.distantPast, .distantFuture)
        }
    }

    /// Enthält der Zeitraum den heutigen Tag? (dann zählt eine laufende Aufnahme mit)
    var enthaeltJetzt: Bool {
        let b = bereich
        return b.von <= Date() && Date() < b.bis
    }

    var text: String {
        let (von, bis) = bereich
        let de = Locale(identifier: "de_DE")
        switch spanne {
        case .tag:
            if versatz == 0 { return "Heute" }
            if versatz == -1 { return "Gestern" }
            let mitJahr = !kalender.isDate(von, equalTo: Date(), toGranularity: .year)
            return mitJahr
                ? von.formatted(.dateTime.weekday(.wide).day().month(.wide).year().locale(de))
                : von.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(de))
        case .woche:
            if versatz == 0 { return "Diese Woche" }
            let ende = kalender.date(byAdding: .day, value: -1, to: bis)!
            return "\(von.formatted(.dateTime.day().month(.abbreviated).locale(de))) – \(ende.formatted(.dateTime.day().month(.abbreviated).year().locale(de)))"
        case .monat:
            return von.formatted(.dateTime.month(.wide).year().locale(de))
        case .jahr:
            return von.formatted(.dateTime.year().locale(de))
        case .alles:
            return "Alle Strecken"
        }
    }
}

/// Leiste mit Pfeilen und Zeitraum-Auswahl.
struct ZeitLeiste: View {
    @ObservedObject var zeit = ZeitFilter.shared

    var body: some View {
        HStack(spacing: 6) {
            Button { withAnimation(.snappy) { zeit.zurueck() } } label: {
                Image(systemName: "chevron.left").frame(width: 36, height: 36)
            }
            .disabled(zeit.spanne == .alles)

            Menu {
                Picker("Zeitraum", selection: $zeit.spanne) {
                    ForEach(Spanne.allCases) { Text($0.name).tag($0) }
                }
                if zeit.versatz != 0 {
                    Button("Zurück zu heute") { zeit.versatz = 0 }
                }
            } label: {
                VStack(spacing: 0) {
                    Text(zeit.text).font(.subheadline.weight(.semibold)).lineLimit(1)
                    HStack(spacing: 3) {
                        Text(zeit.spanne.name)
                        Image(systemName: "chevron.down")
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .foregroundStyle(.primary)

            Button { withAnimation(.snappy) { zeit.vor() } } label: {
                Image(systemName: "chevron.right").frame(width: 36, height: 36)
            }
            .disabled(!zeit.kannVor)
        }
        .font(.body.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.94), in: Capsule())
    }
}
