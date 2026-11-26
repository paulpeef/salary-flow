import SwiftUI
import CryptoKit
import UniformTypeIdentifiers

struct MeetingExtraSettings: View {
    @ObservedObject var recorder: MeetingRecorder
    @State private var qualityFolder: URL?
    @State private var tracks = [MeetingReference.Track]()
    @State private var report = ""
    @State private var measuring = false
    @StateObject private var meet = MeetImportModel()
    @State private var meetCode = ""

    var body: some View {
        Section("Знакомые голоса Zoom") {
            Toggle("Использовать подтверждённые голоса между встречами", isOn: $recorder.useSavedVoices)
            if recorder.useSavedVoices {
                Text("После встречи можно прослушать образцы и подтвердить имя. Профили сохраняются на этом Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(recorder.voiceExamples.keys.sorted(), id: \.self) { name in
                    VStack(alignment: .leading) {
                        Text(name)
                        HStack {
                            ForEach(0..<min(2, recorder.voiceExamples[name]?.count ?? 0), id: \.self) { i in
                                Button("Образец \(i+1)") { recorder.preview(name, index: i) }
                            }
                            Button("Подтвердить имя") { recorder.saveProfile(name) }
                        }
                    }
                }
            }
            ForEach(recorder.savedVoices.keys.sorted(), id: \.self) { name in
                HStack { Text(name); Spacer(); Button("Удалить профиль") { recorder.removeProfile(name) } }
            }
            if !recorder.toolsStatus.isEmpty { Text(recorder.toolsStatus).font(.caption) }
        }
        Section("Проверка имён Zoom") {
            Text("Выбери папку расшифровки Salary Flow и отдельные аудиофайлы всех собеседников из записи Zoom. Свою дорожку пропусти.")
                .font(.caption).foregroundStyle(.secondary)
            Button(qualityFolder?.lastPathComponent ?? "Выбрать папку встречи") { selectMeeting() }
                .disabled(measuring)
            if qualityFolder != nil {
                Button("Выбрать дорожки собеседников") { selectTracks() }.disabled(measuring)
                ForEach($tracks) { $track in
                    TextField(track.url.lastPathComponent, text: $track.name, prompt: Text("Имя в Zoom")).disabled(measuring)
                }
                if !tracks.isEmpty { Button(measuring ? "Сравниваю…" : "Сравнить подписи") { compare() }.disabled(measuring) }
            }
            if !report.isEmpty { Text(report).font(.caption).textSelection(.enabled) }
        }
        Section("Google Meet") {
            Text("Импорт готовой расшифровки сохраняет реплики с именами участников. Для подключения нужен файл OAuth-клиента Google типа Desktop app с включённым Meet REST API.")
                .font(.caption).foregroundStyle(.secondary)
            if !meet.connected {
                Button("Подключить Google Meet") { meet.signIn() }.disabled(meet.busy)
                if meet.signingIn { Button("Отменить вход") { meet.cancelSignIn() } }
            } else {
                TextField("Ссылка или код встречи", text: $meetCode).onChange(of: meetCode) { _, _ in meet.records = [] }
                    .disabled(meet.busy)
                HStack {
                    Button("Найти встречи") { meet.search(meetCode) }.disabled(meet.busy || meetCode.isEmpty)
                    Button("Отключить Google") { meet.disconnect() }.disabled(meet.busy)
                }
                ForEach(meet.records) { record in
                    let label = (try? GoogleMeetAPI.date(record.startTime).formatted(date: .abbreviated, time: .standard)) ?? record.startTime
                    Button("Импортировать · " + label) { meet.importRecord(record) }.disabled(meet.busy)
                }
            }
            if !meet.status.isEmpty { Text(meet.status).font(.caption).textSelection(.enabled) }
            if let file = meet.file {
                Button("Показать файл расшифровки") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }
        }
    }

    private func selectMeeting() {
        let panel = NSOpenPanel()
        panel.directoryURL = recorder.lastFolder?.deletingLastPathComponent()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        tracks = []
        qualityFolder = nil
        guard FileManager.default.fileExists(atPath: folder.appending(path: "speaker-words.json").path) else {
            report = "В папке нет пословных подписей. Они сохраняются со следующей записи в версии 1.19."; return
        }
        qualityFolder = folder
        report = ""
    }

    private func selectTracks() {
        guard let folder = qualityFolder else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let samples = (try? Data(contentsOf: folder.appending(path: "zoom.jsonl")))?.split(separator: 10)
            .compactMap { try? JSONDecoder().decode(ZoomSample.self, from: Data($0)) } ?? []
        let names = Set(samples.flatMap { ($0.roster ?? []) + $0.names })
        tracks = panel.urls.map { MeetingReference.Track($0, names: names) }
        report = ""
    }

    private func compare() {
        guard let meeting = qualityFolder else { return }
        let chosen = tracks
        measuring = true
        report = ""
        Task {
            defer { measuring = false }
            do { report = try await Task.detached(priority: .utility) { try MeetingReference.compare(meeting: meeting, tracks: chosen) }.value }
            catch { report = error.localizedDescription }
        }
    }
}

@MainActor private final class MeetImportModel: ObservableObject {
    @Published var busy = false
    @Published var connected = false
    @Published var signingIn = false
    @Published var records = [GoogleMeetAPI.Record]()
    @Published var status = ""
    @Published var file: URL?
    private var api: GoogleMeetAPI?
    private var signInSession: MeetSignIn?

    func disconnect() {
        api = nil; connected = false; records = []; status = ""
    }
    func cancelSignIn() { signInSession?.cancel() }

    func signIn() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Выбери JSON клиента OAuth типа Desktop app из Google Cloud."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let session = MeetSignIn()
        signInSession = session
        busy = true; signingIn = true; status = "Заверши вход в браузере."
        Task {
            defer { busy = false; signingIn = false; signInSession = nil }
            do {
                let token = try await session.token(credentials: Data(contentsOf: url))
                api = GoogleMeetAPI(token: token)
                connected = true; status = ""
            } catch { status = error.localizedDescription }
        }
    }
    func search(_ code: String) {
        guard let api else { return }
        busy = true; records = []; status = "Ищу завершённые встречи…"
        Task {
            defer { busy = false }
            do { records = try await api.records(code); status = records.isEmpty ? "По этому коду завершённых встреч не найдено." : "" }
            catch { status = error.localizedDescription }
        }
    }
    func importRecord(_ record: GoogleMeetAPI.Record) {
        guard let api else { return }
        busy = true; status = "Загружаю участников и реплики…"
        Task {
            defer { busy = false }
            do {
                let text = try await api.transcript(record)
                let fm = FileManager.default
                let folder = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "SalaryFlow/MeetImports")
                try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let digest = SHA256.hash(data: Data((record.name + text).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
                let stamp = ISO8601DateFormatter().string(from: try GoogleMeetAPI.date(record.startTime)).replacingOccurrences(of: ":", with: "-")
                let destination = folder.appending(path: stamp + "-" + digest + ".txt")
                if !fm.fileExists(atPath: destination.path) { try Data(text.utf8).write(to: destination, options: .atomic) }
                file = destination
                status = MeetingClipboard.write(MeetingClipboard.textForCopy(text)) ? "Файл сохранён. Реплики скопированы." : "Файл сохранён. Буфер обмена недоступен."
            } catch { status = error.localizedDescription }
        }
    }
}
