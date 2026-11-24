import SwiftUI
import CoreLocation
import UniformTypeIdentifiers

struct EinstellungenView: View {
    @EnvironmentObject private var recorder: FahrtRecorder
    @EnvironmentObject private var abgleich: Abgleich
    @AppStorage("serverHeim") private var serverHeim = Abgleich.standardHeim
    @AppStorage("serverUnterwegs") private var serverUnterwegs = Abgleich.standardUnterwegs
    @AppStorage("erscheinung") private var erscheinung = "dunkel"
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
                    Text("In der Google-Maps-App: Profilbild → Einstellungen → Persönliche Inhalte → Zeitachsendaten exportieren. Die Datei hier auswählen. Übernommen werden Auto-, Fuß- und Radstrecken; sie werden danach auf die Straßen gelegt. Doppelte Strecken werden übersprungen.")
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
                    Text("Kartendienst auf dem NUC")
                } footer: {
                    Text("Die App probiert erst das Heimnetz, dann Tailscale. Ist keiner erreichbar, wartet die Strecke und wird später abgeglichen. Fußwege werden auf Geh- und Feldwege gelegt, Autofahrten nur auf Straßen.")
                }
            }
            .navigationTitle("Einstellungen")
            .fileImporter(isPresented: $importZeigen, allowedContentTypes: [.json]) { ergebnis in
                guard case .success(let url) = ergebnis else { return }
                importieren(url)
            }
        }
    }

    private func importieren(_ url: URL) {
        importLaeuft = true
        importMeldung = nil
        Task {
            let zugriff = url.startAccessingSecurityScopedResource()
            defer { if zugriff { url.stopAccessingSecurityScopedResource() } }
            do {
                let daten = try Data(contentsOf: url)
                // Einlesen kann bei großen Dateien dauern – nicht auf dem Hauptthread
                let strecken = try await Task.detached(priority: .userInitiated) {
                    try GoogleImport.lesen(daten)
                }.value
                let ergebnis = GoogleImport.speichern(strecken, in: context)
                abgleich.geaendert()
                importMeldung = strecken.isEmpty
                    ? "Keine Auto-, Fuß- oder Radstrecken in der Datei gefunden."
                    : "\(ergebnis.neu) Strecken übernommen, \(ergebnis.doppelt) waren schon da. Sie werden jetzt nach und nach auf die Straßen gelegt."
                if let container = recorder.container {
                    Task { await abgleich.ausstehendeAbgleichen(container: container) }
                }
            } catch {
                importMeldung = "Die Datei konnte nicht gelesen werden: \(error.localizedDescription)"
            }
            importLaeuft = false
        }
    }
}
