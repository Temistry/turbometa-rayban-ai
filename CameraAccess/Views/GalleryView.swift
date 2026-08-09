/*
 * 촬영 사진 갤러리
 */

import SwiftUI

struct GalleryView: View {
    @State private var photos: [GalleryPhoto] = []
    @State private var selectedPhoto: GalleryPhoto?
    @State private var showPhotoDetail = false

    private let columns = [
        GridItem(.flexible(), spacing: AppSpacing.sm),
        GridItem(.flexible(), spacing: AppSpacing.sm),
        GridItem(.flexible(), spacing: AppSpacing.sm)
    ]

    var body: some View {
        NavigationView {
            ZStack {
                AppColors.secondaryBackground.ignoresSafeArea()

                if photos.isEmpty {
                    VStack(spacing: AppSpacing.lg) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 60))
                            .foregroundColor(AppColors.textTertiary)

                        Text("gallery.empty".localized)
                            .font(AppTypography.title2)
                            .foregroundColor(AppColors.textPrimary)

                        Text("안경으로 촬영한 사진을 저장하면 여기에 표시됩니다")
                            .font(AppTypography.subheadline)
                            .foregroundColor(AppColors.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, AppSpacing.xl)
                    }
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVGrid(columns: columns, spacing: AppSpacing.sm) {
                            ForEach(photos) { photo in
                                PhotoGridItem(photo: photo)
                                    .onTapGesture {
                                        selectedPhoto = photo
                                        showPhotoDetail = true
                                    }
                            }
                        }
                        .padding(AppSpacing.md)
                    }
                }
            }
            .navigationTitle("gallery.title".localized)
            .sheet(isPresented: $showPhotoDetail) {
                if let selectedPhoto {
                    PhotoDetailView(photo: selectedPhoto)
                }
            }
        }
        .onAppear { loadPhotos() }
    }

    private func loadPhotos() {
        // 저장소 연동 전까지 빈 상태를 표시한다.
        photos = []
        print("[Gallery][INFO] 갤러리 저장소 연동 전 상태")
    }
}

struct GalleryPhoto: Identifiable {
    let id = UUID()
    let image: UIImage
    let timestamp: Date
    let aiDescription: String?
}

struct PhotoGridItem: View {
    let photo: GalleryPhoto

    var body: some View {
        GeometryReader { geometry in
            Image(uiImage: photo.image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: geometry.size.width, height: geometry.size.width)
                .clipped()
                .cornerRadius(AppCornerRadius.md)
                .overlay(
                    RoundedRectangle(cornerRadius: AppCornerRadius.md)
                        .stroke(AppColors.textTertiary.opacity(0.1), lineWidth: 1)
                )
                .shadow(color: AppShadow.small(), radius: 4, x: 0, y: 2)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

struct PhotoDetailView: View {
    let photo: GalleryPhoto
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    Image(uiImage: photo.image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if let description = photo.aiDescription {
                        VStack(alignment: .leading, spacing: AppSpacing.sm) {
                            Text("AI 인식")
                                .font(AppTypography.headline)
                                .foregroundColor(.white)

                            Text(description)
                                .font(AppTypography.body)
                                .foregroundColor(.white.opacity(0.9))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(AppSpacing.lg)
                        .background(Color.black.opacity(0.8))
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark").foregroundColor(.white)
                    }
                    .accessibilityLabel("닫기")
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { sharePhoto() } label: {
                        Image(systemName: "square.and.arrow.up").foregroundColor(.white)
                    }
                    .accessibilityLabel("사진 공유")
                }
            }
        }
    }

    private func sharePhoto() {
        let activityViewController = UIActivityViewController(
            activityItems: [photo.image],
            applicationActivities: nil
        )

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootViewController = windowScene.windows.first?.rootViewController {
            rootViewController.present(activityViewController, animated: true)
        }
    }
}
