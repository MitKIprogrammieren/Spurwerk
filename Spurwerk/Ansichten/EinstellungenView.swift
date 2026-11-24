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
        }
    }
}
