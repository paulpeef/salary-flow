import Foundation

struct MeetingVoiceMatch: Codable {
    let start, end: Double
    let name: String
}

struct VoiceExample: Codable {
    let start, end: Double
    let vector: [Float]
}

enum MeetingVoiceMatching {
    struct Window: Decodable {
        let startTime, endTime: Double
        let embedding256: [Float]
    }

    // FluidAudio's reconstructed turn contains a cluster centroid. The exported
    // windows carry independent, time-local embeddings from the original audio.
    static func annotate(_ turns: [MeetingVoice], windows: [Window], samples: [ZoomSample],
                         mic: [MeetingWord], micStart: Date, systemStart: Date,
                         saved: [String: [[Float]]] = [:], enrollment: (([String: [VoiceExample]]) -> Void)? = nil) -> [MeetingVoice] {
        struct Candidate {
            let turn: Int, start: Double, end: Double
            let vector: [Float], anchor: String?, present: Set<String>
        }
        let audio = turns.sorted { $0.start < $1.start }
        let zoom = samples.sorted { $0.time < $1.time }
        let local = mic.sorted { $0.start < $1.start }
        let offset = micStart.timeIntervalSince(systemStart)
        var audioIndex = 0, zoomIndex = 0, micIndex = 0
        var candidates = [Candidate]()
        let direct = Set(["name", "announcement", "banner", "tile-border", "tile-caption-border"])
        for w in windows.sorted(by: { $0.startTime < $1.startTime }) {
            let start = w.startTime, end = w.endTime
            guard (2...12).contains(end - start) else { continue }
            while audioIndex < audio.count && audio[audioIndex].end <= start { audioIndex += 1 }
            guard audioIndex < audio.count, audioIndex + 1 == audio.count || audio[audioIndex + 1].start >= end else { continue }
            // Reconstructed boundaries and embedding masks disagree at quiet edges.
            // Require one turn over the window and label only their intersection.
            let speechStart = max(start, audio[audioIndex].start), speechEnd = min(end, audio[audioIndex].end)
            guard speechEnd - speechStart >= 0.85 * (end - start),
                  speechStart - start <= 0.8, end - speechEnd <= 0.8 else { continue }
            while micIndex < local.count && local[micIndex].end + offset < start - 0.2 { micIndex += 1 }
            guard micIndex == local.count || local[micIndex].start + offset > end + 0.2 else { continue }
            while zoomIndex < zoom.count && zoom[zoomIndex].time.timeIntervalSince(systemStart) < start { zoomIndex += 1 }
            var j = zoomIndex, last = start, clean = true, named = Set<String>(), blocked = false
            var present: Set<String>?, rosterReads = 0, pairReads = 0
            while j < zoom.count {
                let sample = zoom[j], time = sample.time.timeIntervalSince(systemStart)
                if time > end { break }
                let roster = Set(sample.roster ?? [])
                present = present?.intersection(roster) ?? roster
                rosterReads += 1
                named.formUnion(sample.names)
                if let peer = sample.peer {
                    pairReads += 1
                    named.insert(peer)
                } else if sample.names.count != 1 || !direct.contains(sample.status) { clean = false }
                if sample.names.count > 1 { blocked = true }
                if time - last > 1.6 { clean = false }
                last = time
                j += 1
            }
            guard !blocked, named.count <= 1, pairReads == 0 || pairReads == rosterReads else { continue }
            let anchor = clean && j - zoomIndex >= 3 && end - last <= 1.6 ? named.first : nil
            // Weak or contradictory UI evidence must never become training data
            // or be overwritten by an acoustic guess.
            guard anchor != nil || named.isEmpty else { continue }
            let norm = sqrt(w.embedding256.reduce(Float.zero) { $0 + $1 * $1 })
            guard norm.isFinite, norm > 0, w.embedding256.count == 256 else { continue }
            candidates.append(Candidate(turn: audioIndex, start: speechStart, end: speechEnd,
                                        vector: w.embedding256.map { $0 / norm }, anchor: anchor,
                                        present: rosterReads >= 2 ? present ?? [] : []))
        }
        var profiles = [String: [Candidate]]()
        for c in candidates {
            guard let name = c.anchor else { continue }
            let stored = profiles[name] ?? []
            // Overlapping analysis windows from one utterance are one example.
            if stored.count < 12 && !stored.contains(where: { $0.turn == c.turn || $0.end > c.start }) {
                profiles[name, default: []].append(c)
            }
        }
        if let enrollment {
            var examples = [String: [VoiceExample]]()
            for (name, clips) in profiles where clips.count >= 2 {
                var best: Float = 0.72
                for i in clips.indices {
                    for other in clips.dropFirst(i+1) {
                        let similarity = zip(clips[i].vector, other.vector).reduce(Float.zero) { $0 + $1.0 * $1.1 }
                        if similarity > best {
                            best = similarity
                            examples[name] = [clips[i], other].map { VoiceExample(start: $0.start, end: $0.end, vector: $0.vector) }
                        }
                    }
                }
            }
            enrollment(examples)
        }
        guard profiles.count >= 2 || !saved.isEmpty else { return audio }
        var result = audio
        for c in candidates where c.anchor == nil {
            var scores = [(name: String, best: Float, second: Float?)]()
            for name in Set(profiles.keys).union(saved.keys) {
                let local = (profiles[name] ?? []).filter { $0.turn != c.turn }.map(\.vector)
                let previous = c.present.contains(name) ? saved[name] ?? [] : []
                let vectors = local + previous.filter { $0.count == c.vector.count }
                let similarities = vectors.map { vector in
                    zip(vector, c.vector).reduce(Float.zero) { $0 + $1.0 * $1.1 }
                }.sorted(by: >)
                if let best = similarities.first {
                    scores.append((name, best, similarities.dropFirst().first))
                }
            }
            scores.sort { $0.best > $1.best }
            guard let first = scores.first, let second = first.second else { continue }
            let crossMeeting = saved[first.name] != nil && c.present.contains(first.name)
            if scores.count == 1 && !crossMeeting { continue }
            let runnerUp = scores.dropFirst().first?.best ?? 0
            guard second >= (crossMeeting ? 0.84 : 0.72), second - runnerUp >= 0.12 else { continue }
            let match = MeetingVoiceMatch(start: c.start, end: c.end, name: first.name)
            if result[c.turn].matches == nil { result[c.turn].matches = [] }
            result[c.turn].matches?.append(match)
        }
        return result
    }
}
