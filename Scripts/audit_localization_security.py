#!/usr/bin/env python3
"""TurboMeta 한국어 UI 및 기본 보안 설정 정적 점검.

외부 패키지 없이 실행되며 GitHub Actions와 로컬 개발 환경에서 같은 검사를 사용한다.
완전한 침투 테스트를 대신하지는 않지만 저장소 비밀정보, 과도한 ATS 예외,
필수 보호 코드 누락, 번역 키 누락과 중국어 사용자 문자열을 빠르게 차단한다.
"""

from __future__ import annotations

import json
import plistlib
import re
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = ROOT / "CameraAccess"
REPORT_PATH = ROOT / "audit-report.txt"
SUPPORTED_KOREAN_RESOURCE_DIRECTORIES = {"ko.lproj"}
STRINGS_ASSIGNMENT_PATTERN = re.compile(
    r'^\s*"(?P<key>[^"\\]+)"\s*=\s*"(?P<value>(?:\\.|[^"\\])*)"\s*;',
    re.MULTILINE,
)


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
    def preserve_newlines(match: re.Match[str]) -> str:
        return "\n" * match.group(0).count("\n")

    text = re.sub(r"/\*.*?\*/", preserve_newlines, text, flags=re.DOTALL)
    return re.sub(r"//[^\n]*", "", text)


def korean_localization_files() -> list[Path]:
    return sorted(
        path
        for path in SOURCE_ROOT.rglob("Localizable.strings")
        if path.parent.name in SUPPORTED_KOREAN_RESOURCE_DIRECTORIES
    )


def audit_package_resolution(findings: list[Finding]) -> None:
    resolved_path = (
        ROOT
        / "CameraAccess.xcodeproj"
        / "project.xcworkspace"
        / "xcshareddata"
        / "swiftpm"
        / "Package.resolved"
    )

    if not resolved_path.exists():
        findings.append(Finding("치명", relative(resolved_path), 1, "Package.resolved가 없습니다"))
        return

    expected_remote_packages = {
        "haishinkit.swift": "https://github.com/Turbo1123/HaishinKit.swift",
        "meta-wearables-dat-ios": "https://github.com/facebook/meta-wearables-dat-ios",
    }

    try:
        payload = json.loads(resolved_path.read_text(encoding="utf-8"))
        pins = payload.get("pins")
        if not isinstance(pins, list) or not pins:
            findings.append(Finding("치명", relative(resolved_path), 1, "Package.resolved에 고정 패키지가 없습니다"))
        else:
            identities: set[str] = set()
            remote_packages: dict[str, str] = {}
            for pin in pins:
                if not isinstance(pin, dict):
                    findings.append(Finding("치명", relative(resolved_path), 1, "Package.resolved pin 형식이 올바르지 않습니다"))
                    continue
                identity = pin.get("identity")
                if not isinstance(identity, str) or not identity:
                    findings.append(Finding("치명", relative(resolved_path), 1, "Package.resolved pin에 identity가 없습니다"))
                    continue
                if identity in identities:
                    findings.append(Finding("치명", relative(resolved_path), 1, f"Package.resolved에 중복 identity가 있습니다: {identity}"))
                identities.add(identity)

                state = pin.get("state")
                if pin.get("kind") == "remoteSourceControl":
                    location = pin.get("location")
                    if not isinstance(location, str) or not location:
                        findings.append(Finding("치명", relative(resolved_path), 1, f"원격 패키지 location이 없습니다: {identity}"))
                    else:
                        remote_packages[identity] = location.rstrip("/")
                    if (
                        not isinstance(state, dict)
                        or not isinstance(state.get("revision"), str)
                        or not re.fullmatch(r"[0-9a-fA-F]{40}", state["revision"])
                    ):
                        findings.append(Finding("치명", relative(resolved_path), 1, f"원격 패키지 revision이 올바르지 않습니다: {identity}"))

            for identity, location in expected_remote_packages.items():
                if remote_packages.get(identity) != location:
                    findings.append(
                        Finding(
                            "치명",
                            relative(resolved_path),
                            1,
                            f"필수 원격 패키지 또는 location이 올바르지 않습니다: {identity}",
                        )
                    )
    except Exception as exc:  # noqa: BLE001
        findings.append(Finding("치명", relative(resolved_path), 1, f"Package.resolved 파싱 실패: {exc}"))

    enforcement_files = {
        ".github/workflows/ios-validate.yml": "-onlyUsePackageVersionsFromResolvedFile",
        "codemagic.yaml": "-onlyUsePackageVersionsFromResolvedFile",
    }
    for path_text, marker in enforcement_files.items():
        path = ROOT / path_text
        if not path.exists() or marker not in path.read_text(encoding="utf-8", errors="replace"):
            findings.append(Finding("치명", path_text, 1, "고정된 패키지 버전 강제 옵션이 없습니다"))

    if (SOURCE_ROOT / "zh-Hans.lproj").exists():
        findings.append(Finding("치명", "CameraAccess/zh-Hans.lproj", 1, "한국어 리소스는 ko.lproj에 있어야 합니다"))

    codemagic_path = ROOT / "codemagic.yaml"
    if codemagic_path.exists():
        codemagic_text = codemagic_path.read_text(encoding="utf-8", errors="replace")
        testflight_block = re.search(
            r"(?ms)^  ios-testflight:\n(?P<body>.*?)(?=^  [A-Za-z0-9_-]+:|\Z)",
            codemagic_text,
        )
        if testflight_block and "SWIFT_ACTIVE_COMPILATION_CONDITIONS=INTERNAL_BUILD" in testflight_block.group("body"):
            findings.append(Finding("치명", "codemagic.yaml", 1, "ios-testflight 워크플로에 INTERNAL_BUILD가 설정되어 있습니다"))


def audit_openclaw_cloud_inference(findings: list[Finding]) -> None:
    openclaw_root = SOURCE_ROOT / "Services" / "OpenClaw"
    forbidden_markers = ("dashscope", "fun-asr", "staticAlibabaEndpoint", "getAPIKey(for: .alibaba)")

    for path in openclaw_root.rglob("*.swift"):
        text = path.read_text(encoding="utf-8", errors="replace")
        lower = text.lower()
        for marker in forbidden_markers:
            if marker.lower() in lower:
                findings.append(
                    Finding(
                        "치명",
                        relative(path),
                        1,
                        f"OpenClaw 활성 소스에 제거된 Alibaba ASR 참조가 남아 있습니다: {marker}",
                    )
                )

    for path in (SOURCE_ROOT / "Views").glob("OpenClaw*.swift"):
        text = path.read_text(encoding="utf-8", errors="replace")
        lower = text.lower()
        for marker in forbidden_markers:
            if marker.lower() in lower:
                findings.append(
                    Finding(
                        "치명",
                        relative(path),
                        1,
                        f"OpenClaw 화면에 제거된 Alibaba ASR 참조가 남아 있습니다: {marker}",
                    )
                )


def audit_diagnostic_exports(findings: list[Finding]) -> None:
    path_text = "CameraAccess/Views/DebugMenuView.swift"
    path = ROOT / path_text
    if not path.exists():
        findings.append(Finding("치명", path_text, 1, "진단 콘솔 소스가 없습니다"))
        return

    text = path.read_text(encoding="utf-8", errors="replace")
    required_markers = (
        "SensitiveDataRedactor.redact(sections.joined",
        ".map(SensitiveDataRedactor.redact)",
        "SensitiveDataRedactor.redact(text).data(using: .utf8)",
    )
    for marker in required_markers:
        if marker not in text:
            findings.append(Finding("치명", path_text, 1, f"진단 내보내기 마스킹 코드가 없습니다: {marker}"))

    redactor_path = ROOT / "CameraAccess/Utils/SensitiveDataRedactor.swift"
    if not redactor_path.exists():
        findings.append(Finding("치명", relative(redactor_path), 1, "공유 민감정보 마스킹 유틸리티가 없습니다"))

    knowledge_path = ROOT / "CameraAccess/Services/KnowledgeLogService.swift"
    if knowledge_path.exists() and "SensitiveDataRedactor.redactKnowledgeLogText" not in knowledge_path.read_text(encoding="utf-8", errors="replace"):
        findings.append(Finding("치명", relative(knowledge_path), 1, "지식 로그가 공유 민감정보 마스킹 유틸리티를 사용하지 않습니다"))


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

        if plist.get("CFBundleDevelopmentRegion") != "ko":
            findings.append(Finding("치명", relative(info_plist), 1, "앱 기본 언어가 ko로 고정되어 있지 않습니다"))
        if "ko" not in plist.get("CFBundleLocalizations", []):
            findings.append(Finding("치명", relative(info_plist), 1, "CFBundleLocalizations에 ko가 없습니다"))
        if plist.get("CFBundleSpokenName") != "터보메타":
            findings.append(Finding("경고", relative(info_plist), 1, "Siri용 한국어 앱 발음 이름이 터보메타로 설정되지 않았습니다"))
        if not plist.get("NSSiriUsageDescription"):
            findings.append(Finding("치명", relative(info_plist), 1, "NSSiriUsageDescription이 비어 있습니다"))

        mwd = plist.get("MWDAT", {})
        for key in ("MetaAppID", "ClientToken"):
            value = mwd.get(key)
            if not isinstance(value, str) or not value.startswith("$("):
                findings.append(Finding("치명", relative(info_plist), 1, f"MWDAT {key}는 저장소 값이 아니라 빌드 변수로 주입해야 합니다"))
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
        "CameraAccess/Services/ConversationStorage.swift": [
            "completeFileProtectionUntilFirstUserAuthentication",
            "FileProtectionType.completeUntilFirstUserAuthentication",
        ],
        "CameraAccess/Services/QuickVisionStorage.swift": [
            "completeFileProtectionUntilFirstUserAuthentication",
            "FileProtectionType.completeUntilFirstUserAuthentication",
        ],
        "CameraAccess/Views/DebugMenuView.swift": [
            "SensitiveDataRedactor.redact",
            "maximumEntryCount",
        ],
        "CameraAccess/Utils/SensitiveDataRedactor.swift": [
            "Bearer\\s+",
            "<보안상 숨김>",
        ],
        "CameraAccess/TurboMetaApp.swift": [
            "TurboMetaShortcuts.updateAppShortcutParameters()",
            'Locale(identifier: "ko-KR")',
            "DEBUG || INTERNAL_BUILD",
        ],
        "CameraAccess/Info.plist": [
            "NSSiriUsageDescription",
            "NSAllowsLocalNetworking",
            "CFBundleSpokenName",
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
    files = korean_localization_files()
    if not files:
        findings.append(Finding("치명", "CameraAccess", 1, "한국어 Localizable.strings 파일이 없습니다"))
        return

    defined_keys: dict[str, tuple[Path, int, str]] = {}

    for path in files:
        text = path.read_text(encoding="utf-8", errors="replace")
        for match in STRINGS_ASSIGNMENT_PATTERN.finditer(text):
            key = match.group("key")
            value = match.group("value")
            line = line_number(text, match.start())

            if key in defined_keys:
                previous_path, previous_line, _ = defined_keys[key]
                findings.append(
                    Finding(
                        "경고",
                        relative(path),
                        line,
                        f"번역 키가 중복 정의되었습니다: {key} (기존 {relative(previous_path)}:{previous_line})",
                    )
                )
            else:
                defined_keys[key] = (path, line, value)

            if not value.strip():
                findings.append(Finding("경고", relative(path), line, f"번역 값이 비어 있습니다: {key}"))
            if chinese_pattern.search(value):
                findings.append(
                    Finding(
                        "경고",
                        relative(path),
                        line,
                        f"한국어 리소스 값에 중국어/한자가 남아 있습니다: {key} = {value[:80]}",
                    )
                )

    localized_key_pattern = re.compile(r'"(?P<key>[A-Za-z0-9_.-]+)"\s*\.localized\b')
    for path in SOURCE_ROOT.rglob("*.swift"):
        text = path.read_text(encoding="utf-8", errors="replace")
        code = strip_swift_comments(text)
        for match in localized_key_pattern.finditer(code):
            key = match.group("key")
            if key not in defined_keys:
                findings.append(
                    Finding(
                        "경고",
                        relative(path),
                        line_number(code, match.start()),
                        f"한국어 번역 파일에 없는 키를 사용합니다: {key}",
                    )
                )


def audit_swift_strings(findings: list[Finding]) -> None:
    chinese_pattern = re.compile(r"[\u4e00-\u9fff]")
    ui_literal_pattern = re.compile(
        r"\b(?:Text|Button|Label|SecureField|TextField|navigationTitle|alert|ContentUnavailableView|accessibilityLabel)"
        r"\s*\(\s*\"(?P<literal>(?:\\.|[^\"\\])*)\"",
        flags=re.MULTILINE,
    )

    # 서버의 과거 응답을 한국어 UI 값으로 정규화하기 위한 호환 문자열이다.
    allowed_chinese_literals = {"优秀", "良好", "一般", "较差"}
    allowed_english_fragments = {
        "AI",
        "Meta",
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
        "ws:",
        "wss:",
        "127.0.0.1",
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
            literal_without_interpolation = re.sub(r"\\\([^)]*\)", "", literal)
            if not re.search(r"[A-Za-z]", literal_without_interpolation):
                continue
            if re.fullmatch(r"[A-Za-z0-9_.-]+", literal_without_interpolation):
                continue
            if any(fragment in literal_without_interpolation for fragment in allowed_english_fragments):
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
            is_log_line = "print(" in line or "logger." in line
            mentions_sensitive_name = any(
                token in lower
                for token in ("apikey", "api_key", "authorization", "streamkey", "gatewaytoken", "bearer")
            )
            only_reports_metadata = any(
                safe_fragment in lower
                for safe_fragment in ("configured=", "present=", "exists=", "length=", "count=", "source=keychain")
            )
            if is_log_line and mentions_sensitive_name and not only_reports_metadata:
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
    audit_package_resolution(findings)
    audit_openclaw_cloud_inference(findings)
    audit_diagnostic_exports(findings)
    audit_secrets_and_transport(findings)
    audit_localization_strings(findings)
    audit_swift_strings(findings)
    findings.sort(key=lambda item: ({"치명": 0, "경고": 1, "참고": 2}[item.severity], item.path, item.line))
    write_report(findings)

    if any(item.severity in {"치명", "경고"} for item in findings):
        sys.exit(1)
