# TurboMeta 미니 작업로그

이 문서는 기능 변경의 이유, 범위, 검증 결과를 짧게 누적하는 개발 로그다. 실제 인증값, 토큰, 사용자 질문·답변 원문은 기록하지 않는다.

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

- [ ] Xcode 프로젝트에 새 서비스 파일 등록
- [ ] API 제공자 설정을 Google 중심으로 정리
- [ ] Quick Vision Gemini REST 전환
- [ ] Live AI Google 고정
- [ ] Live Translate Gemini Live 전환
- [ ] Q&A 저장 훅 연결
- [ ] 설정 화면에 지식 로그 폴더·동기화 UI 추가
- [ ] README 기능 설명 갱신
- [ ] 정적 보안 검사와 iOS 빌드 검증

### 보안 메모

- 실제 API Key 값은 Keychain 외부에 기록하지 않는다.
- 로그에는 인증값 존재 여부, 접두사, 접미사, 해시를 남기지 않는다.
- 질문·답변 본문은 진단 콘솔에 출력하지 않는다.
- 지식 로그에는 이미지, 음성, 위치, 사용자 계정 정보를 저장하지 않는다.
- 외부 폴더에는 사용자가 명시적으로 선택한 경우에만 동기화한다.

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
