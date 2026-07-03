//
//  LiveSessionView.swift
//  Fomura
//
//  リアルタイム判定画面（モバイル設計書.md 第4.3節）。
//  映像全画面＋オーバーレイHUD＋下部固定アクションバーの構成。
//  待機中も常時プレビュー（骨格＋撮影ガイド）を表示し、開始→カウントダウン→判定と進む。
//  ホームから fullScreenCover で全画面表示される。
//

import SwiftUI
import SwiftData

struct LiveSessionView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @Environment(\.scenePhase) private var scenePhase

  @State private var viewModel = LiveSessionViewModel()
  @AppStorage(AppSettings.showAngleDebug) private var showAngleDebug = false

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      if viewModel.phase == .initializing {
        ProgressView("準備中…")
          .tint(.white)
          .foregroundStyle(.white)
      } else {
        cameraStage
      }

      // エラー表示（権限拒否・初期化失敗など）
      if let message = viewModel.errorMessage {
        errorPanel(message)
      }
    }
    .task {
      await viewModel.prepare()
    }
    .onDisappear {
      viewModel.teardown()
    }
    .onChange(of: viewModel.exercise) { _, _ in
      viewModel.exerciseChanged()
    }
    .onChange(of: scenePhase) { _, newPhase in
      viewModel.handleScenePhaseChange(newPhase, modelContext: modelContext)
    }
    .sheet(isPresented: $viewModel.showResultSheet, onDismiss: {
      viewModel.resultSheetDismissed()
    }) {
      if let session = viewModel.savedSession {
        ResultSheetView(session: session)
      }
    }
    .statusBarHidden()
  }

  // MARK: - カメラステージ（全フェーズ共通のプレビュー＋フェーズ別オーバーレイ）

  private var cameraStage: some View {
    ZStack {
      CameraPreviewView(session: viewModel.cameraService.session)
        .ignoresSafeArea()

      SkeletonOverlayView(viewModel: viewModel)
        .ignoresSafeArea()
        .allowsHitTesting(false)

      VStack(spacing: 0) {
        topBar

        if let thermal = viewModel.thermalMessage {
          Label(thermal, systemImage: "thermometer.high")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
            .padding(.top, 4)
        }

        HudOverlayView(
          snapshot: viewModel.snapshot,
          currentScore: viewModel.currentScore,
          showAngleDebug: showAngleDebug,
          isJudging: viewModel.phase == .running
        )

        bottomControls
      }

      // カウントダウンの大型表示
      if viewModel.phase == .countingDown {
        countdownOverlay
      }

      if viewModel.phase == .saving {
        ProgressView("保存中…")
          .tint(.white)
          .foregroundStyle(.white)
          .padding(24)
          .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
      }
    }
  }

  // MARK: - 上部バー

  private var topBar: some View {
    HStack {
      if viewModel.phase == .ready {
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .padding(10)
            .background(.black.opacity(0.45), in: Circle())
        }
      }

      Spacer()

      if viewModel.phase == .ready {
        Button {
          viewModel.switchCamera()
        } label: {
          Label(
            viewModel.facing == .back ? "背面" : "前面",
            systemImage: "arrow.triangle.2.circlepath.camera"
          )
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.white)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(.black.opacity(0.45), in: Capsule())
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.top, 4)
  }

  // MARK: - 下部コントロール（フェーズ別）

  @ViewBuilder
  private var bottomControls: some View {
    switch viewModel.phase {
    case .ready:
      readySetupPanel

    case .countingDown:
      Button {
        viewModel.cancelCountdown()
      } label: {
        Label("キャンセル", systemImage: "xmark.circle.fill")
          .font(.headline)
          .padding(.horizontal, 24)
          .padding(.vertical, 12)
      }
      .buttonStyle(.borderedProminent)
      .tint(.gray)
      .padding(.bottom, 16)

    case .running:
      HStack {
        Text(viewModel.exercise.displayName)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.white)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(.black.opacity(0.55), in: Capsule())

        Spacer()

        Button {
          viewModel.stop(modelContext: modelContext)
        } label: {
          Label("停止", systemImage: "stop.fill")
            .font(.headline)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 12)

    default:
      EmptyView()
    }
  }

  // 待機中の設定パネル（種目・推奨アングル・開始）。プレビューに重ねて表示する。
  private var readySetupPanel: some View {
    VStack(spacing: 12) {
      Picker("種目", selection: $viewModel.exercise) {
        ForEach(ExerciseType.allCases) { exercise in
          Text(exercise.displayName).tag(exercise)
        }
      }
      .pickerStyle(.segmented)
      .colorScheme(.dark)

      if let recommended = FramingEvaluator.recommendedViews[viewModel.exercise] {
        VStack(alignment: .leading, spacing: 4) {
          Label(
            "\(recommended.view)・\(recommended.cameraHeight)・\(recommended.distance)",
            systemImage: "camera.viewfinder"
          )
          .font(.caption.weight(.semibold))
          Text(recommended.reason)
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
      }

      if let message = viewModel.statusMessage {
        Text(message)
          .font(.footnote)
          .foregroundStyle(.yellow)
          .multilineTextAlignment(.center)
      }

      Button {
        viewModel.start()
      } label: {
        Label("判定を開始", systemImage: "play.fill")
          .font(.headline)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 12)
      }
      .buttonStyle(.borderedProminent)
      .tint(.green)
    }
    .padding(14)
    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
    .padding(.horizontal, 12)
    .padding(.bottom, 8)
  }

  // MARK: - カウントダウン表示

  private var countdownOverlay: some View {
    VStack(spacing: 8) {
      Text("\(viewModel.countdownValue)")
        .font(.system(size: 140, weight: .bold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 12)
        .contentTransition(.numericText(countsDown: true))
        .animation(.snappy, value: viewModel.countdownValue)
      Text("定位置についてください")
        .font(.headline)
        .foregroundStyle(.white.opacity(0.9))
        .shadow(color: .black.opacity(0.6), radius: 6)
    }
  }

  // MARK: - エラー表示

  private func errorPanel(_ message: String) -> some View {
    VStack(spacing: 16) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.largeTitle)
        .foregroundStyle(.yellow)
      Text(message)
        .font(.body)
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
      Button("閉じる") {
        dismiss()
      }
      .buttonStyle(.borderedProminent)
    }
    .padding(24)
    .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
    .padding(32)
  }
}
