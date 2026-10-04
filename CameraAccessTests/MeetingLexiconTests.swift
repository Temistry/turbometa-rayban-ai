import XCTest
@testable import CameraAccess

final class MeetingLexiconTests: XCTestCase {
    func testRecognitionHintsAreBoundedAndCoverBothDomains() {
        XCTAssertLessThanOrEqual(MeetingPolicy.recognitionHints.count, 40)
        XCTAssertTrue(MeetingPolicy.recognitionHints.contains("기술부채"))
        XCTAssertTrue(MeetingPolicy.recognitionHints.contains("EBITDA"))
    }

    func testMeaningUnitConsumesOnlyNewTextAndPreservesCorrections() {
        XCTAssertEqual(MeetingPolicy.meaningUnit("API 설명입니다", after: "API"), "설명입니다")
        XCTAssertEqual(MeetingPolicy.meaningUnit("API", after: "API"), "")
        XCTAssertEqual(MeetingPolicy.meaningUnit("API", after: "에이피"), "API")
        XCTAssertEqual(MeetingPolicy.meaningUnit(String(repeating: "가", count: 900), after: "").count, 600)
    }

    func testWaitDecisionNeverExplainsEvenWithConflictingYes() {
        let result = JevUtteranceDecision.make(answers: [
            "needs_explanation": JevAnswer(value: "yes", confidence: 0.9),
            "lane": JevAnswer(value: "wait", confidence: 0.9)
        ])
        XCTAssertTrue(result.needsMoreContext)
        XCTAssertFalse(result.needsExplanation)
    }
    func testDetectsBusinessAndDevAbbreviations() {
        XCTAssertTrue(MeetingPolicy.lexiconHit(in: "이번 분기 EBITDA가 개선됐습니다"))
        XCTAssertTrue(MeetingPolicy.lexiconHit(in: "S3 버킷에 올려서 확인해 보죠"))
        XCTAssertTrue(MeetingPolicy.lexiconHit(in: "CI CD 파이프라인을 정리합시다"))
    }

    func testEverydaySpeechDoesNotTriggerLexicon() {
        XCTAssertFalse(MeetingPolicy.lexiconHit(in: "어제 회의록 정리해 주셔서 감사합니다"))
        XCTAssertFalse(MeetingPolicy.lexiconHit(in: "점심 먹으러 가실 분 계신가요"))
    }

    func testLexiconMatchingIsCaseInsensitive() {
        XCTAssertTrue(MeetingPolicy.lexiconHit(in: "Kubernetes 클러스터 이야기입니다"))
        XCTAssertTrue(MeetingPolicy.lexiconHit(in: "ebitda 얘기가 아니라"))
    }

    func testKoreanParticleAttachedToTermStillMatches() {
        XCTAssertTrue(MeetingPolicy.lexiconHit(in: "API를 먼저 열어 두죠"))
        XCTAssertTrue(MeetingPolicy.lexiconHit(in: "KPI는 다음 주에"))
        XCTAssertFalse(MeetingPolicy.lexiconHit(in: "가나다라마바사"))
    }
}
