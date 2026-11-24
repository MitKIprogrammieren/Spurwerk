import Foundation
import CoreLocation
import CoreMotion
import SwiftData

/// Zeichnet Strecken per GPS auf – Auto, zu Fuß oder Fahrrad.
/// Von Hand oder automatisch, sobald das iPhone erkennt, dass du fährst bzw. läufst.
@MainActor
final class FahrtRecorder: NSObject, ObservableObject {
    static let shared = FahrtRecorder()

    @Published private(set) var nimmtAuf = false
    @Published private(set) var art: FahrtArt = .auto
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
    /// Nach einem verworfenen Mini-Fußweg eine Weile keine neue Fußaufnahme starten.
    private var fussPauseBis = Date.distantPast

    // MARK: - Einstellungen

    /// Autofahrten automatisch aufzeichnen (Schlüssel „automatik“ aus der ersten Version).
    var automatikAuto: Bool {
        get { UserDefaults.standard.object(forKey: "automatik") as? Bool ?? true }
        set { einstellen("automatik", newValue) }
    }

    /// Fußwege automatisch aufzeichnen.
    var automatikFuss: Bool {
        get { UserDefaults.standard.object(forKey: "automatikFuss") as? Bool ?? false }
        set { einstellen("automatikFuss", newValue) }
    }

    var automatik: Bool { automatikAuto || automatikFuss }

    private func einstellen(_ schluessel: String, _ wert: Bool) {
        objectWillChange.send()
        UserDefaults.standard.set(wert, forKey: schluessel)
        if wert && manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
        automatikAnwenden()
    }

    override init() {
        super.init()
        manager.delegate = self
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

    func starten(_ art: FahrtArt, automatisch: Bool = false) {
        guard !nimmtAuf, let container else { return }
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        let fahrt = Fahrt(start: Date(), art: art)
        container.mainContext.insert(fahrt)
        try? container.mainContext.save()

        self.art = art
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

        switch art {
        case .auto:
            manager.activityType = .automotiveNavigation
            manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            manager.distanceFilter = 5
        case .fuss:
            manager.activityType = .fitness
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = 3
        case .rad:
            manager.activityType = .fitness
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = 4
        }
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

        if liveDistanz < fahrt.art.mindestStrecke {
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
        guard automatischGestartet, let start = startZeit else { return }
        let jetzt = Date()

        switch art {
        case .auto:
            // 5 Minuten kein Fahren → geparkt
            if jetzt.timeIntervalSince(letzteBewegung) > 300 {
                beenden()
            } else if let g = gehenSeit, jetzt.timeIntervalSince(g) > 90 {
                // ausgestiegen und losgelaufen → Autofahrt fertig, ggf. Fußweg anfangen
                beenden()
                if automatikFuss { starten(.fuss, automatisch: true) }
            }
        case .fuss, .rad:
            if jetzt.timeIntervalSince(letzteBewegung) > 300 {
                beenden()
            } else if jetzt.timeIntervalSince(start) > 180 && liveDistanz < 100 {
                // nur in der Wohnung herumgelaufen → GPS wieder aus, spart Akku
                fussPauseBis = jetzt.addingTimeInterval(600)
                beenden()
            }
        }
    }

    /// Falls die App während einer Aufnahme beendet wurde: Strecke trotzdem behalten.
    private func abgebrocheneFahrtenRetten() {
        guard let context = container?.mainContext else { return }
        let beschreibung = FetchDescriptor<Fahrt>(predicate: #Predicate { $0.statusText == "aufnahme" })
        let offen = (try? context.fetch(beschreibung)) ?? []
        for fahrt in offen {
            if fahrt.distanzMeter < fahrt.art.mindestStrecke {
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
        let sicher = a.confidence != .low
        if a.automotive && sicher {
            gehenSeit = nil
            if nimmtAuf && art == .auto { letzteBewegung = Date() }
            // Vom Fußweg ins Auto gestiegen → Fußweg beenden, Autofahrt starten
            if nimmtAuf && art == .fuss && automatischGestartet { beenden() }
            if !nimmtAuf && automatikAuto { starten(.auto, automatisch: true) }
        } else if (a.walking || a.running) && sicher {
            if gehenSeit == nil { gehenSeit = Date() }
            if nimmtAuf && art == .fuss { letzteBewegung = Date() }
            if !nimmtAuf && automatikFuss && Date() > fussPauseBis { starten(.fuss, automatisch: true) }
        } else if a.cycling && sicher {
            if nimmtAuf && art == .rad { letzteBewegung = Date() }
        } else if a.stationary {
            gehenSeit = nil
        }
    }

    /// Nach einem Aufwecken durch Ortswechsel: nachsehen, ob wir fahren oder laufen.
    private func nachAufweckenPruefen(_ ort: CLLocation) {
        guard automatik, !nimmtAuf else { return }
        if automatikAuto && ort.speed > 8 { // über ca. 30 km/h
            starten(.auto, automatisch: true)
            return
        }
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        bewegung.queryActivityStarting(from: Date().addingTimeInterval(-300), to: Date(), to: .main) { [weak self] liste, _ in
            let letzte = liste?.last(where: { $0.confidence != .low })
            let imAuto = letzte?.automotive == true
            let zuFuss = letzte?.walking == true || letzte?.running == true
            Task { @MainActor in
                guard let self, !self.nimmtAuf else { return }
                if imAuto && self.automatikAuto {
                    self.starten(.auto, automatisch: true)
                } else if zuFuss && self.automatikFuss && Date() > self.fussPauseBis {
                    self.starten(.fuss, automatisch: true)
                }
            }
        }
    }

    fileprivate func orteEmpfangen(_ orte: [CLLocation]) {
        guard nimmtAuf else {
            if let letzter = orte.last { nachAufweckenPruefen(letzter) }
            return
        }
        let bewegtAb: Double = art == .auto ? 2.5 : 0.7   // m/s
        let maxUngenau: Double = art == .auto ? 40 : 30
        for ort in orte {
            guard ort.horizontalAccuracy > 0, ort.horizontalAccuracy < maxUngenau else { continue }
            if let vorher = letzterOrt {
                let abstand = ort.distance(from: vorher)
                if abstand < 3 { continue }
                liveDistanz += abstand
            }
            letzterOrt = ort
            if ort.speed > bewegtAb { letzteBewegung = Date() }
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
