/*
 * 일반 AI 이미지 인식 화면
 */

import SwiftUI

struct VisionRecognitionView: View {
    @StateObject private var viewModel: VisionRecognitionViewModel
    @Environment(\.dismiss) private var dismiss

    let photo: UIImage

    init(photo: UIImage, apiKey: String) {
        self.photo = photo
        self._viewModel = StateObject(wrappedValue: VisionRecognitionViewModel(photo: photo, apiKey: apiKey))
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    photoSection
                    promptSection
                    quickPromptsSection
                    analyzeButton
                    resultSection
                }
                .padding()
            }
            .navigationTitle("vision.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("close".localized) { dismiss() }
                }
            }
        }
    }

    private var photoSection: some View {
        Image(uiImage: photo)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxHeight: 300)
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.2), radius: 5, x: 0, y: 2)
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("질문 내용")
                .font(.headline)
                .foregroundColor(.primary)

            TextField("사진에 대해 물어볼 내용을 입력하세요", text: $viewModel.customPrompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
                .disabled(viewModel.isAnalyzing)
        }
    }

    private var quickPromptsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("빠른 질문")
                .font(.headline)
                .foregroundColor(.primary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(VisionRecognitionViewModel.quickPrompts, id: \.self) { prompt in
                        Button {
                            viewModel.customPrompt = prompt
                        } label: {
                            Text(prompt)
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(viewModel.customPrompt == prompt ? Color.blue : Color.gray.opacity(0.2))
                                .foregroundColor(viewModel.customPrompt == prompt ? .white : .primary)
                                .cornerRadius(16)
                        }
                        .disabled(viewModel.isAnalyzing)
                    }
                }
            }
        }
    }

    private var analyzeButton: some View {
        Button {
            Task { await viewModel.analyzeImage() }
        } label: {
            HStack {
                if viewModel.isAnalyzing {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.8)
                }
                Text(viewModel.isAnalyzing ? "vision.analyzing".localized : "분석 시작")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(viewModel.isAnalyzing ? Color.gray : Color.blue)
            .foregroundColor(.white)
            .cornerRadius(12)
        }
        .disabled(
            viewModel.isAnalyzing
                || viewModel.customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    @ViewBuilder
    private var resultSection: some View {
        if let result = viewModel.recognitionResult {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("vision.result".localized)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Spacer()
                    Button { viewModel.clearResult() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.gray)
                    }
                    .accessibilityLabel("결과 닫기")
                }

                Text(result)
                    .font(.body)
                    .foregroundColor(.primary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(12)
                    .textSelection(.enabled)

                Button {
                    UIPasteboard.general.string = result
                } label: {
                    Label("결과 복사", systemImage: "doc.on.doc")
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.1))
                        .foregroundColor(.blue)
                        .cornerRadius(8)
                }
            }
        } else if let error = viewModel.errorMessage {
            VStack(alignment: .leading, spacing: 12) {
                Text("error".localized)
                    .font(.headline)
                    .foregroundColor(.red)

                Text(error)
                    .font(.body)
                    .foregroundColor(.primary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(12)
                    .textSelection(.enabled)

                Button {
                    Task { await viewModel.retryAnalysis() }
                } label: {
                    Label("retry".localized, systemImage: "arrow.clockwise")
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.1))
                        .foregroundColor(.orange)
                        .cornerRadius(8)
                }
            }
        }
    }
}

#Preview {
    VisionRecognitionView(photo: UIImage(systemName: "photo")!, apiKey: "demo")
}
