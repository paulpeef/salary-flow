import Foundation

func checkMeetingTranscripts(_ check: (String, Bool) -> Void) {
    let date = Date(timeIntervalSince1970: 1_000)
    let turns = [
        MeetingVoice(start: 0, end: 6, voice: "a"), MeetingVoice(start: 7, end: 13, voice: "b"),
        MeetingVoice(start: 14, end: 20, voice: "a"), MeetingVoice(start: 21, end: 27, voice: "b"),
        MeetingVoice(start: 30, end: 31, voice: "a"), MeetingVoice(start: 30, end: 31, voice: "b")
    ]
    func sample(_ t: Int, _ name: String) -> ZoomSample {
        ZoomSample(time: date.addingTimeInterval(Double(t)), names: [name], status: "name", windows: 1, nodes: 8)
    }
    let names = [1, 2, 3, 4, 15, 16, 17, 18].map { sample($0, "Ольга") } +
                [8, 9, 10, 11, 22, 23, 24, 25].map { sample($0, "Антон") }
    let words = [MeetingWord(start: 5, end: 5.5, text: "Беру."), MeetingWord(start: 12, end: 12.5, text: "Проверю."),
                 MeetingWord(start: 30, end: 30.4, text: "Перебили."), MeetingWord(start: 75, end: 76, text: "Позже.")]
    let local = [MeetingWord(start: 0.1, end: 0.4, text: "Окей.")]
    let text = MeetingTranscript.render(mic: local, system: words, turns: turns, samples: names,
                                         micStart: date, systemStart: date.addingTimeInterval(0.1))
    check("привязка голоса по нескольким репликам", text.contains("Ольга — Беру.") && text.contains("Антон — Проверю."))
    check("микрофон подписан отдельно", text.contains("Я — Окей."))
    check("наложение голосов не получает имя", text.contains("Несколько голосов — Перебили."))
    check("через минуту последнее имя не переносится", text.contains("Участник — Позже."))
    let missing = MeetingTranscript.render(mic: [], system: words, turns: turns, samples: [], micStart: date, systemStart: date)
    check("без Zoom голоса остаются различимы", missing.contains("Голос 1 — Беру.") && missing.contains("Голос 2 — Проверю."))
    let conflicts = names + [sample(1, "Антон"), sample(3, "Антон"), sample(17, "Антон")]
    let disputed = MeetingTranscript.render(mic: [], system: words, turns: turns, samples: conflicts, micStart: date, systemStart: date)
    check("конфликт Zoom оставляет метку голоса", disputed.contains("Голос 1 — Беру."))
    let longTurn = [MeetingVoice(start: 0, end: 16, voice: "a")]
    let wordsInTurn = (0..<15).map { MeetingWord(start: Double($0) + 0.1, end: Double($0) + 0.7, text: "слово") }
    let blinking = [1, 2, 3, 8, 10, 11, 12, 13].map { sample($0, "Ольга") } + [sample(4, "Антон")]
    let continuous = MeetingTranscript.render(mic: [], system: wordsInTurn, turns: longTurn, samples: blinking,
                                              micStart: date, systemStart: date)
    check("мигание рамки не дробит голосовой интервал", continuous.hasPrefix("[00:00:00] Ольга — ") && !continuous.contains("\n"))
    let mixed = MeetingTranscript.render(mic: [], system: wordsInTurn, turns: longTurn,
                                         samples: [1, 2, 3, 4].map { sample($0, "Ольга") } + [6, 7, 8, 9].map { sample($0, "Антон") },
                                         micStart: date, systemStart: date)
    check("неоднозначный интервал сохраняет номер голоса", mixed.contains("Голос 1 —") && !mixed.contains("\n"))
    let sustained = MeetingTranscript.render(mic: [], system: wordsInTurn, turns: longTurn,
        samples: (0...6).map { sample($0, "Ольга") } + (8...14).map { sample($0, "Антон") }, micStart: date, systemStart: date)
    check("устойчивые имена внутри объединённого голоса ограничены наблюдаемыми словами",
          sustained.contains("[00:00:00] Ольга —") && sustained.contains("[00:00:06] Голос 1 —") &&
          sustained.contains("[00:00:08] Антон —") && sustained.contains("[00:00:14] Голос 1 —"))
    let dominant = MeetingTranscript.render(mic: [], system: [MeetingWord(start: 23, end: 24, text: "Моя реплика.")],
        turns: [MeetingVoice(start: 0, end: 29, voice: "a")],
        samples: (0...20).map { sample($0, "Ольга") } + (22...28).map { sample($0, "Антон") },
        micStart: date, systemStart: date)
    check("устойчивая смена имени внутри интервала с доминирующим голосом", dominant.contains("Антон — Моя реплика."))
    let crossing = [MeetingWord(start: 1.8, end: 3.1, text: "Договорились.")]
    let uninterrupted = MeetingTranscript.render(mic: [], system: crossing, turns: [],
        samples: [1, 2, 3, 4].map { sample($0, "Ольга") }, micStart: date, systemStart: date)
    check("без модели голосов реплика может пересекать несколько наблюдений", uninterrupted.contains("Ольга — Договорились."))
    let reusedVoice = [MeetingVoice(start: 0, end: 5, voice: "a"), MeetingVoice(start: 5.3, end: 7.9, voice: "a"),
                       MeetingVoice(start: 8, end: 13, voice: "a"), MeetingVoice(start: 14, end: 22, voice: "a")]
    let aroundGap = [1, 2, 3, 4, 9, 10, 11, 12].map { sample($0, "Ольга") } +
        [15, 16, 17, 18, 19, 20, 21].map { sample($0, "Антон") }
    let inGap = [MeetingWord(start: 6, end: 6.5, text: "Продолжаю.")]
    func atGap(_ duringGap: ZoomSample) -> String {
        MeetingTranscript.render(mic: [], system: inGap, turns: reusedVoice, samples: aroundGap + [duringGap],
                                 micStart: date, systemStart: date)
    }
    let dropout = ZoomSample(time: date.addingTimeInterval(6), names: [], status: "no-border", windows: 1, nodes: 8)
    check("короткий пропуск между двумя подтверждениями одного имени", atGap(dropout).contains("Ольга —"))
    check("при чужом имени в пропуске говорящий остаётся неизвестен", atGap(sample(6, "Ирина")).contains("Голос 1 —"))
    let edgeWord = [MeetingWord(start: 3.1, end: 4.1, text: "Происходит.")]
    let edge = MeetingTranscript.render(mic: [], system: edgeWord, turns: [MeetingVoice(start: 0, end: 3.6, voice: "a")],
        samples: [1, 2, 3, 4, 5].map { sample($0, "Марк") }, micStart: date, systemStart: date)
    check("слово на границе интервала сохраняет подтверждённое рамкой имя", edge.contains("Марк — Происходит."))
    let fragmentTurns = [MeetingVoice(start: 0, end: 4, voice: "a"), MeetingVoice(start: 5.7, end: 9, voice: "b")]
    let fragmentWords = [MeetingWord(start: 3.7, end: 4.05, text: "Кто"), MeetingWord(start: 4.05, end: 4.9, text: "ставит."),
                         MeetingWord(start: 5.7, end: 6.0, text: "Я.")]
    func fragment(_ extra: [ZoomSample]) -> String {
        MeetingTranscript.render(mic: [], system: fragmentWords, turns: fragmentTurns,
            samples: [1, 2, 3].map { sample($0, "Лиза") } + extra, micStart: date, systemStart: date)
    }
    check("окончание вопроса остаётся у автора", fragment([]).contains("Лиза — Кто ставит."))
    check("чужое имя во время окончания блокирует склейку", fragment([ZoomSample(time: date.addingTimeInterval(4.6),
        names: ["Нина"], status: "name", windows: 1, nodes: 8)]).contains("Участник — ставит."))
    let chat = MeetingChat.message("Ирина, Проверю, вот ссылка\nhttps://example.org, 10:52 PM, 1 reply, expanded")
    check("из ячейки общего чата сохраняются время, автор, текст и ссылка",
          chat == MeetingChatMessage(clock: "10:52 PM", author: "Ирина", body: "Проверю, вот ссылка\nhttps://example.org"))
    check("служебные строки разделяют встречи в постоянном чате",
          MeetingChat.sessionBoundary("23 Oct, 7:03 PM - Meeting ended: 1h 3m") == false &&
          MeetingChat.sessionBoundary("23 Oct, 6:00 PM - Meeting started") == false &&
          MeetingChat.sessionBoundary("4:30 PM - Meeting started") == true)
    check("строка без автора требует предыдущего сообщения",
          MeetingChat.continuation("ссылка,", body: "ссылка", after: nil) == nil)
    check("дата старой встречи перед часами не попадает в тело", MeetingChat.message("Анна, Проверю, 23 Oct, 4:35 PM") == nil)
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    let midnight = Date(timeIntervalSince1970: 86400)
    let start = midnight.addingTimeInterval(-90), end = midnight.addingTimeInterval(120)
    check("часы чата проверяются с учётом полуночи",
          MeetingChat.inRecording("11:59 PM", from: start, to: end, calendar: utc) &&
          MeetingChat.inRecording("12:01 AM", from: start, to: end, calendar: utc) &&
          !MeetingChat.inRecording("6:57 PM", from: start, to: end, calendar: utc))
    check("только выбранная общая вкладка", MeetingChat.everyoneTab(["Tab Everyone, selected, 1 of 2"], selected: nil) &&
          !MeetingChat.everyoneTab(["Everyone"], selected: false) && !MeetingChat.everyoneTab(["Tab Lena, selected"], selected: true))
    if let chat {
        let older = MeetingChatMessage(clock: "22:45", author: "А", body: "Раньше")
        check("повторное чтение и прокрутка сохраняют порядок", MeetingChat.merged([chat], [older, chat, chat]) == [older, chat, chat])
        check("тот же снимок не удваивает чат", MeetingChat.merged([chat, chat], [chat, chat]) == [chat, chat])
    }
    let remote = [MeetingWord(start: 0, end: 28, text: "Разговор")]
    check("минимум голосов из наблюдений во время речи", MeetingTranscript.minimumVoices(mic: [], system: remote, samples: names, micStart: date, systemStart: date) == 2)
    check("имя во время собственной реплики не увеличивает число удалённых голосов",
          MeetingTranscript.minimumVoices(mic: remote, system: remote, samples: names, micStart: date, systemStart: date) == 0)
}

@MainActor func checkMeetingHistory(_ check: (String, Bool) -> Void) {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let first = root.appending(path: "2026-11-24T08-01-55Z-AAAAAA")
    let last = root.appending(path: "2026-11-24T09-30-27Z-BBBBBB")
    do {
        for dir in [first, last] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let transcript = "[00:00:02] Участник — проверю завтра.\n\nЧат встречи\n[09:30] Участник — договорились."
        let legacyFooter = "\n\nНаблюдения Salary Flow в Zoom\nZoom: 0 из 1 наблюдений с именем.\n[00:00:00] имя не видно"
        try Data((transcript + legacyFooter).utf8).write(to: first.appending(path: "meeting.txt"))
        let copiedLegacy = try MeetingProcessing.readTranscript(first)
        check("копирование старой встречи убирает диагностику и сохраняет чат", copiedLegacy == transcript)
        for file in ["mic.wav", "system.wav"] { try Data().write(to: last.appending(path: file)) }
        let error = last.appending(path: "error.txt")
        try Data("Обработка прервана. Spokenly недоступен.".utf8).write(to: error)
        let failed = MeetingRecorder(directory: root, restoreSessions: true)
        if case .failed(let reason) = failed.latestResult {
            check("после перезапуска видна причина сбоя", reason == "Spokenly недоступен.")
        } else { check("после перезапуска видна причина сбоя", false) }
        check("при сбое новой встречи кнопка указывает на предыдущую с её датой",
              failed.canCopy && failed.canRetry && failed.copiesEarlierMeeting &&
              failed.transcriptDate == ISO8601DateFormatter().date(from: "2026-11-24T08:01:55Z"))
        try fm.removeItem(at: error)
        try Data(transcript.utf8).write(to: last.appending(path: "meeting.txt"))
        let copied = try MeetingProcessing.readTranscript(last)
        check("копирование новой встречи возвращает весь текст с чатом", copied == transcript)
        let ready = MeetingRecorder(directory: root, restoreSessions: true)
        check("новый результат доступен с датой последней встречи",
              ready.canCopy && !ready.copiesEarlierMeeting && ready.latestMeetingDate == ready.transcriptDate)
    } catch { check("чтение файлов тестовой встречи: " + error.localizedDescription, false) }
}
