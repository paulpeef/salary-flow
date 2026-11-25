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
            VStack(alignment: .leading, spacing: 4) {
                action(recorder.recording ? "Остановить запись" : "Записать встречу",
                       icon: recorder.recording ? "stop.circle.fill" : "waveform.circle",
                       run: recorder.toggle)
                    .disabled(recorder.busy)
                if recorder.canCopy && (details || !recorder.recording) {
                    action(recorder.copiesEarlierMeeting ? "Скопировать предыдущую расшифровку" : "Скопировать расшифровку",
                           icon: "doc.on.doc", date: recorder.transcriptDate, run: recorder.copyAgain)
                }
            }
            if let result = recorder.latestResult {
                resultCard(result)
            }
            if !recorder.status.isEmpty {
                Text(recorder.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if recorder.recording, !recorder.zoomStatus.isEmpty {
                Text(recorder.zoomStatus).font(.caption).lineLimit(2)
            }
            if recorder.recording, !recorder.chatStatus.isEmpty {
                Text(recorder.chatStatus).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                    Button("Повторить расшифровку") { recorder.retry() }.disabled(!recorder.canRetry)
                }
            }
        }
    }

    private func action(_ title: String, icon: String, date: Date? = nil, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 19)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .fixedSize(horizontal: false, vertical: true)
                    if let date {
                        Text(date, format: .dateTime.day().month(.abbreviated).hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.primary.opacity(0.075), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func resultCard(_ result: MeetingRecorder.ResultStatus) -> some View {
        switch result {
        case .ready:
            // The dated copy action already shows the available transcript.
            EmptyView()
        case .queued:
            statusRow("В очереди на расшифровку", detail: "Аудио сохранено.", icon: "clock")
        case .processing:
            statusRow("Идёт расшифровка", detail: "Текст появится здесь после обработки.", icon: "waveform", tint: .accentColor)
        case .missingAudio:
            statusRow("Аудиодорожки не найдены", detail: "Сохранён журнал Zoom.", icon: "exclamationmark.triangle", tint: .orange)
        case .failed(let reason):
            statusRow("Не удалось расшифровать", detail: reason, icon: "exclamationmark.triangle", tint: .orange, retry: true)
        }
    }

    private func statusRow(_ title: String, detail: String, icon: String, tint: Color = .secondary,
                           retry: Bool = false) -> some View {
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 19)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text(title).fixedSize().fontWeight(.semibold)
                        Spacer(minLength: 0)
                        meetingDate
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).fontWeight(.semibold)
                        meetingDate
                    }
                }
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if retry && !details && recorder.canRetry {
                    Button("Повторить расшифровку") { recorder.retry() }
                }
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var meetingDate: some View {
        if let date = recorder.latestMeetingDate {
            Text(date, format: .dateTime.day().month(.abbreviated).hour().minute())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

}
