# Google Gemini 단일화 및 지식 로그 구현 계획

## 목표

TurboMeta의 일반 사용자 설정을 Google Gemini API Key 하나로 단순화하고, 퀵비전·Live AI·실시간 번역의 질문과 답변을 로컬 우선 방식으로 저장한 뒤 사용자가 지정한 Google Drive 폴더에 Markdown과 JSONL로 동기화한다.

## 성공 기준

1. 일반 사용자 설정에는 Google Gemini API Key 입력란 하나만 보인다.
2. 퀵비전은 Google Gemini 이미지 이해 API를 사용한다.
3. Live AI는 Google Gemini Live API만 사용한다.
4. 실시간 번역은 Gemini Live 기반 통역 세션을 사용한다.
5. 퀵비전 음성 출력은 네트워크 TTS가 아닌 iOS `ko-KR` 시스템 음성을 기본으로 사용한다.
6. 질문과 답변은 사진·음성 원본 없이 로컬 보호 저장소에 기록된다.
7. 로그는 `Markdown + JSONL` 두 형식으로 생성된다.
8. 사용자가 iOS 파일 선택기에서 Google Drive 폴더를 지정하면 `TurboMetaKnowledge` 하위에 자동 동기화된다.
9. Windows에서는 Google Drive for desktop으로 같은 파일을 즉시 확인할 수 있다.
10. API Key, 인증 토큰, 긴 Base64 데이터는 코드 상수·README·작업로그·진단로그·지식로그 어디에도 실제 값이 남지 않는다.

## 아키텍처

```text
Ray-Ban Meta
    ↓
TurboMeta
    ↓
Google Gemini API Key 1개
    ├─ Quick Vision: Gemini 3.6 Flash REST
    ├─ Live AI: Gemini 3.1 Flash Live
    └─ Live Translate: Gemini Live 통역 프롬프트

질문·답변
    ↓
KnowledgeLogService
    ├─ Application Support 보호 저장소
    ├─ YYYY-MM-DD.jsonl
    └─ YYYY-MM-DD.md
    ↓
iOS 파일 선택기에서 지정한 폴더
    ↓
Google Drive / Files
    ↓
Windows Google Drive for desktop / Obsidian
```

## 저장 구조

```text
TurboMetaKnowledge/
└─ logs/
   └─ 2026/
      └─ 08/
         ├─ 2026-08-09.jsonl
         └─ 2026-08-09.md
```

### JSONL 필드

- `schemaVersion`
- `id`
- `timestamp`
- `source`
- `sessionID`
- `question`
- `answer`
- `model`
- `language`
- `tags`
- `metadata`

사진, 음성 원본, 위치, 기기 식별자, API Key, 토큰은 저장하지 않는다.

## 단계

### 1단계: Google 단일 제공자

- [ ] `GeminiModelCatalog` 도입
- [ ] Quick Vision을 Gemini REST `generateContent` 형식으로 전환
- [ ] Live AI 제공자를 Google로 고정
- [ ] Live Translate를 Gemini Live 기반으로 전환
- [ ] 설정 화면에서 Alibaba/OpenRouter 선택 UI 숨김
- [ ] 기존 Alibaba/OpenRouter Keychain 값은 사용하지 않되 자동 삭제하지 않음
- [ ] 퀵비전 TTS를 iOS `ko-KR` 시스템 음성으로 단순화

### 2단계: 지식 로그

- [x] `KnowledgeLogService` 기본 구현
- [x] Markdown + JSONL 로컬 저장
- [x] 민감정보 사전 마스킹
- [x] Google Drive/Files 폴더 선택기
- [x] 선택 폴더로 수동·자동 동기화
- [ ] Quick Vision 기록 연결
- [ ] Live AI 대화 기록 연결
- [ ] Live Translate 기록 연결
- [ ] 설정 화면에 저장 위치와 동기화 상태 표시

### 3단계: 보안 및 운영

- [ ] 저장 전 마스킹 테스트 추가
- [ ] 소스와 README의 비밀값 패턴 검사 강화
- [ ] 질문·답변 본문이 콘솔 로그로 출력되지 않는지 검사
- [ ] 폴더 권한 만료 시 재선택 안내
- [ ] TestFlight 실기기에서 Google Drive 파일 제공자 쓰기 검증

### 4단계: 검증

- [ ] 정적 보안·한국어 검사 통과
- [ ] iOS 시뮬레이터 빌드 통과
- [ ] iPhone 13에서 퀵비전 이미지 분석 확인
- [ ] 한국어 시스템 음성 확인
- [ ] Live AI 영상·음성 대화 확인
- [ ] 실시간 번역 확인
- [ ] Google Drive 폴더에 Markdown·JSONL 생성 확인
- [ ] Windows Drive for desktop에서 동기화 확인
- [ ] Obsidian Vault에서 Markdown 열기 확인

## 보안 규칙

- 실제 API Key와 토큰은 iOS Keychain 밖으로 내보내지 않는다.
- 인증값의 일부, 앞뒤 문자, 해시도 로그에 남기지 않는다.
- URL 쿼리에 인증값이 들어가는 경우 전체 URL을 로그로 남기지 않는다.
- 지식 로그에는 사진·음성·Base64 원본을 저장하지 않는다.
- 질문과 답변은 사용자가 지정한 외부 폴더로 동기화될 수 있으므로 설정 화면에 개인정보 안내를 표시한다.
- Google Drive API OAuth를 추가하지 않고 iOS 파일 제공자 접근을 사용해 별도 OAuth 토큰을 만들지 않는다.
- 정식 공개 배포 단계에서는 장기 Gemini API Key를 앱에 직접 저장하지 않고 서버 발급 단기 토큰 구조를 검토한다.

## 후속 위키화

1차 구현은 원본 Q&A를 손실 없이 축적하는 데 집중한다. 이후 PC 작업에서 JSONL을 읽어 다음 파이프라인을 추가한다.

```text
JSONL
→ 중복 제거
→ 태그·개체 추출
→ 기존 Markdown 문서 검색
→ 새 문서 생성 또는 기존 문서 갱신
→ 상호 링크 생성
```

장기 지식으로 남길 항목과 일회성 질문을 구분하기 위해 향후 `기억해` 명령과 `wiki_candidate` 필드를 추가한다.
