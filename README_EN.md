# TurboMeta

TurboMeta is an iOS development project that connects the camera and microphone of Ray-Ban Meta smart glasses to AI features. This branch uses **Google Gemini as the single user-facing AI backend**.

> This repository contains source code only. It does not distribute prebuilt IPA files or provide a way to bypass Apple distribution requirements. Installing on a device requires standard Apple signing or TestFlight.

## Current status

| Item | Status |
|---|---|
| Minimum iOS version | iOS 17.0 |
| Shared Xcode scheme | `TurboMeta` |
| Primary UI and voice language | Korean (`ko-KR`) |
| User-facing AI backend | Google Gemini |
| CI | GitHub Actions static audit + iOS Simulator build; Codemagic Release/TestFlight workflows |
| Device validation | Required for glasses, camera, Bluetooth, microphone, Siri, and Files-provider behavior |

## Google Gemini setup

1. Create a Gemini API key in [Google AI Studio](https://aistudio.google.com/apikey).
2. Open **Settings** in TurboMeta.
3. Select **Google Gemini API Key**, enter the key, and save it.

The app stores the user-entered key in the iOS Keychain with device-only accessibility. Never put an API key in source code, `Info.plist`, `.env`, JSON, build logs, the README, work logs, test output, or commits.

When a placeholder is needed, use only:

```text
<YOUR_API_KEY>
```

Meta Wearables values are supplied as build settings, not committed files:

```text
META_APP_ID=<YOUR_META_APP_ID>
CLIENT_TOKEN=<YOUR_CLIENT_TOKEN>
```

`CameraAccess/Info.plist` references these settings through `$(META_APP_ID)` and `$(CLIENT_TOKEN)`.

## AI features

### Quick Vision

Quick Vision captures a frame from the glasses, sends it to Gemini image analysis, and presents a Korean result. Its result is spoken using iOS system TTS with the `ko-KR` voice—no separate cloud TTS key is required.

Supported modes include scene description, food and drink analysis, obstacle awareness, text reading, Korean translation, and object/place explanation.

### Gemini Live AI

Live AI uses Gemini Live for real-time multimodal conversation with the glasses camera and microphone. The normal settings flow exposes one Gemini API key and does not expose legacy provider selection to general users.

### Live Translate

Live Translate uses a Gemini Live session configured as an interpreter. It supports phone or Bluetooth microphone input, translation text, optional audio output, and image frames only as contextual input. It does not store image or audio source data in knowledge logs.

### Food analysis

Food nutrition analysis uses the same Gemini configuration and returns an AI estimate. It is informational only and is not medical or nutrition advice.

## Personal knowledge log

Quick Vision, Live AI, and Live Translate can write text-only Q&A events to a protected local store in two formats:

- Markdown, for people and note-taking tools
- JSONL, for machine processing

Before writing, the log service sanitizes API keys, Bearer tokens, JWTs, long credential-like strings, and large Base64 payloads. It does **not** save image originals, audio originals, location data, or authentication data. User text is not printed as diagnostic log content.

## Files-based Google Drive folder sync

TurboMeta does not add a Google Drive API key, Drive OAuth client secret, refresh token, or a separate OAuth flow.

Instead, the user selects a folder in the iOS Files document picker. That can be a Google Drive folder exposed by the Files app, or a folder from another supported Files provider. The app stores a security-scoped bookmark for the selected folder and copies the text-only knowledge-log files under:

```text
<selected folder>/TurboMetaKnowledge/
```

Folder access and sync must be selected and authorized by the user. Re-select the folder if a bookmark becomes stale or the provider revokes access.

## On-device developer diagnostics

`DEBUG` builds include the full developer toolset. TestFlight builds from this branch use the narrowly scoped `TESTFLIGHT_TTS_DIAGNOSTICS` condition to include only the protected diagnostics console and **Diagnose TTS with OpenClaw** flow; general mock and debug settings remain excluded.

The on-device console displays up to 2,000 recent lines. Internal/TestFlight diagnostics keep a bounded rotating log in protected Application Support so a physical-device failure can be reviewed after reproduction. Before display, persistence, export, or an explicitly confirmed OpenClaw diagnostic request, the app redacts credentials, URLs containing credentials, UUIDs, MAC addresses, accessory identifiers, socket paths, certificate dumps, and large payloads. It does not write raw speech transcripts or OpenClaw answer text into diagnostic logs.

The developer does **not** automatically collect or upload these diagnostics. Exporting a file or sending the allowlisted TTS/audio metadata to OpenClaw requires a user action and review. Redaction is defense in depth, so users should still inspect a report before sharing it.

OpenClaw final-response notifications contain only the same Markdown/URL/code-stripped summary used for speech, limited to three sentences and 250 characters. While the app is running and can process the Gateway final event, it also speaks that summary through the current iPhone media output (Ray-Ban or iPhone). A local notification cannot force the iOS system Announce Notifications feature, and if iOS suspends or terminates the app before it receives the final event, the app cannot create or speak that response.

## OpenClaw Quick Shot and protected Gallery

The top of the Home screen provides large **Photo** and **Video** Quick Shot actions. Each capture freezes the selected mode name and prompt at capture start. Modes can be created, edited, duplicated, deleted, and reordered in the app, with separate photo/video defaults and recent selections.

- The app fixes streaming at the DAT SDK 0.5.0 maximum of portrait 720×1280 at 30fps. This higher data rate can increase glasses battery use and heat as well as iPhone encoding load.
- Photos preserve the DAT SDK's approximately 1080×1440 JPEG byte-for-byte in protected app storage. The SDK exposes no 12MP photo-resolution option, so the app does not fake detail by upscaling. Only an original that exceeds the Gateway's 4MiB cap gets a separate analysis-only JPEG derivative.
- Videos preserve the 720×1280 input at up to 30fps in a bounded H.264 High Profile MP4 original for up to 10 seconds. The app does **not** upload that MP4 to OpenClaw. It builds a 2×3 contact sheet from up to six representative frames at their natural pixel size and selects the highest JPEG quality that fits 4MiB, labeling the result as representative-frame analysis.
- The app-owned repository in protected Application Support is the Gallery source of truth. Copies to iPhone Photos use add-only access; the app does not read or enumerate the existing photo library.
- A Photos export or OpenClaw analysis failure never removes the protected original. The Gallery provides explicit retry actions.
- Deleting a Gallery item removes only the app original, thumbnail, and index entry. A copy already saved in iPhone Photos remains untouched.
- An ambiguous delivery is never resent automatically. It remains marked as needing confirmation until the user checks for possible duplication and explicitly retries with a new request attempt.

Completed analyses reuse protected OpenClaw chat history, final-event deduplication, local notifications, and summarized TTS. Notifications and speech cannot be guaranteed if iOS suspends or terminates the app before it processes the Gateway final event.

## OpenClaw Nord Meshnet remote connection

To use OpenClaw away from the office without router port forwarding or public Internet exposure, link the Windows PC and iPhone as **personally approved Nord Meshnet peers**, then explicitly select **Nord Meshnet** mode in TurboMeta's OpenClaw settings.

- Meshnet mode permits `ws://` only for an **exact IPv4 peer address** in `100.64.0.0/10`. The address range is not trusted automatically: in standard mode, the same address still requires `wss://`.
- Do not use Meshnet mode for ordinary office-LAN addresses, hostnames, or public hosts. External or unverified hosts must continue to use `wss://`.
- Keep the Gateway loopback-only when a Meshnet-only proxy/listener can provide access. If a direct listener is necessary, constrain the Windows Firewall inbound rule to the Meshnet interface and one approved iPhone peer.
- Meshnet does not replace Gateway authentication, signed device connection, or OpenClaw pairing. Do not put a token in a URL, bind the Gateway to public WAN, enable Nord traffic routing for this purpose, or broaden local-network permissions.
- After configuring the peer link, Gateway, and firewall, verify the physical iPhone path on the same Meshnet and then on cellular. Never share endpoint addresses, peer names, tokens, raw handshakes, or raw logs in work records or support requests.

If the direct Meshnet `ws://` path fails on a physical device because of iOS App Transport Security, do not add a broad ATS exception. Use a Meshnet-only `wss://` proxy on the PC instead.

## Build and validation

### Static audit

Run the repository audit without placing credentials in output:

```bash
python Scripts/audit_localization_security.py
```

The audit checks for common committed secrets, unsafe transport settings, required storage protections, package pinning, and Korean localization issues. It is a static safeguard, not a replacement for a full security review.

### iOS Simulator build

On macOS with Xcode and an iPhone Simulator SDK:

```bash
xcodebuild \
  -project CameraAccess.xcodeproj \
  -scheme TurboMeta \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  ONLY_ACTIVE_ARCH=NO \
  clean build
```

GitHub Actions runs the same fixed-package, unsigned Simulator build in [`.github/workflows/ios-validate.yml`](.github/workflows/ios-validate.yml). Codemagic additionally provides an unsigned Release compile check and signing/TestFlight workflows; TestFlight signing remains a separate deployment concern.

## Real-device validation still required

A green Simulator build proves compilation, not physical-device behavior. Validate the following on an iPhone with Ray-Ban Meta glasses:

- registration, reconnect, camera streaming, and camera permission
- microphone and Bluetooth audio routing
- Gemini key entry and Keychain persistence
- Quick Vision Gemini result and Korean system TTS
- Gemini Live AI and Live Translate conversations
- text-only local Markdown/JSONL knowledge-log creation and credential redaction
- Files document-picker selection, bookmark restoration, and sync to a Google Drive folder
- Siri shortcuts, OpenClaw behavior, and RTMP/RTMPS streaming as applicable

## Project structure

```text
CameraAccess/
├── Intents/                 Siri App Intents and shortcuts
├── Managers/                Gemini configuration and feature modes
├── Models/                  Conversation, translation, and nutrition models
├── Services/                Gemini, knowledge-log, stream, OpenClaw, and RTMP services
├── Utils/                   Keychain and permissions utilities
├── ViewModels/              View state and service integration
├── Views/                   SwiftUI screens and the unified settings view
└── TurboMetaApp.swift       App entry point

Scripts/audit_localization_security.py
.github/workflows/ios-validate.yml
codemagic.yaml
docs/GOOGLE_GEMINI_KNOWLEDGE_LOG_PLAN.md
docs/WORKLOG.md
```

## Security notes

- Store user-entered credentials only in the Keychain where the implementation supports it.
- Do not log credentials, their prefixes/suffixes, hashes, Base64 forms, authorization headers, or query-string values.
- Prefer encrypted endpoints. OpenClaw and streaming integrations have their own deployment and network-security considerations.
- A client-held long-lived API key still carries device compromise risk. A production deployment should consider a backend-issued, short-lived credential design.

## License

This project is distributed under the [MIT License](LICENSE). Meta, Ray-Ban, Apple, Google, OpenClaw, and other product names are trademarks of their respective owners. TurboMeta is not an official product of those companies.
