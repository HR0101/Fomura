//
//  UploadView.swift
//  Fomura
//
//  動画ファイル解析画面（モバイル設計書.md 第4.7節を端末内解析へ適応）。
//  Web版はバックエンドへアップロードしていたが、「処理はアプリ内で完結」方針の
//  ため、フォトライブラリから選択した動画を端末内で解析して保存する。
//

import SwiftUI
import SwiftData
import PhotosUI
import AVKit

// PhotosPicker から動画を一時ファイルとして受け取るための Transferable。
struct PickedVideo: Transferable {
  let url: URL

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(contentType: .movie) { video in
      SentTransferredFile(video.url)
    } importing: { received in
      let destination = URL.temporaryDirectory
        .appending(path: "picked-\(UUID().uuidString).\(received.file.pathExtension)")
      try FileManager.default.copyItem(at: received.file, to: destination)
      return PickedVideo(url: destination)
    }
  }
}

@MainActor
@Observable
final class UploadViewModel {
  var exercise: ExerciseType = .squat
  var pickedItem: PhotosPickerItem?
  private(set) var videoURL: URL?
  private(set) var isLoadingVideo = false
  private(set) var isAnalyzing = false
  private(set) var progress: Double = 0
  var errorMessage: String?
  var savedSessionId: UUID?

  private var analysisTask: Task<Void, Never>?

  // 選択された PhotosPickerItem を一時ファイルへ書き出す。
  func loadVideo(from item: PhotosPickerItem) async {
    isLoadingVideo = true
    errorMessage = nil
    defer { isLoadingVideo = false }

    do {
      guard let video = try await item.loadTransferable(type: PickedVideo.self) else {
        errorMessage = "動画を読み込めませんでした．別の動画を選択してください．"
        return
      }
      // 前回の一時ファイルを掃除する。
      removeTemporaryVideo()
      videoURL = video.url
    } catch {
      errorMessage = "動画の読み込みに失敗しました: \(error.localizedDescription)"
    }
  }

  // 端末内解析を実行し、結果を SwiftData へ保存する。
  func analyze(modelContext: ModelContext) {
    guard let videoURL, !isAnalyzing else { return }
    isAnalyzing = true
    progress = 0
    errorMessage = nil

    let analyzer = VideoAnalyzer()
    let exercise = exercise
    // ライブ判定と同じ設定（モデル種別・平滑化）で解析する。
    let modelType = PoseModelType(
      rawValue: UserDefaults.standard.string(forKey: AppSettings.modelType) ?? "lite"
    ) ?? .lite
    let smoothingEnabled =
      UserDefaults.standard.object(forKey: AppSettings.smoothingEnabled) as? Bool ?? true

    analysisTask = Task { [weak self] in
      do {
        // 解析はCPU負荷が高いためバックグラウンドで実行する。
        let result = try await Task.detached(priority: .userInitiated) {
          try await analyzer.analyze(
            url: videoURL,
            exercise: exercise,
            modelType: modelType,
            smoothingEnabled: smoothingEnabled
          ) { value in
            Task { @MainActor [weak self] in
              self?.progress = value
            }
          }
        }.value

        guard let self else { return }

        if result.reps.isEmpty {
          self.errorMessage = "レップが検出されませんでした．推奨アングル（体の真横・全身）で撮影された動画か確認してください．"
        } else {
          let session = TrainingSession(
            exerciseType: exercise,
            source: .video,
            totalScore: result.totalScore,
            durationMs: result.durationMs
          )
          modelContext.insert(session)
          session.reps = result.reps.map { RepRecord(from: $0) }
          try modelContext.save()
          self.savedSessionId = session.id
        }
      } catch {
        self?.errorMessage = error.localizedDescription
      }
      self?.isAnalyzing = false
    }
  }

  func cancelAnalysis() {
    analysisTask?.cancel()
    analysisTask = nil
    isAnalyzing = false
  }

  func removeTemporaryVideo() {
    if let videoURL {
      try? FileManager.default.removeItem(at: videoURL)
    }
    videoURL = nil
  }
}

struct UploadView: View {
  @Environment(\.modelContext) private var modelContext
  @Query(sort: \TrainingSession.createdAt, order: .reverse)
  private var sessions: [TrainingSession]

  @State private var viewModel = UploadViewModel()

  var body: some View {
    Form {
      Section("種目") {
        Picker("種目", selection: $viewModel.exercise) {
          ForEach(ExerciseType.allCases) { exercise in
            Text(exercise.displayName).tag(exercise)
          }
        }
        .pickerStyle(.menu)
        .disabled(viewModel.isAnalyzing)
      }

      Section("動画") {
        PhotosPicker(selection: $viewModel.pickedItem, matching: .videos) {
          Label(
            viewModel.videoURL == nil ? "フォトライブラリから選択" : "動画を選び直す",
            systemImage: "photo.on.rectangle"
          )
        }
        .disabled(viewModel.isAnalyzing || viewModel.isLoadingVideo)

        if viewModel.isLoadingVideo {
          HStack {
            ProgressView()
            Text("動画を読み込み中…")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }

        if let url = viewModel.videoURL {
          VideoPlayer(player: AVPlayer(url: url))
            .frame(height: 220)
            .listRowInsets(EdgeInsets())
        }
      }

      if let recommended = FramingEvaluator.recommendedViews[viewModel.exercise] {
        Section("推奨の撮影方法") {
          LabeledContent("向き", value: recommended.view)
          LabeledContent("高さ", value: recommended.cameraHeight)
          LabeledContent("距離", value: recommended.distance)
        }
      }

      Section {
        if viewModel.isAnalyzing {
          VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: viewModel.progress) {
              Text("解析中… \(Int((viewModel.progress * 100).rounded()))%")
                .font(.footnote)
            }
            Button("キャンセル", role: .destructive) {
              viewModel.cancelAnalysis()
            }
          }
        } else {
          Button {
            viewModel.analyze(modelContext: modelContext)
          } label: {
            Label("解析を開始", systemImage: "waveform.badge.magnifyingglass")
              .frame(maxWidth: .infinity)
          }
          .disabled(viewModel.videoURL == nil)
        }
      }

      if let message = viewModel.errorMessage {
        Section {
          Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.red)
        }
      }
    }
    .navigationTitle("動画解析")
    .onChange(of: viewModel.pickedItem) { _, newItem in
      if let newItem {
        Task {
          await viewModel.loadVideo(from: newItem)
        }
      }
    }
    .onDisappear {
      viewModel.cancelAnalysis()
      viewModel.removeTemporaryVideo()
    }
    // 解析完了後は詳細画面へ遷移する。
    .navigationDestination(item: $viewModel.savedSessionId) { sessionId in
      if let session = sessions.first(where: { $0.id == sessionId }) {
        SessionDetailView(session: session)
      }
    }
  }
}
