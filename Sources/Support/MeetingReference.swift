import Accelerate
import AVFoundation

enum MeetingReference {
    struct Track: Identifiable {
        let url: URL
        var name: String
        var id: URL { url }

        init(_ url: URL, names: Set<String>) {
            self.url = url
            let filename = url.deletingPathExtension().lastPathComponent
            func key(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
            let stem = key(filename).replacingOccurrences(of: "^audio", with: "", options: .regularExpression)
            let choices = names.filter { !key($0).isEmpty && stem.hasPrefix(key($0)) && stem.dropFirst(key($0).count).allSatisfy(\.isNumber) }
            name = choices.count == 1 ? choices.first! : ""
        }
    }

    // One RMS value per 100 ms. Decode in bounded chunks even for long meetings.
    static func envelope(_ url: URL) throws -> [Float] {
        let audio = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let step = max(1, Int((audio.processingFormat.sampleRate / 10).rounded()))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(step * 100)) else { throw CocoaError(.fileReadUnknown) }
        var result = [Float]()
        while audio.framePosition < audio.length {
            try audio.read(into: buffer, frameCount: buffer.frameCapacity)
            let length = Int(buffer.frameLength)
            guard length > 0, let channels = buffer.floatChannelData else { break }
            for i in stride(from: 0, to: length, by: step) {
                var level: Float = 0
                for ch in 0..<Int(buffer.format.channelCount) {
                    var rms: Float = 0
                    vDSP_rmsqv(channels[ch] + i, 1, &rms, vDSP_Length(min(step, length - i)))
                    level = max(level, rms)
                }
                result.append(level)
            }
        }
        return result
    }

    struct Alignment { let shift: Int; let quality: Float }
    static func align(reference: [Float], mix: [Float]) -> Alignment? {
        let size = min(100, min(reference.count, mix.count) / 4)
        guard size >= 20 else { return nil }
        func compress(_ v: Float) -> Float { log1p(max(0, v) * 500) }
        let a = reference.map(compress), b = mix.map(compress)
        let gated = max(0.0008, (reference.max() ?? 0) * 0.018)
        let bSquared = b.map { $0 * $0 }
        var votes = [Alignment]()
        // Search a distinct speech pattern in each quarter. Agreeing offsets also
        // catch recordings where leading silence was removed independently.
        for part in 0..<4 {
            let first = part * a.count / 4, last = (part + 1) * a.count / 4 - size
            guard last >= first else { continue }
            var bestStart = first, energy: Float = 0, bestCount = 0
            var pattern = [Float](), mask = [Float]()
            for index in stride(from: first, through: last, by: max(1, size/4)) {
                let active = (0..<size).filter { reference[index+$0] > gated }
                guard active.count >= max(12, size/4) else { continue }
                let mean = active.reduce(Float.zero) { $0 + a[index+$1] } / Float(active.count)
                var centered = [Float](repeating: 0, count: size)
                var weights = centered
                for j in active { centered[j] = a[index+j] - mean; weights[j] = 1 }
                let variance = centered.reduce(Float.zero) { $0 + $1*$1 }
                if variance > energy {
                    energy = variance; bestStart = index; bestCount = active.count
                    pattern = centered; mask = weights
                }
            }
            guard bestCount > 0, energy > Float(bestCount) * 0.025 else { continue }
            // A silent reference channel may contain a different speaker in the
            // mixed recording. Compare only the selected person's active frames.
            var scores = [Float](repeating: 0, count: b.count - size + 1)
            b.withUnsafeBufferPointer { samples in
                bSquared.withUnsafeBufferPointer { squared in
                    pattern.withUnsafeBufferPointer { shape in
                        mask.withUnsafeBufferPointer { weights in
                            for i in scores.indices {
                                let window = samples.baseAddress! + i
                                var total: Float = 0, sumSquares: Float = 0, dot: Float = 0
                                vDSP_dotpr(window, 1, weights.baseAddress!, 1, &total, vDSP_Length(size))
                                vDSP_dotpr(squared.baseAddress! + i, 1, weights.baseAddress!, 1, &sumSquares, vDSP_Length(size))
                                let variance = sumSquares - total*total / Float(bestCount)
                                guard variance > 0.02 else { continue }
                                vDSP_dotpr(window, 1, shape.baseAddress!, 1, &dot, vDSP_Length(size))
                                scores[i] = dot / sqrt(energy * variance)
                            }
                        }
                    }
                }
            }
            guard let i = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[i] >= 0.65 else { continue }
            let runner = scores.indices.filter { abs($0-i) > 5 }.map { scores[$0] }.max() ?? 0
            if scores[i] - runner >= 0.045 { votes.append(Alignment(shift: i-bestStart, quality: scores[i])) }
        }
        guard let first = votes.first, votes.count >= 2, votes.allSatisfy({ abs($0.shift-first.shift) <= 2 }) else { return nil }
        return Alignment(shift: votes.map(\.shift).sorted()[votes.count/2], quality: votes.map(\.quality).min()!)
    }

    struct Activity {
        let name: String, shift: Int
        let active: [Bool], short: [Bool]
        init(name: String, levels: [Float], shift: Int) {
            self.name = name
            self.shift = shift
            let ordered = levels.sorted()
            let peak = ordered.last ?? 0, floor = ordered.isEmpty ? 0 : ordered[ordered.count / 10]
            let gate = max(0.0008, min(peak*0.18, floor*3), peak*0.018)
            active = levels.map { $0 > gate }
            var brief = [Bool](repeating: false, count: levels.count), index = 0
            while index < levels.count {
                guard active[index] else { index += 1; continue }
                let start = index
                var last = index
                index += 1
                while index < levels.count && index-last <= 3 {
                    if active[index] { last = index }
                    index += 1
                }
                if last-start < 15 { for i in start...last { brief[i] = true } }
            }
            short = brief
        }
    }

    static func score(_ words: [AttributedWord], tracks: [Activity]) -> String {
        var single = 0, named = 0, right = 0, short = 0, shortNamed = 0, shortRight = 0, overlap = 0, unverified = 0
        for word in words {
            let first = Int((word.start*10).rounded(.down)), last = max(first, Int((word.end*10).rounded(.up))-1)
            var candidates = Set<String>(), brief = false, simultaneous = false
            for frame in first...last {
                var active = 0
                for track in tracks {
                    let i = frame - track.shift
                    if track.active.indices.contains(i), track.active[i] {
                        candidates.insert(track.name)
                        active += 1
                        brief = brief || track.short[i]
                    }
                }
                if active > 1 { simultaneous = true }
            }
            if simultaneous { overlap += 1; continue }
            guard candidates.count == 1, let speaker = candidates.first else { unverified += 1; continue }
            single += 1
            if brief { short += 1 }
            if word.named {
                named += 1
                if brief { shortNamed += 1 }
                if speaker.caseInsensitiveCompare(word.speaker) == .orderedSame {
                    right += 1
                    if brief { shortRight += 1 }
                }
            }
        }
        func ratio(_ n: Int, _ d: Int) -> String { d == 0 ? "нет данных" : String(format: "%d из %d (%.1f%%)", n, d, 100*Double(n)/Double(d)) }
        return ["Подписано слов удалённой дорожки — " + ratio(words.filter(\.named).count, words.count),
                "С одним говорящим на эталонных дорожках — " + ratio(single, words.count),
                "Подписано среди проверяемых — " + ratio(named, single),
                "Верное имя среди проверяемых подписей — " + ratio(right, named),
                "Короткие реплики до 1,5 с — подписано " + ratio(shortNamed, short) + ", верно " + ratio(shortRight, shortNamed),
                "Наложение речи — \(overlap) слов. Тишина или смена говорящего — \(unverified)."].joined(separator: "\n")
    }

    static func compare(meeting: URL, tracks: [Track]) throws -> String {
        let names = tracks.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard !names.isEmpty, !names.contains(""), Set(names).count == names.count else {
            throw MeetingIssue("Укажи отдельное имя для каждой удалённой дорожки.")
        }
        let words = try JSONDecoder().decode([AttributedWord].self, from: Data(contentsOf: meeting.appending(path: "speaker-words.json")))
        let mix = try envelope(meeting.appending(path: "system.wav"))
        var activity = [Activity](), alignments = [String]()
        for track in tracks {
            let reference = try envelope(track.url)
            guard let alignment = align(reference: reference, mix: mix) else {
                throw MeetingIssue("Не удалось подтвердить синхронизацию дорожки «" + track.name + "» по двум участкам. Проверь выбор встречи и файлов.")
            }
            let name = track.name.trimmingCharacters(in: .whitespacesAndNewlines)
            activity.append(Activity(name: name, levels: reference, shift: alignment.shift))
            alignments.append(String(format: "%@ %+.1f с", name, Double(alignment.shift)/10))
        }
        return score(words, tracks: activity) + "\nСдвиг дорожек — " + alignments.joined(separator: ", ")
    }
}
