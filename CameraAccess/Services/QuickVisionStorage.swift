/*
 * 퀵비전 기록 저장 서비스
 *
 * 인식 결과와 썸네일은 사용자의 주변 환경을 담을 수 있으므로 UserDefaults 대신
 * iOS 파일 보호가 적용된 Application Support 영역에 저장한다.
 */

import Foundation

final class QuickVisionStorage {
    static let shared = QuickVisionStorage()

    private let fileManager = FileManager.default
    private let userDefaults = UserDefaults.standard
    private let legacyRecordsKey = "quickVisionRecords"
    private let maxRecords = 100
    private let storageURL: URL

    private init() {
        let baseDirectory = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory

        let protectedDirectory = baseDirectory.appendingPathComponent("TurboMeta", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: protectedDirectory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
        } catch {
            let nsError = error as NSError
            print("[QuickVisionStorage][ERROR] 보호 저장 폴더 생성 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")
        }

        storageURL = protectedDirectory.appendingPathComponent("quick-vision-records.json", isDirectory: false)
        migrateLegacyDataIfNeeded()
    }

    // MARK: - Save Record

    func saveRecord(_ record: QuickVisionRecord) {
        var records = loadAllRecords()
        records.insert(record, at: 0)

        if records.count > maxRecords {
            records = Array(records.prefix(maxRecords))
        }

        save(records, reason: "퀵비전 기록 추가")
    }

    // MARK: - Load Records

    func loadAllRecords() -> [QuickVisionRecord] {
        guard fileManager.fileExists(atPath: storageURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: storageURL)
            let records = try JSONDecoder().decode([QuickVisionRecord].self, from: data)
            print("[QuickVisionStorage][INFO] 퀵비전 기록 불러오기 성공 count=\(records.count) bytes=\(data.count)")
            return records
        } catch {
            let nsError = error as NSError
            print("[QuickVisionStorage][ERROR] 퀵비전 기록 불러오기 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription) path=\(storageURL.lastPathComponent)")
            return []
        }
    }

    func loadRecords(limit: Int = 20, offset: Int = 0) -> [QuickVisionRecord] {
        let allRecords = loadAllRecords()
        guard offset >= 0, limit > 0, offset < allRecords.count else {
            return []
        }

        let endIndex = min(offset + limit, allRecords.count)
        return Array(allRecords[offset..<endIndex])
    }

    // MARK: - Delete Records

    func deleteRecord(_ id: UUID) {
        var records = loadAllRecords()
        let previousCount = records.count
        records.removeAll { $0.id == id }

        guard records.count != previousCount else {
            print("[QuickVisionStorage][WARN] 삭제할 퀵비전 기록을 찾지 못했습니다")
            return
        }

        save(records, reason: "퀵비전 기록 삭제")
    }

    func deleteAllRecords() {
        do {
            if fileManager.fileExists(atPath: storageURL.path) {
                try fileManager.removeItem(at: storageURL)
            }
            userDefaults.removeObject(forKey: legacyRecordsKey)
            print("[QuickVisionStorage][INFO] 모든 퀵비전 기록 삭제 완료")
        } catch {
            let nsError = error as NSError
            print("[QuickVisionStorage][ERROR] 전체 퀵비전 기록 삭제 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")
        }
    }

    // MARK: - Get Record

    func getRecord(by id: UUID) -> QuickVisionRecord? {
        loadAllRecords().first { $0.id == id }
    }

    var recordCount: Int {
        loadAllRecords().count
    }

    // MARK: - Protected persistence

    private func save(_ records: [QuickVisionRecord], reason: String) {
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(
                to: storageURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            userDefaults.removeObject(forKey: legacyRecordsKey)
            print("[QuickVisionStorage][INFO] \(reason) 저장 성공 count=\(records.count) bytes=\(data.count) protection=completeUntilFirstUserAuthentication")
        } catch {
            let nsError = error as NSError
            print("[QuickVisionStorage][ERROR] \(reason) 저장 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")
        }
    }

    private func migrateLegacyDataIfNeeded() {
        guard !fileManager.fileExists(atPath: storageURL.path),
              let legacyData = userDefaults.data(forKey: legacyRecordsKey) else {
            return
        }

        do {
            let records = try JSONDecoder().decode([QuickVisionRecord].self, from: legacyData)
            let normalized = Array(records.prefix(maxRecords))
            let protectedData = try JSONEncoder().encode(normalized)
            try protectedData.write(
                to: storageURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            userDefaults.removeObject(forKey: legacyRecordsKey)
            print("[QuickVisionStorage][INFO] 기존 UserDefaults 퀵비전 기록을 보호 파일로 이전 완료 count=\(normalized.count) bytes=\(protectedData.count)")
        } catch {
            let nsError = error as NSError
            print("[QuickVisionStorage][ERROR] 기존 퀵비전 기록 이전 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")
        }
    }
}
