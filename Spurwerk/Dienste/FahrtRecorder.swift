import Foundation
import CoreLocation
import CoreMotion
import SwiftData

/// Zeichnet Fahrten per GPS auf – von Hand oder automatisch, sobald das iPhone eine Autofahrt erkennt.
@MainActor
final class FahrtRecorder: NSObject, ObservableObject {
    static let shared = FahrtRecorder()

    @Published private(set) var nimmtAuf = false
    @Published private(set) var livePunkte: [CLLocationCoordinate2D] = []
    @Published private(set) var liveDistanz: Double = 0
    @Published private(set) var startZeit: Date?
    @Published private(set) var berechtigung: CLAuthorizationStatus = .notDetermined

    private(set) var container: ModelContainer?

    private let manager = CLLocationManager()
    private let bewegung = CMMotionActivityManager()
    private var punkte: [Punkt] = []
    private var letzterOrt: CLLocation?
    private var aktuelleFahrt: Fahrt?
    private var letztesSpeichern = Date.distantPast
    private var letzteBewegung = Date()
    private var gehenSeit: Date?
    private var automatischGestartet = false
    private var pruefTimer: Timer?
    private var hintergrundSitzung: CLBackgroundActivitySession?
    private var bewegungLaeuft = false

    /// Mindeststrecke, damit eine Fahrt behalten wird.
    private let mindestStrecke: Double = 300

    var automatik: Bool {
        get { UserDefaults.standard.object(forKey: "automatik") as? Bool ?? true }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: "automatik")
            if newValue && manager.authorizationStatus == .authorizedWhenInUse {
                manager.requestAlwaysAuthorization()
            }
            automatikAnwenden()
        }
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .automotiveNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 5
        manager.pausesLocationUpdatesAutomatically = false
        berechtigung = manager.authorizationStatus
    }

    func vorbereiten(container: ModelContainer) {
        self.container = container
        abgebrocheneFahrtenRetten()
        automatikAnwenden()
    }

    func berechtigungAnfragen() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        default: break
        }
    }

    // MARK: - Aufnahme

    func starten(automatisch: Bool = false) {
        guard !nimmtAuf, let container else { return }
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        let fahrt = Fahrt(start: Date())
        container.mainContext.insert(fahrt)
        try? container.mainContext.save()

        aktuelleFahrt = fahrt
        punkte = []
        livePunkte = []
        liveDistanz = 0
        letzterOrt = nil
        startZeit = fahrt.start
        letzteBewegung = Date()
        gehenSeit = nil
        automatischGestartet = automatisch
        nimmtAuf = true

        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        hintergrundSitzung = CLBackgroundActivitySession()
        manager.startUpdatingLocation()

        pruefTimer?.invalidate()
        pruefTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.stillstandPruefen() }
        }
    }

    func beenden() {
        guard nimmtAuf else { return }
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        pruefTimer?.invalidate()
        pruefTimer = nil
        hintergrundSitzung?.invalidate()
        hintergrundSitzung = nil
        nimmtAuf = false
        startZeit = nil

        guard let fahrt = aktuelleFahrt, let container else { return }
        aktuelleFahrt = nil
        let context = container.mainContext

        if liveDistanz < mindestStrecke {
            context.delete(fahrt)
        } else {
            fahrt.punkte = punkte
            fahrt.distanzMeter = liveDistanz
            fahrt.ende = Date()
            fahrt.status = .wartet
        }
        try? context.save()
        livePunkte = []
        punkte = []

        Task { await Abgleich.shared.ausstehendeAbgleichen(container: container) }
    }

    private func zwischenspeichern() {
        guard let fahrt = aktuelleFahrt else { return }
        fahrt.punkte = punkte
        fahrt.distanzMeter = liveDistanz
        try? container?.mainContext.save()
        letztesSpeichern = Date()
    }

    private func stillstandPruefen() {
        guard nimmtAuf else { return }
        if Date().timeIntervalSince(letztesSpeichern) > 30 { zwischenspeichern() }
        guard automatischGestartet else { return }
        // 5 Minuten kein Fahren oder 90 Sekunden zu Fuß → Fahrt ist vorbei
        if Date().timeIntervalSince(letzteBewegung) > 300 {
            beenden()
        } else if let g = gehenSeit, Date().timeIntervalSince(g) > 90 {
            beenden()
        }
    }

    /// Falls die App während einer Aufnahme beendet wurde: Fahrt trotzdem behalten.
    private func abgebrocheneFahrtenRetten() {
        guard let context = container?.mainContext else { return }
        let beschreibung = FetchDescriptor<Fahrt>(predicate: #Predicate { $0.statusText == "aufnahme" })
        let offen = (try? context.fetch(beschreibung)) ?? []
        for fahrt in offen {
            if fahrt.distanzMeter < mindestStrecke {
                context.delete(fahrt)
            } else {
                fahrt.ende = fahrt.punkte.last.map { Date(timeIntervalSince1970: $0.zeit) } ?? fahrt.start
                fahrt.status = .wartet
            }
        }
        try? context.save()
    }

    // MARK: - Automatik

    private func automatikAnwenden() {
        let erlaubt = manager.authorizationStatus == .authorizedAlways
        guard automatik, erlaubt else {
            manager.stopMonitoringSignificantLocationChanges()
            if bewegungLaeuft { bewegung.stopActivityUpdates(); bewegungLaeuft = false }
            return
        }
        // Weckt die App auch dann, wenn sie geschlossen ist (bei größeren Ortswechseln).
        manager.startMonitoringSignificantLocationChanges()
        if CMMotionActivityManager.isActivityAvailable() && !bewegungLaeuft {
            bewegungLaeuft = true
            bewegung.startActivityUpdates(to: .main) { [weak self] aktivitaet in
                guard let aktivitaet else { return }
                Task { @MainActor in self?.bewegungErkannt(aktivitaet) }
            }
        }
    }

    private func bewegungErkannt(_ a: CMMotionActivity) {
        if a.automotive && a.confidence != .low {
            gehenSeit = nil
            letzteBewegung = Date()
            if !nimmtAuf && automatik { starten(automatisch: true) }
        } else if a.walking || a.running || a.cycling {
            if gehenSeit == nil { gehenSeit = Date() }
        }
    }

    /// Nach einem Aufwecken durch Ortswechsel: kurz nachsehen, ob wir im Auto sitzen.
    private func nachAufweckenPruefen(_ ort: CLLocation) {
        guard automatik, !nimmtAuf else { return }
        if ort.speed > 8 { // über ca. 30 km/h
            starten(automatisch: true)
            return
        }
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        bewegung.queryActivityStarting(from: Date().addingTimeInterval(-300), to: Date(), to: .main) { [weak self] liste, _ in
            let imAuto = liste?.last?.automotive == true
            Task { @MainActor in
                if imAuto { self?.starten(automatisch: true) }
            }
        }
    }

    fileprivate func orteEmpfangen(_ orte: [CLLocation]) {
        guard nimmtAuf else {
            if let letzter = orte.last { nachAufweckenPruefen(letzter) }
            return
        }
        for ort in orte {
            guard ort.horizontalAccuracy > 0, ort.horizontalAccuracy < 40 else { continue }
            if let vorher = letzterOrt {
                let abstand = ort.distance(from: vorher)
                if abstand < 3 { continue }
                liveDistanz += abstand
            }
            letzterOrt = ort
            if ort.speed > 2.5 { letzteBewegung = Date() }
            punkte.append(Punkt(lat: ort.coordinate.latitude,
                                lon: ort.coordinate.longitude,
                                zeit: ort.timestamp.timeIntervalSince1970,
                                genauigkeit: ort.horizontalAccuracy,
                                tempo: ort.speed))
            livePunkte.append(ort.coordinate)
        }
        if Date().timeIntervalSince(letztesSpeichern) > 30 { zwischenspeichern() }
    }

    fileprivate func berechtigungGeaendert() {
        berechtigung = manager.authorizationStatus
        automatikAnwenden()
    }
}

extension FahrtRecorder: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.orteEmpfangen(locations) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.berechtigungGeaendert() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
