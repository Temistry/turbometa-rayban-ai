/*
 * Developer console and debug menu.
 *
 * The in-app console is intentionally available in the internal/TestFlight build so
 * device-only failures can be inspected without attaching Xcode. Captured output is
 * kept in memory only and common credentials/base64 payloads are redacted.
 */

import Darwin
import Foundation
import SwiftUI
import UIKit

// MARK: - In-app developer console

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

final class DeveloperConsole: ObservableObject {
  static let shared = DeveloperConsole()

  @Published private(set) var entries: [DeveloperLogEntry] = []
  @Published private(set) var unreadErrorCount = 0
  @Published var isPresented = false

  private let maximumEntryCount = 2_000
  private let parsingQueue = DispatchQueue(label: "com.turbometa.developer-console")
  private var capturePipe: Pipe?
  private var originalStandardOutput: Int32 = -1
  private var originalStandardError: Int32 = -1
  private var pendingText = ""
  private var isCapturing = false

  private static let redactionRules: [(NSRegularExpression, String)] = {
    let definitions: [(String, String)] = [
      (#"(?i)(Bearer\s+)[A-Za-z0-9._~+\-/=]+"#, "$1<보안상 숨김>"),
      (#"(?i)((?:api[_ -]?key|apikey|client[_ -]?token|gateway[_ -]?token|access[_ -]?token|authorization|token)\s*[:=]\s*)[\"']?[^\s,\"'&]+"#, "$1<보안상 숨김>"),
      (#"(?i)([?&](?:token|key|api_key|apikey)=)[^&\s]+"#, "$1<보안상 숨김>"),
      (#"\bsk-[A-Za-z0-9_-]{8,}\b"#, "<보안상 숨김>"),
      (#"\bAIza[0-9A-Za-z_-]{20,}\b"#, "<보안상 숨김>"),
      (#"data:image/[^;\s]+;base64,[A-Za-z0-9+/=]+"#, "<이미지 데이터 생략>"),
      (#"(?i)(\"(?:audio|image|data)\"\s*:\s*\")[A-Za-z0-9+/=]{80,}(\")"#, "$1<대용량 데이터 생략>$2"),
      (#"(?<![A-Za-z0-9])[A-Za-z0-9+/]{256,}={0,2}(?![A-Za-z0-9])"#, "<대용량 데이터 생략>")
    ]

    return definitions.compactMap { pattern, replacement in
      guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
      return (regex, replacement)
    }
  }()

  private init() {}

  func startCapturing() {
    guard !isCapturing else { return }
    isCapturing = true

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
      appendDirect("표준 출력 캡처를 시작하지 못했습니다", level: .error)
      return
    }

    capturePipe = pipe
    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      self?.mirrorToXcodeConsole(data)
      self?.consume(data)
    }

    appendDirect("기기 로그 캡처 시작. 최대 \(maximumEntryCount)줄, 메모리 보관, 자격 증명 자동 마스킹", level: .info)
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
  }

  func exportText(entries selectedEntries: [DeveloperLogEntry]? = nil) -> String {
    let target = selectedEntries ?? entries
    guard !target.isEmpty else { return "기록된 로그가 없습니다." }

    return target.map { entry in
      "[\(Self.timestampFormatter.string(from: entry.timestamp))] [\(entry.level.rawValue)] \(entry.message)"
    }.joined(separator: "\n")
  }

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

      self.pendingText.append(text)

      while let newlineRange = self.pendingText.rangeOfCharacter(from: .newlines) {
        let line = String(self.pendingText[..<newlineRange.lowerBound])
        self.pendingText.removeSubrange(self.pendingText.startIndex...newlineRange.lowerBound)
        self.enqueue(line)
      }

      // A logger may omit a newline. Do not let a pathological payload grow forever.
      if self.pendingText.utf8.count > 8_192 {
        let line = self.pendingText
        self.pendingText.removeAll(keepingCapacity: true)
        self.enqueue(line)
      }
    }
  }

  private func enqueue(_ rawLine: String) {
    let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    let redacted = Self.redact(trimmed)
    let level = Self.classify(redacted)

    DispatchQueue.main.async { [weak self] in
      self?.appendDirect(redacted, level: level)
    }
  }

  private func appendDirect(_ message: String, level: DeveloperLogLevel) {
    entries.append(DeveloperLogEntry(timestamp: Date(), level: level, message: message))

    if entries.count > maximumEntryCount {
      entries.removeFirst(entries.count - maximumEntryCount)
    }

    if level == .error && !isPresented {
      unreadErrorCount += 1
    }
  }

  private static func redact(_ input: String) -> String {
    var output = input
    for (regex, replacement) in redactionRules {
      let range = NSRange(output.startIndex..<output.endIndex, in: output)
      output = regex.stringByReplacingMatches(in: output, range: range, withTemplate: replacement)
    }
    return output
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

    let warningTokens = ["[warn]", "warning", "⚠️", "경고", "주의", "timeout", "시간 초과"]
    if warningTokens.contains(where: lowercased.contains) {
      return .warning
    }

    return .info
  }

  private static let timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ko_KR")
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
  }()
}

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
          .font(.system(size: 18, weight: .semibold))
          .foregroundColor(.white)
          .frame(width: 48, height: 48)
          .background(Color.black.opacity(0.82))
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
  @State private var showShareSheet = false

  private var filteredEntries: [DeveloperLogEntry] {
    console.entries.filter { entry in
      let levelMatches: Bool
      switch selectedFilter {
      case .all: levelMatches = true
      case .errors: levelMatches = entry.level == .error
      case .warnings: levelMatches = entry.level == .warning
      }

      let searchMatches = searchText.isEmpty || entry.message.localizedCaseInsensitiveContains(searchText)
      return levelMatches && searchMatches
    }
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        VStack(spacing: 8) {
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

            if !searchText.isEmpty {
              Button {
                searchText = ""
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .foregroundColor(.secondary)
              }
            }

            Divider().frame(height: 20)

            Button {
              autoScroll.toggle()
            } label: {
              Image(systemName: autoScroll ? "arrow.down.to.line.circle.fill" : "arrow.down.to.line.circle")
                .foregroundColor(autoScroll ? .blue : .secondary)
            }
            .accessibilityLabel("자동 스크롤")
          }
          .padding(.horizontal, 10)
          .frame(height: 38)
          .background(Color(.secondarySystemBackground))
          .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)

        Divider()

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
                  DeveloperLogRow(entry: entry)
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
      .navigationTitle("개발자 로그 \(filteredEntries.count)")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button("닫기") {
            console.isPresented = false
            dismiss()
          }
        }

        ToolbarItemGroup(placement: .navigationBarTrailing) {
          Button {
            UIPasteboard.general.string = console.exportText(entries: filteredEntries)
          } label: {
            Image(systemName: "doc.on.doc")
          }
          .accessibilityLabel("로그 복사")

          Button {
            showShareSheet = true
          } label: {
            Image(systemName: "square.and.arrow.up")
          }
          .accessibilityLabel("로그 공유")

          Button(role: .destructive) {
            console.clear()
          } label: {
            Image(systemName: "trash")
          }
          .accessibilityLabel("로그 삭제")
        }
      }
      .sheet(isPresented: $showShareSheet) {
        DeveloperLogShareSheet(items: [console.exportText(entries: filteredEntries)])
      }
      .onAppear {
        console.markAllRead()
      }
    }
  }
}

private struct DeveloperLogRow: View {
  let entry: DeveloperLogEntry

  private static let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ko_KR")
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
  }()

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: entry.level.symbolName)
        .font(.system(size: 12))
        .foregroundColor(entry.level.color)
        .padding(.top, 2)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(Self.formatter.string(from: entry.timestamp))
          Text(entry.level.rawValue)
            .fontWeight(.semibold)
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundColor(entry.level.color)

        Text(entry.message)
          .font(.system(size: 11, design: .monospaced))
          .foregroundColor(.primary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
  }
}

private struct DeveloperLogShareSheet: UIViewControllerRepresentable {
  let items: [Any]

  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: items, applicationActivities: nil)
  }

  func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
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
