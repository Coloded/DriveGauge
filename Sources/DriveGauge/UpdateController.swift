import AppKit

#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
final class UpdateController {
    static let shared = UpdateController()

#if canImport(Sparkle)
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
#endif

    private init() {}

    func start() {
#if canImport(Sparkle)
        _ = controller
#endif
    }

    func checkForUpdates() {
#if canImport(Sparkle)
        controller.checkForUpdates(nil)
#else
        let alert = NSAlert()
        alert.messageText = "Обновления недоступны"
        alert.informativeText = "Эта отладочная сборка создана без Sparkle. Соберите приложение через scripts/build-app.sh."
        alert.runModal()
#endif
    }
}
