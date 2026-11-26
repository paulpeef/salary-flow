import Foundation
import AVFoundation

enum MeetingProcessing {
    struct Recognition: Decodable {
        let segments: [MeetingWord]
    }

    static func recognize(_ file: URL) async throws -> [MeetingWord] {
        let cache = file.deletingPathExtension().appendingPathExtension("json")
        if let saved = try? JSONDecoder().decode(Recognition.self, from: Data(contentsOf: cache)) { return saved.segments }
        let url = URL(string: "http://127.0.0.1:51089")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 7200
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // speakers=true in Spokenly 2.35.16 invokes its hosted model even when a
        // local file model is selected. Diarization is done by our local helper.
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "transcribe_file", "arguments": [
                "file_path": file.path, "format": "json", "speakers": false, "separate_channels": false]]])
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 10800
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (data, _) = try await session.data(for: request)
        let rpc = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let result = rpc?["result"] as? [String: Any]
        let content = (result?["content"] as? [[String: Any]])?.first?["text"] as? String
        guard result?["isError"] as? Bool != true, let content else {
            let reason = (rpc?["error"] as? [String: Any])?["message"] as? String ?? content ?? "нет результата"
            throw MeetingIssue("Spokenly: " + reason)
        }
        let raw = Data(content.utf8)
        guard let parsed = try? JSONDecoder().decode(Recognition.self, from: raw) else {
            throw MeetingIssue("Не удалось прочитать текст и таймкоды из ответа Spokenly. Аудиодорожка сохранена.")
        }
        try raw.write(to: cache, options: .atomic)
        return parsed.segments
    }

    static func diarize(_ directory: URL, minimum: Int, samples: [ZoomSample], mic: [MeetingWord],
                        micStart: Date, systemStart: Date) throws -> [MeetingVoice] {
        let output = directory.appending(path: "voices.json")
        if !FileManager.default.fileExists(atPath: output.path) {
            guard let helper = Bundle.main.url(forAuxiliaryExecutable: "MeetingVoices") else {
                throw MeetingIssue("В сборке отсутствует модуль разделения голосов.")
            }
            // Cache only turn boundaries and matched names with the meeting.
            // Raw embedding vectors live in a private, per-run temporary folder.
            let scratch = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: scratch) }
            let rawTurns = scratch.appending(path: "turns.json"), embeddings = scratch.appending(path: "embeddings.json")
            let matchVoices = Set(samples.filter { $0.names.count == 1 && $0.peer == nil }.flatMap(\.names)).count >= 2
            let p = Process()
            p.executableURL = helper
            p.arguments = [directory.appending(path: "system.wav").path, rawTurns.path, String(minimum)]
            if matchVoices { p.arguments?.append(embeddings.path) }
            p.standardOutput = FileHandle.nullDevice
            let log = directory.appending(path: "voices.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            defer { try? handle.close() }
            p.standardError = handle
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw MeetingIssue("Локальная модель голосов не завершила обработку. Подробности в voices.log.") }
            var turns = try JSONDecoder().decode([MeetingVoice].self, from: Data(contentsOf: rawTurns))
            if matchVoices, let data = try? Data(contentsOf: embeddings),
               let windows = try? JSONDecoder().decode([MeetingVoiceMatching.Window].self, from: data) {
                turns = MeetingVoiceMatching.annotate(turns, windows: windows, samples: samples, mic: mic,
                                                     micStart: micStart, systemStart: systemStart)
            }
            try JSONEncoder().encode(turns).write(to: output, options: .atomic)
            return turns
        }
        return try JSONDecoder().decode([MeetingVoice].self, from: Data(contentsOf: output))
    }

    static func waitForClosedAudio(_ directory: URL) async throws {
        let files = ["mic.wav", "system.wav"].map { directory.appending(path: $0) }
        var previous: [Int] = [], stable = 0
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 500_000_000)
            let sizes = try files.map { try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
            stable = sizes == previous ? stable + 1 : 0
            previous = sizes
            if stable >= 4, sizes.allSatisfy({ $0 > 44 }),
               files.allSatisfy({ ((try? AVAudioFile(forReading: $0).length) ?? 0) > 0 }) { return }
        }
        throw MeetingIssue("Аудиофайлы ещё записываются или пусты. Останови запись в Spokenly и повтори обработку.")
    }

    static func readTranscript(_ directory: URL) throws -> String {
        let text = try String(contentsOf: directory.appending(path: "meeting.txt"), encoding: .utf8)
        // Older recordings included the Zoom diagnostics after the meeting chat.
        let footer = "\n\nНаблюдения Salary Flow в Zoom\nZoom: "
        guard let range = text.range(of: footer, options: .backwards) else { return text }
        return String(text[..<range.lowerBound])
    }

    static func process(_ directory: URL) async throws -> (String, String) {
        try await waitForClosedAudio(directory)
        let micFile = directory.appending(path: "mic.wav"), sysFile = directory.appending(path: "system.wav")
        let mic = try await recognize(micFile)
        let system = try await recognize(sysFile)
        let data = try Data(contentsOf: directory.appending(path: "zoom.jsonl"))
        let samples = try data.split(separator: 10).map { try JSONDecoder().decode(ZoomSample.self, from: Data($0)) }
        guard let micDate = try micFile.resourceValues(forKeys: [.creationDateKey]).creationDate,
              let sysDate = try sysFile.resourceValues(forKeys: [.creationDateKey]).creationDate else {
            throw MeetingIssue("Не удалось прочитать время начала аудиодорожек.")
        }
        let minimum = MeetingTranscript.minimumVoices(mic: mic, system: system, samples: samples,
                                                     micStart: micDate, systemStart: sysDate)
        var warning = ""
        let turns: [MeetingVoice]
        do { turns = try diarize(directory, minimum: minimum, samples: samples, mic: mic, micStart: micDate, systemStart: sysDate) } catch {
            turns = []
            warning = "Разделение голосов недоступно. " + error.localizedDescription
        }
        let transcript = MeetingTranscript.render(mic: mic, system: system, turns: turns, samples: samples,
                                                  micStart: micDate, systemStart: sysDate)
        guard !transcript.isEmpty else { throw MeetingIssue("Spokenly не нашёл речи в этих дорожках.") }
        let names = Set(samples.flatMap(\.names)).sorted()
        var summary = "Zoom: \(samples.filter { !$0.names.isEmpty }.count) из \(samples.count) наблюдений с именем" +
            (names.isEmpty ? "." : " (\(names.joined(separator: ", "))).")
        let pairCount = samples.filter { $0.peer != nil }.count
        let matchedTurns = turns.filter { $0.matches?.isEmpty == false }.count
        summary += " Состав один на один подтверждён в \(pairCount) наблюдениях. Голосовые совпадения найдены в \(matchedTurns) интервалах."
        try (summary + "\n" + warning).write(to: directory.appending(path: "summary.txt"), atomically: true, encoding: .utf8)
        try transcript.write(to: directory.appending(path: "transcript.txt"), atomically: true, encoding: .utf8)
        let chat = try MeetingChat.load(directory)
        let combined = transcript + MeetingChat.section(chat)
        try combined.write(to: directory.appending(path: "meeting.txt"), atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: directory.appending(path: "error.txt"))
        return (combined, [summary, warning].filter { !$0.isEmpty }.joined(separator: " "))
    }
}
