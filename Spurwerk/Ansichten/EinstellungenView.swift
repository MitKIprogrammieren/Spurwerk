import SwiftUI
import CoreLocation
import UniformTypeIdentifiers

struct EinstellungenView: View {
    @EnvironmentObject private var recorder: FahrtRecorder
    @EnvironmentObject private var abgleich: Abgleich
    @AppStorage("serverHeim") private var serverHeim = Abgleich.standardHeim
    @AppStorage("serverUnterwegs") private var serverUnterwegs = Abgleich.standardUnterwegs
    @AppStorage("erscheinung") private var erscheinung = "dunkel"
    @AppStorage("spurHeim") private var spurHeim = Abgleich.standardSpurHeim
    @AppStorage("spurUnterwegs") private var spurUnterwegs = Abgleich.standardSpurUnterwegs
    @Environment(\.modelContext) private var context
    @State private var importZeigen = false
    @State private var importLaeuft = false
    @State private var importMeldung: String?

    private var berechtigungText: String {
        switch recorder.berechtigung {
        case .authorizedAlways: "Immer erlaubt"
        case .authorizedWhenInUse: "Nur beim Benutzen"
        case .denied, .restricted: "Abgelehnt"
        default: "Noch nicht gefragt"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: Binding(get: { recorder.automatikAuto },
                                         set: { recorder.automatikAuto = $0 })) {
                        Label("Autofahrten automatisch", systemImage: "car.fill")
                    }
                    Toggle(isOn: Binding(get: { recorder.automatikFuss },
                                         set: { recorder.automatikFuss = $0 })) {
                        Label("Fußwege automatisch", systemImage: "figure.walk")
                    }
                    LabeledContent("Standortzugriff", value: berechtigungText)
                    if recorder.berechtigung != .authorizedAlways {
                        Button("Standort „Immer“ erlauben") {
                            if recorder.berechtigung == .denied {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            } else {
                                recorder.berechtigungAnfragen()
                            }
                        }
                    }
                } header: {
                    Text("Aufzeichnung")
                } footer: {
                    Text("Für die Automatik braucht die App „Immer“. Sie startet, sobald das iPhone erkennt, dass du fährst oder läufst, und stoppt nach 5 Minuten Stillstand. Wege unter 100 m (z. B. in der Wohnung) werden verworfen. Fahrrad startest du von Hand.")
                }

                Section {
                    Button {
                        importZeigen = true
                    } label: {
                        Label("Google-Zeitachse importieren", systemImage: "square.and.arrow.down")
                    }
                    .disabled(importLaeuft)
                    if importLaeuft {
                        HStack { ProgressView(); Text("Lese Zeitachse …").foregroundStyle(.secondary) }
                    }
                    if let importMeldung {
                        Text(importMeldung).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Alter Verlauf")
                } footer: {
                    Text("In der Google-Maps-App: Profilbild → Einstellungen → Persönliche Inhalte → Zeitachsendaten exportieren. Die Datei hier auswählen – auch mehrere auf einmal, z. B. alle Monatsdateien aus einem alten Takeout-Export. Übernommen werden Auto-, Fuß- und Radstrecken; sie werden danach auf die Straßen gelegt. Doppelte Strecken werden übersprungen.")
                }

                Section {
                    Picker("Erscheinungsbild", selection: $erscheinung) {
                        Text("Dunkel").tag("dunkel")
                        Text("Hell").tag("hell")
                        Text("Wie iPhone").tag("system")
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Aussehen")
                }

                Section {
                    TextField("Heimnetz", text: $spurHeim)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Unterwegs (Tailscale)", text: $spurUnterwegs)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if let url = URL(string: spurHeim) {
                        Link(destination: url) {
                            Label("Im Browser öffnen", systemImage: "safari")
                        }
                    }
                } header: {
                    Text("Spurwerk auf dem NUC")
                } footer: {
                    Text("Die App lädt alle Strecken auf den NUC. Dort werden sie auf die Straße gelegt und gesichert – das iPhone muss dafür nicht offen bleiben. Im Browser siehst du alles unter derselben Adresse.")
                }

                Section {
                    TextField("Heimnetz", text: $serverHeim)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Unterwegs (Tailscale)", text: $serverUnterwegs)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Verbindung testen") {
                        Task { await abgleich.verbindungTesten() }
                    }
                    Button("Alle offenen Strecken jetzt abgleichen") {
                        guard let container = recorder.container else { return }
                        Task { await abgleich.ausstehendeAbgleichen(container: container, auchFehler: true) }
                    }
                    .disabled(abgleich.laeuft)
                    if let meldung = abgleich.meldung {
                        Text(meldung).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Kartendienst (Valhalla) – Ersatz, wenn Spurwerk-NUC fehlt")
                } footer: {
                    Text("Die App probiert erst das Heimnetz, dann Tailscale. Ist keiner erreichbar, wartet die Strecke und wird später abgeglichen. Fußwege werden auf Geh- und Feldwege gelegt, Autofahrten nur auf Straßen.")
                }
            }
            .navigationTitle("Einstellungen")
            .fileImporter(isPresented: $importZeigen, allowedContentTypes: [.json], allowsMultipleSelection: true) { ergebnis in
                guard case .success(let urls) = ergebnis, !urls.isEmpty else { return }
                importieren(urls)
            }
        }
    }

    /// Liest eine oder mehrere Zeitachsen-Dateien nacheinander ein (z. B. alle Takeout-Monatsdateien).
    private func importieren(_ urls: [URL]) {
        importLaeuft = true
        importMeldung = nil
        Task {
            var neu = 0, doppelt = 0, unlesbar: [String] = []
            for (nr, url) in urls.enumerated() {
                importMeldung = urls.count > 1 ? "Datei \(nr + 1) von \(urls.count): \(url.lastPathComponent)" : nil
                let zugriff = url.startAccessingSecurityScopedResource()
                defer { if zugriff { url.stopAccessingSecurityScopedResource() } }
                do {
                    let daten = try Data(contentsOf: url)
                    // Einlesen kann bei großen Dateien dauern – nicht auf dem Hauptthread
                    let (strecken, orte) = try await Task.detached(priority: .userInitiated) {
                        let strecken = try GoogleImport.lesen(daten)
                        return (strecken, GoogleImport.besuche(daten))
                    }.value
                    OrtNamen.shared.hinzufuegen(orte)
                    let ergebnis = GoogleImport.speichern(strecken, in: context)
                    neu += ergebnis.neu
                    doppelt += ergebnis.doppelt
                } catch {
                    unlesbar.append(url.lastPathComponent)
                }
            }
            abgleich.geaendert()
            var text = neu + doppelt == 0
                ? "Keine Auto-, Fuß- oder Radstrecken gefunden."
                : "\(neu) Strecken übernommen, \(doppelt) waren schon da. Sie werden jetzt nach und nach auf die Straßen gelegt."
            if !unlesbar.isEmpty {
                text += " Nicht lesbar: " + unlesbar.prefix(5).joined(separator: ", ") + (unlesbar.count > 5 ? " …" : "")
            }
            importMeldung = text
            importLaeuft = false
            if neu > 0, let container = recorder.container {
                Task { await abgleich.ausstehendeAbgleichen(container: container) }
            }
        }
    }
}
