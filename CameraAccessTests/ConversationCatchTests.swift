import XCTest
@testable import CameraAccess

final class ConversationCatchTests: XCTestCase {
    // MARK: - 오디오 조각

    func testWavHeaderDescribes16kMonoPCM() {
        let data = DiarizationAudio.wav(samples: [0, 1, -1, 32767])
        XCTAssertEqual(data.count, 44 + 8)
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: data[36..<40], as: UTF8.self), "data")
        let rate = data[24..<28].enumerated().reduce(0) { $0 | (Int($1.element) << (8 * $1.offset)) }
        XCTAssertEqual(rate, 16_000)
        XCTAssertEqual(data[22], 1)
    }

    func testCompositePutsEnrollmentFirst() {
        let enrollment = [Int16](repeating: 100, count: 16_000 * 5)
        let chunk = [Int16](repeating: 200, count: 16_000)
        let composite = DiarizationAudio.composite(chunk: chunk, enrollment: enrollment)
        XCTAssertEqual(composite.samples.first, 100)
        XCTAssertEqual(composite.samples.last, 200)
        XCTAssertEqual(composite.samples.count, enrollment.count + Int(DiarizationAudio.enrollmentGap * 16_000) + chunk.count)
        XCTAssertEqual(composite.enrollmentEnd ?? 0, 5.3, accuracy: 0.001)

        let alone = DiarizationAudio.composite(chunk: chunk, enrollment: nil)
        XCTAssertEqual(alone.samples, chunk)
        XCTAssertNil(alone.enrollmentEnd)
    }

    func testSpeechSecondsIgnoresSilence() {
        let silence = [Int16](repeating: 0, count: 16_000 * 2)
        let tone = (0..<(16_000 * 3)).map { Int16(8000 * sin(Double($0) * 2 * .pi / 40)) }
        XCTAssertEqual(DiarizationAudio.speechSeconds(silence), 0)
        XCTAssertEqual(DiarizationAudio.speechSeconds(silence + tone), 3, accuracy: 0.11)
    }

    // MARK: - 화자 구분 응답

    private func response(_ words: [(String, String, String)]) -> [String: Any] {
        [
            "status": "completed",
            "steps": [[
                "type": "model_output",
                "content": [[
                    "type": "text",
                    "text": words.map(\.0).joined(separator: " "),
                    "annotations": words.map { word in
                        ["type": "word_info", "text": word.0, "speaker": word.1, "start_offset": word.2]
                    }
                ]]
            ]]
        ]
    }

    /// 견본 구간(0~5.3초)에 붙은 이름표가 "나"가 된다. 조각마다 번호가 바뀌어도 된다.
    func testEnrollmentLabelBecomesMe() {
        let object = response([
            ("안녕하세요", "spk_2", "0.2s"),
            ("지금부터", "spk_2", "1.1s"),
            ("대화를", "spk_2", "2.0s"),
            ("매출이", "spk_1", "6.0s"),
            ("두", "spk_1", "6.4s"),
            ("배", "spk_1", "6.6s"),
            ("근거가", "spk_2", "9.0s"),
            ("뭐예요", "spk_2", "9.5s")
        ])
        let words = DiarizationParser.words(from: object)
        XCTAssertEqual(words.count, 8)
        let turns = DiarizationParser.turns(words: words, enrollmentEnd: 5.3)
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].role, .other)
        XCTAssertEqual(turns[0].text, "매출이 두 배")
        XCTAssertEqual(turns[0].start, 0.7, accuracy: 0.001)
        XCTAssertEqual(turns[1].role, .me)
        XCTAssertEqual(turns[1].text, "근거가 뭐예요")
    }

    func testWithoutEnrollmentRolesAreUnknown() {
        let words = DiarizationParser.words(from: response([
            ("매출이", "spk_1", "0.5s"),
            ("올랐어요", "spk_1", "1.0s"),
            ("정말요", "spk_2", "2.0s")
        ]))
        let turns = DiarizationParser.turns(words: words, enrollmentEnd: nil)
        XCTAssertEqual(turns.map(\.role), [.unknown, .unknown])
        XCTAssertEqual(turns.count, 2)
    }

    func testOffsetParsing() {
        XCTAssertEqual(DiarizationParser.offset("1.250s"), 1.25)
        XCTAssertEqual(DiarizationParser.offset(NSNumber(value: 2.5)), 2.5)
        XCTAssertNil(DiarizationParser.offset(nil))
    }

    func testDiarizationRequestUsesVerbatimSpeakerMode() throws {
        let body = SpeakerDiarizationService.requestBody(wavBase64: "AAAA")
        XCTAssertEqual(body["model"] as? String, "gemini-3.5-transcribe")
        let input = try XCTUnwrap((body["input"] as? [[String: Any]])?.first)
        XCTAssertEqual(input["type"] as? String, "audio")
        XCTAssertEqual(input["mime_type"] as? String, "audio/wav")
        let config = try XCTUnwrap((body["generation_config"] as? [String: Any])?["transcription_config"] as? [String: Any])
        let mode = try XCTUnwrap(config["mode"] as? [String: Any])
        XCTAssertEqual(mode["type"] as? String, "verbatim")
        XCTAssertEqual(mode["diarization_mode"] as? String, "speaker")
        XCTAssertNil(config["custom_vocabulary"], "화자 구분과 사전은 함께 쓸 수 없다")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
    }

    // MARK: - 허점 판단과 결과

    func testJevCatchDecision() {
        let analyze = JevCatchDecision.make(answers: ["catch": JevAnswer(value: "leap", confidence: 0.8)])
        XCTAssertEqual(analyze?.shouldAnalyze, true)
        let weak = JevCatchDecision.make(answers: ["catch": JevAnswer(value: "leap", confidence: 0.3)])
        XCTAssertEqual(weak?.shouldAnalyze, false)
        let none = JevCatchDecision.make(answers: ["catch": JevAnswer(value: "none", confidence: 0.99)])
        XCTAssertEqual(none?.shouldAnalyze, false)
        XCTAssertNil(JevCatchDecision.make(answers: ["catch": JevAnswer(value: "weird", confidence: 0.9)]))
        XCTAssertNil(JevCatchDecision.make(answers: [:]))
    }

    func testCatchParsingKeepsValidItemsAndLimitsToTwo() {
        let raw = """
        ```json
        {"catches":[
          {"kind":"unsupported","quote":"다들 그렇게 해요","point":"근거 없이 다수에 기댐","ask":"어떤 사례가 있나요?","confidence":0.82},
          {"kind":"bogus","quote":"x","point":"y","ask":"z","confidence":0.9},
          {"kind":"leap","quote":"한 번 됐으니","point":"사례 하나로 일반화","ask":"다른 경우도 확인했나요?","confidence":1.4},
          {"kind":"claim","quote":"두 배","point":"수치 확인 필요","ask":"출처가 어디인가요?","confidence":0.6}
        ]}
        ```
        """
        let items = ConversationCatchParser.parse(raw, speakerKnown: true)
        XCTAssertEqual(items.map(\.kind), [.unsupported, .leap])
        XCTAssertEqual(items[1].confidence, 1)
        XCTAssertTrue(items[0].speakerKnown)
        XCTAssertTrue(ConversationCatchParser.parse("{\"catches\":[]}", speakerKnown: false).isEmpty)
        XCTAssertTrue(ConversationCatchParser.parse("오류", speakerKnown: false).isEmpty)
    }

    func testCritiqueRequestTargetsOnlyOtherSpeaker() throws {
        let body = MeetingGeminiService.critiqueRequestBody(
            statement: "다들 그렇게 해요", earlierOther: ["어제는 반대였어요"], mine: ["왜요?"],
            hint: "unsupported", speakerKnown: true
        )
        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
        let text = try XCTUnwrap((contents.first?["parts"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertTrue(text.contains("상대의 새 발언: 다들 그렇게 해요"))
        XCTAssertTrue(text.contains("검토 대상 아님"))
        let config = try XCTUnwrap(body["generationConfig"] as? [String: Any])
        XCTAssertEqual(config["responseMimeType"] as? String, "application/json")
    }

    // MARK: - 전사문 연결

    func testHighlighterAssociatesByWordOverlap() {
        let line = "이번엔 매출이 두 배 늘었다고 보셔도 됩니다"
        XCTAssertTrue(CatchHighlighter.isAssociated(
            lineText: line, quote: "매출이 두 배 늘었다고 보셔도"
        ))
        XCTAssertTrue(CatchHighlighter.isAssociated(
            lineText: line, quote: "매출이 두 배 늘었다고"
        ))
        XCTAssertFalse(CatchHighlighter.isAssociated(
            lineText: line, quote: "다음 분기 예산 안건으로 넘어가죠"
        ))
    }

    func testHighlighterShortQuoteFallsBackToSubstring() {
        XCTAssertTrue(CatchHighlighter.isAssociated(lineText: "EBITDA 기준", quote: "EBITDA"))
        XCTAssertFalse(CatchHighlighter.isAssociated(lineText: "EBITDA 기준", quote: "EBITDA 마진"))
    }

    func testHighlighterMarksOverlapWordsInOrder() {
        let marks = CatchHighlighter.marks(
            in: "매출이 두 배 늘었다고 봐야죠",
            quote: "매출이 두 배 늘었다고 봅니다",
            kind: .claim
        )
        XCTAssertEqual(marks.map(\.kind), Array(repeating: .claim, count: marks.count))
        XCTAssertEqual(marks.first?.word, "매출이")
        XCTAssertTrue(marks.contains { $0.word == "늘었다고" })
        // 오프셋은 정렬되어 있고 서로 겹치지 않는다.
        let pairs = zip(marks, marks.dropFirst())
        XCTAssertTrue(pairs.allSatisfy { $0.lowerOffset < $1.lowerOffset })
    }

    // MARK: - 대화 요약

    private func catchItem(_ kind: CatchKind, minutesAgo: Double) -> ConversationCatch {
        ConversationCatch(
            kind: kind,
            quote: "다들 그렇게 해요",
            point: "근거 없이 다수에 기댄 주장",
            ask: "어떤 사례가 있나요?",
            confidence: 0.8,
            timestamp: Date(timeIntervalSinceNow: -minutesAgo * 60),
            speakerKnown: true
        )
    }

    func testSummaryBuilderCountsAndSorts() {
        let startedAt = Date(timeIntervalSinceNow: -600)
        let summary = MeetingSummaryBuilder.build(
            startedAt: startedAt,
            endedAt: Date(),
            lineCount: 12,
            catches: [
                catchItem(.leap, minutesAgo: 1),
                catchItem(.unsupported, minutesAgo: 8),
                catchItem(.leap, minutesAgo: 4)
            ],
            cost: 0.0312
        )
        XCTAssertEqual(summary.lineCount, 12)
        XCTAssertEqual(summary.catches.count, 3)
        XCTAssertEqual(summary.counts[.leap], 2)
        XCTAssertEqual(summary.counts[.unsupported], 1)
        XCTAssertEqual(summary.duration, 600, accuracy: 1)
        // 오래된 것부터 정렬.
        XCTAssertEqual(summary.catches.first?.kind, .unsupported)
        XCTAssertEqual(summary.cost, 0.0312, accuracy: 0.000001)
    }

    func testSummaryExportIncludesStatsAndCatches() {
        let startedAt = Date(timeIntervalSince1970: 1_790_000_000)
        let summary = MeetingSummaryBuilder.build(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(300),
            lineCount: 5,
            catches: [catchItem(.unsupported, minutesAgo: 0)],
            cost: 0.02
        )
        let text = MeetingSummaryBuilder.exportText(summary)
        XCTAssertTrue(text.contains("TurboMeta 대화 리포트"))
        XCTAssertTrue(text.contains("대화 시간: 00:05:00"))
        XCTAssertTrue(text.contains("발화 5건 · 잡아낸 것 1건"))
        XCTAssertTrue(text.contains("인용: 다들 그렇게 해요"))
        XCTAssertTrue(text.contains("되묻기: 어떤 사례가 있나요?"))
    }

    // MARK: - 귓속말 방향

    func testWhisperSidePanAndDefault() {
        XCTAssertEqual(WhisperSide.resolve(stored: nil), .right)
        XCTAssertEqual(WhisperSide.right.pan, 1)
        XCTAssertEqual(WhisperSide.left.pan, -1)
        XCTAssertEqual(WhisperSide.both.pan, 0)
        XCTAssertTrue(TTSService.supportsStereoPan(outputs: [.bluetoothA2DP]))
        XCTAssertFalse(TTSService.supportsStereoPan(outputs: [.bluetoothHFP]))
        XCTAssertFalse(TTSService.supportsStereoPan(outputs: [.builtInSpeaker]))
    }

    func testWatchCatchEntry() {
        let entry = WatchMeetingStatus.catchEntry(id: "1", kind: "leap", title: "논리 비약", point: "p", ask: "a")
        let payload = WatchMeetingStatus.payload(
            state: "listening", route: "-", startedAt: nil, latest: "", recent: [],
            whisperCount: 0, error: "", quotaPaused: false, catches: [entry]
        )
        let catches = payload[WatchMeetingStatus.catches] as? [[String: String]]
        XCTAssertEqual(catches?.first?[WatchMeetingStatus.catchKind], "leap")
    }
}
