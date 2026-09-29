# OpenClaw Gateway 대화 → myObsidian 동기화

Windows OpenClaw Gateway가 보관하는 모든 agent/session JSONL 대화를 private myObsidian 저장소에 세션별 Markdown으로 장기 보관한다.

## 보관 범위

- `~/.openclaw/agents/*/sessions/sessions.json`에 등록된 모든 agent 세션
- 사용자, assistant, tool call/result 메시지
- Gateway에 이미 남아 있는 기존 대화 backfill과 이후 증분 갱신

Gateway retention에서 이미 삭제된 대화와 저장되지 않은 streaming 중간 token은 복구할 수 없다.

## 보안 정책

- Gateway token, password, authorization, cookie, signature, nonce 제거
- URL credential, IPv4, UUID와 장문 secret 형태 제거
- 실제 session key/ID 대신 SHA-256 기반 12자리 비식별 hash 사용
- 실행 로그에는 대화 원문을 출력하지 않음
- Git force push와 자동 rebase를 하지 않음
- iPhone 앱에는 Git 자격증명을 저장하지 않음

대화 원문 자체에는 개인정보가 포함될 수 있으므로 **반드시 private Git remote**를 사용한다.

## 설치

관리자 PowerShell이 아니라 일반 사용자 PowerShell에서 실행한다. 최초 backfill과 push는 각각 명시적으로 확인해야 하며, 성공한 뒤에만 5분 예약 작업을 설치한다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Scripts\OpenClaw\Install-OpenClawObsidianSync.ps1
```

다른 vault를 사용할 경우:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Scripts\OpenClaw\Install-OpenClawObsidianSync.ps1 -VaultPath "C:\path\to\myObsidian"
```

## 수동 미리보기

파일을 쓰지 않고 세션과 변경 예정 노트 수만 확인한다.

```powershell
python .\Scripts\OpenClaw\Export-OpenClawConversations.py --vault "C:\path\to\myObsidian" --dry-run
```

## 수동 동기화

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Scripts\OpenClaw\Invoke-OpenClawObsidianSync.ps1 -VaultPath "C:\path\to\myObsidian"
```

myObsidian에 다른 작업 변경이 있거나 remote가 앞서 있으면 자동 작업은 중단된다. 대화 commit은 로컬에 보존되며 사용자가 충돌을 해결한 다음 다시 실행한다.

## 출력 구조

```text
Inbox/OpenClaw/YYYY-MM/Sessions/<안전한-별칭>-<세션-hash>.md
.openclaw-sync-manifest.json
```

세션 파일은 canonical transcript 전체에서 결정적으로 재생성된다. 같은 입력으로 반복 실행하면 diff와 중복 commit이 생기지 않는다.
