import Foundation

private final class MeetFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.host == "meet.googleapis.com", request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let conference = "conferenceRecords/abc", start = "2026-01-05T10:00:00Z"
        let p = conference + "/participants/1", t = conference + "/transcripts/1"
        let response: [String: Any]
        switch url.lastPathComponent {
        case "conferenceRecords": response = ["conferenceRecords": [["name": conference, "startTime": start, "endTime": "2026-01-05T10:15:00Z"]]]
        case "participants": response = ["participants": [["name": p, "anonymousUser": ["displayName": "Тест"]]]]
        case "transcripts": response = ["transcripts": [["name": t, "state": "FILE_GENERATED"]]]
        case "entries":
            if URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "pageToken" && $0.value == "next" }) == true {
                response = ["transcriptEntries": [["name": t + "/entries/2", "participant": p, "startTime": "2026-01-05T10:00:03.125Z", "text": "Два"]]]
            } else {
                response = ["transcriptEntries": [["name": t + "/entries/1", "participant": p, "startTime": start, "text": "Один"]], "nextPageToken": "next"]
            }
        default: client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: response))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func checkMeetingIntegrations(_ check: (String, Bool) -> Void) {
    // Independent sequence with known offset. The reference follows a different clock.
    var seed: UInt64 = 17
    let signal = (0..<520).map { _ -> Float in
        seed = seed &* 6364136223846793005 &+ 1
        return Float(seed >> 54)/2048
    }
    let mix = Array(repeating: Float.zero, count: 31) + signal
    check("сдвиг Zoom определяется по независимым отрезкам", MeetingReference.align(reference: signal, mix: mix)?.shift == 31)
    check("тишина не подтверждает синхронизацию", MeetingReference.align(reference: Array(repeating: 0, count: 200), mix: mix) == nil)
    let reference = signal.enumerated().map { i, amp in i/13 % 2 == 0 ? amp : 0 }
    check("паузы одного участника допускают речь другого в общей записи", MeetingReference.align(reference: reference, mix: mix)?.shift == 31)
    let a = MeetingReference.Activity(name: "Anna", levels: [0,1,1,1,0,0,0], shift: 0)
    let b = MeetingReference.Activity(name: "Boris", levels: [0,0,0,1,1,1,0], shift: 0)
    let scored = MeetingReference.score([.init(start: 0.11, end: 0.19, speaker: "Anna", text: "да"),
        .init(start: 0.21, end: 0.29, speaker: "Голос 1", text: "вот"),
        .init(start: 0.31, end: 0.39, speaker: "Anna", text: "вместе"),
        .init(start: 0.41, end: 0.49, speaker: "Anna", text: "нет")], tracks: [a,b])
    check("покрытие и точность имеют отдельные знаменатели", scored.contains("3 из 4 (75.0%)") && scored.contains("1 из 2 (50.0%)") && scored.contains("Наложение речи — 1"))
    check("API принимает код либо ссылку Google Meet", GoogleMeetAPI.meetingCode("https://meet.google.com/abc-defg-hij?authuser=0") == "abc-defg-hij" &&
          GoogleMeetAPI.meetingCode("https://example.org/abc-defg-hij") == nil)
    let finished = DispatchSemaphore(value: 0)
    final class Outcome: @unchecked Sendable { var transcript: String? }
    let outcome = Outcome()
    Task.detached {
        defer { finished.signal() }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MeetFixture.self]
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        let api = GoogleMeetAPI(token: "fixture", session: session)
        if let record = try? await api.records("abc-defg-hij").first {
            outcome.transcript = try? await api.transcript(record)
        }
    }
    let returned = finished.wait(timeout: .now() + 10) == .success
    check("Google Meet импортирует обе страницы реплик с именем и временем",
          returned && outcome.transcript == "[00:00:00] Тест — Один\n[00:00:03] Тест — Два")
}
