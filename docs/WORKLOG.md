# TurboMeta 미니 작업로그

이 문서는 기능 변경의 이유, 범위, 검증 결과를 짧게 누적하는 개발 로그다. 실제 인증값, 토큰, 사용자 질문·답변 원문은 기록하지 않는다.

---

## 2026-08-21 · 홈 OpenClaw 음성 대화 진입 수정

### 목적

- 실기기에서 홈 OpenClaw 카드가 일반 채팅만 열어 Galvis STT가 전혀 시작되지 않던 진입 경로 불일치를 수정한다.
- 홈과 Siri가 같은 연속 음성 세션을 열고, 텍스트 채팅은 음성 화면 안의 기존 **채팅** 버튼으로 유지한다.

### 주요 변경

- 홈 OpenClaw 카드가 `requestOpenClawChat()` 대신 `requestOpenClawSession()`을 호출하도록 변경하고 카드 문구와 아이콘을 음성 대화에 맞췄다.
- launch coordinator가 voice/chat modal을 동시에 활성화하지 않으며, 겹친 요청은 현재 화면 종료 후 순서대로 표시한다.
- request, 앱 준비, 화면 표시·종료, 음성 화면 진입과 manager 시작 경계에 비식별 route marker를 추가했다.
- marker는 route와 Bool 상태만 기록하며 사용자 발화·답변, message UUID, token, 주소와 기기 식별정보를 기록하지 않는다.
- coordinator의 ready 전 요청, chat message 선택, 겹친 요청의 순차 표시와 voice 재진입 회귀 테스트를 추가했다.

### 검증 범위

- `git diff --check`, 보안·현지화 audit와 OpenClaw exporter Python 테스트를 실행한다.
- Windows에는 Xcode가 없어 Swift compile/XCTest는 push 후 GitHub Actions iPhone Simulator에서 확인한다.
- 실기기에서는 홈 OpenClaw → 음성 화면 → STT 시작 → `owner=galvis` → 자동 TTS → AudioSession 복구 → 두 번째 STT를 확인해야 한다.

---

## 2026-08-21 · 갈비스 OpenClaw 연속 대화 복구

### 목적

- 앱이 foreground에서 갈비스 대화 모드로 열린 동안 첫 답변 이후에도 wake word 없이 STT → OpenClaw → TTS → STT 순환을 유지한다.
- 일시적 음성·오디오·Gateway 오류를 턴 단위로 복구하되 실패한 질문을 자동 재전송하지 않는다.

### 주요 변경

- 기존 15초 follow-up과 wake-word 복귀 상태를 제거하고 사용자가 종료할 때까지 계속 듣는 conversation loop로 변경했다.
- 빈 transcript와 알 수 없는 일시적 Speech/Audio 오류는 마이크 엔진을 정리·reset하고 최대 5회 bounded backoff 후 다시 듣는다.
- Gateway connection failure와 disconnect는 기존 연결 정책으로 복구한 뒤 새 발화를 기다린다. timeout, disconnect 또는 request-in-progress가 발생한 질문을 자동 replay하지 않는다.
- delivery ambiguous, Gateway rejection, 설정·권한 오류는 자동 복구하지 않고 명확한 오류 상태로 종료한다.
- TTS가 공유 AudioSession을 playback으로 바꾼 뒤 모든 경로에서 `.playAndRecord`·`.voiceChat`을 다시 설정하며, 다음 listen 전에도 실제 shared session 구성을 재확인한다.
- cancellation은 recovery 대상으로 취급하지 않고 background·사용자 종료 시 STT, pending OpenClaw 요청, TTS와 AudioSession을 정리한다.
- 상태 로그는 복구 action, attempt, 오류 domain/code와 text length만 사용하고 transcript·답변 원문은 기록하지 않는다.

### 검증 범위

- 순수 recovery/loop policy XCTest에 성공 턴 이후 budget reset, 빈 transcript·일시 오류 재청취, reconnect 후 새 발화 대기, timeout no-replay, ambiguous delivery·cancellation 종료, 최대 retry와 bounded backoff를 추가했다.
- `git diff --check`는 오류 없이 통과했다. `python Scripts/audit_localization_security.py`는 치명 0·경고 0·기존 정보성 1을 확인했고, OpenClaw export Python 테스트 2개가 통과했다.
- Windows에는 Xcode/Swift toolchain이 없지만 commit `139f2d0`의 GitHub Actions iPhone Simulator 빌드가 [실행 1](https://github.com/Temistry/turbometa-rayban-ai/actions/runs/32463823910)과 [실행 2](https://github.com/Temistry/turbometa-rayban-ai/actions/runs/32463821611)에서 모두 통과해 Swift compile과 test target 통합을 확인했다.
- 실기기에서는 질문 1 → TTS → 질문 2, 무음 복구, TTS 실패 후 재청취, Gateway 단절·재연결, background·종료 문구 종료를 확인해야 한다.

---

## 2026-08-20 · OpenClaw 사진·동영상 Quick Shot과 보호 갤러리

### 목적

- OpenClaw를 홈의 최우선 진입점으로 배치하고 사진·동영상 촬영부터 분석, 저장, 알림·TTS까지 한 흐름으로 연결한다.
- 사용자 편집형 촬영 모드와 보호된 앱 소유 갤러리로 재시도 가능성과 개인정보 보호를 함께 확보한다.

### 주요 변경

- DAT SDK 0.5.0의 세로 `.high` 720×1280을 유지하고 15fps로 낮춰 Bluetooth 대역폭을 프레임 수보다 프레임당 세부 묘사에 우선하도록 했다. 소비자용 12MP/3K 카메라 경로와 DAT 개발자 스트림의 차이를 설정과 문서에 명시했다.
- 설정 화면의 저/중/고 선택을 읽기 전용 `고세부 묘사 · 720×1280 · 15fps (DAT)` 상태로 바꿔 실제 스트림 정책과 일치시켰다.
- Quick Shot MP4 입력 상한을 15fps로 맞추고 첫 입력 프레임 크기를 그대로 H.264 High Profile로 기록한다. 기존 최대 10초·30MiB soft budget과 backpressure frame drop은 유지한다.
- DAT 사진 JPEG는 보호 저장하고, 4MiB를 넘을 때만 원본과 분리된 분석 전송용 JPEG를 최고 품질부터 축소한다. SDK가 제공하지 않는 12MP 업스케일은 하지 않는다. 일반 OpenClaw 채팅 카메라도 stream frame 대신 exact JPEG 정지 사진을 사용한다.
- 동영상 contact sheet는 최대 6프레임을 유지하면서 작은 입력을 확대하지 않고 자연 픽셀 크기를 보존하며, 긴 변 최대 4096px·JPEG quality 1.0부터 4MiB 안의 최고 결과를 선택한다. Gallery 재분석도 보호 원본 MP4에서 contact sheet를 다시 생성한다.
- Gallery thumbnail의 긴 변과 JPEG 품질을 높여 원본을 건드리지 않고 미리보기 선명도를 개선했다. 상세 동영상은 실제 세로 비율을 사용하며 원본 해상도·용량·fps·bitrate를 표시한다.
- 기본 off인 `촬영 위치 포함`을 추가했다. 사용자가 켜고 when-in-use 권한을 허용한 경우에만 단발성 iPhone GPS snapshot을 사진 GPS EXIF, MP4 QuickTime 위치 metadata, Photos asset과 OpenClaw 분석 문맥에 적용한다. 위치 실패는 촬영을 막지 않는다.
- 홈 Quick Shot의 모드 선택 화면에 `모드 추가 및 편집` 진입점을 추가해 촬영 흐름을 벗어나지 않고 기존 모드 관리·편집 UI를 사용할 수 있게 했다.
- 모드 관리를 picker의 navigation 계층에 연결해 관리 후 돌아오면 동일한 manager에서 변경된 호환 모드 목록이 즉시 갱신되며, 실제 촬영은 사용자가 모드를 다시 탭할 때 기존 immutable snapshot으로 시작한다.
- 실기기 진단에서 background/잠금 중 Keychain OSStatus `-25308`을 자격 증명 미설정으로 오인해 빈 인증 요청을 보내던 경로를 차단했다.
- Gateway token 상태를 configured/not configured/temporarily unavailable/failure로 구분하고 foreground에서만 읽어 연결 attempt당 캐시한다.
- pending reconnect backoff를 화면 `onAppear`와 foreground 복귀가 우회하지 않게 했으며, 자동 연결은 재시도 횟수를 초기화하지 않는다.
- ExternalAccessory/DAT의 공백 구분 node/service/connection ID, firmware key와 표시 이름 숫자 suffix를 마스킹하고 lifecycle 전환 시 부분 로그 라인을 독립 flush한다.
- Quick Shot 사진은 원문 없이 JPEG byte count와 capture/save 성공 여부만 진단 로그에 남긴다.
- 사진·동영상별 Quick Shot 카드, 모드 picker/editor/관리 화면과 immutable 실행 snapshot을 추가했다.
- 단일 DAT `StreamSession`에 capture owner/lease를 추가해 Quick Vision, Siri, Quick Shot 촬영 경쟁을 직렬화했다.
- 사진은 SDK JPEG 원본을 보호 저장하고, 동영상은 최대 10초·15fps H.264 MP4를 저장한다.
- 동영상 분석은 MP4 upload가 아니라 최대 6개 대표 프레임의 2×3 contact sheet JPEG만 사용한다.
- Application Support 보호 미디어 repository, add-only Photos 복사, 독립 local/Photos/analysis/delivery 상태를 추가했다.
- 일반 chat, Galvis, Quick Shot이 단일 typed outbound owner를 공유하고 stable request/message UUID, ambiguous delivery, final message linkage를 처리한다.
- 앱 갤러리에 전체/사진/동영상 필터, thumbnail/status, MP4 재생, 공유, Photos/분석 재시도, 연결 답변 이동, 앱 원본 삭제 확인을 구현했다.
- OpenClaw chat/session presentation을 `MainTabView`로 올려 Gallery에서도 특정 답변으로 이동할 수 있게 했다.
- recorder manual stop·auto-finalize·cancel 경쟁을 직렬화하고 finalizing 중 취소된 temp output을 제거한다.

### 보안·데이터 정책

- mode prompt, 이미지·동영상 payload, transcript, OpenClaw 답변 원문과 좌표를 진단 로그에 남기지 않는다.
- 위치 기능은 기본 off이며 지속 추적·background location을 사용하지 않는다. 권한 거부·제한·timeout 시 위치 없이 촬영을 계속한다.
- Photos에는 `.addOnly`로 복사하며 기존 보관함을 읽거나 앱 repository의 source of truth로 사용하지 않는다.
- 앱 항목 삭제는 앱 원본·thumbnail·index만 삭제하고 Photos 복사본은 건드리지 않는다.
- delivery가 불명확하면 자동 재전송하지 않고 사용자의 명시적 재시도만 허용한다.
- Gateway token, 실제 Meshnet 주소, 기기·pairing·외부 서비스 식별정보는 이 기록에 포함하지 않았다.

### 검증 결과

- 화질 변경에 15fps/source-dimension MP4, 보호 MP4 대표 프레임 재추출, contact sheet 자연 크기·4MiB budget, JPEG 원본 pass-through·초과 fallback 회귀 테스트를 추가했다.
- location 없는 기존 media index decode, location snapshot round-trip·copy 보존, 위치 없음 JPEG byte-for-byte pass-through와 GPS EXIF pixel dimension 보존 테스트를 추가했다.
- `git diff --check`: 오류 없음. Windows 작업 트리의 LF→CRLF 경고만 확인했다.
- `python Scripts/audit_localization_security.py`: 치명 0, 경고 0, 기존 정보성 1.
- `python -m unittest Scripts/OpenClaw/test_export_openclaw_conversations.py`: 2개 테스트 통과.
- reconnect/foreground 정책과 신규 runtime 식별정보 redaction 회귀 XCTest를 추가했다. Windows에는 XCTest 실행 환경이 없어 CI에서 실행해야 한다.
- Xcode project top-level object ID 중복 없음.
- 금지한 video attachment/Base64 MP4, broad ATS 예외, TLS 검증 비활성화 추가 없음.
- Windows에는 Xcode/Swift toolchain이 없어 app compile, XCTest, Simulator, Photos/AVAssetWriter/DAT 실기기 검증은 수행하지 못했다.

### 남은 배포 전 검증

- macOS/Xcode에서 고정 package resolution으로 Debug/Release unsigned Simulator build와 `CameraAccessTests` 실행.
- 실기기에서 사진 capture, 조기 stop/10초 auto-stop/cancel 동영상, Photos 권한 거부·재시도, Gallery playback/share/delete 의미 확인.
- Meshnet 단절·복구 중 exactly-once/ambiguous 동작과 기존 final dedup·알림·요약 TTS 회귀 확인.

---

## 2026-08-09 · Google Gemini 단일화와 지식 로그 착수

### 결정

- 일반 사용자에게는 Google Gemini API Key 하나만 받는다.
- Quick Vision은 Gemini 이미지 이해 REST API로 전환한다.
- Live AI는 Gemini Live로 고정한다.
- 실시간 번역은 Gemini Live에 통역 전용 시스템 지시를 적용한다.
- Quick Vision의 짧은 한국어 결과는 iOS 시스템 TTS `ko-KR`로 읽는다.
- Google Drive API와 별도 OAuth 토큰은 추가하지 않는다.
- 사용자가 iOS 파일 선택기에서 Google Drive 폴더를 지정하면 해당 폴더에 파일을 동기화한다.
- 사람용 Markdown과 기계용 JSONL을 동시에 만든다.

### 이유

- API Key 입력과 공급자 선택을 하나로 줄여 사용 흐름을 단순화한다.
- Google Drive for desktop과 Obsidian에서 별도 변환 없이 파일을 사용할 수 있다.
- Drive API OAuth를 없애 인증 토큰 보관과 갱신 문제를 피한다.
- 사진·음성 원본 대신 텍스트 Q&A만 보관해 개인정보와 저장 용량을 줄인다.

### 완료

- [x] 구현 계획 문서 생성
- [x] `KnowledgeLogService` 기본 코드 추가
- [x] 로컬 보호 저장소에 Markdown + JSONL 기록 구조 추가
- [x] 민감정보 마스킹 규칙 추가
- [x] iOS 폴더 선택기와 외부 폴더 동기화 구조 추가

### 진행 중

- [x] Xcode 프로젝트에 새 서비스 파일 등록
- [x] API 제공자 설정을 Google 중심으로 정리
- [x] Quick Vision Gemini REST 전환
- [x] Live AI Google 고정
- [x] Live Translate Gemini Live 전환
- [x] Q&A 저장 훅 연결
- [x] 설정 화면에 지식 로그 폴더·동기화 UI 추가
- [x] README 기능 설명 갱신
- [ ] 정적 보안 검사와 iOS 빌드 검증

### 보안 메모

- 실제 API Key 값은 Keychain 외부에 기록하지 않는다.
- 로그에는 인증값 존재 여부, 접두사, 접미사, 해시를 남기지 않는다.
- 질문·답변 본문은 진단 콘솔에 출력하지 않는다.
- 지식 로그에는 이미지, 음성, 위치, 사용자 계정 정보를 저장하지 않는다.
- 외부 폴더에는 사용자가 명시적으로 선택한 경우에만 동기화한다.

---

## 2026-08-09 · iOS 시뮬레이터 컴파일 안정화 및 문서 정합화

### 목적

- GitHub Actions iOS Simulator 빌드를 막던 통합 설정 화면과 지식 로그 서비스의 인터페이스 불일치를 최소 수정으로 해결한다.
- 공개 문서를 현재 Gemini 중심·Files 기반 로그 동기화 구조에 맞춘다.

### 수정 파일

- `CameraAccess/Views/UnifiedSettingsView.swift`
- `README.md`
- `README_EN.md`
- `docs/WORKLOG.md`

### 주요 변경

- 존재하지 않는 `destinationDisplayName` 참조를 서비스의 `destinationStatusText`로 교체했다.
- `configureDestination`의 비-throwing 인터페이스에 맞춰 불필요한 `try/catch`를 제거했다.
- iOS 17 `onChange` overload로 설정 화면 경고를 정리했다.
- README를 Google Gemini API Key 단일 설정, Quick Vision `ko-KR` 시스템 TTS, Gemini Live AI/번역, Markdown·JSONL 지식 로그, Files 기반 Google Drive 폴더 동기화, 별도 Drive OAuth secret 미사용 정책으로 갱신했다.

### 발생한 문제와 해결

- **문제:** `KnowledgeLogService`에는 `destinationName`과 `destinationStatusText`만 있는데 설정 화면이 `destinationDisplayName`을 참조하여 Swift 컴파일이 실패했다.
- **해결:** 기존 서비스가 이미 제공하는 안전한 표시용 계산 속성 `destinationStatusText`를 사용했다. 폴더 선택과 동기화 동작은 변경하지 않았다.

### 검증 결과

- 로컬 정적 감사: fatal 0건, warning 0건, informational 1건(기존 개발자 로그 공유 안내).
- 로컬 Windows 작업 환경에는 Xcode/iPhone Simulator SDK가 없어 `xcodebuild`는 실행할 수 없다.
- 원격 브랜치의 기존 GitHub Actions Simulator 빌드는 이 수정 전 커밋에서 실패했다. 수정 커밋 push 후 같은 워크플로의 성공 결과를 확인해야 한다.

### 남은 실제 기기 검증

- Ray-Ban Meta 권한·카메라 스트림, Gemini Live 오디오와 Bluetooth 경로
- Quick Vision Gemini 결과 및 iOS `ko-KR` 시스템 TTS
- 실시간 번역, 텍스트 전용 Markdown/JSONL 로그 마스킹
- Files 문서 선택기, bookmark 복원, Google Drive 폴더 동기화

### 보안 메모

- 실제 API Key, access token, refresh token, JWT, OAuth secret 및 식별 가능한 파생 형태를 문서·로그·테스트 출력에 기록하지 않았다.
- Files 기반 Drive 동기화는 사용자가 선택한 폴더와 security-scoped bookmark만 사용하며 별도 Drive OAuth 자격 증명을 추가하지 않는다.

---

## 2026-09-22 · 회의 통역기(회의모드) 1차 구현

### 결정
- 스파이더센스는 폐기하고 "회의 전문용어 통역기"로 목표를 축소했다. 전사(안경 마이크) 기반으로 귓속말 설명 레인과 근거 조사 레인을 운영한다.
- TypeSafe Jev를 신경 반사 계층으로 채택: 발화별 개입 여부(needs_explanation)와 후속 레인(lane)을 choice 질문으로 판정한다. Jev 오류는 fail-stop(E-JEV-401/503/500)으로 에러 코드를 표시하고 통역을 즉시 중지한다. 대체 휴리스틱 게이트는 만들지 않는다.
- 용어 설명·근거 조사 문장 생성은 기존 Google Gemini Key를 재사용하고, 근거 조사는 google_search 그라운딩으로 링크를 추출한다.
- Jev API 키는 기존 패턴대로 Keychain(typesafe-jev-api-key)에만 저장하고 설정 화면에서 등록한다. 실제 키는 레포·로그에 기록하지 않는다.

### 완료
- [x] JevClient(TypeSafe /v1/systemone 클라이언트, 응답 파서, 에러 코드 체계)
- [x] MeetingGeminiService(용어 설명 + 검색 그라운딩 근거 조사)
- [x] MeetingTranscriptionService(HFP/LE 입력 우선, 온디바이스 한국어 연속 전사, 45초 재시작 루프, 귓속말 재생 중 pause/resume)
- [x] MeetingInterpreterViewModel(쿨다운 30초, 신뢰도 임계 0.85, fail-stop, 팩트 카드)
- [x] MeetingModeView(전사 스트림, 귓속말 인디케이터, 근거 링크 카드, E-JEV/E-MIC 에러 화면)
- [x] 홈 진입 카드, 설정 Jev API Key 섹션, TTSService 저음량 귓속말(volume 0.35)
- [x] JevDecisionParsingTests(파서·레인 매핑·쿨다운·그라운딩 링크)

### 남음
- [x] CodeMagic 빌드 결과 확인 및 TestFlight 배포 완료 확인(커밋 c54db8b: ios-compile-check success, ios-testflight 워크플로 success — App Store Connect 제출 단계 포함)
- [ ] 실기기: 안경 마이크 라우팅, 귓속말 음량/쿨다운 체감, Jev 실호출 지연(한국 기준) 측정
- [ ] 전사 세그먼트 품질 평가 후 온디바이스/서버 인식 전략 확정

### 검증
- 로컬 정적 감사(Windows): fatal 0건, warning 0건, informational 1건(기존 항목)
- 로컬 Windows 환경에서는 xcodebuild 불가. 컴파일은 원격으로 검증했다: GitHub Actions iPhone 시뮬레이터 빌드 2건 success, CodeMagic iOS 컴파일 점검 success.
- CodeMagic iOS TestFlight 워크플로(서명 아카이브 + App Store Connect 제출) success. TestFlight 처리 완료 여부는 App Store Connect/TestFlight 앱에서 최종 확인한다.

### 보안 메모
- Jev/Gemini 키를 소스·문서·로그에 기록하지 않았다. Jev 키는 기기 Keychain 전용 항목으로 저장한다.
- 회의 전사 원문은 로컬 화면 표시로 한정하고 별도 저장·업로드 경로를 추가하지 않았다.

## 기록 형식

## 2026-09-22 · 회의 통역기 단일 목적 개편 + 시각 보조 인식

### 결정
- 앱을 단일 목적(회의 통역)으로 좁힌다. 런치 즉시 회의 통역 화면이 뜨고 레거시 홈(Quick Shot·OpenClaw 등) 진입점을 제거했다(코드는 보존).
- 안내 문장·시스템 용어 노출을 제거했다. 상태는 "듡는 중/대기" 칩 하나, 마이크 출래는 실제 기기명 칩, 오류는 코드+한 줄+닫기만 남긴다.
- Meta 통역기의 "바라보면 인식률 상승" 힌트를 시각 보조 인식으로 구현한다: 회의 중 카메라 스트림 유지 → 5초마다 프레임 분석 → 용어는 SFSpeechRecognizer contextualStrings 주입, 장면 요약은 귓속말 설명 맥락으로 사용.
- 전사 UI를 채팅 말풍선에서 라이브 캡션으로 바꾼다. 용어 인라인 하이라이트, 귓속말 결과는 조용히 붙이고, 근거 조사는 배지 → 하프시트.

### 완료
- [x] 루트 진입 MeetingModeView 교체(MainAppView), 레거시 탭 제거
- [x] VisualAssistService: 스트림 유지 + 프레임 512px 축소 + Gemini 장면/용어 JSON 분석 + contextualStrings 주입 + 설명 맥락 전달
- [x] MeetingGeminiService.explain JSON화(term+text)로 용어 인라인 하이라이트 구현
- [x] 캡션 스트림 UI, 상태 칩, 근거 배지/하프시트, 최소 에러 오버레이, 설정 톱니
- [x] 설정: 시각 보조 토글(기본 켜짐)
- [x] 파서 단위 테스트 6건 추가

### 남음
- [ ] CodeMagic 빌드·TestFlight 배포 확인
- [ ] 실기기: 시각 보조 토글 on/off 인식률 비교, 캡션 흐름 체감, 카메라 LED·배터리 영향 확인

### 검증
- 로컬 정적 감사: fatal 0, warning 0, informational 1(기존)
- 컴파일·배포는 CodeMagic 워크플로에서 확인한다.

### 보안 메모
- 변경 없음. 프레임은 512px로 축소해 전송하고 저장하지 않는다. 사람 식별 정보 추출 금지를 프롬프트에 명시했다.

## 2026-09-22 · 무음 촬영 설명과 세션 수명 보강

### 결정
- 회의 시작 전과 회의 중 모두 하단 104pt 촬영 버튼으로 현재 안경 장면을 설명한다. 무음에서도 작동하고 접수·촬영 완료를 진동으로 알린다.
- SDK JPEG 원본을 축소·재인코딩하지 않고 Gemini에 전달한다. 실제 픽셀 크기는 기기 로그에 기록하며 센서 최대 해상도를 보장하지 않는다.
- 직접 촬영 요청은 자동 개입 임계값을 적용하지 않지만 Jev 정상 응답은 필수다. Jev 실패 시 기존 fail-stop 정책을 유지한다.

### 완료
- [x] 사진 촬영 → Jev 확인 → 장면 설명 → 저음량 재생, 자막 보존, 실패 시 재시도 표시
- [x] 시작·촬영 중복 차단, 중지 시 작업 취소 및 이전 세션 응답 무시, 카메라 SDK 중복 시작 직렬화
- [x] 전사 엔진 정지 후 입력 tap 재설치, 채널·샘플레이트 검증, 마이크 권한 확인
- [x] 시각 보조 분석 직렬화와 취소 후 결과 차단
- [x] 원본 사진 요청 보존·빈 응답 처리 XCTest 추가

### 남음
- [ ] 이번 크래시의 .ips와 재현 동작 확보. 기존 첨부 로그의 429/503만으로 프로세스 종료 원인을 확정할 수 없음
- [ ] 실기기: 무음 촬영, 반복 촬영, 전사→설명→전사, 처리 중 중지·재시작, 연결 해제, Jev/Gemini 실패 확인
- [ ] 실제 사진 픽셀 크기와 안경 스피커 출력 경로 확인
- [ ] CodeMagic 컴파일·TestFlight 결과 확인

### 검증
- 로컬 보안·번역 감사: fatal 0, warning 0, informational 1(기존). git diff --check 통과.
- Windows에는 Xcode가 없어 XCTest 실행 및 실기기 크래시 재현은 수행하지 못함.

### 보안 메모
- 키는 기존 Keychain 경로 사용. 사진 원본은 사용자 촬영 요청 시 Gemini로 전송하며 키·사진 내용은 로그에 기록하지 않음.

## 2026-09-23 · 백그라운드 통역·애플워치 디스플레이·도메인 사전 감지

### 결정
- 오디오 백그라운드 모드는 이미 선언돼 있으므로, 통화·시리 방해 종료 후 세션 재구성·전사 재개, 라우트 변경(안경 연결 해제→아이폰 마이크) 복구, 엔진 시작 실패 시 즉사 대신 2초 간격 재시도(3회)를 추가한다.
- watchOS 컴패니언 앱(TurboMetaWatch)을 iOS 앱에 내장해 TestFlight로 함께 배포한다. WatchConnectivity applicationContext로 상태를 밀어주고(자막 2초 스로틀, 상태·오류 즉시), 실패는 로그만 남긴다.
- 귓속말 개입 대상을 비즈니스(재무·회계·전략·마케팅·법무)와 개발(소프트웨어·인프라·데이터·보안) 두 도메인으로 한정한다. Jev questions에 category(business/dev/none)를 추가하고 category=none이면 생략한다.
- 사전 감지: 기기 내 약어 사전(EBITDA·API·S3 등) 적중 시 신뢰도 문턱을 0.6→0.3으로 낮춘다. 확정 판정이 아니라 가중치다.
- Gemini 설명 프롬프트도 두 도메인으로 제한하고 category를 받아 저장한다. 유효한 JSON의 빈 text는 실패가 아니라 정상 생략으로 처리하고, 200 실패 원인(finishReason·blockReason)을 내용 없이 기록한다.

### 완료
- [x] 방해·라우트 복구, 엔진 재시도 상한, 관련 진단 로그
- [x] 워치 앱 4파일 + WatchMeetingStatus/WatchBridgeService + watchOS 타깃 등록(Embed Watch Content, 의존성, 서명 설정)
- [x] 사전 감지, Jev category 게이트, Gemini 도메인 필터·category·빈 설명 정상 처리
- [x] 회귀 테스트 추가(사전 3건, 워치 페이로드 2건, Jev category 1건, Gemini category/diagnostic 2건) 및 CI 테스트 목록 갱신

### 남음
- [ ] CodeMagic에서 워치 번들(io.github.temistry.turbometa.watchkitapp) 프로비저닝 자동 생성 확인 — 실패 시 대안 작업
- [ ] 실기기: 홈 나가기·화면 끄기 상태 실시간 귓속말, 통화 후 복구, 안경 연결 해제 시 폰 마이크 전환, 워치 실시간 갱신

### 검증
- 로컬 정적 감사: fatal 0, warning 0, informational 1(기존). git diff --check 통과.

### 보안 메모
- 워치 페이로드는 상태·자막 일부만 담고 회의 전문은 폰에만 보관한다. 키·서버 값은 기록하지 않는다.

## 2026-09-23 · 귓속말 복원력과 회의 서랍

### 결정
- Jev 신뢰도 임계값을 0.85→0.6으로 낮춘다. 실측에서 explain=true 신뢰도 0.8이 임계값에 막혀 귓속말이 생략됐다.
- Gemini 설명 요청 타임아웃을 30→12초로 줄인다. 실패 시 최신 안정 문장으로 1회 재시도한다. 429는 재시도 없이 즉시 실패한다.
- 429 발생 시 설명 생성은 120초, 근거 검색은 300초를 쉬어 귓속말 예산을 확보한다. 로그에 생략 사유를 남긴다.
- 중지 등으로 폐기되는 귓속말 요청도 폐기 로그를 남긴다.
- 회의 세션마다 마이크 원본(audio.caf)과 전사 JSON을 앱 전용 문서 폴더에 보관한다. 파일 보호(.complete)를 적용한다.
- 전사 줄을 터치하면 보관된 설명·근거 링크를 말풍선으로 보여주고 저음량으로 읽어 준다. 보관된 설명이 없으면 사용자 직접 요청으로 생성한다(Jev 게이트 제외, 사진 설명과 동일 원칙).

### 완료
- [x] 임계값·타임아웃·재시도·쿼터 일시정지와 생략/폐기 진단 로그
- [x] MeetingArchiveService: 세션 저장/목록/삭제/텍스트 내보내기, MeetingArchiveViews: 서랍 목록·상세·ShareLink 내보내기
- [x] 전사 서비스에 마이크 원본 녹음(스레드 안전 파일 박스), 세션 종료 시 자동 저장
- [x] 캡션 줄 터치 → 말풍선(설명/근거 링크) + TTS 읽기, 말풍선 닫기
- [x] 서랍·말풍선 한국어/영어 문자열, 회귀 테스트 6건(저장·조회·삭제·내보내기 포맷)

### 남음
- [ ] 실기기: audio.caf 재생·내보내기 확인, 429 이후 120/300초 동작 확인
- [ ] CodeMagic 컴파일·회귀 테스트·TestFlight 배포 확인

### 검증
- 로컬 정적 감사: fatal 0, warning 0, informational 1(기존). git diff --check 통과.

### 보안 메모
- 녹취 파일과 전사는 기기에만 저장하고 외부 반출은 사용자 공유 동작으로만 발생한다. 새 로그에는 대화 원문을 남기지 않는다.

## 2026-09-22 · 실시간 캡션과 AI 작업 분리

### 결정
- 부분 전사는 즉시 같은 줄을 수정하고, 확정 결과만 줄을 마무리한다. 40자·문장부호 대기를 UI 경로에서 제거한다.
- Jev는 1초 안정된 결과 또는 연속 발화 4초 스냅샷을 별도 유한 큐에서 처리한다. 동일 스냅샷과 대기 중 구버전은 중복 전송하지 않는다.
- 귓속말은 playAndRecord를 유지하며 청취를 멈추지 않는다. iOS voice processing 활성화를 시도하되 실패를 기록한다. HSTN에서 반향 제거 효과는 실기기 검증 필요.
- 30초 전역 쿨다운 대신 재생 완료된 용어를 회의 세션 내 중복 억제한다. 설명 프롬프트에도 기존 용어를 전달한다.
- 근거 검색은 별도 직렬 큐, 시각 분석은 장면 변화 감지와 120초 갱신을 사용하고 직접 촬영 중 신규 분석을 보류한다.

### 완료
- [x] 즉시 부분 캡션, 안정 스냅샷 큐, 용어 중복 방지, 검색 큐
- [x] 음성 입력 유지 TTS, 일시적 온디바이스 인식 후 서버 재시도, 인식 오류 재시도 간격·상한
- [x] 마이크·출력 경로, 인식 오류, Jev 판단·생략 이유, Gemini HTTP 상태·시간, TTS 상태 직접 기록. stdout 버퍼링 해제
- [x] Jev 누락 신뢰도를 0으로 숨기지 않고 invalidResponse로 중지
- [x] 회의 화면 진입 시 레거시 QuickVision 초기화·OpenClaw 자동 연결·Galvis 준비 제거. 레거시 구현 코드는 보존
- [x] 짧은 발화·연속 발화·수정/중복 스냅샷·장면 변화·Jev 신뢰도 회귀 테스트 추가

### 남음
- [ ] HSTN에서 재생 중 청취·음성 반향·연속 재생·연결 변경 확인
- [ ] Xcode 회귀 테스트 실행 및 CodeMagic 컴파일·배포 확인

### 검증
- Windows 환경에서는 Xcode 실행 불가. 로컬 정적 감사 후 원격 빌드로 컴파일 확인한다.

### 보안 메모
- 신규 진단 기록에는 회의 원문·용어·키·사진을 포함하지 않는다. 기존 Keychain과 CodeMagic 배포 유지.

새 작업은 아래 형식을 복사해 추가한다.

```markdown
## YYYY-MM-DD · 작업 제목

### 결정
- ...

### 완료
- [x] ...

### 남음
- [ ] ...

### 검증
- ...

### 보안 메모
- ...
```

## 2026-09-23 · 워치 세션 델리게이트 watchOS SDK 모순 해소

### 결정
- 재진단: xcodebuild가 TurboMetaWatch 타깃을 같은 빌드에서 iOS SDK 라운드와 watchOS SDK 라운드로 각각 컴파일한다(7e6538c 로그에서 두 라운드 모두 확인).
- iOS 라운드에서는 두 델리게이트 메서드가 필수+사용 가능(생략·이름변경 시 non-conformance가 iOS 라운드에서 발생), watchOS 라운드에서는 unavailable(구현 시 cannot override). 기존 catch-22 판단은 실패 라운드를 혼동한 오진.
- 해법: sessionDidBecomeInactive/sessionDidDeactivate를 #if os(iOS)로 감싸 iOS 컴파일에만 제공하고 watchOS 컴파일에서는 생략한다.

### 완료
- [x] PhoneLink 델리게이트 플랫폼 조건부 구현(#if os(iOS))
- [x] 로컬 정적 감사 통과(fatal 0 / warning 0)
- [x] 컴파일 통과 확인(CodeMagic iOS 컴파일 점검 success)
- [x] WKCompanionAppBundleIdentifier를 구성별 빌드 설정으로 분리(Debug com.glassai.app1 / Release io.github.temistry.turbometa). 시뮬레이터 설치 검증 오류 수정

### 남음
- [ ] CI(iPhone 시뮬레이터 빌드 2건 + CodeMagic 컴파일·TestFlight) 결과 확인

## 2026-09-23 · 사전 감지 조사 결합 버그 + 워치 TestFlight 서명

### 결정
- 회귀 테스트가 사전 감지 버그를 잡았다. 한글도 alphanumerics라서 "EBITDA가"가 한 토큰이 되어 사전 매칭이 실패했다. 실제 한국어 전사에서는 조사가 거의 항상 붙으므로 실사용 감지율이 크게 낮았을 것이다. ASCII 영문·숫자 연속 구간만 토큰으로 떼도록 수정하고 kubernetes를 사전에 추가했다.
- CodeMagic TestFlight 실패 원인: 워치 번들(io.github.temistry.turbometa.watchkitapp)용 App Store 프로필 부재("TurboMetaWatch requires a provisioning profile").
- 해법: ios-testflight/ios-feature-build에 워치 서명 단계를 추가해 App Store Connect 연동으로 워치 App ID를 확보하고 "TurboMeta Watch App Store" 프로필을 재사용하거나 없을 때만 생성한다. 인증서 개인키는 필요 없다(배포 인증서 ID 목록만 사용).
- TestFlight 업로드 검증 대비로 워치 AppIcon(1024 단일 크기, 본 앱 아이콘 재사용, 알파 없음)과 Resources 빌드 단계를 추가했다.

### 완료
- [x] lexiconHit 토큰화 수정 + 조사 결합 회귀 테스트
- [x] 워치 서명 프로필 확보 단계(codemagic.yaml)
- [x] 워치 AppIcon 자산 카탈로그 등록

### 남음
- [ ] CodeMagic에서 App Store Connect 연동 변수가 노출되는지 확인(없으면 turbometa_secrets에 추가 필요)
- [ ] TestFlight 업로드·처리 결과 확인, 실기기 워치 동기화 확인

### 검증
- 로컬: YAML 파싱, 워치 단계 bash -n 문법 검사, 정적 감사.

### 보안 메모
- App Store Connect 키는 CodeMagic 연동에서만 주입되며 레포·로그에 남기지 않는다.

## 2026-09-23 · 워치 빌드 반복 실패 근본 원인

### 결정
- 근본 원인: .github/workflows/ios-validate.yml의 시뮬레이터 빌드 명령에 있던 `-sdk iphonesimulator`. 이 옵션은 스킴의 모든 타깃에 SDK를 강제하므로 워치 타깃이 아이폰 시뮬레이터 SDK로 컴파일됐다(로그상 워치 산출물 30건 전부 Debug-iphonesimulator).
- 같은 원인에서 나온 증상: WCSessionDelegate 두 메서드 필수/unavailable 모순(9d33007~1262a13), 워치 AppIcon "applicable content 없음"(7910de6). 회귀 테스트 단계는 `-sdk` 없이 destination만 써서 워치를 정상 watchOS SDK로 빌드했기 때문에 두 라운드의 에러가 서로 반대로 보였다.
- 조치: 빌드 명령에서 `-sdk iphonesimulator` 제거(destination만으로 Xcode가 워치 타깃에 watchsimulator 선택). 증상 대응으로 넣었던 PhoneLink의 `#if os(iOS)` 우회는 제거하고 watchOS 정석 구현으로 복귀.
- CodeMagic 두 워크플로는 원래 `-sdk`를 쓰지 않아 영향 없음(컴파일 점검 success로 확인).

### 교훈
- 에러를 고치기 전에 실패한 컴파일 명령의 `-target`/SDK와 산출물 경로를 먼저 확인한다. 같은 파일에서 서로 반대되는 에러가 나오면 코드보다 빌드 설정을 의심한다.

### 완료
- [x] 근본 원인 확정 및 워크플로 수정
- [x] 워치 서명 단계 첫 실행 성공(App ID XDD9QM27GU, 프로필 WDT3V8WQ9V)

### 남음
- [ ] GitHub 검증(빌드+회귀 테스트) 통과 확인
- [ ] TestFlight 업로드 결과 확인

## 2026-09-23 · 귓속말 생성 실패 근본 원인(빌드 75 실기기 로그)

### 결정
- 귓속말 실패는 매번 `MeetingGemini malformed finish=MAX_TOKENS` 뒤 code=2(invalidResponse)였다. gemini-3.6-flash는 답 전에 생각 토큰을 쓰고 이것도 maxOutputTokens(256)에서 차감되어 JSON이 잘렸다. 이전 빌드의 "귓속말 생성 실패"도 같은 원인으로 본다(당시엔 finish 로그가 없었다).
- 같은 원인으로 응답이 느려져 백그라운드 전환 직후 12초 타임아웃(-1001)도 발생했다.
- 장면 맥락(카메라 프레임) 요청은 두 세션 모두 응답을 받지 못했다(55초 대기 후 취소, 30초 이상 무응답). 사진+기본 생각 수준 조합으로 추정.
- 조치: 회의 Gemini 요청 3종과 QuickVisionService에 thinkingConfig(thinkingLevel=low) 추가, 출력 한도 상향(귓속말·사진 1024, 근거 조사 2048, 장면 1024). 모델이 thinkingConfig를 400으로 거부하면 설정을 빼고 1회 재시도하고, 이후 요청에서도 뺀다(GeminiThinkingSupport).
- 워치 WCError 7006 = 워치에 앱 미설치. 전송 전에 isPaired/isWatchAppInstalled를 확인하고, 미설치 시 최신 상태를 보관했다가 sessionWatchStateDidChange에서 보낸다. 경고 반복 대신 상태 변화 시 1회만 기록.
- 참고: 회의 중 안경 연결 후 입력 16kHz인데 엔진 탭은 48kHz로 보고됨. 음성 처리 단계가 변환하며 전사는 정상이라 이번 범위에서 제외.

### 완료
- [x] 생각 수준·출력 한도 조정 + 400 폴백
- [x] 워치 미설치 시 전송 보류 + 설치 즉시 전송
- [x] 요청 설정 회귀 테스트 3건(MeetingPhotoRequestTests)

### 남음
- [ ] 실기기에서 귓속말 재생 확인(로그에 malformed/MAX_TOKENS가 사라지는지)
- [ ] 아이폰 Watch 앱에서 TurboMeta 워치 앱 설치 후 실시간 표시 확인

### 보안 메모
- 로그에는 finish/block 코드와 상태 문자열만 남기며 응답 원문·키는 기록하지 않는다.

## 2026-09-23 · E-JEV-401(워치 표시) 원인: 잠금 중 키체인 읽기 차단

### 결정
- E-JEV-401은 서버 401이 아니라 JevClientError.missingAPIKey(키체인에서 키를 못 읽음)였다. 서버 오류는 모두 E-JEV-503으로 묶여 있었다.
- API 키가 kSecAttrAccessibleWhenUnlockedThisDeviceOnly로 저장되어 있어 백그라운드 통역 중 아이폰이 잠기면 SecItemCopyMatching이 errSecInteractionNotAllowed를 반환했고, 이 상태는 로그에서도 숨겨져 '키 없음'으로 처리되어 fail-stop했다. 워치로 보고 있었다는 정황(폰 잠김)과 일치. Gemini 키도 같은 위험.
- 1차 시도(접근 정책을 AfterFirstUnlock으로 완화, 674aa36)는 보안 감사의 필수 규칙(WhenUnlockedThisDeviceOnly)에 걸려 되돌렸다.
- 최종 조치: 키체인 정책은 WhenUnlockedThisDeviceOnly 유지. 회의 시작 시(항상 잠금 해제 상태) Jev·Gemini 키를 읽어 실행 중 메모리에 캐시하고, 이후 잠금 중에는 캐시를 사용한다. 읽기 결과를 found/notFound/locked로 구분. 오류 코드 분리: 401 키 없음, 423 잠금으로 읽기 실패, 403 서버가 키 거부, 503 연결·기타 서버 오류.
- 한계: 앱이 잠금 상태에서 종료 후 재실행되는 경우에는 캐시가 없어 E-JEV-423이 뜬다(잠금 해제 후 다시 시작하면 됨).
- RTMP·OpenClaw 레거시 키 항목은 회의 기능과 무관해 변경하지 않았다.

### 남음
- [ ] 화면을 잠근 채 회의 지속 확인(워치에 E-JEV 코드가 뜨지 않아야 함)

## 2026-09-23 · 빌드 79 로그: Gemini 429 + 회의 서랍 잠금 저장 실패

### 결정
- 빌드 79 세션의 귓속말 실패는 Gemini 429 RESOURCE_EXHAUSTED(Google API 키 할당량 소진). Jev(200)·워치(state=ready)·전사는 정상. 코드 결함이 아니라 계정 한도 문제.
- 로그에 한도 종류가 없어 분당/일일 구분 불가 → 429 응답의 quotaId·quotaValue·retryDelay만 기록하도록 추가(MeetingGemini, QuickVisionAPI). 메시지 원문은 기록하지 않음.
- 할당량 소비 구조: 회의 중 장면 분석이 20초마다 카메라 프레임을 보내(시간당 최대 180회) 귓속말보다 많이 소비한다. 간격 조정은 사용자 결정 사항으로 남김.
- 직전 세션(업데이트 전 빌드)의 E-JEV-401·Gemini code=1(missingAPIKey)은 잠금 중 키체인 읽기 문제로 dca03da에서 해결됨.
- 회의 서랍 save failed code=513: 폴더·전사 파일을 FileProtectionType.complete로 저장해 잠금 중 쓰기가 막혔다. 녹음 파일도 폴더 등급을 따라 잠금 후 끊겼을 가능성이 크다. 프로젝트 기준(ConversationStorage·QuickVisionStorage와 동일)인 completeUntilFirstUserAuthentication으로 변경하고 감사 필수 규칙에 MeetingArchiveService를 추가.
- MetricKit 크래시 기록은 빌드 48의 과거 기록이라 무관.

### 남음
- [ ] 할당량 해소 방법 결정(유료 결제 연결 또는 장면 분석 간격 조정)
- [ ] 새 빌드에서 화면 잠금 상태로 회의 종료 후 서랍에 전사·녹음이 남는지 확인

## 2026-09-23 · 화면 인식 3단계 설정 + 장면 비용 절감 + 사용량 기록

### 결정
- 사용자가 Gemini 결제(8,000원) 연결. gemini-3.6-flash 유료 단가(2026-12-31까지): 입력 0.75, 출력 3.75 USD/100만 토큰, 이미지 기본 1,120토큰. 2027-01-01부터 두 배.
- 설정의 시각 보조 토글을 "화면 인식: 기본(20초)/절약(60초)/끄기"로 교체. 저장 키 meeting.sceneMode, 저장값이 없으면 이전 토글(meeting.visualAssist)을 이어받음(false→끄기). 끄기면 안경 카메라 스트림도 켜지 않음(촬영 버튼은 임시 스트림 사용).
- 기존에는 VM init에서 한 번만 설정을 읽어 앱 재실행 전까지 변경이 반영되지 않았다 → 회의 시작마다 구성. 이전 회의의 장면 용어·요약도 초기화.
- 자동 장면 사진(512px)에 Gemini 3 사진별 mediaResolution MEDIUM(560토큰) 적용. 사용자 촬영 사진은 기본 해상도 유지. 400이면 해상도→생각 설정 순으로 빼고 재시도하며, 성공한 조합으로 거부 옵션을 기억.
- 같은 화면 판정: 16×16 흑백 썸네일, 1칸 이동 9가지 중 최소 차이, 겹치는 칸 기준 평균 밝기 보정. 화면 전체 평균으로 보정하면 가장자리 명암이 드나들 때 1칸 이동만으로 약 10점(기준 12에 근접)이 나와 겹침 기준으로 변경. 파이썬 재현: 잡음 1.7, 밝기 +15 0, 1칸 이동 0, 내용 반전 149.
- 판정마다 MeetingScene diff 점수 기록(기준값 재조정용). Gemini 응답 usageMetadata로 요청별 토큰 기록, 회의 종료 시 MeetingCost 한 줄 요약(요청 수·토큰·예상 요금·종류별 건수). 검색 그라운딩 요금은 제외(월 5,000건 무료).

### 완료
- [x] MeetingSceneMode + 설정 Picker + 번역 문자열(ko/en)
- [x] 회의 시작마다 장면 분석 구성
- [x] 장면 사진 중간 해상도 + 2단계 폴백
- [x] 판정 알고리즘 개선 + 점수 로그
- [x] 토큰 사용량 기록과 회의별 요약
- [x] 테스트: 판정 5건, 설정 이전·간격 3건, 사용량·요금 3건, 요청 형식 1건

### 남음
- [ ] 기본 단계로 20~30분 회의 후 진단 로그로 실제 1시간 비용과 diff 분포 확인, 기준값 조정
- [ ] 글자만 바뀌는 슬라이드 누락이 확인되면 Vision 특징 비교 검토

## 2026-09-23 · 애플워치 촬영 버튼

### 결정
- 안경 물리 촬영 버튼은 앱에 전달되지 않는다. DAT SDK 0.5.0 공개 인터페이스(MWDATCamera/MWDATCore swiftinterface)에 버튼·터치·제스처 이벤트 API가 없고, photoDataPublisher는 앱이 요청한 capturePhoto 결과만 전달한다.
- 대안으로 애플워치 촬영 버튼을 추가. 워치 → sendMessage(action=capturePhoto) → 폰 WatchBridgeService → VM이 앱 촬영 버튼과 같은 describeCurrentScene() 실행. 응답: accepted/busy/unavailable.
- 워치 UI: 화면 하단 고정(safeAreaInset) 큰 버튼, 누를 때 click 진동, 결과에 success/failure 진동, 3초간 결과 문구. 사진 설명 상태(scene: working/failed)를 applicationContext로 실시간 반영.
- 위험: 앱 스트림 코덱이 VideoCodec.raw라 SDK 문서상 앱이 백그라운드면 스트리밍이 멈춘다. 폰이 잠긴 상태에서 워치 촬영이 실패할 수 있다. hvc1(백그라운드 지속)은 모든 프레임 소비자(makeUIImage 단일 경로)에 영향을 주고 hvc1에서 변환 동작이 문서로 확인되지 않아 이번에는 보류. 요청 시 앱 상태·스트림 상태, 실패 시 오류 코드를 기록해 실기기로 판단한다.

### 완료
- [x] 공유 계약 WatchCapture + scene 페이로드
- [x] 폰 메시지 수신(replyHandler) + VM 연결 + 상태 동기화 + 진단 로그
- [x] 워치 버튼 UI·진동·결과 표시
- [x] 테스트: 페이로드 scene 2건, 메시지 계약 1건

### 남음
- [ ] 실기기: 폰 화면 켠 상태 / 잠근 상태 각각 워치 촬영 시도 후 로그(MeetingWatch capture request, MeetingPhoto failed) 확인
- [ ] 잠금 상태 실패 시 hvc1 코덱 전환 검토

## 2026-09-24 · 회의 마이크 선택(폰 기본) + 입력 품질 기록

### 결정
- 증상: 안경 착용 시 상대 말이 전사되지 않음. 원인 추정: 안경·에어팟 HFP 마이크는 착용자 입 방향 빔포밍·근거리 잡음 억제로 상대 목소리를 깎고, 앱의 voiceChat 모드 + voice processing이 한 번 더 억제하며, HFP는 16kHz.
- 사용자 요청은 "모든 마이크 동시 사용 후 최고 음원 선택"이었으나 iOS는 앱당 입력 라우트가 하나라 불가(안경·에어팟은 모두 HFP로 서로 배타). 워치 마이크 병행은 워치 앱 상시 전면·지연·배터리 문제로 보류. 사용자 동의 후 마이크 선택 방식으로 변경.
- 설정 "마이크: 폰(기본) / 안경·이어폰". 제안 시의 "자동"은 폰과 동작이 같아 두 단계로 줄였다. 회의 중 자동 전환은 전환마다 약 1초 녹음이 끊겨 넣지 않음.
- 폰 모드: playAndRecord + mode .default + [.allowBluetoothA2DP, .defaultToSpeaker](HFP 제외) → 입력은 내장 마이크, 귓속말은 연결된 블루투스(A2DP)로. 내장 마이크는 무지향 패턴 아래쪽 데이터 소스 우선. 귓속말이 폰 스피커·수화기로 나올 때만 voice processing(에코 제거) 켬.
- 안경·이어폰 모드: 기존 동작(voiceChat + HFP 입력 우선 + voice processing).
- 품질 기록: 10초마다 MeetingMic(평균·최대 dBFS, 말소리 버퍼 비율, 그 구간 전사 글자 수), 최종 결과 인식 신뢰도. 30초 연속 최대 음량 -50dBFS 미만이면 워치에 "소리 작음 · 폰을 상대 쪽으로".

### 완료
- [x] MeetingMicMode + 설정 Picker + 문구(ko/en)
- [x] 모드별 오디오 세션, 무지향 데이터 소스, 조건부 voice processing
- [x] MeetingInputMeter + 품질 로그 + 워치 micQuiet
- [x] 테스트: 모드 기본값, 에코 판단, dBFS 계산, 소리 작음 판정, 워치 페이로드

### 남음
- [ ] 실기기: 폰 모드에서 귓속말이 안경으로 나오는지(A2DP) 확인
- [ ] 같은 회의를 폰/안경 모드로 각각 녹음해 MeetingMic 로그로 비교
- [ ] 폰 모드에서 안경 스피커 귓속말이 폰 마이크로 되들어가 전사되는지 확인

## 2026-09-25 · 방향 전환 1단계: 대화 허점 잡기 + 화자 구분 + 오른쪽 귓속말

### 결정
- 앱 방향: 상대 양해 후 대화 시작 버튼 → 상대 발언의 근거 없는 단정·논리 비약·앞뒤 모순·사실 주장 + 전문용어를 잡아 귓속말/워치/알림.
- 두 흐름: 빠른 길(기존 실시간 인식 → Jev → 전문용어 귓속말), 느린 길(30초 조각 → Gemini 3.5 Transcribe 화자 구분 → 상대 발언 → Jev evaluateCatch → Gemini critique).
- Transcribe(문서 확인): Interactions API POST /v1beta/interactions, 오디오 인라인 base64(audio/wav), transcription_config.mode = verbatim + diarization_mode speaker + timestamp_granularities word. 이름표 spk_N은 요청마다 새로 붙음. custom_vocabulary와 화자 구분 동시 사용 불가.
- 내 목소리 등록: 설정에서 문장 1개 5.5초 녹음(말소리 2.5초 이상), 16kHz PCM으로 앱 지원 폴더에 저장. 매 조각 앞에 견본+0.6초 무음을 붙여 보내고 견본 구간 단어의 최다 이름표를 "나"로 판정. 미등록 시 화자 미확인으로 전체 분석.
- 사실 확인: 화자 구분이 90초 내 성공 중이면 느린 길(상대 발언)만 사용, 아니면 기존 실시간 경로 유지.
- 알림: 잡을 때마다 iPhone 로컬 알림(폰 잠금 시 워치로 전달). 앱 사용 중에는 배너 없음(기존 알림 델리게이트가 다른 카테고리 억제). 귓속말은 확신도 0.7 이상만, "종류. 되물을 질문" 형식.
- 워치: 전사문 제거, 잡은 항목 카드(최신 5개)만 표시, 새 항목 도착 시 진동.
- 오른쪽 귓속말: 설정 "귓속말 방향: 오른쪽(기본)/왼쪽/양쪽". 스테레오 출력(A2DP·헤드폰)이고 녹음 유지 재생일 때 AVSpeechSynthesizer.write → AVAudioPlayerNode pan. 통화(HFP) 출력은 모노라 양쪽. 마지막 빈 버퍼 미수신 대비로 합성 완료 델리게이트 + 20초 강제 종료.
- 비용 추정: 화자 구분 약 $0.35/h(견본 포함), 분석 $0.2~0.3/h. MeetingCost 요약에 audio 초와 요금 포함.

### 완료
- [x] SpeakerDiarizationService(조각 버퍼·WAV·Transcribe 호출·응답 해석·나/상대 판정)
- [x] ConversationCatchService(모델·결과 해석·알림), Jev evaluateCatch, Gemini critique
- [x] VM 느린 흐름·전달·워치 페이로드, 워치 카드 UI, 앱 목록 시트에 허점 카드
- [x] VoiceEnrollmentView + 설정(내 목소리, 귓속말 방향), 문구 ko/en
- [x] ConversationCatchTests 13건, CI 목록 추가

### 남음
- [ ] 실기기: 목소리 등록 → 2인 대화에서 MeetingDiarize turns/me/other 로그 확인
- [ ] 한쪽 귀 재생 실기기 확인(에어팟·안경), 빈 버퍼 수신 여부
- [ ] 2단계 앱 화면 재설계

### 검증
- 원격 빌드로만 컴파일 가능. 실패 시 GitHub job 로그의 error 필터로 재진단.

### 보안 메모
- 코드·로그·워크로그에 키·회의 원문 미포함. Keychain 및 CodeMagic 시크릿 구성 변경 없음.
