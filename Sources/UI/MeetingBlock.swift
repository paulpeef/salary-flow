import SwiftUI

struct MeetingBlock: View {
    @ObservedObject var recorder = MeetingRecorder.shared
    var body: some View {
        if recorder.enabled && recorder.showInPanel {
            VStack(alignment: .leading, spacing: 7) {
                Text("Запись встреч")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                MeetingControls(recorder: recorder)
            }
        }
    }
}

struct MeetingSettings: View {
    @ObservedObject private var recorder = MeetingRecorder.shared

    var body: some View {
        Form {
            Section("Запись встреч") {
                Toggle("Включить запись встреч", isOn: Binding(get: { recorder.enabled }, set: recorder.setEnabled))
                    .disabled(!recorder.canChangeEnabled)
                if !recorder.canChangeEnabled {
                    Text("Выключить функцию можно после завершения записи и обработки.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if recorder.enabled {
                    Toggle("Показывать в панели", isOn: $recorder.showInPanel)
                }
            }
            if recorder.enabled {
                Section("Spokenly") {
                    Toggle("Сворачивать окно расшифровки после записи", isOn: $recorder.minimizeSpokenly)
                    MeetingControls(recorder: recorder, details: true)
                }
                Section("Говорящий в Zoom") {
                    MeetingTileToggle(recorder: recorder)
                    Toggle("Читать подпись в верхней части окна Zoom", isOn: $recorder.useBanner)
                    Text("Кадры обрабатываются на Mac. В журнал попадают время и найденные имена.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct MeetingTileToggle: View {
    @ObservedObject var recorder: MeetingRecorder

    var body: some View {
        Toggle("Читать рамку говорящего в Zoom", isOn: $recorder.readTileFrames)
            .help("Salary Flow читает рамку, подпись на единственной увеличенной плитке и имя в плавающем видеоокне Zoom.")
    }
}

private struct MeetingControls: View {
    @ObservedObject var recorder: MeetingRecorder
    var details = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                recorder.toggle()
            } label: {
                Label(recorder.recording ? "Остановить запись" : "Записать встречу",
                      systemImage: recorder.recording ? "stop.circle.fill" : "waveform.circle")
            }
            .disabled(recorder.busy)
            if !recorder.status.isEmpty {
                Text(recorder.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if recorder.recording, !recorder.zoomStatus.isEmpty {
                Text(recorder.zoomStatus).font(.caption).lineLimit(2)
            }
            if recorder.recording, !recorder.chatStatus.isEmpty {
                Text(recorder.chatStatus).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !recorder.processingStatus.isEmpty {
                Text(recorder.processingStatus).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            if !details && recorder.recording {
                MeetingTileToggle(recorder: recorder)
            }
            if details {
                HStack {
                    Text(recorder.controlGranted ? "Доступ к управлению разрешён" : "У этой сборки нет доступа к управлению")
                    Button("Проверить") { recorder.refreshControl() }
                }
                .font(.caption)
                .onAppear { recorder.refreshControl() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    recorder.refreshControl()
                }
                HStack {
                    Button("Файлы встречи") { recorder.openFiles() }.disabled(recorder.lastFolder == nil)
                    Button("Повторить обработку") { recorder.retry() }.disabled(!recorder.canRetry)
                }
            }
            if recorder.canCopy && (details || !recorder.recording) {
                Button("Скопировать последний текст") { recorder.copyAgain() }
            }
        }
    }
}
