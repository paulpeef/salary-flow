import Combine
import Foundation
import Sparkle

/// Обновление через Sparkle.
///
/// Приложение подписано ad-hoc — своей подписью без сертификата Apple. Гарантию
/// подлинности обновления даёт не она, а подпись EdDSA: приватный ключ лежит
/// в секретах репозитория, публичный вшит в `Info.plist`, и Sparkle ставит
/// только то, что подписано этим ключом. Подмена файла на сервере или посредник
/// в сети обновление не пройдут.
@MainActor
final class Updater: ObservableObject {
    /// Идёт ли сейчас проверка — чтобы кнопка не нажималась дважды.
    @Published private(set) var isChecking = false
    /// Когда проверяли в последний раз, по данным самого Sparkle.
    @Published private(set) var lastCheck: Date?

    /// Пусто у вспомогательных инструментов: превью и зонд — это отдельные
    /// исполняемые файлы без бандла, и запущенный в них Sparkle уходит проверять
    /// обновления и подвешивает процесс. Проверено: рендер превью вставал намертво.
    private let controller: SPUStandardUpdaterController?

    init() {
        guard Bundle.main.bundleIdentifier != nil,
              let feed = Bundle.main.infoDictionary?["SUFeedURL"] as? String,
              !feed.isEmpty else {
            controller = nil
            return
        }
        // Автоматическую проверку включаем не здесь, а по настройке пользователя.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        lastCheck = controller?.updater.lastUpdateCheckDate
        Log.info("обновления: канал \(feed)")
    }

    /// Доступно ли обновление в принципе — у инструментов сборки его нет.
    var isAvailable: Bool { controller != nil }

    var feedURL: String? {
        Bundle.main.infoDictionary?["SUFeedURL"] as? String
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// Проверять ли обновления самостоятельно. Sparkle хранит это у себя,
    /// поэтому отдельного поля в настройках приложения нет.
    var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            controller?.updater.automaticallyChecksForUpdates = newValue
            objectWillChange.send()
            Log.info("обновления: автопроверка \(newValue ? "включена" : "выключена")")
        }
    }

    /// Проверка по кнопке: Sparkle сам покажет окно с описанием версии,
    /// скачает, заменит приложение и перезапустит его.
    func checkNow() {
        guard let controller, !isChecking else { return }
        isChecking = true
        Log.info("обновления: проверка по кнопке")
        controller.updater.checkForUpdates()

        // Sparkle не сообщает об окончании через публичный интерфейс,
        // а окно он показывает сам — снимаем блокировку кнопки по времени.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            self.isChecking = false
            self.lastCheck = controller.updater.lastUpdateCheckDate
        }
    }
}
