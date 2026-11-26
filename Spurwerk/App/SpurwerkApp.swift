import SwiftUI
import SwiftData

@main
struct SpurwerkApp: App {
    let container: ModelContainer
    @StateObject private var recorder = FahrtRecorder.shared
    @StateObject private var abgleich = Abgleich.shared

    init() {
        do {
            container = try ModelContainer(for: Fahrt.self)
        } catch {
            fatalError("Datenbank konnte nicht geöffnet werden: \(error)")
        }
        FahrtRecorder.shared.vorbereiten(container: container)
        // Einmalig nach dem Update: Genauigkeit berechnen, falsche Google-Fahrräder korrigieren
        if !UserDefaults.standard.bool(forKey: "wartung1") {
            let c = container
            Task.detached(priority: .utility) {
                let korrigiert = await Wartung(modelContainer: c).einmalig()
                UserDefaults.standard.set(true, forKey: "wartung1")
                UserDefaults.standard.set(korrigiert, forKey: "wartung1Korrigiert")
                await MainActor.run { Abgleich.shared.geaendert() }
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            HauptView()
                .environmentObject(recorder)
                .environmentObject(abgleich)
        }
        .modelContainer(container)
    }
}

struct HauptView: View {
    @Environment(\.scenePhase) private var phase
    @EnvironmentObject private var recorder: FahrtRecorder
    @AppStorage("erscheinung") private var erscheinung = "dunkel"

    private var schema: ColorScheme? {
        switch erscheinung {
        case "dunkel": .dark
        case "hell": .light
        default: nil
        }
    }

    var body: some View {
        TabView {
            KartenView()
                .tabItem { Label("Karte", systemImage: "map") }
            FahrtenListe()
                .tabItem { Label("Strecken", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
            EinstellungenView()
                .tabItem { Label("Einstellungen", systemImage: "gearshape") }
        }
        .tint(.teal)
        .preferredColorScheme(schema)
        .onChange(of: phase) { _, neu in
            guard neu == .active, let container = recorder.container else { return }
            SpurCache.shared.imVordergrund()
            Task { await Abgleich.shared.ausstehendeAbgleichen(container: container) }
        }
        .task {
            // Solange die App offen ist: jede Minute fertige Linien vom NUC abholen
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if phase == .active, let container = recorder.container {
                    await Abgleich.shared.ausstehendeAbgleichen(container: container)
                }
            }
        }
    }
}
