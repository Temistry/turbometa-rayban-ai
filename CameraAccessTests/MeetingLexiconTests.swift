import XCTest
@testable import CameraAccess

final class MeetingLexiconTests: XCTestCase {
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
}
