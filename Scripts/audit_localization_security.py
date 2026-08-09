#!/usr/bin/env python3
"""TurboMeta 한국어 UI 및 기본 보안 설정 정적 점검.

외부 패키지 없이 실행되며, GitHub Actions와 로컬 개발 환경에서 같은 검사를 사용한다.
이 검사는 완전한 침투 테스트를 대체하지 않는다. 명백한 비밀정보, 과도한 ATS 예외,
필수 보호 코드 누락과 남은 외국어 사용자 문자열을 빠르게 찾는 용도다.
"""

from __future__ import annotations

import plistlib
import re
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = ROOT / "CameraAccess"
REPORT_PATH = ROOT / "audit-report.txt"


@dataclass(frozen=True)
class Finding:
    severity: str
    path: str
    line: int
    message: str

    def render(self) -> str:
        return f"[{self.severity}] {self.path}:{self.line} {self.message}"


def line_number(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def relative(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def swift_string_literals(text: str):
    pattern = re.compile(r'"(?:\\.|[^"\\])*"')
    for match in pattern.finditer(text):
        yield match, match.group(0)[1:-1]


def strip_swift_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    return re.sub(r"//.*", "", text)


def audit_secrets_and_transport(findings: list[Finding]) -> None:
    secret_patterns = [
        (re.compile(r"\bsk-[A-Za-z0-9_-]{20,}\b"), "OpenAI 계열 API Key처럼 보이는 문자열"),
        (re.compile(r"\bAIza[0-9A-Za-z_-]{30,}\b"), "Google API Key처럼 보이는 문자열"),
        (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}\b"), "GitHub 토큰처럼 보이는 문자열"),
        (re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"), "개인 키 본문"),
    ]

    scan_extensions = {".swift", ".plist", ".entitlements", ".yml", ".yaml", ".md", ".json"}
    for path in ROOT.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in scan_extensions:
            continue
        if any(part in {".git", "DerivedData", ".build"} for part in path.parts):
            continue

        text = path.read_text(encoding="utf-8", errors="replace")
        for pattern, description in secret_patterns:
            for match in pattern.finditer(text):
                findings.append(
                    Finding(
                        "치명",
                        relative(path),
                        line_number(text, match.start()),
                        f"저장소에 {description}이 포함되어 있습니다",
                    )
                )

    info_plist = SOURCE_ROOT / "Info.plist"
    try:
        with info_plist.open("rb") as handle:
            plist = plistlib.load(handle)
        ats = plist.get("NSAppTransportSecurity", {})
        if ats.get("NSAllowsArbitraryLoads") is True:
            findings.append(Finding("치명", relative(info_plist), 1, "NSAllowsArbitraryLoads=true는 허용되지 않습니다"))
        if ats.get("NSAllowsArbitraryLoadsInWebContent") is True:
            findings.append(Finding("치명", relative(info_plist), 1, "웹 콘텐츠 전체 ATS 예외가 설정되어 있습니다"))
    except Exception as exc:  # noqa: BLE001
        findings.append(Finding("치명", relative(info_plist), 1, f"Info.plist 파싱 실패: {exc}"))

    required_markers = {
        "CameraAccess/Utils/APIKeyManager.swift": [
            "kSecAttrAccessibleWhenUnlockedThisDeviceOnly",
        ],
        "CameraAccess/Services/OpenClaw/OpenClawNodeService.swift": [
            "kSecAttrAccessibleWhenUnlockedThisDeviceOnly",
            "insecurePublicWebSocket",
            "credentialsOrQueryNotAllowed",
        ],
        "CameraAccess/ViewModels/RTMPStreamingViewModel.swift": [
            "kSecAttrAccessibleWhenUnlockedThisDeviceOnly",
        ],
        "CameraAccess/Views/DebugMenuView.swift": [
            "Bearer\\s+",
            "<보안상 숨김>",
            "maximumEntryCount",
        ],
        "CameraAccess/TurboMetaApp.swift": [
            "TurboMetaShortcuts.updateAppShortcutParameters()",
            'Locale(identifier: "ko-KR")',
            "DEBUG || INTERNAL_BUILD",
        ],
        "CameraAccess/Info.plist": [
            "NSSiriUsageDescription",
            "NSAllowsLocalNetworking",
        ],
    }

    for path_text, markers in required_markers.items():
        path = ROOT / path_text
        if not path.exists():
            findings.append(Finding("치명", path_text, 1, "필수 보호 파일이 없습니다"))
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for marker in markers:
            if marker not in text:
                findings.append(Finding("치명", path_text, 1, f"필수 보호 코드가 없습니다: {marker}"))


def audit_localization_strings(findings: list[Finding]) -> None:
    chinese_pattern = re.compile(r"[\u4e00-\u9fff]")
    assignment_pattern = re.compile(r'^\s*"(?P<key>[^"\\]+)"\s*=\s*"(?P<value>(?:\\.|[^"\\])*)"\s*;', re.MULTILINE)

    for path in SOURCE_ROOT.rglob("Localizable.strings"):
        # 한국어 전용 리소스로 사용 중인 번들만 검사한다.
        if path.parent.name not in {"ko.lproj", "zh-Hans.lproj"}:
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for match in assignment_pattern.finditer(text):
            value = match.group("value")
            if chinese_pattern.search(value):
                findings.append(
                    Finding(
                        "경고",
                        relative(path),
                        line_number(text, match.start()),
                        f"한국어 리소스 값에 중국어/한자가 남아 있습니다: {match.group('key')} = {value[:80]}",
                    )
                )


def audit_swift_strings(findings: list[Finding]) -> None:
    chinese_pattern = re.compile(r"[\u4e00-\u9fff]")
    ui_literal_pattern = re.compile(
        r"\b(?:Text|Button|Label|SecureField|TextField|navigationTitle|alert|ContentUnavailableView|accessibilityLabel)"
        r"\s*\(\s*\"(?P<literal>(?:\\.|[^\"\\])*)\"",
        flags=re.MULTILINE,
    )

    allowed_chinese_literals = {"优秀", "良好", "一般", "较差"}
    allowed_english_fragments = {
        "TurboMeta",
        "Ray-Ban Meta",
        "OpenClaw",
        "Live AI",
        "API Key",
        "Google Gemini",
        "Alibaba",
        "OpenRouter",
        "RTMP",
        "RTMPS",
        "FPS",
        "YouTube",
        "Twitch",
        "TikTok",
        "Facebook",
        "Bilibili",
        "Douyin",
        "iPhone",
        "Keychain",
        "Siri",
        "TestFlight",
        "Xcode",
        "WebSocket",
        "Gateway",
    }

    for path in SOURCE_ROOT.rglob("*.swift"):
        text = path.read_text(encoding="utf-8", errors="replace")
        code = strip_swift_comments(text)

        for match, literal in swift_string_literals(code):
            if chinese_pattern.search(literal) and literal not in allowed_chinese_literals:
                findings.append(
                    Finding(
                        "경고",
                        relative(path),
                        line_number(code, match.start()),
                        f"중국어/한자 문자열이 남아 있습니다: {literal[:80]}",
                    )
                )

        for match in ui_literal_pattern.finditer(code):
            literal = match.group("literal")
            if not re.search(r"[A-Za-z]", literal):
                continue
            if re.fullmatch(r"[a-z0-9_.-]+", literal):
                continue
            if any(fragment in literal for fragment in allowed_english_fragments):
                continue
            findings.append(
                Finding(
                    "참고",
                    relative(path),
                    line_number(code, match.start()),
                    f"사용자 화면에 영어 문자열이 직접 노출될 가능성: {literal[:100]}",
                )
            )

        for index, line in enumerate(text.splitlines(), start=1):
            lower = line.lower()
            if ("print(" in line or "logger." in line) and any(
                token in lower for token in ("apikey", "api_key", "authorization", "streamkey", "gatewaytoken", "bearer")
            ):
                findings.append(
                    Finding(
                        "참고",
                        relative(path),
                        index,
                        "민감정보 관련 로그 문장입니다. 실제 값이 출력되지 않는지 검토하세요",
                    )
                )


def write_report(findings: list[Finding]) -> None:
    counts = {severity: sum(item.severity == severity for item in findings) for severity in ("치명", "경고", "참고")}
    lines = [
        "TurboMeta 한국어·보안 정적 점검",
        "=" * 36,
        f"치명 {counts['치명']}개 / 경고 {counts['경고']}개 / 참고 {counts['참고']}개",
        "",
    ]

    if not findings:
        lines.append("발견 항목이 없습니다.")
    else:
        for severity in ("치명", "경고", "참고"):
            group = [item for item in findings if item.severity == severity]
            if not group:
                continue
            lines.append(f"[{severity}]")
            lines.extend(item.render() for item in group)
            lines.append("")

    report = "\n".join(lines).rstrip() + "\n"
    REPORT_PATH.write_text(report, encoding="utf-8")
    print(report, end="")


if __name__ == "__main__":
    findings: list[Finding] = []
    audit_secrets_and_transport(findings)
    audit_localization_strings(findings)
    audit_swift_strings(findings)
    findings.sort(key=lambda item: ({"치명": 0, "경고": 1, "참고": 2}[item.severity], item.path, item.line))
    write_report(findings)

    if any(item.severity == "치명" for item in findings):
        sys.exit(1)
