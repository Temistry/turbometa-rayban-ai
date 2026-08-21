# TurboMeta 미니 작업로그

이 문서는 기능 변경의 이유, 범위, 검증 결과를 짧게 누적하는 개발 로그다. 실제 인증값, 토큰, 사용자 질문·답변 원문은 기록하지 않는다.

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

## 기록 형식

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
