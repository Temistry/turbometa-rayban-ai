# TurboMeta

Ray-Ban Meta 스마트 안경의 카메라와 마이크를 AI 서비스에 연결하는 iOS 개발 프로젝트입니다.

이 브랜치는 다음 목표에 맞춰 정리되어 있습니다.

- 앱 화면, 오류 안내, Siri 문구, AI 응답과 음성 출력을 한국어로 통일
- iPhone 13 실기기에서 Xcode 없이도 원인을 추적할 수 있는 기기 내 개발자 로그 제공
- Quick Vision, Live AI, 실시간 번역, OpenClaw, RTMP 송출 기능 통합
- API Key와 스트림 키의 기기 전용 Keychain 저장
- 네트워크 연결과 진단 로그에서 자격 증명 노출 최소화

> 이 저장소는 소스 코드 중심의 개발 프로젝트입니다. 공개 배포용 IPA를 제공하지 않으며, 실제 기기 설치에는 Apple 개발자 서명 또는 TestFlight 환경이 필요합니다.

## 현재 상태

| 항목 | 상태 |
|---|---|
| 최소 iOS 버전 | iOS 17.0 |
| 공유 Xcode Scheme | `TurboMeta` |
| 기본 화면 언어 | 한국어 |
| 기본 AI 출력 언어 | 한국어 |
| 기본 시스템 TTS | `ko-KR` |
| GitHub Actions | 정적 점검 및 iOS 시뮬레이터 빌드 |
| Codemagic | 서명 없는 Release 컴파일, 내부 IPA, TestFlight 워크플로 |
| 실기기 검증 | iPhone과 Ray-Ban Meta가 필요한 별도 검증 단계 |

## 주요 기능

### Quick Vision

안경 시점의 사진을 촬영해 **Google Gemini**로 분석하고 결과를 iOS 시스템 TTS `ko-KR` 음성으로 읽습니다. 별도의 Cloud TTS Key는 필요하지 않습니다.

지원 모드:

- 일반 장면 설명
- 음식과 음료의 건강 정보 분석
- 주변 환경과 장애물 설명
- 글자 읽기
- 한국어 번역
- 사물과 장소 정보 설명

처리 흐름은 다음과 같습니다.

```text
안경 스트림 시작
→ 사진 촬영
→ 스트림 중지
→ 비전 API 분석
→ 한국어 결과 표시
→ 한국어 TTS 재생
```

### Gemini Live AI

안경 카메라와 마이크를 이용한 실시간 멀티모달 대화 기능입니다. 일반 사용자 실행 경로는 **Google Gemini Live**로 고정되며, 설정 화면에서는 Google Gemini API Key 하나만 입력합니다. 기존 공급자 호환 코드는 이전 설치 데이터와 개발자 호환을 위해 내부에 남아 있을 수 있지만 일반 UI에는 노출하지 않습니다.

대화 기록은 한국어 환경 기준으로 저장되며, 음성 인식 결과와 대화 본문은 개발자 로그에 직접 출력하지 않습니다.

### 실시간 번역

Gemini Live 세션을 통역 전용으로 구성해 음성을 실시간으로 인식하고 선택한 대상 언어로 번역합니다. 기본 대상 언어는 한국어입니다.

- iPhone 마이크 또는 Bluetooth 입력 선택
- 번역 텍스트와 선택적 음성 출력
- 선택적 안경 영상 프레임 보조 입력
- Google Gemini API Key 하나 사용
- 번역 기록 최대 50개 유지

### 개인 지식 로그

Quick Vision, Gemini Live AI, 실시간 번역의 질문과 답변을 기기 로컬 보호 저장소에 기록합니다.

- 사람이 읽는 Markdown과 기계 처리를 위한 JSONL을 함께 저장
- API Key, Bearer Token, JWT, 긴 credential 문자열, Base64 payload를 저장 전에 마스킹
- 이미지 원본, 오디오 원본, 위치 정보, 인증 정보는 저장하지 않음
- 사용자 질문·답변 원문을 진단 콘솔에 출력하지 않음

### Files 기반 Google Drive 폴더 동기화

Google Drive API Key, OAuth client secret, refresh token, 별도 OAuth 인증 체계는 추가하지 않습니다. 사용자가 iOS Files 문서 선택기에서 Google Drive 폴더(또는 지원되는 다른 Files 제공자 폴더)를 선택하면 보안 범위 bookmark로 권한을 보관하고 아래 경로에 지식 로그를 동기화합니다.

```text
<선택한 폴더>/TurboMetaKnowledge/
```

북마크가 오래되었거나 Files 제공자가 권한을 회수하면 사용자가 폴더를 다시 선택해야 합니다.

### OpenClaw

Ray-Ban Meta를 OpenClaw Gateway의 카메라 노드로 연결합니다.

허용된 원격 명령은 다음 항목으로 제한됩니다.

- `camera.snap`
- `camera.list`
- `device.status`
- `device.info`

Gateway 토큰은 현재 기기 전용 Keychain에 저장됩니다. 토큰은 WebSocket URL에 붙이지 않고 서명된 연결 요청의 인증 데이터로 전달합니다.

### RTMP 송출

안경 영상을 RTMP 또는 RTMPS 서버로 보낼 수 있습니다.

- YouTube Live
- Twitch
- TikTok
- Facebook Live
- Bilibili
- Douyin
- 사용자 지정 RTMP 서버

스트림 키는 현재 기기 전용 Keychain에 저장됩니다. 가능한 경우 `rtmps://` 주소를 권장합니다. `rtmp://`는 전송 내용이 암호화되지 않습니다.

### 음식 영양 분석

촬영한 음식 사진을 바탕으로 다음 항목을 한국어 JSON으로 분석합니다.

- 음식 이름과 예상 분량
- 칼로리
- 단백질, 지방, 탄수화물
- 식이섬유와 당류
- 건강 점수와 영양 조언

분석 수치는 사진을 바탕으로 한 AI 추정치이며 의료 또는 영양 진단이 아닙니다.

## 기기 내 개발자 로그

`DEBUG` 또는 `INTERNAL_BUILD` 조건으로 빌드하면 화면 오른쪽 아래에 터미널 버튼이 표시됩니다.

개발자 로그 화면에서 다음 기능을 사용할 수 있습니다.

- 표준 출력과 표준 오류 실시간 확인
- 전체, 오류, 경고 필터
- 검색과 자동 스크롤
- 로그 복사와 공유
- 로그 전체 삭제
- 읽지 않은 오류 개수 표시

로그 정책:

- 최대 2,000줄을 메모리에만 보관
- 앱을 종료하면 로그 소멸
- Bearer 토큰, API Key, Gateway 토큰, URL 쿼리 자격 증명 자동 마스킹
- 이미지와 오디오의 긴 Base64 payload 생략
- 원본 출력은 Xcode 콘솔에도 계속 전달

로그 공유 전에는 사용자 대화, 서버 오류 문구, 호스트 이름 등 주변 정보가 포함되지 않았는지 직접 확인해야 합니다. 비밀 문자열을 가렸다고 해서 로그 전체가 자동으로 무해해지는 기적은 아직 발명되지 않았습니다.

## 한국어 Siri 명령

TurboMeta는 App Intents와 App Shortcuts를 사용합니다. 앱 실행 시 `updateAppShortcutParameters()`를 호출해 현재 한국어 문구를 시스템에 갱신합니다.

대표 호출 예시:

```text
Siri야, TurboMeta 이거 뭐야
Siri야, TurboMeta 주변 설명
Siri야, TurboMeta 이거 읽어줘
Siri야, TurboMeta 이거 번역해줘
Siri야, TurboMeta 건강 분석
Siri야, TurboMeta 실시간 대화
Siri야, TurboMeta 대화 종료
```

App Shortcut은 앱 설치 후 시스템에 노출되며 별도의 사용자 제작 단축어 없이 실행할 수 있습니다. 다만 앱은 iPhone의 Siri 시스템 언어를 강제로 변경할 수 없습니다. 한국어 호출을 사용하려면 iOS의 Siri 언어를 한국어로 설정해야 합니다.

Quick Vision과 Live AI는 안경 카메라와 앱 상태가 필요하므로 명령 실행 시 앱을 엽니다.

## 지원 AI 서비스

일반 사용자 AI 실행 경로는 Google Gemini 중심입니다.

| 기능 | 기본 모델/구성 | 인증 |
|---|---|---|
| Quick Vision · 음식 분석 | `gemini-3.6-flash` | Google Gemini API Key |
| Live AI | `gemini-3.1-flash-live-preview` | 같은 Google Gemini API Key |
| 실시간 번역 | Gemini Live 통역 지시 | 같은 Google Gemini API Key |
| Quick Vision 음성 출력 | iOS 시스템 TTS `ko-KR` | 별도 TTS Key 없음 |

기존 Alibaba/OpenRouter 제공자 타입은 이전 설치 데이터와 개발자 호환을 위해 남아 있을 수 있지만, 일반 설정 화면과 기본 실행 경로에서는 사용하지 않습니다.

## 개발 환경 준비

### 필수 항목

- macOS와 최신 안정 버전 Xcode
- iOS 17 이상이 설치된 iPhone
- Ray-Ban Meta 스마트 안경
- Meta Wearables 개발자 프로젝트
- Google Gemini API Key
- 실제 기기 설치를 위한 Apple 개발자 서명 환경

Windows에서 작업하는 경우 GitHub와 Codemagic을 이용해 원격 macOS 빌드를 수행할 수 있습니다. 다만 Bluetooth, 카메라, 오디오 경로와 Siri 동작은 결국 실제 iPhone에서 확인해야 합니다. 시뮬레이터가 안경을 갑자기 물리적으로 만들어 주지는 않습니다.

### 저장소 받기

```bash
git clone https://github.com/Temistry/turbometa-rayban-ai.git
cd turbometa-rayban-ai
git checkout feature/testflight-signing-config
```

### Meta Wearables 설정

1. Meta Wearables Developer Center에서 프로젝트를 생성합니다.
2. iOS 앱 설정에서 Application ID와 Client Token을 발급합니다.
3. Xcode의 Target Build Settings에 다음 User-Defined Setting을 추가합니다.

```text
META_APP_ID=<발급받은 Application ID>
CLIENT_TOKEN=<발급받은 Client Token>
```

`CameraAccess/Info.plist`는 값을 직접 저장하지 않고 다음 빌드 변수를 참조합니다.

```xml
<key>MetaAppID</key>
<string>$(META_APP_ID)</string>
<key>ClientToken</key>
<string>$(CLIENT_TOKEN)</string>
```

실제 비밀값을 `Info.plist`, 소스 코드, README 또는 커밋 기록에 넣지 마세요.

### Xcode 빌드

1. `CameraAccess.xcodeproj`를 엽니다.
2. Scheme으로 `TurboMeta`를 선택합니다.
3. Signing & Capabilities에서 자신의 Team을 선택합니다.
4. iPhone을 연결하고 Run을 실행합니다.
5. 앱에서 Ray-Ban Meta 연결 권한을 승인합니다.
6. 설정 화면에서 **Google Gemini API Key**를 등록합니다. 일반 사용자는 공급자·서비스 지역·모델을 따로 선택하지 않습니다.

서명 없이 컴파일만 확인할 때는 다음 명령을 사용할 수 있습니다.

```bash
xcodebuild \
  -project CameraAccess.xcodeproj \
  -scheme TurboMeta \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  clean build
```

## Google Gemini API Key 설정

1. [Google AI Studio](https://aistudio.google.com/apikey)에서 Gemini API Key를 발급합니다.
2. 앱의 `내 정보` 탭에서 **Google Gemini API Key**를 선택합니다.
3. Key를 입력하고 저장합니다.

예시가 필요할 때는 실제 형식과 구별되는 placeholder만 사용합니다.

```text
<YOUR_API_KEY>
```

**절대로 API Key를 소스 코드, `Info.plist`, `.env`, JSON, README, 작업 로그, 테스트 출력 또는 커밋에 넣지 마세요.** 실제 값뿐 아니라 접두사·접미사·해시·Base64 원문 등 식별 가능한 형태도 기록하지 않습니다.

저장 정책:

- 사용자 입력 API Key와 연동 토큰은 iOS Keychain 사용
- 접근 등급은 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- iCloud Keychain이나 새 기기로 자동 이전하지 않음
- `UserDefaults`와 일반 파일에 평문 저장하지 않음

Meta Wearables 설정은 Xcode 또는 CI의 빌드 변수로 주입합니다.

```text
META_APP_ID=<YOUR_META_APP_ID>
CLIENT_TOKEN=<YOUR_CLIENT_TOKEN>
```

기기에 저장된 Key는 탈옥, 디버깅 권한 탈취, 악성 프로파일, 메모리 분석까지 막아 주는 절대 방패가 아닙니다. 공개 서비스에서는 서버가 발급하는 짧은 수명의 토큰을 사용하는 구조가 더 안전합니다.

## OpenClaw 연결

앱의 `내 정보 > OpenClaw`에서 다음 값을 설정합니다.

```text
호스트: 192.168.0.10
포트: 18789
Gateway 토큰: <발급받은 토큰>
```

또는 공개 서버에 암호화된 주소를 지정할 수 있습니다.

```text
wss://gateway.example.com
```

보안 규칙:

- `ws://`는 엄격히 확인된 루프백, 사설 IP, `.local` 호스트에서만 허용
- 공인망 호스트는 `wss://` 필수
- 호스트 입력란의 사용자 이름, 비밀번호, 쿼리 문자열, 프래그먼트 거부
- 수신 명령은 코드의 허용 목록으로 제한
- 첨부 이미지는 최대 크기 제한 적용

사설망 `ws://`도 암호화되지 않습니다. 신뢰할 수 없는 Wi-Fi에서는 사용하지 마세요.

## 정적 점검

한국어와 기본 보안 설정을 검사하려면 다음 명령을 실행합니다.

```bash
python3 Scripts/audit_localization_security.py
```

검사 항목:

- 저장소에 포함된 API Key, GitHub 토큰, 개인 키 형태 탐지
- 광범위한 ATS 예외 탐지
- Keychain 기기 전용 접근 정책 확인
- OpenClaw 평문 연결 제한 확인
- 내부 빌드 로그 조건 확인
- 한국어 리소스에 남은 중국어 문자열 탐지
- SwiftUI 화면의 외국어 하드코딩 후보 탐지
- 민감정보 관련 로그 문장 검토 목록 생성

결과는 `audit-report.txt`에 저장됩니다. 이 스크립트는 정적 휴리스틱 검사이며 전문 침투 테스트나 공급망 감사의 대체물이 아닙니다.

## CI와 원격 빌드

### GitHub Actions

`.github/workflows/ios-validate.yml`은 다음 순서로 실행됩니다.

1. 한국어 및 보안 정적 점검
2. Swift Package 의존성 해석
3. `TurboMeta` Scheme의 iOS 시뮬레이터 빌드
4. 빌드 로그와 감사 결과 업로드

### Codemagic

`codemagic.yaml`에는 세 개의 워크플로가 있습니다.

| 워크플로 | 목적 |
|---|---|
| `ios-compile-check` | Apple 서명 없이 Release 컴파일 검사 |
| `ios-feature-build` | 기능 브랜치 내부 IPA 빌드 |
| `ios-testflight` | `main` 브랜치 TestFlight IPA 빌드 |

Codemagic의 `turbometa_secrets` 그룹에 다음 변수를 등록합니다.

```text
META_APP_ID
CLIENT_TOKEN
```

내부 IPA와 TestFlight 빌드는 `INTERNAL_BUILD` 컴파일 조건을 사용하므로 기기 내 개발자 로그 버튼이 포함됩니다. 일반 Release 빌드에는 해당 조건을 넣지 않아야 합니다.

## 보안 설계와 남은 위험

### 적용된 보호

- API Key, OpenClaw 토큰, RTMP 스트림 키의 기기 전용 Keychain 저장
- ATS 전체 허용 미사용
- 공개 OpenClaw Gateway의 `wss://` 강제
- URL 자격 증명과 쿼리 입력 거부
- OpenClaw 원격 명령 허용 목록
- 로그 자격 증명과 Base64 payload 마스킹
- Quick Vision·Live AI·번역 지식 로그를 Markdown + JSONL 텍스트로만 저장
- 이미지·음성 원본·위치·인증정보를 지식 로그에서 제외
- 사용자가 선택한 Files 폴더만 security-scoped bookmark로 동기화
- Google Drive API/OAuth secret·refresh token을 추가하지 않음
- 사용자 발화와 AI 대화 본문을 네트워크 진단 로그에서 제외
- `URLSessionConfiguration.ephemeral` 사용
- 예상된 WebSocket 종료와 실제 연결 장애 구분
- 내부 빌드에서만 기기 내 로그 콘솔 노출

### 남은 위험

- 클라이언트 앱에 장기 API Key를 저장하는 구조 자체는 역공학과 탈취 위험이 남습니다.
- Gemini 원시 WebSocket API는 연결 URL 쿼리에 Key가 필요합니다. 앱 로그에는 출력하지 않지만, 운영 환경에서는 서버 발급 단기 토큰 구조가 더 안전합니다.
- 사설망의 `ws://`와 일부 플랫폼의 `rtmp://`는 평문 전송입니다.
- 사용자가 공유한 진단 로그에는 호스트 이름과 오류 문맥이 포함될 수 있습니다.
- AI 서비스로 전송한 사진, 음성, 번역 내용은 각 제공자의 데이터 처리 정책을 따릅니다.
- 의존 패키지와 공급망은 별도의 정기 감사가 필요합니다.

## 실기기 검증 체크리스트

CI 성공은 컴파일 가능성을 확인할 뿐, 실제 안경과 iPhone의 모든 동작을 증명하지 않습니다. 내부 TestFlight 빌드에서 다음 항목을 확인합니다.

- Ray-Ban Meta 등록과 재연결
- 안경 카메라 영상 수신과 카메라 권한
- 사진 촬영 후 Gemini Quick Vision 분석
- iOS `ko-KR` 시스템 TTS가 iPhone 또는 Bluetooth 출력으로 재생되는지
- Gemini Live AI 마이크 입력과 한국어 응답
- Gemini Live 실시간 번역의 기본 대상 언어가 한국어인지
- Siri 한국어 호출 문구 인식
- Markdown + JSONL 로컬 지식 로그 생성과 credential 마스킹
- Files 문서 선택기, security-scoped bookmark 복원, Google Drive 폴더 동기화
- OpenClaw의 사설망과 WSS 연결
- RTMP 또는 RTMPS 송출
- 연결 해제 시 불필요한 `Socket is not connected` 오류가 나타나지 않는지
- 개발자 로그의 오류 상세와 자격 증명 마스킹
- 장시간 사용 시 발열, 배터리, 메모리 사용량

## 프로젝트 구조

```text
CameraAccess/
├── Intents/                 Siri App Intents와 App Shortcuts
├── Managers/                언어, AI 제공자, 기능 모드 관리
├── Models/                  대화, 번역, 영양 분석 데이터 모델
├── Services/                Gemini, 지식 로그, Live AI, 번역, RTMP, OpenClaw
├── Utils/                   Keychain과 권한 유틸리티
├── ViewModels/              화면 상태와 서비스 연결
├── Views/                   SwiftUI 화면, 통합 설정, 개발자 로그 콘솔
├── Info.plist               권한 문구와 Meta DAT 설정
└── TurboMetaApp.swift       앱 진입점과 한국어 Shortcut 갱신

Scripts/
└── audit_localization_security.py

.github/workflows/
└── ios-validate.yml

codemagic.yaml
```

## 기여 방법

1. `main`에서 기능 브랜치를 만듭니다.
2. 사용자 화면 문구는 한국어 리소스 또는 한국어 문자열로 작성합니다.
3. API Key, 토큰, 음성 원문, 이미지 Base64를 로그에 남기지 않습니다.
4. 정적 점검과 시뮬레이터 빌드를 통과시킵니다.
5. 실제 기기에서 변경 기능과 오디오 경로를 확인합니다.
6. Pull Request에 검증 기기, iOS 버전, 안경 펌웨어, 재현 절차를 기록합니다.

## 라이선스

이 프로젝트는 `LICENSE`에 명시된 MIT License를 따릅니다.

Meta, Ray-Ban, Apple, Alibaba Cloud, Google, OpenRouter, OpenClaw와 기타 제품명은 각 소유자의 상표입니다. 이 프로젝트는 해당 회사들의 공식 제품이 아닙니다.
