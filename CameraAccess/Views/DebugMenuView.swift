/*
 * TurboMeta internal/TestFlight diagnostics console.
 *
 * The console captures application stdout/stderr, keeps a small protected rotating log,
 * redacts credentials and large payloads, and lets a tester share one diagnostic text file.
 * No diagnostic data is uploaded automatically.
 */

import Darwin
import Foundation
import SwiftUI
import UIKit

#if canImport(MetricKit)
import MetricKit
#endif

// MARK: - Log model

enum DeveloperLogLevel: String, CaseIterable, Identifiable {
  case info = "정보"
  case warning = "경고"
  case error = "오류"

  var id: String { rawValue }

  var symbolName: String {
    switch self {
    case .info: return "info.circle.fill"
    case .warning: return "exclamationmark.triangle.fill"
    case .error: return "xmark.octagon.fill"
    }
  }

  var color: Color {
    switch self {
    case .info: return .secondary
    case .warning: return .orange
    case .error: return .red
    }
  }
}

struct DeveloperLogEntry: Identifiable {
  let id = UUID()
  let timestamp: Date
  let level: DeveloperLogLevel
  let message: String
}

// MARK: - In-app and persistent console

final class DeveloperConsole: ObservableObject {
  static let shared = DeveloperConsole()

  @Published private(set) var entries: [DeveloperLogEntry] = []
  @Published private(set) var unreadErrorCount = 0
  @Published var isPresented = false

  private let maximumEntryCount = 2_000
  private let maximumLineLength = 4_000
  private let maximumPersistentFileBytes: UInt64 = 3_000_000
  private let maximumExportAge: TimeInterval = 60 * 60 * 24
  private let parsingQueue = DispatchQueue(label: "com.turbometa.developer-console")

  private let sessionID = UUID().uuidString
  private let sessionStateKey = "developer_console_session_finished_cleanly"

  private var capturePipe: Pipe?
  private var originalStandardOutput: Int32 = -1
  private var originalStandardError: Int32 = -1
  private var pendingText = ""
  private var isCapturing = false

  private var diagnosticsDirectoryURL: URL?
  private var currentLogURL: URL?
  private var lastSessionLogURL: URL?
  private var rotatedLogURL: URL?
  private var metricsDirectoryURL: URL?
  private var exportDirectoryURL: URL?
  private var persistentHandle: FileHandle?
  private var persistentBytesWritten: UInt64 = 0
  private var previousSessionLikelyUnclean = false
  private var notificationTokens: [NSObjectProtocol] = []

  private init() {}

  deinit {
    for token in notificationTokens {
      NotificationCenter.default.removeObserver(token)
    }
    try? persistentHandle?.close()
  }

  func startCapturing() {
    guard !isCapturing else { return }
    isCapturing = true

    preparePersistentStorage()
    installLifecycleObservers()
    installUncaughtExceptionHandler()
    startMetricKitCollection()

    fflush(stdout)
    fflush(stderr)

    let pipe = Pipe()
    originalStandardOutput = dup(STDOUT_FILENO)
    originalStandardError = dup(STDERR_FILENO)

    guard originalStandardOutput >= 0,
          originalStandardError >= 0,
          dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) >= 0,
          dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO) >= 0 else {
      isCapturing = false
      log(.error, category: "DeveloperConsole", "표준 출력 캡처를 시작하지 못했습니다")
      return
    }

    capturePipe = pipe
    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      self?.consume(data)
    }

    log(
      .info,
      category: "DeveloperConsole",
      "기기 로그 캡처 시작 session=\(sessionID) 최대=\(maximumEntryCount)줄 파일보호=활성 자동업로드=없음"
    )

    if previousSessionLikelyUnclean {
      log(
        .warning,
        category: "DeveloperConsole",
        "이전 세션이 정상 종료로 기록되지 않았습니다. 강제 종료 또는 크래시 가능성이 있습니다"
      )
    }
  }

  func present() {
    isPresented = true
    markAllRead()
  }

  func markAllRead() {
    unreadErrorCount = 0
  }

  func clear() {
    entries.removeAll(keepingCapacity: true)
    unreadErrorCount = 0

    parsingQueue.async { [weak self] in
      self?.resetPersistentDiagnostics()
    }
  }

  func log(
    _ level: DeveloperLogLevel,
    category: String,
    _ message: String,
    metadata: [String: String] = [:]
  ) {
    let metadataText = metadata
      .sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }
      .joined(separator: " ")

    let suffix = metadataText.isEmpty ? "" : " \(metadataText)"
    enqueue("[\(category)][\(levelToken(level))] \(message)\(suffix)", forcedLevel: level)
  }

  func record(
    error: Error,
    category: String,
    operation: String,
    metadata: [String: String] = [:]
  ) {
    let nsError = error as NSError
    var details = metadata
    details["operation"] = operation
    details["domain"] = nsError.domain
    details["code"] = String(nsError.code)
    details["description"] = nsError.localizedDescription

    if !nsError.userInfo.isEmpty {
      details["userInfo"] = String(describing: nsError.userInfo)
    }

    log(.error, category: category, "작업 실패", metadata: details)
  }

  func exportText(entries selectedEntries: [DeveloperLogEntry]? = nil) -> String {
    let target = selectedEntries ?? entries
    guard !target.isEmpty else { return "기록된 로그가 없습니다." }

    return target.map { entry in
      "[\(Self.fullTimestampFormatter.string(from: entry.timestamp))] [\(entry.level.rawValue)] \(entry.message)"
    }.joined(separator: "\n")
  }

  @MainActor
  func makeDiagnosticReport(entries selectedEntries: [DeveloperLogEntry]? = nil) throws -> URL {
    flushPersistentLog()

    let target = selectedEntries ?? entries
    let reportURL = try makeExportURL()
    let appInfo = Self.applicationInformation()
    let deviceInfo = Self.deviceInformation()
    let screenInfo = Self.screenInformation()
    let processInfo = Self.processInformation()

    var sections: [String] = []
    sections.append(
      """
      TurboMeta TestFlight 진단 보고서
      ========================================
      생성 시각: \(Self.fullTimestampFormatter.string(from: Date()))
      세션 ID: \(sessionID)
      배포 채널: \(Self.distributionChannel())
      자동 업로드: 사용하지 않음
      이전 세션 비정상 종료 추정: \(previousSessionLikelyUnclean ? "예" : "아니오")
      """
    )

    sections.append(
      """
      [앱]
      \(appInfo)
      """
    )

    sections.append(
      """
      [기기]
      \(deviceInfo)
      """
    )

    sections.append(
      """
      [화면]
      \(screenInfo)
      """
    )

    sections.append(
      """
      [상태]
      \(processInfo)
      """
    )

    sections.append(
      """
      [AI 설정]
      이미지 제공자: \(APIProviderManager.staticCurrentProvider.displayName)
      이미지 모델: \(APIProviderManager.staticCurrentModel)
      Alibaba 지역: \(APIProviderManager.staticAlibabaEndpoint.displayName)
      """
    )

    sections.append(
      """
      [보안 안내]
      API Key, Bearer 토큰, Gateway 토큰, RTMP 송출 경로와 대용량 Base64 데이터는 자동으로 마스킹됩니다.
      MetricKit 진단과 오류 문구에는 재현에 필요한 사용자 화면의 텍스트 또는 AI 응답이 포함될 수 있습니다.
      이 파일은 사용자가 공유 버튼을 누를 때만 외부로 전달됩니다.
      """
    )

    sections.append(
      """
      [현재 세션 로그 \(target.count)줄]
      \(exportText(entries: target))
      """
    )

    if let rotated = readTextFile(rotatedLogURL, maximumBytes: 700_000), !rotated.isEmpty {
      sections.append(
        """
        [현재 세션 이전 구간]
        \(rotated)
        """
      )
    }

    if let previous = readTextFile(lastSessionLogURL, maximumBytes: 900_000), !previous.isEmpty {
      sections.append(
        """
        [직전 앱 세션]
        \(previous)
        """
      )
    }

    let metricPayloads = metricPayloadTexts()
    if !metricPayloads.isEmpty {
      sections.append(
        """
        [MetricKit 진단 \(metricPayloads.count)개]
        \(metricPayloads.joined(separator: "\n\n--- MetricKit payload ---\n\n"))
        """
      )
    }

    let report = SensitiveDataRedactor.redact(sections.joined(separator: "\n\n") + "\n")
    try report.write(to: reportURL, atomically: true, encoding: .utf8)
    applyFileProtection(to: reportURL)
    cleanupOldExports()
    return reportURL
  }

  // MARK: Capture pipeline

  private func mirrorToXcodeConsole(_ data: Data) {
    let descriptor = originalStandardOutput >= 0 ? originalStandardOutput : originalStandardError
    guard descriptor >= 0 else { return }

    data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else { return }
      _ = Darwin.write(descriptor, baseAddress, rawBuffer.count)
    }
  }

  private func consume(_ data: Data) {
    parsingQueue.async { [weak self] in
      guard let self,
            let text = String(data: data, encoding: .utf8) else { return }

      pendingText.append(text)

      while let newlineRange = pendingText.rangeOfCharacter(from: .newlines) {
        let line = String(pendingText[..<newlineRange.lowerBound])
        pendingText.removeSubrange(pendingText.startIndex...newlineRange.lowerBound)
        enqueue(line)
      }

      if pendingText.utf8.count > 8_192 {
        let line = pendingText
        pendingText.removeAll(keepingCapacity: true)
        enqueue(line)
      }
    }
  }

  private func enqueue(_ rawLine: String, forcedLevel: DeveloperLogLevel? = nil) {
    let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    let redacted = SensitiveDataRedactor.redact(trimmed)
    let limited: String
    if redacted.count > maximumLineLength {
      limited = String(redacted.prefix(maximumLineLength)) + " … <한 줄 최대 길이 초과로 생략>"
    } else {
      limited = redacted
    }

    let level = forcedLevel ?? Self.classify(limited)
    let timestamp = Date()
    if let mirrored = (limited + "\n").data(using: .utf8) {
      mirrorToXcodeConsole(mirrored)
    }
    persist(timestamp: timestamp, level: level, message: limited)

    DispatchQueue.main.async { [weak self] in
      self?.appendToScreen(timestamp: timestamp, message: limited, level: level)
    }
  }

  private func appendToScreen(timestamp: Date, message: String, level: DeveloperLogLevel) {
    entries.append(DeveloperLogEntry(timestamp: timestamp, level: level, message: message))

    if entries.count > maximumEntryCount {
      entries.removeFirst(entries.count - maximumEntryCount)
    }

    if level == .error && !isPresented {
      unreadErrorCount += 1
    }
  }

  private static func classify(_ text: String) -> DeveloperLogLevel {
    let lowercased = text.lowercased()
    let errorTokens = [
      "[error]", "error:", " error ", "failed", "failure", "exception",
      "socket is not connected", "fatal", "crash", "❌", "실패", "오류"
    ]
    if errorTokens.contains(where: lowercased.contains) {
      return .error
    }

    let warningTokens = [
      "[warn]", "[warning]", "warning", "⚠️", "경고", "주의",
      "timeout", "timed out", "시간 초과", "취소됨"
    ]
    if warningTokens.contains(where: lowercased.contains) {
      return .warning
    }

    return .info
  }

  private func levelToken(_ level: DeveloperLogLevel) -> String {
    switch level {
    case .info: return "INFO"
    case .warning: return "WARN"
    case .error: return "ERROR"
    }
  }

  // MARK: Persistent storage

  private func preparePersistentStorage() {
    do {
      let fileManager = FileManager.default
      let applicationSupport = try fileManager.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      let root = applicationSupport.appendingPathComponent("TurboMetaDiagnostics", isDirectory: true)
      try fileManager.createDirectory(
        at: root,
        withIntermediateDirectories: true,
        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
      )
      excludeFromBackup(root)

      let current = root.appendingPathComponent("session-current.log")
      let last = root.appendingPathComponent("session-last.log")
      let rotated = root.appendingPathComponent("session-current-older.log")
      let metrics = root.appendingPathComponent("MetricKit", isDirectory: true)
      let exports = FileManager.default.temporaryDirectory
        .appendingPathComponent("TurboMetaDiagnosticExports", isDirectory: true)

      try fileManager.createDirectory(
        at: metrics,
        withIntermediateDirectories: true,
        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
      )
      try fileManager.createDirectory(at: exports, withIntermediateDirectories: true)
      excludeFromBackup(metrics)

      try? persistentHandle?.close()
      persistentHandle = nil

      if fileManager.fileExists(atPath: last.path) {
        try? fileManager.removeItem(at: last)
      }
      if fileManager.fileExists(atPath: current.path) {
        try fileManager.moveItem(at: current, to: last)
      }
      if fileManager.fileExists(atPath: rotated.path) {
        try? fileManager.removeItem(at: rotated)
      }

      let attributes: [FileAttributeKey: Any] = [
        .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
      ]
      fileManager.createFile(atPath: current.path, contents: nil, attributes: attributes)

      diagnosticsDirectoryURL = root
      currentLogURL = current
      lastSessionLogURL = last
      rotatedLogURL = rotated
      metricsDirectoryURL = metrics
      exportDirectoryURL = exports
      persistentHandle = try FileHandle(forWritingTo: current)
      persistentHandle?.seekToEndOfFile()
      persistentBytesWritten = 0

      let defaults = UserDefaults.standard
      if defaults.object(forKey: sessionStateKey) != nil {
        previousSessionLikelyUnclean = !defaults.bool(forKey: sessionStateKey)
      } else {
        previousSessionLikelyUnclean = false
      }
      defaults.set(false, forKey: sessionStateKey)
    } catch {
      let nsError = error as NSError
      DispatchQueue.main.async { [weak self] in
        self?.appendToScreen(
          timestamp: Date(),
          message: "[DeveloperConsole][ERROR] 로그 파일 준비 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)",
          level: .error
        )
      }
    }
  }

  private func persist(timestamp: Date, level: DeveloperLogLevel, message: String) {
    let line = "[\(Self.fullTimestampFormatter.string(from: timestamp))] [\(level.rawValue)] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }

    parsingQueue.async { [weak self] in
      guard let self else { return }
      rotatePersistentFileIfNeeded(adding: UInt64(data.count))
      persistentHandle?.write(data)
      persistentBytesWritten += UInt64(data.count)
    }
  }

  private func rotatePersistentFileIfNeeded(adding byteCount: UInt64) {
    guard persistentBytesWritten + byteCount > maximumPersistentFileBytes,
          let currentLogURL,
          let rotatedLogURL else { return }

    try? persistentHandle?.synchronize()
    try? persistentHandle?.close()
    persistentHandle = nil

    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: rotatedLogURL.path) {
      try? fileManager.removeItem(at: rotatedLogURL)
    }
    if fileManager.fileExists(atPath: currentLogURL.path) {
      try? fileManager.moveItem(at: currentLogURL, to: rotatedLogURL)
    }

    let attributes: [FileAttributeKey: Any] = [
      .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
    ]
    fileManager.createFile(atPath: currentLogURL.path, contents: nil, attributes: attributes)
    persistentHandle = try? FileHandle(forWritingTo: currentLogURL)
    persistentHandle?.seekToEndOfFile()
    persistentBytesWritten = 0
  }

  private func flushPersistentLog() {
    parsingQueue.sync {
      try? persistentHandle?.synchronize()
    }
  }

  private func resetPersistentDiagnostics() {
    try? persistentHandle?.close()
    persistentHandle = nil

    let fileManager = FileManager.default
    [currentLogURL, lastSessionLogURL, rotatedLogURL].compactMap { $0 }.forEach {
      try? fileManager.removeItem(at: $0)
    }

    if let metricsDirectoryURL,
       let metricFiles = try? fileManager.contentsOfDirectory(
         at: metricsDirectoryURL,
         includingPropertiesForKeys: nil
       ) {
      for file in metricFiles {
        try? fileManager.removeItem(at: file)
      }
    }

    guard let currentLogURL else { return }
    let attributes: [FileAttributeKey: Any] = [
      .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
    ]
    fileManager.createFile(atPath: currentLogURL.path, contents: nil, attributes: attributes)
    persistentHandle = try? FileHandle(forWritingTo: currentLogURL)
    persistentHandle?.seekToEndOfFile()
    persistentBytesWritten = 0
  }

  private func applyFileProtection(to url: URL) {
    try? FileManager.default.setAttributes(
      [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
      ofItemAtPath: url.path
    )
  }

  private func excludeFromBackup(_ url: URL) {
    var mutableURL = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? mutableURL.setResourceValues(values)
  }

  private func readTextFile(_ url: URL?, maximumBytes: Int) -> String? {
    guard let url,
          let data = try? Data(contentsOf: url),
          !data.isEmpty else { return nil }

    let limitedData: Data
    if data.count > maximumBytes {
      limitedData = data.suffix(maximumBytes)
    } else {
      limitedData = data
    }

    return String(data: limitedData, encoding: .utf8)
  }

  private func makeExportURL() throws -> URL {
    guard let exportDirectoryURL else {
      throw DeveloperConsoleError.exportDirectoryUnavailable
    }

    try FileManager.default.createDirectory(
      at: exportDirectoryURL,
      withIntermediateDirectories: true
    )

    let name = "TurboMeta-TestFlight-\(Self.fileTimestampFormatter.string(from: Date())).txt"
    return exportDirectoryURL.appendingPathComponent(name)
  }

  private func cleanupOldExports() {
    guard let exportDirectoryURL,
          let files = try? FileManager.default.contentsOfDirectory(
            at: exportDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
          ) else { return }

    let expiration = Date().addingTimeInterval(-maximumExportAge)
    for file in files {
      let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
      if let modified = values?.contentModificationDate, modified < expiration {
        try? FileManager.default.removeItem(at: file)
      }
    }
  }

  // MARK: Lifecycle and crash breadcrumbs

  private func installLifecycleObservers() {
    guard notificationTokens.isEmpty else { return }
    let center = NotificationCenter.default

    notificationTokens.append(
      center.addObserver(
        forName: UIApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        guard let self else { return }
        UserDefaults.standard.set(false, forKey: sessionStateKey)
        log(.info, category: "AppLifecycle", "앱 활성화")
      }
    )

    notificationTokens.append(
      center.addObserver(
        forName: UIApplication.didEnterBackgroundNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        guard let self else { return }
        UserDefaults.standard.set(true, forKey: sessionStateKey)
        log(.info, category: "AppLifecycle", "백그라운드 진입")
        flushPersistentLog()
      }
    )

    notificationTokens.append(
      center.addObserver(
        forName: UIApplication.willTerminateNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        guard let self else { return }
        UserDefaults.standard.set(true, forKey: sessionStateKey)
        log(.info, category: "AppLifecycle", "앱 정상 종료 알림 수신")
        flushPersistentLog()
      }
    )
  }

  private func installUncaughtExceptionHandler() {
    NSSetUncaughtExceptionHandler { exception in
      DeveloperConsole.shared.persistUncaughtException(exception)
    }
  }

  private func persistUncaughtException(_ exception: NSException) {
    let stack = exception.callStackSymbols.joined(separator: " | ")
    let message = SensitiveDataRedactor.redact(
      "[UncaughtException][ERROR] name=\(exception.name.rawValue) reason=\(exception.reason ?? "-") stack=\(stack)"
    )
    persistEmergencyLine(message)
  }

  private func persistEmergencyLine(_ message: String) {
    guard let currentLogURL,
          let data = "[\(Self.fullTimestampFormatter.string(from: Date()))] [오류] \(message)\n"
            .data(using: .utf8) else { return }

    do {
      let handle = try FileHandle(forWritingTo: currentLogURL)
      handle.seekToEndOfFile()
      handle.write(data)
      try handle.synchronize()
      try handle.close()
    } catch {
      // A crash path must not trigger a second exception through logging.
    }
  }

  // MARK: MetricKit

  private func startMetricKitCollection() {
    #if canImport(MetricKit)
    if #available(iOS 14.0, *) {
      DeveloperMetricKitSubscriber.shared.start(directoryURL: metricsDirectoryURL)
    }
    #endif
  }

  private func metricPayloadTexts() -> [String] {
    guard let metricsDirectoryURL,
          let files = try? FileManager.default.contentsOfDirectory(
            at: metricsDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
          ) else { return [] }

    return files
      .sorted { lhs, rhs in
        let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return leftDate < rightDate
      }
      .suffix(8)
      .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
      .map(SensitiveDataRedactor.redact)
  }

  // MARK: Diagnostic metadata

  @MainActor
  private static func applicationInformation() -> String {
    let dictionary = Bundle.main.infoDictionary ?? [:]
    let name = dictionary["CFBundleDisplayName"] as? String
      ?? dictionary["CFBundleName"] as? String
      ?? "TurboMeta"
    let version = dictionary["CFBundleShortVersionString"] as? String ?? "-"
    let build = dictionary["CFBundleVersion"] as? String ?? "-"
    let bundleID = Bundle.main.bundleIdentifier ?? "-"

    return """
    이름: \(name)
    버전: \(version) (\(build))
    Bundle ID: \(bundleID)
    """
  }

  @MainActor
  private static func deviceInformation() -> String {
    let identifier = machineIdentifier()
    let marketingName = marketingDeviceName(for: identifier)
    let device = UIDevice.current

    return """
    모델: \(marketingName) (\(identifier))
    시스템: \(device.systemName) \(device.systemVersion)
    Locale: \(Locale.current.identifier)
    시간대: \(TimeZone.current.identifier)
    """
  }

  @MainActor
  private static func screenInformation() -> String {
    let screen = UIScreen.main
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
      ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first
    let insets = window?.safeAreaInsets ?? .zero
    let orientation = scene.map { orientationName($0.interfaceOrientation) } ?? "알 수 없음"

    return """
    포인트: \(Int(screen.bounds.width)) x \(Int(screen.bounds.height))
    실제 픽셀: \(Int(screen.nativeBounds.width)) x \(Int(screen.nativeBounds.height))
    배율: \(screen.scale) / native \(screen.nativeScale)
    안전 영역: top \(Int(insets.top)), left \(Int(insets.left)), bottom \(Int(insets.bottom)), right \(Int(insets.right))
    방향: \(orientation)
    레이아웃 검증 기준: iPhone 13 390 x 844 포인트
    """
  }

  private static func processInformation() -> String {
    let info = ProcessInfo.processInfo
    let lowPower = info.isLowPowerModeEnabled ? "켜짐" : "꺼짐"
    let memory = ByteCountFormatter.string(
      fromByteCount: Int64(info.physicalMemory),
      countStyle: .memory
    )

    return """
    저전력 모드: \(lowPower)
    발열 상태: \(thermalStateName(info.thermalState))
    물리 메모리: \(memory)
    시스템 가동 시간: \(Int(info.systemUptime))초
    """
  }

  private static func distributionChannel() -> String {
    #if DEBUG
    return "Xcode Debug"
    #elseif TESTFLIGHT_TTS_DIAGNOSTICS
    let receiptName = Bundle.main.appStoreReceiptURL?.lastPathComponent ?? "-"
    return receiptName == "sandboxReceipt" ? "TestFlight / Sandbox" : "내부 Release"
    #else
    return "App Store Release"
    #endif
  }

  private static func machineIdentifier() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)
    return withUnsafePointer(to: &systemInfo.machine) {
      $0.withMemoryRebound(to: CChar.self, capacity: 1) {
        String(cString: $0)
      }
    }
  }

  @MainActor
  private static func marketingDeviceName(for identifier: String) -> String {
    switch identifier {
    case "iPhone14,4": return "iPhone 13 mini"
    case "iPhone14,5": return "iPhone 13"
    case "iPhone14,2": return "iPhone 13 Pro"
    case "iPhone14,3": return "iPhone 13 Pro Max"
    case "arm64", "x86_64": return "iOS Simulator"
    default: return UIDevice.current.model
    }
  }

  private static func orientationName(_ orientation: UIInterfaceOrientation) -> String {
    switch orientation {
    case .portrait: return "세로"
    case .portraitUpsideDown: return "세로 뒤집힘"
    case .landscapeLeft: return "가로 왼쪽"
    case .landscapeRight: return "가로 오른쪽"
    case .unknown: return "알 수 없음"
    @unknown default: return "알 수 없음"
    }
  }

  private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: return "정상"
    case .fair: return "약간 높음"
    case .serious: return "높음"
    case .critical: return "위험"
    @unknown default: return "알 수 없음"
    }
  }

  private static let fullTimestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ko_KR")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZ"
    return formatter
  }()

  private static let fileTimestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter
  }()
}

enum DeveloperConsoleError: LocalizedError {
  case exportDirectoryUnavailable

  var errorDescription: String? {
    switch self {
    case .exportDirectoryUnavailable:
      return "진단 파일을 만들 임시 폴더를 준비하지 못했습니다"
    }
  }
}

#if canImport(MetricKit)
@available(iOS 14.0, *)
private final class DeveloperMetricKitSubscriber: NSObject, MXMetricManagerSubscriber {
  static let shared = DeveloperMetricKitSubscriber()

  private var directoryURL: URL?
  private var isStarted = false

  func start(directoryURL: URL?) {
    self.directoryURL = directoryURL
    guard !isStarted else { return }
    isStarted = true
    MXMetricManager.shared.add(self)
  }

  func didReceive(_ payloads: [MXMetricPayload]) {
    save(payloads.map { $0.jsonRepresentation() }, prefix: "metric")
  }

  func didReceive(_ payloads: [MXDiagnosticPayload]) {
    save(payloads.map { $0.jsonRepresentation() }, prefix: "diagnostic")
  }

  private func save(_ payloads: [Data], prefix: String) {
    guard let directoryURL else { return }

    let formatter = ISO8601DateFormatter()
    let fileManager = FileManager.default

    for (index, payload) in payloads.enumerated() {
      guard let text = String(data: payload, encoding: .utf8),
            let redactedPayload = SensitiveDataRedactor.redact(text).data(using: .utf8) else {
        continue
      }

      let timestamp = formatter.string(from: Date())
        .replacingOccurrences(of: ":", with: "-")
      let url = directoryURL
        .appendingPathComponent("\(prefix)-\(timestamp)-\(index).json")

      try? redactedPayload.write(to: url, options: .atomic)
      try? fileManager.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: url.path
      )
    }

    trimOldFiles()
  }

  private func trimOldFiles() {
    guard let directoryURL,
          let files = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
          ) else { return }

    let sorted = files.sorted { lhs, rhs in
      let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
      let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
      return left > right
    }

    for file in sorted.dropFirst(8) {
      try? FileManager.default.removeItem(at: file)
    }
  }
}
#endif

// MARK: - iPhone 13 sized log screen

private enum DeveloperLogFilter: String, CaseIterable, Identifiable {
  case all = "전체"
  case errors = "오류"
  case warnings = "경고"

  var id: String { rawValue }
}

struct DeveloperConsoleButton: View {
  @ObservedObject var console: DeveloperConsole

  var body: some View {
    Button {
      console.present()
    } label: {
      ZStack(alignment: .topTrailing) {
        Image(systemName: "terminal.fill")
          .font(.system(size: 17, weight: .semibold))
          .foregroundColor(.white)
          .frame(width: 44, height: 44)
          .background(Color.black.opacity(0.84))
          .clipShape(Circle())
          .shadow(radius: 5)

        if console.unreadErrorCount > 0 {
          Text(console.unreadErrorCount > 99 ? "99+" : "\(console.unreadErrorCount)")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .background(Color.red)
            .clipShape(Capsule())
            .offset(x: 6, y: -5)
        }
      }
    }
    .accessibilityLabel("개발자 로그 열기")
  }
}

struct DeveloperLogView: View {
  @ObservedObject var console: DeveloperConsole
  @Environment(\.dismiss) private var dismiss

  @State private var selectedFilter: DeveloperLogFilter = .all
  @State private var searchText = ""
  @State private var autoScroll = true
  @State private var showShareConfirmation = false
  @State private var showShareSheet = false
  @State private var shareItems: [Any] = []
  @State private var exportErrorMessage = ""
  @State private var showExportError = false
  @State private var isPreparingExport = false
  @State private var showOpenClawDiagnosticComposer = false
  @State private var diagnosticUserMessage = ""
  @State private var isSendingOpenClawDiagnostic = false
  @State private var diagnosticErrorMessage = ""
  @State private var showDiagnosticError = false

  private var filteredEntries: [DeveloperLogEntry] {
    console.entries.filter { entry in
      let levelMatches: Bool
      switch selectedFilter {
      case .all: levelMatches = true
      case .errors: levelMatches = entry.level == .error
      case .warnings: levelMatches = entry.level == .warning
      }

      let searchMatches = searchText.isEmpty
        || entry.message.localizedCaseInsensitiveContains(searchText)
      return levelMatches && searchMatches
    }
  }

  private var errorCount: Int {
    console.entries.lazy.filter { $0.level == .error }.count
  }

  private var warningCount: Int {
    console.entries.lazy.filter { $0.level == .warning }.count
  }

  private var diagnosticLineCount: Int {
    (try? OpenClawDiagnosticReportBuilder.makePrompt(
      userMessage: "진단 미리보기",
      entries: console.entries
    ))?
    .components(separatedBy: .newlines)
    .filter { $0.hasPrefix("[") && $0.contains("][") }
    .count ?? 0
  }

  var body: some View {
    NavigationStack {
      GeometryReader { geometry in
        let compact = geometry.size.width <= 400

        VStack(spacing: 0) {
          summaryHeader(compact: compact)
          filterControls(compact: compact)
          Divider()
          logList(compact: compact)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
          actionBar(compact: compact)
        }
      }
      .navigationTitle("기기 진단 로그")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button("닫기") {
            console.isPresented = false
            dismiss()
          }
        }
      }
      .confirmationDialog(
        "TestFlight 진단 파일을 공유할까요?",
        isPresented: $showShareConfirmation,
        titleVisibility: .visible
      ) {
        Button("진단 파일 만들고 공유") {
          prepareDiagnosticExport()
        }
        Button("취소", role: .cancel) {}
      } message: {
        Text("비밀 키와 대용량 데이터는 자동으로 숨깁니다. MetricKit 진단과 오류 문구에는 사용자 화면의 텍스트 또는 AI 응답이 포함될 수 있으며, 파일은 자동 전송되지 않습니다.")
      }
      .alert("진단 파일 생성 실패", isPresented: $showExportError) {
        Button("확인", role: .cancel) {}
      } message: {
        Text(exportErrorMessage)
      }
      .sheet(isPresented: $showShareSheet) {
        DeveloperLogShareSheet(
          items: shareItems,
          subject: "TurboMeta TestFlight 진단 로그"
        )
      }
      .sheet(isPresented: $showOpenClawDiagnosticComposer) {
        OpenClawDiagnosticComposer(
          userMessage: $diagnosticUserMessage,
          isSending: isSendingOpenClawDiagnostic,
          diagnosticLineCount: diagnosticLineCount,
          onCancel: {
            showOpenClawDiagnosticComposer = false
          },
          onSend: sendDiagnosticToOpenClaw
        )
      }
      .alert("openclaw.diagnostic.error.title".localized, isPresented: $showDiagnosticError) {
        Button("ok".localized, role: .cancel) {}
      } message: {
        Text(diagnosticErrorMessage)
      }
      .onAppear {
        console.markAllRead()
      }
    }
  }

  @ViewBuilder
  private func summaryHeader(compact: Bool) -> some View {
    VStack(alignment: .leading, spacing: compact ? 7 : 9) {
      HStack(spacing: 6) {
        countChip(title: "전체", count: console.entries.count, level: .info)
        countChip(title: "경고", count: warningCount, level: .warning)
        countChip(title: "오류", count: errorCount, level: .error)
        Spacer(minLength: 4)

        if isPreparingExport {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("진단 파일 만드는 중")
        }
      }

      Text("오류를 재현한 뒤 아래의 ‘진단 파일’ 버튼으로 메일, AirDrop 또는 파일 앱에 공유할 수 있습니다.")
        .font(.system(size: compact ? 11 : 12))
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, compact ? 10 : 14)
    .padding(.vertical, compact ? 8 : 10)
    .background(Color(.secondarySystemBackground))
  }

  private func countChip(
    title: String,
    count: Int,
    level: DeveloperLogLevel
  ) -> some View {
    HStack(spacing: 4) {
      Image(systemName: level.symbolName)
      Text("\(title) \(count)")
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
    .font(.system(size: 11, weight: .semibold))
    .foregroundColor(level.color)
    .padding(.horizontal, 8)
    .frame(height: 28)
    .background(level.color.opacity(0.10))
    .clipShape(Capsule())
  }

  @ViewBuilder
  private func filterControls(compact: Bool) -> some View {
    VStack(spacing: compact ? 7 : 9) {
      Picker("로그 필터", selection: $selectedFilter) {
        ForEach(DeveloperLogFilter.allCases) { filter in
          Text(filter.rawValue).tag(filter)
        }
      }
      .pickerStyle(.segmented)

      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundColor(.secondary)

        TextField("로그 검색", text: $searchText)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .submitLabel(.search)

        if !searchText.isEmpty {
          Button {
            searchText = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundColor(.secondary)
          }
          .accessibilityLabel("검색어 지우기")
        }

        Divider().frame(height: 20)

        Button {
          autoScroll.toggle()
        } label: {
          Image(
            systemName: autoScroll
              ? "arrow.down.to.line.circle.fill"
              : "arrow.down.to.line.circle"
          )
          .foregroundColor(autoScroll ? .blue : .secondary)
        }
        .accessibilityLabel(autoScroll ? "자동 스크롤 끄기" : "자동 스크롤 켜기")
      }
      .padding(.horizontal, 10)
      .frame(height: compact ? 36 : 40)
      .background(Color(.secondarySystemBackground))
      .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    .padding(.horizontal, compact ? 10 : 14)
    .padding(.vertical, compact ? 8 : 10)
  }

  @ViewBuilder
  private func logList(compact: Bool) -> some View {
    if filteredEntries.isEmpty {
      ContentUnavailableView(
        "표시할 로그가 없습니다",
        systemImage: "terminal",
        description: Text("필터를 바꾸거나 기능을 다시 실행하세요")
      )
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(filteredEntries) { entry in
              DeveloperLogRow(entry: entry, compact: compact)
                .id(entry.id)
              Divider()
            }
          }
        }
        .background(Color(.systemBackground))
        .onChange(of: console.entries.count) { _ in
          guard autoScroll, let last = filteredEntries.last else { return }
          DispatchQueue.main.async {
            proxy.scrollTo(last.id, anchor: .bottom)
          }
        }
        .onAppear {
          guard autoScroll, let last = filteredEntries.last else { return }
          DispatchQueue.main.async {
            proxy.scrollTo(last.id, anchor: .bottom)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func actionBar(compact: Bool) -> some View {
    HStack(spacing: 8) {
      Button {
        UIPasteboard.general.string = console.exportText(entries: filteredEntries)
      } label: {
        Label("복사", systemImage: "doc.on.doc")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)

      Button {
        showShareConfirmation = true
      } label: {
        Label(
          isPreparingExport ? "준비 중" : "진단 파일",
          systemImage: "square.and.arrow.up"
        )
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .disabled(isPreparingExport)

      Menu {
        Button {
          diagnosticUserMessage = ""
          showOpenClawDiagnosticComposer = true
        } label: {
          Label(
            "openclaw.diagnostic.button".localized,
            systemImage: "stethoscope"
          )
        }
        .disabled(isSendingOpenClawDiagnostic)

        Button {
          autoScroll.toggle()
        } label: {
          Label(
            autoScroll ? "자동 스크롤 끄기" : "자동 스크롤 켜기",
            systemImage: "arrow.down.to.line"
          )
        }

        Button(role: .destructive) {
          console.clear()
        } label: {
          Label("전체 로그 삭제", systemImage: "trash")
        }
      } label: {
        Label("더보기", systemImage: "ellipsis.circle")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
    }
    .font(.system(size: compact ? 12 : 14, weight: .semibold))
    .controlSize(compact ? .small : .regular)
    .padding(.horizontal, compact ? 10 : 14)
    .padding(.top, 8)
    .padding(.bottom, 8)
    .background(.ultraThinMaterial)
  }

  @MainActor
  private func sendDiagnosticToOpenClaw() {
    guard !isSendingOpenClawDiagnostic else { return }

    let prompt: String
    do {
      prompt = try OpenClawDiagnosticReportBuilder.makePrompt(
        userMessage: diagnosticUserMessage,
        entries: console.entries
      )
    } catch {
      diagnosticErrorMessage = error.localizedDescription
      showDiagnosticError = true
      return
    }

    isSendingOpenClawDiagnostic = true
    Task { @MainActor in
      do {
        _ = try await OpenClawNodeService.shared.analyzeDiagnosticReport(prompt)
        isSendingOpenClawDiagnostic = false
        showOpenClawDiagnosticComposer = false
        diagnosticUserMessage = ""
        console.isPresented = false
        dismiss()
        try? await Task.sleep(nanoseconds: 200_000_000)
        GalvisLaunchCoordinator.shared.requestOpenClawChat()
      } catch {
        isSendingOpenClawDiagnostic = false
        diagnosticErrorMessage = error.localizedDescription
        showDiagnosticError = true
      }
    }
  }

  @MainActor
  private func prepareDiagnosticExport() {
    guard !isPreparingExport else { return }
    isPreparingExport = true

    Task { @MainActor in
      await Task.yield()

      do {
        let url = try console.makeDiagnosticReport()
        shareItems = [url]
        isPreparingExport = false

        try? await Task.sleep(nanoseconds: 200_000_000)
        showShareSheet = true
      } catch {
        isPreparingExport = false
        exportErrorMessage = error.localizedDescription
        showExportError = true
      }
    }
  }
}

private struct OpenClawDiagnosticComposer: View {
  @Binding var userMessage: String
  let isSending: Bool
  let diagnosticLineCount: Int
  let onCancel: () -> Void
  let onSend: () -> Void

  @State private var showConfirmation = false

  private var normalizedMessage: String {
    userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("openclaw.diagnostic.message.title".localized) {
          TextEditor(text: $userMessage)
            .frame(minHeight: 150)
            .onChange(of: userMessage) { value in
              if value.count > OpenClawDiagnosticReportBuilder.maximumUserMessageLength {
                userMessage = String(
                  value.prefix(OpenClawDiagnosticReportBuilder.maximumUserMessageLength)
                )
              }
            }

          Text("openclaw.diagnostic.message.hint".localized)
            .font(.caption)
            .foregroundColor(.secondary)

          Text("\(userMessage.count)/\(OpenClawDiagnosticReportBuilder.maximumUserMessageLength)")
            .font(.caption.monospacedDigit())
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }

        Section("openclaw.diagnostic.scope.title".localized) {
          Label(
            "openclaw.diagnostic.scope.lines".localized(diagnosticLineCount),
            systemImage: "checkmark.shield"
          )
          Text("openclaw.diagnostic.scope.detail".localized)
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }
      .navigationTitle("openclaw.diagnostic.title".localized)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("cancel".localized, action: onCancel)
            .disabled(isSending)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button {
            showConfirmation = true
          } label: {
            if isSending {
              ProgressView()
            } else {
              Text("openclaw.diagnostic.review".localized)
            }
          }
          .disabled(normalizedMessage.isEmpty || diagnosticLineCount == 0 || isSending)
        }
      }
      .confirmationDialog(
        "openclaw.diagnostic.confirm.title".localized,
        isPresented: $showConfirmation,
        titleVisibility: .visible
      ) {
        Button("openclaw.diagnostic.confirm.send".localized) {
          onSend()
        }
        Button("cancel".localized, role: .cancel) {}
      } message: {
        Text("openclaw.diagnostic.confirm.message".localized)
      }
    }
  }
}

private struct DeveloperLogRow: View {
  let entry: DeveloperLogEntry
  let compact: Bool

  private static let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ko_KR")
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
  }()

  var body: some View {
    HStack(alignment: .top, spacing: compact ? 6 : 8) {
      Image(systemName: entry.level.symbolName)
        .font(.system(size: compact ? 11 : 12))
        .foregroundColor(entry.level.color)
        .padding(.top, 2)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(Self.formatter.string(from: entry.timestamp))
          Text(entry.level.rawValue)
            .fontWeight(.semibold)
        }
        .font(.system(size: compact ? 9 : 10, design: .monospaced))
        .foregroundColor(entry.level.color)

        Text(entry.message)
          .font(.system(size: compact ? 10 : 11, design: .monospaced))
          .foregroundColor(.primary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.horizontal, compact ? 8 : 10)
    .padding(.vertical, compact ? 6 : 7)
    .contentShape(Rectangle())
  }
}

private struct DeveloperLogShareSheet: UIViewControllerRepresentable {
  let items: [Any]
  let subject: String

  func makeUIViewController(context: Context) -> UIActivityViewController {
    let controller = UIActivityViewController(
      activityItems: items,
      applicationActivities: nil
    )
    controller.setValue(subject, forKey: "subject")
    return controller
  }

  func updateUIViewController(
    _ uiViewController: UIActivityViewController,
    context: Context
  ) {}
}

// MARK: - Existing mock-device debug menu

#if DEBUG
import MWDATMockDevice

struct DebugMenuView: View {
  @ObservedObject var debugMenuViewModel: DebugMenuViewModel

  var body: some View {
    HStack {
      Spacer()
      VStack {
        Spacer()
        Button(action: {
          debugMenuViewModel.showDebugMenu = true
        }) {
          Image(systemName: "ladybug.fill")
            .foregroundColor(.white)
            .padding()
            .background(.secondary)
            .clipShape(Circle())
            .shadow(radius: 4)
        }
        .accessibilityIdentifier("debug_menu_button")
        Spacer()
      }
      .padding(.trailing)
    }
  }
}
#endif
