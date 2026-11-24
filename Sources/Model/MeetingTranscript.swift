import Foundation

struct MeetingWord: Codable {
    let start, end: Double
    let text: String
}
struct MeetingVoice: Codable {
    let start, end: Double
    let voice: String
}
struct ZoomSample: Codable {
    let time: Date
    let names: [String]
    let status: String
    let windows, nodes: Int
}

enum MeetingTranscript {
    // Only count repeated names during remote speech while the microphone is quiet.
    // This is a lower bound: speakers whose names were hidden may still be present.
    static func minimumVoices(mic: [MeetingWord], system: [MeetingWord], samples: [ZoomSample],
                              micStart: Date, systemStart: Date) -> Int {
        let local = mic.sorted { $0.start < $1.start }, remote = system.sorted { $0.start < $1.start }
        var m = 0, r = 0, counts: [String: Int] = [:]
        for sample in samples.sorted(by: { $0.time < $1.time }) where sample.names.count == 1 {
            let t = sample.time.timeIntervalSince(systemStart), myTime = sample.time.timeIntervalSince(micStart)
            while m < local.count && local[m].end < myTime - 0.4 { m += 1 }
            while r < remote.count && remote[r].end < t - 0.15 { r += 1 }
            guard m == local.count || local[m].start > myTime + 0.4,
                  r < remote.count, remote[r].start <= t + 0.15 else { continue }
            counts[sample.names[0], default: 0] += 1
        }
        return counts.values.filter { $0 >= 4 }.count
    }

    // Sorted inputs, forward-only cursors. A two-hour call contains tens of
    // thousands of word timestamps; avoid scanning all turns for each word.
    static func render(mic: [MeetingWord], system: [MeetingWord], turns: [MeetingVoice],
                       samples: [ZoomSample], micStart: Date, systemStart: Date) -> String {
        let turns = turns.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        let localWords = mic.sorted { $0.start < $1.start }
        var localIndex = 0
        let samples = samples.sorted { $0.time < $1.time }.map { reading -> ZoomSample in
            let t = reading.time.timeIntervalSince(micStart)
            while localIndex < localWords.count && localWords[localIndex].end < t - 0.2 { localIndex += 1 }
            guard localIndex < localWords.count && localWords[localIndex].start <= t + 0.2 else { return reading }
            return ZoomSample(time: reading.time, names: [], status: "microphone-active", windows: reading.windows, nodes: reading.nodes)
        }
        // A continuous run also works with models that return long segments
        // or when the local diarizer is unavailable. Missing samples end a run.
        var runs: [(name: String, start: Double, end: Double, observations: Int)] = []
        for (first, next) in zip(samples, samples.dropFirst()) {
            guard first.names.count == 1, first.names == next.names,
                  next.time > first.time, next.time.timeIntervalSince(first.time) < 2.5 else { continue }
            let start = first.time.timeIntervalSince(systemStart), end = next.time.timeIntervalSince(systemStart)
            if runs.last?.end == start, runs.last?.name == first.names[0] {
                runs[runs.count - 1].end = end
                runs[runs.count - 1].observations += 1
            } else {
                runs.append((first.names[0], start, end, 2))
            }
        }
        var votes: [String: [String: Int]] = [:]
        var turnVotes: [Int: [String: Int]] = [:]
        var index = 0
        for sample in samples where sample.names.count == 1 {
            let t = sample.time.timeIntervalSince(systemStart)
            while index < turns.count && turns[index].end < t { index += 1 }
            var active = [Int]()
            var j = index
            while j < turns.count && turns[j].start <= t {
                if turns[j].end > t { active.append(j) }
                j += 1
            }
            guard active.count == 1, let i = active.first, turns[i].start + 0.4 < t, turns[i].end - 0.4 > t else { continue }
            let voice = turns[i].voice, name = sample.names[0]
            turnVotes[i, default: [:]][name, default: 0] += 1
            votes[voice, default: [:]][name, default: 0] += 1
        }
        // Vote once per acoustic turn. Rapid frame changes near an interruption
        // must not rename individual words or veto hours of consistent evidence.
        func winner(_ scores: [String: Int], minimum: Int, share: Double) -> String? {
            guard let best = scores.max(by: { $0.value < $1.value }), best.value >= minimum,
                  Double(best.value) >= share * Double(scores.values.reduce(0, +)) else { return nil }
            return best.key
        }
        let turnLabels = turnVotes.compactMapValues { winner($0, minimum: 3, share: 0.75) }
        var supported: [String: [String: Int]] = [:]
        for (index, name) in turnLabels {
            supported[turns[index].voice, default: [:]][name, default: 0] += 1
        }
        var labels: [String: String] = [:]
        for (voice, scores) in votes {
            guard let name = winner(scores, minimum: 4, share: 0.80),
                  let evidence = supported[voice], (evidence[name] ?? 0) >= 2 else { continue }
            // One contradictory turn can be an interruption. Its own label wins
            // locally. Only generalise across it with strong, repeated support.
            if evidence.count > 1 {
                let opposition = evidence.filter { $0.key != name }.values.reduce(0, +)
                guard opposition == 1, (evidence[name] ?? 0) >= 4,
                      winner(scores, minimum: 4, share: 0.90) == name else { continue }
            }
            labels[voice] = name
        }
        // A voice cluster can contain multiple people. Recover short intervals
        // from local evidence only, without assigning the entire cluster a name.
        var localLabels = turnLabels
        var r = 0
        for (i, turn) in turns.enumerated() {
            while r < runs.count && runs[r].end < turn.start { r += 1 }
            guard localLabels[i] == nil, r < runs.count, runs[r].start <= turn.start,
                  runs[r].end >= turn.end, runs[r].end - runs[r].start >= 2.5 else { continue }
            localLabels[i] = runs[r].name
        }
        // Bridge a dropout only between two independently named intervals of
        // the same voice. Stop at a voice change, overlap, pause or contrary
        // observation, including microphone activity and multi-speaker frames.
        var anchor: Int?, sampleIndex = 0
        for i in turns.indices {
            if i > 0 {
                let gap = turns[i].start - turns[i-1].end
                if turns[i].voice != turns[i-1].voice || gap < 0 || gap > 2 { anchor = nil }
            }
            guard let name = localLabels[i] else { continue }
            if let left = anchor, left + 1 < i, localLabels[left] == name,
               turns[i].start - turns[left].end <= 18 {
                let from = turns[left].end, to = turns[i].start
                while sampleIndex < samples.count && samples[sampleIndex].time.timeIntervalSince(systemStart) < from { sampleIndex += 1 }
                var j = sampleIndex, last = from, consistent = true
                while j < samples.count {
                    let sample = samples[j], time = sample.time.timeIntervalSince(systemStart)
                    if time > to { break }
                    if time - last > 2.5 || !(sample.names == [name] || (sample.names.isEmpty && sample.status == "no-border")) {
                        consistent = false
                        break
                    }
                    last = time
                    j += 1
                }
                if consistent && to - last <= 2.5 {
                    for middle in (left+1)..<i { localLabels[middle] = name }
                }
            }
            anchor = i
        }
        // A short glimpse can confirm an adjacent named turn of the same voice,
        // even when that voice cluster is ambiguous elsewhere in the meeting.
        let anchors = localLabels
        for i in turns.indices where anchors[i] == nil {
            guard let scores = turnVotes[i], scores.count == 1, let name = scores.keys.first else { continue }
            let neighbours = [i - 1, i + 1].filter { j in
                guard turns.indices.contains(j), turns[j].voice == turns[i].voice else { return false }
                let gap = turns[max(i, j)].start - turns[min(i, j)].end
                return gap >= 0 && gap <= 1.5
            }
            if Set(neighbours.compactMap { anchors[$0] }) == [name] { localLabels[i] = name }
        }
        var numbers: [String: Int] = [:]
        for turn in turns where numbers[turn.voice] == nil { numbers[turn.voice] = numbers.count + 1 }
        struct Token { let start: Double; var end: Double; var speaker: String; var text: String; var candidateNames = Set<String>(); var disputed = false }
        let baseline = min(micStart, systemStart)
        let systemOffset = systemStart.timeIntervalSince(baseline)
        let micOffset = micStart.timeIntervalSince(baseline)
        let myTokens = mic.map { Token(start: $0.start + micOffset, end: $0.end + micOffset, speaker: "Я", text: $0.text) }
        var remoteTokens = [Token]()
        var i = 0, z = 0
        for word in system.sorted(by: { $0.start < $1.start }) {
            while i < turns.count && turns[i].end <= word.start { i += 1 }
            let midpoint = (word.start + word.end) / 2
            var byVoice: [String: Double] = [:]
            var strongest: (index: Int, duration: Double)?
            var candidateNames = Set<String>(), disputed = false
            var ends: [String: Double] = [:]
            var simultaneous = false
            var j = i
            while j < turns.count && turns[j].start < word.end {
                let turn = turns[j]
                let start = max(word.start, turn.start), end = min(word.end, turn.end)
                if end > start {
                    if ends.contains(where: { $0.key != turn.voice && $0.value > start }) { simultaneous = true }
                    ends[turn.voice] = max(ends[turn.voice] ?? start, end)
                    if let name = localLabels[j] ?? labels[turn.voice] { candidateNames.insert(name) }
                    else { disputed = true }
                    byVoice[turn.voice, default: 0] += end - start
                    if end - start > (strongest?.duration ?? 0) { strongest = (j, end - start) }
                }
                j += 1
            }
            while z < runs.count && runs[z].end < word.start { z += 1 }
            var selected: Int?
            if let best = strongest, let duration = byVoice[turns[best.index].voice],
               duration >= (word.end - word.start) * 0.55 {
                selected = best.index
            } else if byVoice.count <= 1 && word.end - word.start <= 0.7 {
                // ASR word boundaries can fall just outside a voice interval.
                // Extend only an unopposed neighbour, never across a voice change.
                let nearby = [i - 1, i, j].filter { turns.indices.contains($0) &&
                    turns[$0].end >= midpoint - 0.45 && turns[$0].start <= midpoint + 0.45 }
                if Set(nearby.map { turns[$0].voice }).count == 1 { selected = strongest?.index ?? nearby.first }
            }
            var speaker = "Участник"
            if simultaneous {
                speaker = "Несколько голосов"
            } else if let index = selected {
                let voice = turns[index].voice
                if let name = localLabels[index] ?? labels[voice] {
                    speaker = name
                } else if byVoice.count == 1, z < runs.count, runs[z].observations >= 5,
                          runs[z].end - runs[z].start >= 5, runs[z].start <= word.start, runs[z].end >= word.end {
                    // A merged acoustic turn can span several people. A sustained
                    // Zoom observation applies only to the words it actually covers.
                    speaker = runs[z].name
                } else {
                    speaker = "Голос \(numbers[voice]!)"
                }
            } else if byVoice.count <= 1, z < runs.count, runs[z].start <= word.start, runs[z].end >= word.end,
                      strongest.flatMap({ localLabels[$0.index] ?? labels[turns[$0.index].voice] }).map({ $0 == runs[z].name }) != false {
                speaker = runs[z].name
            }
            remoteTokens.append(Token(start: word.start + systemOffset, end: word.end + systemOffset, speaker: speaker, text: word.text, candidateNames: candidateNames, disputed: disputed))
        }
        let knownNames = Set(samples.flatMap(\.names))
        var cursor = 0, reading = 0, microphone = 0
        while cursor < remoteTokens.count {
            guard remoteTokens[cursor].speaker == "Участник" else { cursor += 1; continue }
            let first = cursor
            while cursor < remoteTokens.count && remoteTokens[cursor].speaker == "Участник" { cursor += 1 }
            guard first > 0, cursor < remoteTokens.count else { continue }
            let left = remoteTokens[first - 1], right = remoteTokens[cursor]
            let fragment = remoteTokens[first..<cursor], start = remoteTokens[first].start, end = remoteTokens[cursor - 1].end
            let leftGap = start - left.end, rightGap = right.start - end
            guard knownNames.contains(left.speaker), (0...0.5).contains(leftGap), rightGap >= 0,
                  end - start <= 1.2, fragment.count <= 2,
                  fragment.reduce(0, { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }) <= 2,
                  fragment.allSatisfy({ !$0.disputed && $0.candidateNames.subtracting([left.speaker]).isEmpty }) else { continue }
            let between = left.speaker == right.speaker && rightGap <= 0.5
            let terminators = ".!?…"
            let tail = leftGap <= 0.12 && rightGap >= 0.35 &&
                left.text.last.map { !terminators.contains($0) } == true &&
                fragment.first?.text.first?.isLowercase == true &&
                fragment.last?.text.last.map { terminators.contains($0) } == true
            guard between || tail else { continue }
            let until = between ? right.start : end
            while microphone < localWords.count && localWords[microphone].end + micOffset < left.end { microphone += 1 }
            guard microphone == localWords.count || localWords[microphone].start + micOffset > until else { continue }
            while reading < samples.count && samples[reading].time.timeIntervalSince(baseline) < left.end { reading += 1 }
            var k = reading, conflict = false
            while k < samples.count && samples[k].time.timeIntervalSince(baseline) <= until {
                let sample = samples[k]
                if !(sample.names == [left.speaker] || (sample.names.isEmpty && sample.status == "no-border")) { conflict = true; break }
                k += 1
            }
            if !conflict { for j in first..<cursor { remoteTokens[j].speaker = left.speaker } }
        }
        // Assemble each channel first so simultaneous speech keeps both sentences intact.
        func phrases(_ tokens: [Token]) -> [Token] {
            var rows = [Token]()
            for token in tokens.sorted(by: { $0.start < $1.start }) {
                let text = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                if let last = rows.last, last.speaker == token.speaker,
                   token.start - last.end <= 1.8, token.start - last.start < 55,
                   !(token.start - last.start >= 28 && last.text.last.map { ".?!…".contains($0) } == true) {
                    let separator = text.first.map { ".,!?;:)".contains($0) } == true ? "" : " "
                    rows[rows.count - 1].text += separator + text
                    rows[rows.count - 1].end = max(last.end, token.end)
                } else {
                    rows.append(Token(start: token.start, end: token.end, speaker: token.speaker, text: text))
                }
            }
            return rows
        }
        return (phrases(myTokens) + phrases(remoteTokens)).sorted { $0.start < $1.start }.map { row in
            let s = max(0, Int(row.start))
            return String(format: "[%02d:%02d:%02d] ", s / 3600, s / 60 % 60, s % 60) + row.speaker + " — " + row.text
        }.joined(separator: "\n")
    }
}
