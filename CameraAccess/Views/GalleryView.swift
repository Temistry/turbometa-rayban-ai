/*
 * OpenClaw 보호 미디어 갤러리
 */

import AVKit
import SwiftUI
import UIKit

@MainActor
final class OpenClawGalleryViewModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case all
        case photo
        case video

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "gallery.filter.all".localized
            case .photo: return "gallery.filter.photo".localized
            case .video: return "gallery.filter.video".localized
            }
        }
    }

    @Published private(set) var items: [OpenClawMediaItem] = []
    @Published private(set) var thumbnails: [UUID: UIImage] = [:]
    @Published var filter: Filter = .all
    @Published var errorMessage: String?
    @Published private(set) var busyItemID: UUID?
    @Published private(set) var analysisRetrySucceededMessageID: UUID?

    private let repository: OpenClawMediaRepository
    private let photoLibrarySaver: PhotoLibrarySaver
    private let openClawService: OpenClawNodeService

    init(
        repository: OpenClawMediaRepository = .shared,
        photoLibrarySaver: PhotoLibrarySaver? = nil,
        openClawService: OpenClawNodeService = .shared
    ) {
        self.repository = repository
        self.photoLibrarySaver = photoLibrarySaver ?? .shared
        self.openClawService = openClawService
    }

    var filteredItems: [OpenClawMediaItem] {
        switch filter {
        case .all:
            return items
        case .photo:
            return items.filter { $0.kind == .photo }
        case .video:
            return items.filter { $0.kind == .video }
        }
    }

    func load() async {
        do {
            let loaded = try await repository.listItems()
            items = loaded
            errorMessage = nil

            var loadedThumbnails: [UUID: UIImage] = [:]
            for item in loaded {
                if let data = try? await repository.thumbnailData(for: item),
                   let image = UIImage(data: data) {
                    loadedThumbnails[item.id] = image
                }
            }
            thumbnails = loadedThumbnails
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func originalURL(for item: OpenClawMediaItem) async -> URL? {
        let url = await repository.originalURL(for: item)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func originalPhoto(for item: OpenClawMediaItem) async -> UIImage? {
        guard item.kind == .photo,
              let data = try? await repository.originalData(for: item) else {
            return nil
        }
        return UIImage(data: data)
    }

    func retryPhotosExport(for item: OpenClawMediaItem) async {
        guard busyItemID == nil else { return }
        busyItemID = item.id
        defer { busyItemID = nil }

        do {
            _ = try await repository.updatePhotosStatus(id: item.id, status: .pending)
            switch item.kind {
            case .photo:
                let data = try await repository.originalData(for: item)
                _ = try await photoLibrarySaver.saveJPEG(data)
            case .video:
                let url = await repository.originalURL(for: item)
                _ = try await photoLibrarySaver.saveMP4(fileURL: url)
            }
            _ = try await repository.updatePhotosStatus(id: item.id, status: .saved)
            await load()
        } catch PhotoLibrarySaverError.permissionDenied,
                PhotoLibrarySaverError.permissionRestricted {
            _ = try? await repository.updatePhotosStatus(id: item.id, status: .permissionDenied)
            errorMessage = "gallery.error.photos.permission".localized
            await load()
        } catch {
            _ = try? await repository.updatePhotosStatus(id: item.id, status: .failed)
            errorMessage = error.localizedDescription
            await load()
        }
    }

    func retryAnalysis(for item: OpenClawMediaItem) async {
        guard busyItemID == nil else { return }
        busyItemID = item.id
        defer { busyItemID = nil }

        let requestID = UUID()
        let userMessageID = UUID()
        do {
            let jpegData: Data
            let prompt: String
            switch item.kind {
            case .photo:
                jpegData = try await repository.originalData(for: item)
                prompt = item.modeSnapshot.prompt
            case .video:
                guard let thumbnailData = try await repository.thumbnailData(for: item),
                      !thumbnailData.isEmpty else {
                    throw OpenClawConversationError.invalidImage
                }
                jpegData = thumbnailData
                prompt = videoRetryPrompt(for: item)
            }

            _ = try await repository.updateDeliveryStatus(
                id: item.id,
                status: .sending,
                retryAttempt: item.retryAttempt + 1
            )
            _ = try await repository.updateAnalysisStatus(id: item.id, status: .pending)

            let result = try await openClawService.sendConversation(
                prompt,
                imageJPEGData: jpegData,
                owner: .quickShot,
                requestID: requestID,
                idempotencyKey: requestID,
                userMessageID: userMessageID
            )
            _ = try await repository.updateDeliveryStatus(id: item.id, status: .delivered)
            _ = try await repository.updateAnalysisStatus(id: item.id, status: .completed)
            _ = try await repository.linkMessages(
                id: item.id,
                userMessageID: result.receipt.userMessageID,
                assistantMessageID: result.assistantMessageID
            )
            analysisRetrySucceededMessageID = result.assistantMessageID
            await load()
        } catch OpenClawConversationError.deliveryAmbiguous {
            _ = try? await repository.updateDeliveryStatus(id: item.id, status: .ambiguous)
            _ = try? await repository.updateAnalysisStatus(id: item.id, status: .failed)
            errorMessage = "gallery.error.analysis.ambiguous".localized
            await load()
        } catch {
            _ = try? await repository.updateDeliveryStatus(id: item.id, status: .failed)
            _ = try? await repository.updateAnalysisStatus(id: item.id, status: .failed)
            errorMessage = error.localizedDescription
            await load()
        }
    }

    func consumeAnalysisRetrySuccess() -> UUID? {
        defer { analysisRetrySucceededMessageID = nil }
        return analysisRetrySucceededMessageID
    }

    func delete(_ item: OpenClawMediaItem) async {
        guard busyItemID == nil else { return }
        busyItemID = item.id
        defer { busyItemID = nil }
        do {
            try await repository.deleteItem(id: item.id)
            items.removeAll { $0.id == item.id }
            thumbnails[item.id] = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func videoRetryPrompt(for item: OpenClawMediaItem) -> String {
        let duration = String(format: "%.1f", item.durationSeconds ?? 0)
        return item.modeSnapshot.prompt
            + "\n\n"
            + "gallery.video.retry.prompt".localized(duration)
    }
}

struct GalleryView: View {
    @StateObject private var viewModel = OpenClawGalleryViewModel()
    @State private var selectedItemID: UUID?

    private let columns = [
        GridItem(.adaptive(minimum: 104), spacing: AppSpacing.sm)
    ]

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.filteredItems.isEmpty {
                    emptyState
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVGrid(columns: columns, spacing: AppSpacing.sm) {
                            ForEach(viewModel.filteredItems) { item in
                                OpenClawMediaGridItem(
                                    item: item,
                                    thumbnail: viewModel.thumbnails[item.id]
                                )
                                .onTapGesture { selectedItemID = item.id }
                            }
                        }
                        .padding(AppSpacing.md)
                    }
                    .refreshable { await viewModel.load() }
                }
            }
            .background(AppColors.secondaryBackground.ignoresSafeArea())
            .navigationTitle("gallery.title".localized)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("gallery.filter.title".localized, selection: $viewModel.filter) {
                            ForEach(OpenClawGalleryViewModel.Filter.allCases) { filter in
                                Text(filter.title).tag(filter)
                            }
                        }
                    } label: {
                        Label("gallery.filter.title".localized, systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .navigationDestination(item: $selectedItemID) { itemID in
                OpenClawMediaDetailView(itemID: itemID, viewModel: viewModel)
            }
            .task { await viewModel.load() }
            .alert(
                "gallery.result.title".localized,
                isPresented: Binding(
                    get: {
                        viewModel.errorMessage != nil
                            || viewModel.analysisRetrySucceededMessageID != nil
                    },
                    set: { isPresented in
                        if !isPresented {
                            viewModel.errorMessage = nil
                            _ = viewModel.consumeAnalysisRetrySuccess()
                        }
                    }
                )
            ) {
                if viewModel.analysisRetrySucceededMessageID != nil {
                    Button("gallery.action.answer".localized) {
                        if let messageID = viewModel.consumeAnalysisRetrySuccess() {
                            GalvisLaunchCoordinator.shared.requestOpenClawChat(messageID: messageID)
                        }
                    }
                }
                Button("done".localized, role: .cancel) {
                    viewModel.errorMessage = nil
                    _ = viewModel.consumeAnalysisRetrySuccess()
                }
            } message: {
                Text(
                    viewModel.analysisRetrySucceededMessageID != nil
                        ? "gallery.analysis.completed.message".localized
                        : (viewModel.errorMessage ?? "")
                )
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: AppSpacing.lg) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 60))
                .foregroundColor(AppColors.textTertiary)
            Text("gallery.empty".localized)
                .font(AppTypography.title2)
                .foregroundColor(AppColors.textPrimary)
            Text("gallery.empty.hint".localized)
                .font(AppTypography.subheadline)
                .foregroundColor(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppSpacing.xl)
        }
    }
}

private struct OpenClawMediaGridItem: View {
    let item: OpenClawMediaItem
    let thumbnail: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color.secondary.opacity(0.12)
                        Image(systemName: item.kind == .video ? "video.slash" : "photo")
                            .font(.title)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fill)
            .clipped()

            LinearGradient(
                colors: [.clear, .black.opacity(0.72)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    if item.kind == .video {
                        Label(durationText, systemImage: "video.fill")
                    }
                    Spacer()
                    statusIcon
                }
                .font(.caption2.bold())
                Text(item.modeSnapshot.name)
                    .font(.caption.bold())
                    .lineLimit(1)
                Text(item.createdAt, style: .date)
                    .font(.caption2)
            }
            .foregroundStyle(.white)
            .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: AppCornerRadius.md)
                .stroke(AppColors.textTertiary.opacity(0.12), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var durationText: String {
        guard let duration = item.durationSeconds else { return "0:00" }
        let seconds = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.analysisStatus {
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .pending:
            ProgressView().tint(.white)
        case .failed:
            Image(systemName: item.deliveryStatus == .ambiguous ? "questionmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(item.deliveryStatus == .ambiguous ? .orange : .red)
        case .notRequested:
            Image(systemName: "circle.dashed")
        }
    }

    private var accessibilityLabel: String {
        let kind = item.kind == .photo
            ? "gallery.kind.photo".localized
            : "gallery.kind.video".localized
        return "gallery.item.accessibility".localized(kind, item.modeSnapshot.name)
    }
}

private struct OpenClawMediaDetailView: View {
    let itemID: UUID
    @ObservedObject var viewModel: OpenClawGalleryViewModel

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var launchCoordinator = GalvisLaunchCoordinator.shared
    @State private var item: OpenClawMediaItem?
    @State private var photo: UIImage?
    @State private var originalURL: URL?
    @State private var showDeleteConfirmation = false

    var body: some View {
        Group {
            if let item {
                ScrollView {
                    VStack(spacing: AppSpacing.lg) {
                        mediaPreview(item)
                        metadata(item)
                        actions(item)
                    }
                    .padding(AppSpacing.md)
                }
                .navigationTitle(item.modeSnapshot.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        if let originalURL {
                            ShareLink(item: originalURL) {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .accessibilityLabel("gallery.share".localized)
                        }
                    }
                }
                .confirmationDialog(
                    "gallery.delete.title".localized,
                    isPresented: $showDeleteConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("delete".localized, role: .destructive) {
                        Task {
                            await viewModel.delete(item)
                            dismiss()
                        }
                    }
                    Button("cancel".localized, role: .cancel) {}
                } message: {
                    Text("gallery.delete.message".localized)
                }
            } else {
                ContentUnavailableView(
                    "gallery.missing.title".localized,
                    systemImage: "exclamationmark.triangle",
                    description: Text("gallery.missing.message".localized)
                )
            }
        }
        .task(id: itemID) { await reload() }
        .onChange(of: viewModel.items) { _, _ in
            Task { await reload() }
        }
    }

    @ViewBuilder
    private func mediaPreview(_ item: OpenClawMediaItem) -> some View {
        switch item.kind {
        case .photo:
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.md))
            } else {
                missingPreview
            }
        case .video:
            if let originalURL {
                VideoPlayer(player: AVPlayer(url: originalURL))
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.md))
            } else {
                missingPreview
            }
        }
    }

    private var missingPreview: some View {
        ContentUnavailableView(
            "gallery.missing.media".localized,
            systemImage: "doc.questionmark",
            description: Text("gallery.missing.media.message".localized)
        )
        .frame(minHeight: 240)
    }

    private func metadata(_ item: OpenClawMediaItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("gallery.detail.captured".localized) {
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
            }
            HStack {
                Text("gallery.detail.mode".localized)
                Spacer()
                Text(item.modeSnapshot.name)
                    .foregroundStyle(.secondary)
            }
            if let duration = item.durationSeconds {
                LabeledContent(
                    "gallery.detail.duration".localized,
                    value: "gallery.detail.seconds".localized(duration)
                )
            }
            HStack {
                Text("gallery.detail.photos".localized)
                Spacer()
                Text(photosStatus(item.photosStatus))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("gallery.detail.analysis".localized)
                Spacer()
                Text(analysisStatus(item))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.md))
    }

    private func actions(_ item: OpenClawMediaItem) -> some View {
        VStack(spacing: 12) {
            if item.photosStatus != .saved {
                actionButton(
                    title: "gallery.action.photos.retry".localized,
                    icon: "photo.badge.plus"
                ) {
                    Task { await viewModel.retryPhotosExport(for: item) }
                }
            }

            if item.analysisStatus != .completed {
                actionButton(
                    title: item.deliveryStatus == .ambiguous
                        ? "gallery.action.analysis.retry.ambiguous".localized
                        : "gallery.action.analysis.retry".localized,
                    icon: "arrow.clockwise"
                ) {
                    Task { await viewModel.retryAnalysis(for: item) }
                }
            }

            if let messageID = item.linkedAssistantMessageID {
                actionButton(
                    title: "gallery.action.answer".localized,
                    icon: "bubble.left.and.bubble.right"
                ) {
                    launchCoordinator.requestOpenClawChat(messageID: messageID)
                }
            }

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("gallery.action.delete".localized, systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.busyItemID != nil)
        }
    }

    private func actionButton(
        title: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(viewModel.busyItemID != nil)
    }

    private func reload() async {
        guard let updated = viewModel.items.first(where: { $0.id == itemID }) else {
            item = nil
            photo = nil
            originalURL = nil
            return
        }
        item = updated
        originalURL = await viewModel.originalURL(for: updated)
        photo = await viewModel.originalPhoto(for: updated)
    }

    private func photosStatus(_ status: OpenClawMediaPhotosStatus) -> String {
        switch status {
        case .notRequested: return "gallery.status.photos.notrequested".localized
        case .pending: return "gallery.status.pending".localized
        case .saved: return "gallery.status.photos.saved".localized
        case .failed: return "gallery.status.failed".localized
        case .permissionDenied: return "gallery.status.photos.permission".localized
        }
    }

    private func analysisStatus(_ item: OpenClawMediaItem) -> String {
        if item.deliveryStatus == .ambiguous {
            return "gallery.status.analysis.ambiguous".localized
        }
        switch item.analysisStatus {
        case .notRequested: return "gallery.status.analysis.notrequested".localized
        case .pending: return "gallery.status.pending".localized
        case .completed: return "gallery.status.analysis.completed".localized
        case .failed: return "gallery.status.failed".localized
        }
    }
}
