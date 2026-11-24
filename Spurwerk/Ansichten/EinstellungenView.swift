import SwiftUI
import CoreLocation

struct EinstellungenView: View {
    @EnvironmentObject private var recorder: FahrtRecorder
    @EnvironmentObject private var abgleich: Abgleich
    @AppStorage("serverHeim") private var serverHeim = Abgleich.standardHeim
    @AppStorage("serverUnterwegs") private var serverUnterwegs = Abgleich.standardUnterwegs

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
                    Toggle("Fahrten automatisch aufzeichnen", isOn: Binding(
                        get: { recorder.automatik },
                        set: { recorder.automatik = $0 }))
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
                    Text("Für die Automatik braucht die App „Immer“. Sie startet, sobald das iPhone eine Autofahrt erkennt, und stoppt nach 5 Minuten Stillstand oder wenn du losläufst.")
                }

                Section {
                    TextField("Heimnetz", text: $serverHeim)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Unterwegs (Tailscale)", text: $serverUnterwegs)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Verbindung testen") {
                        Task { await abgleich.verbindungTesten() }
                    }
                    Button("Alle offenen Fahrten jetzt abgleichen") {
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
                    Text("Die App probiert erst das Heimnetz, dann Tailscale. Ist keiner erreichbar, wartet die Fahrt und wird später abgeglichen.")
                }
            }
            .navigationTitle("Einstellungen")
        }
    }
}
