/*
 * Quick Vision Models
 * 快速识图数据模型 - 识图模式和历史记录
 */

import Foundation
import UIKit

// MARK: - Quick Vision Mode

enum QuickVisionMode: String, CaseIterable, Codable, Identifiable {
    case standard = "standard"      // 默认模式
    case health = "health"          // 健康识图
    case blind = "blind"            // 盲人模式
    case reading = "reading"        // 阅读模式
    case translate = "translate"    // 翻译模式
    case encyclopedia = "encyclopedia" // 百科（博物馆）模式
    case custom = "custom"          // 自定义提示词

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard:
            return "quickvision.mode.standard".localized
        case .health:
            return "quickvision.mode.health".localized
        case .blind:
            return "quickvision.mode.blind".localized
        case .reading:
            return "quickvision.mode.reading".localized
        case .translate:
            return "quickvision.mode.translate".localized
        case .encyclopedia:
            return "quickvision.mode.encyclopedia".localized
        case .custom:
            return "quickvision.mode.custom".localized
        }
    }

    var icon: String {
        switch self {
        case .standard:
            return "eye.circle"
        case .health:
            return "heart.circle"
        case .blind:
            return "figure.walk.circle"
        case .reading:
            return "text.viewfinder"
        case .translate:
            return "character.bubble"
        case .encyclopedia:
            return "books.vertical.circle"
        case .custom:
            return "pencil.circle"
        }
    }

    var description: String {
        switch self {
        case .standard:
            return "quickvision.mode.standard.desc".localized
        case .health:
            return "quickvision.mode.health.desc".localized
        case .blind:
            return "quickvision.mode.blind.desc".localized
        case .reading:
            return "quickvision.mode.reading.desc".localized
        case .translate:
            return "quickvision.mode.translate.desc".localized
        case .encyclopedia:
            return "quickvision.mode.encyclopedia.desc".localized
        case .custom:
            return "quickvision.mode.custom.desc".localized
        }
    }

    /// 获取模式对应的提示词
    var prompt: String {
        switch self {
        case .standard:
            return "prompt.quickvision".localized
        case .health:
            return "prompt.quickvision.health".localized
        case .blind:
            return "prompt.quickvision.blind".localized
        case .reading:
            return "prompt.quickvision.reading".localized
        case .translate:
            // 翻译模式需要从 Manager 获取目标语言
            return "prompt.quickvision.translate".localized
        case .encyclopedia:
            return "prompt.quickvision.encyclopedia".localized
        case .custom:
            // 自定义模式需要从 Manager 获取
            return ""
        }
    }
}

// MARK: - Quick Vision Record

enum QuickVisionRecordStatus: String, Codable {
    case pending
    case succeeded
    case failed
    case rejected

    var isTerminal: Bool {
        self != .pending
    }

    var displayName: String {
        switch self {
        case .pending: return "진행 중"
        case .succeeded: return "완료"
        case .failed: return "실패"
        case .rejected: return "요청 거절"
        }
    }

    var systemImageName: String {
        switch self {
        case .pending: return "clock"
        case .succeeded: return "checkmark.circle.fill"
        case .failed, .rejected: return "exclamationmark.triangle.fill"
        }
    }
}

struct QuickVisionRecord: Identifiable, Codable {
    var id: UUID
    var timestamp: Date
    var mode: QuickVisionMode
    var prompt: String
    var result: String
    var thumbnailData: Data?
    var status: QuickVisionRecordStatus
    var errorCode: String?
    var errorMessage: String?
    var captureSource: String
    var metadata: [String: String]

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        mode: QuickVisionMode,
        prompt: String,
        result: String = "",
        thumbnail: UIImage? = nil,
        status: QuickVisionRecordStatus = .pending,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        captureSource: String = "none",
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.mode = mode
        self.prompt = prompt
        self.result = result
        self.status = status
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.captureSource = captureSource
        self.metadata = metadata
        self.thumbnailData = Self.makeThumbnailData(from: thumbnail)
    }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, mode, prompt, result, thumbnailData
        case status, errorCode, errorMessage, captureSource, metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        mode = try container.decode(QuickVisionMode.self, forKey: .mode)
        prompt = try container.decode(String.self, forKey: .prompt)
        result = try container.decode(String.self, forKey: .result)
        thumbnailData = try container.decodeIfPresent(Data.self, forKey: .thumbnailData)
        status = try container.decodeIfPresent(QuickVisionRecordStatus.self, forKey: .status) ?? .succeeded
        errorCode = try container.decodeIfPresent(String.self, forKey: .errorCode)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        captureSource = try container.decodeIfPresent(String.self, forKey: .captureSource) ?? "none"
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
    }

    mutating func setThumbnail(_ image: UIImage?) {
        thumbnailData = Self.makeThumbnailData(from: image)
    }

    private static func makeThumbnailData(from image: UIImage?) -> Data? {
        guard let image else { return nil }
        let size = CGSize(width: 100, height: 100)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: 0.5)
    }

    var thumbnail: UIImage? {
        guard let data = thumbnailData else { return nil }
        return UIImage(data: data)
    }

    var title: String {
        let content = displayContent
        return content.count > 30 ? String(content.prefix(30)) + "..." : content
    }

    var summary: String {
        let content = displayContent
        return content.count > 80 ? String(content.prefix(80)) + "..." : content
    }

    var displayContent: String {
        if !result.isEmpty { return result }
        if let errorMessage, !errorMessage.isEmpty { return errorMessage }
        return status == .pending ? "인식 준비 중입니다" : "인식 결과가 없습니다"
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        let calendar = Calendar.current

        if calendar.isDateInToday(timestamp) {
            formatter.dateFormat = "HH:mm"
            return "quickvision.today".localized + " " + formatter.string(from: timestamp)
        } else if calendar.isDateInYesterday(timestamp) {
            formatter.dateFormat = "HH:mm"
            return "quickvision.yesterday".localized + " " + formatter.string(from: timestamp)
        } else if calendar.isDate(timestamp, equalTo: Date(), toGranularity: .weekOfYear) {
            formatter.dateFormat = "EEEE HH:mm"
            return formatter.string(from: timestamp)
        } else {
            formatter.dateFormat = "MM-dd HH:mm"
            return formatter.string(from: timestamp)
        }
    }
}
