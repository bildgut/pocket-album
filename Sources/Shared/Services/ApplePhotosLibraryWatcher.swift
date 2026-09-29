import Foundation
import Photos

/// Beobachtet die Apple-Fotos-Mediathek, während die App läuft, und meldet sich,
/// sobald nach Änderungen Ruhe eingekehrt ist (`ApplePhotosRuhefenster`).
///
/// Wertet `PHChange` bewusst nicht aus: Was aussteht, beantwortet allein die
/// Vorschau-Pipeline (`startupPendingIdentifiers()`) — so stimmt der Zähler mit der
/// Vorschau überein. Registriert sich nur mit bereits erteilter Berechtigung und löst
/// deshalb nie einen Berechtigungsdialog aus.
@MainActor
final class ApplePhotosLibraryWatcher: NSObject, PHPhotoLibraryChangeObserver {

    private var fenster = ApplePhotosRuhefenster()
    private var onRuhe: (@MainActor () -> Void)?
    private var wecker: Task<Void, Never>?
    private var registriert = false
    private let jetzt: () -> Date

    /// Ob die Beobachtung gerade bei `PHPhotoLibrary` registriert ist — `false`
    /// heißt entweder „noch nie gestartet", „Berechtigung fehlt noch" oder
    /// „per `stop()` beendet".
    var istAktiv: Bool { registriert }

    init(jetzt: @escaping () -> Date = Date.init) {
        self.jetzt = jetzt
        super.init()
    }

    /// Mehrfach aufrufbar: Ein weiterer Aufruf tauscht nur `onRuhe` aus.
    func start(onRuhe: @escaping @MainActor () -> Void) {
        self.onRuhe = onRuhe
        guard !registriert else { return }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            AppLogger.upload.info("AppleWatch: nicht gestartet — Fotos-Berechtigung \(status.rawValue)")
            return
        }
        PHPhotoLibrary.shared().register(self)
        registriert = true
        AppLogger.upload.info("AppleWatch: beobachte die Apple-Fotos-Mediathek")
    }

    func stop() {
        wecker?.cancel()
        wecker = nil
        onRuhe = nil
        fenster = ApplePhotosRuhefenster()
        guard registriert else { return }
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
        registriert = false
        AppLogger.upload.info("AppleWatch: Beobachtung beendet")
    }

    /// Kommt auf einem Hintergrund-Thread.
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in self.änderungGemeldet() }
    }

    private func änderungGemeldet() {
        guard registriert else { return }
        fenster.änderung(um: jetzt())
        planeWecker()
    }

    private func planeWecker() {
        wecker?.cancel()
        guard let fällig = fenster.fälligkeit() else { return }
        let warten = max(0, fällig.timeIntervalSince(jetzt()))
        wecker = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(warten))
            guard !Task.isCancelled, let self else { return }
            self.weckerKlingelt()
        }
    }

    private func weckerKlingelt() {
        guard let fällig = fenster.fälligkeit() else { return }
        // Task.sleep kann früher enden als geplant — dann neu stellen statt feuern.
        guard fällig <= jetzt() else {
            planeWecker()
            return
        }
        fenster.gefeuert()
        AppLogger.upload.info("AppleWatch: Mediathek ruhig — zähle neue Fotos")
        onRuhe?()
    }
}
