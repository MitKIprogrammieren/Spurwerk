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

    var body: some View {
        TabView {
            KartenView()
                .tabItem { Label("Karte", systemImage: "map") }
            FahrtenListe()
                .tabItem { Label("Fahrten", systemImage: "car") }
            EinstellungenView()
                .tabItem { Label("Einstellungen", systemImage: "gearshape") }
        }
        .tint(.teal)
        .onChange(of: phase) { _, neu in
            guard neu == .active, let container = recorder.container else { return }
            Task { await Abgleich.shared.ausstehendeAbgleichen(container: container) }
        }
    }
}
