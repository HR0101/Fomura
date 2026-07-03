//
//  LiveSessionViewModel.swift
//  Fomura
//
//  リアルタイム判定画面の中核（モバイル設計書.md 第7章）。
//  カメラ→推論→解析パイプラインを束ね、結果を SwiftUI へ公開する。
//  保存はバックエンドではなく SwiftData（端末内）に対して行う。
//
//  フロー: 準備完了後は常時プレビュー（骨格＋撮影ガイド）で立ち位置を合わせ、
//  開始ボタン→カウントダウン（設定秒数・音声付き）→判定、の順に進む。
//

import Foundation
import SwiftUI
import SwiftData
import AVFoundation

@MainActor
@Observable
final class LiveSessionViewModel {
  enum Phase: Equatable {
    case initializing   // エンジン初期化・権限確認中
    case ready          // プレビュー中（種目選択可・撮影ガイド表示）
    case countingDown   // 開始カウントダウン中
    case running        // 判定中
    case saving         // 保存中
    case finished       // 保存完了（結果シート表示中）
  }

  // MARK: - 公開状態

  var phase: Phase = .initializing
  var exercise: ExerciseType = .squat
  private(set) var facing: CameraFacing = .back
  private(set) var snapshot: Snapshot?
  private(set) var completedReps: [CompletedRep] = []
  private(set) var countdownValue = 0
  var errorMessage: String?
  // 保存スキップ等の通知メッセージ（Web版の保存メッセージ相当）
  var statusMessage: String?
  // 熱状態の注意表示（serious/critical時のみ）
  private(set) var thermalMessage: String?
  var showResultSheet = false
  private(set) var savedSession: TrainingSession?

  // 現在スコア（レップ平均。Web版 currentScore と同じ）
  var currentScore: Double? {
    RepScorer.sessionScore(repScores: completedReps.map(\.score))
  }

  // MARK: - 依存

  let cameraService = CameraService()
  private let poseEngine = PoseEngine()
  private let pipeline = AnalysisPipeline()
  private let feedback = FeedbackService()

  // 骨格描画ビュー（SwiftUIの再描画を経由せず直接更新する）
  weak var skeletonView: SkeletonOverlayUIView?

  private var startedAt: Date?
  private var countdownTask: Task<Void, Never>?
  private var thermalObserver: (any NSObjectProtocol)?
  // 同一警告の連続フィードバックを抑えるクールダウン管理
  private var warningLastFiredAt: [String: Date] = [:]

  // MARK: - ユーザー設定（開始時に読み込む）

  private var hapticsEnabled: Bool {
    UserDefaults.standard.object(forKey: AppSettings.hapticsEnabled) as? Bool ?? true
  }
  private var voiceCountEnabled: Bool {
    UserDefaults.standard.bool(forKey: AppSettings.voiceCountEnabled)
  }
  private var smoothingEnabled: Bool {
    UserDefaults.standard.object(forKey: AppSettings.smoothingEnabled) as? Bool ?? true
  }
  private var modelType: PoseModelType {
    PoseModelType(rawValue: UserDefaults.standard.string(forKey: AppSettings.modelType) ?? "lite") ?? .lite
  }
  private var countdownSeconds: Int {
    UserDefaults.standard.object(forKey: AppSettings.countdownSeconds) as? Int ?? 3
  }
  private var warningSoundEnabled: Bool {
    UserDefaults.standard.bool(forKey: AppSettings.warningSoundEnabled)
  }
  private var warningSpeechEnabled: Bool {
    UserDefaults.standard.bool(forKey: AppSettings.warningSpeechEnabled)
  }

  // MARK: - 準備

  // エンジン初期化・権限確認・カメラ構成（画面表示時に1回呼ぶ）。
  func prepare() async {
    phase = .initializing
    errorMessage = nil

    guard await CameraService.requestPermission() else {
      errorMessage = CameraService.CameraError.permissionDenied.localizedDescription
      return
    }

    // 既定カメラは設定から（Web版の既定は背面）。
    let defaultFacingRaw = UserDefaults.standard.string(forKey: AppSettings.defaultFacing) ?? "back"
    facing = CameraFacing(rawValue: defaultFacingRaw) ?? .back

    do {
      try poseEngine.initializeLiveStream(modelType: modelType)
      try cameraService.configure(facing: facing)
    } catch {
      errorMessage = error.localizedDescription
      return
    }

    wireCallbacks()
    observeThermalState()
    phase = .ready
    startPreview()
  }

  // プレビューを開始する（骨格＋撮影ガイドで立ち位置を合わせられる）。
  private func startPreview() {
    pipeline.startPreview(exercise: exercise, smoothingEnabled: smoothingEnabled)
    cameraService.start()
  }

  // 種目変更をパイプラインへ反映する（プレビュー中のみ）。
  func exerciseChanged() {
    pipeline.updateExercise(exercise)
  }

  // カメラ→推論→解析→UI のコールバック連結。
  private func wireCallbacks() {
    // カメラフレーム → 推論投入（camera.queue 上）
    cameraService.onSampleBuffer = { [poseEngine] sampleBuffer in
      let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
      let timestampMs = Int((pts.seconds * 1000).rounded())
      poseEngine.detectAsync(sampleBuffer: sampleBuffer, timestampMs: timestampMs)
    }

    // 推論結果 → 解析パイプライン（MediaPipe内部スレッド → analysis.queue）
    poseEngine.onResult = { [pipeline] landmarks, timestampMs in
      pipeline.process(landmarks: landmarks, timestampMs: timestampMs)
    }

    // 骨格描画（人物確認済みのみ。MainActor で CAShapeLayer を直更新）
    pipeline.onSkeleton = { [weak self] landmarks in
      Task { @MainActor [weak self] in
        self?.skeletonView?.render(landmarks: landmarks)
      }
    }

    // HUDスナップショット（100ms間引き済み）
    pipeline.onSnapshot = { [weak self] snapshot in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.snapshot = snapshot
        if self.phase == .running {
          self.processWarningFeedback(snapshot.warnings)
        }
      }
    }

    // レップ完了 → 一覧追加＋フィードバック
    pipeline.onRepCompleted = { [weak self] rep in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.completedReps.append(rep)
        self.feedback.repCompleted(
          count: rep.repNumber,
          hapticsEnabled: self.hapticsEnabled,
          voiceCountEnabled: self.voiceCountEnabled
        )
      }
    }
  }

  // MARK: - 開始（カウントダウン → 判定）

  func start() {
    guard phase == .ready else { return }
    statusMessage = nil

    let seconds = countdownSeconds
    guard seconds > 0 else {
      beginJudging()
      return
    }

    phase = .countingDown
    countdownValue = seconds
    countdownTask = Task { [weak self] in
      for value in stride(from: seconds, through: 1, by: -1) {
        guard let self, !Task.isCancelled else { return }
        self.countdownValue = value
        self.feedback.countdownTick(value)
        try? await Task.sleep(for: .seconds(1))
      }
      guard let self, !Task.isCancelled else { return }
      self.feedback.startCue()
      self.beginJudging()
    }
  }

  func cancelCountdown() {
    countdownTask?.cancel()
    countdownTask = nil
    if phase == .countingDown {
      phase = .ready
    }
  }

  private func beginJudging() {
    completedReps = []
    snapshot = nil
    savedSession = nil
    warningLastFiredAt = [:]
    startedAt = Date()

    pipeline.beginJudging()
    phase = .running

    // 判定中の画面スリープを抑止する（終了時に必ず戻す）。
    UIApplication.shared.isIdleTimerDisabled = true
  }

  // MARK: - 停止・保存（Web版 handleStop 相当）

  func stop(modelContext: ModelContext) {
    guard phase == .running else { return }
    // カメラは止めずプレビューへ戻る（続けて次のセットを行いやすくする）。
    pipeline.endJudging()
    UIApplication.shared.isIdleTimerDisabled = false

    // レップ0件は保存しない（Web版と同じ挙動・同じ文言）。
    guard !completedReps.isEmpty else {
      statusMessage = "レップが検出されなかったため保存しませんでした。"
      snapshot = nil
      phase = .ready
      return
    }

    phase = .saving
    do {
      let durationMs = startedAt.map { Date().timeIntervalSince($0) * 1000 }
      let session = TrainingSession(
        exerciseType: exercise,
        source: .live,
        totalScore: currentScore,
        durationMs: durationMs
      )
      modelContext.insert(session)
      session.reps = completedReps.map { RepRecord(from: $0) }
      try modelContext.save()

      savedSession = session
      phase = .finished
      showResultSheet = true
    } catch {
      // ローカル保存の失敗は稀（ディスク満杯等）。結果は画面に残して再試行可能にする。
      errorMessage = "保存に失敗しました: \(error.localizedDescription)"
      phase = .ready
    }
  }

  // 結果シートを閉じた後は待機（プレビュー）状態へ戻す。
  func resultSheetDismissed() {
    if phase == .finished {
      phase = .ready
      snapshot = nil
    }
  }

  // MARK: - カメラ切替（判定中は不可）

  func switchCamera() {
    guard phase == .ready else { return }
    do {
      try cameraService.switchFacing()
      facing = cameraService.facing
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  // MARK: - 警告フィードバック（音・読み上げ。クールダウン付き）

  private func processWarningFeedback(_ warnings: [FormWarning]) {
    guard warningSoundEnabled || warningSpeechEnabled else { return }
    let now = Date()
    for warning in warnings where warning.severity == .warn {
      if let last = warningLastFiredAt[warning.id],
         now.timeIntervalSince(last) < PoseConstants.warningFeedbackCooldownSec {
        continue
      }
      warningLastFiredAt[warning.id] = now
      feedback.warningTriggered(
        label: warning.label,
        soundEnabled: warningSoundEnabled,
        speechEnabled: warningSpeechEnabled
      )
    }
  }

  // MARK: - 熱状態監視（モバイル設計書.md 11.1節）

  private func observeThermalState() {
    thermalObserver = NotificationCenter.default.addObserver(
      forName: ProcessInfo.thermalStateDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.applyThermalPolicy()
      }
    }
    applyThermalPolicy()
  }

  private func applyThermalPolicy() {
    switch ProcessInfo.processInfo.thermalState {
    case .serious:
      cameraService.setFrameRate(24)
      thermalMessage = "端末が高温のため処理を軽くしています"
    case .critical:
      cameraService.setFrameRate(15)
      thermalMessage = "端末が非常に高温です．判定を止めて端末を冷ましてください"
    default:
      cameraService.setFrameRate(30)
      thermalMessage = nil
    }
  }

  // MARK: - 中断処理（着信・バックグラウンド遷移。モバイル設計書.md 表5）

  func handleScenePhaseChange(_ newPhase: ScenePhase, modelContext: ModelContext) {
    guard newPhase == .background else { return }
    switch phase {
    case .countingDown:
      cancelCountdown()
    case .running:
      // 自動停止し、レップがあれば保存する（結果消失防止）。
      stop(modelContext: modelContext)
    default:
      break
    }
  }

  // 画面を離れるときの後始末。
  func teardown() {
    countdownTask?.cancel()
    countdownTask = nil
    if let thermalObserver {
      NotificationCenter.default.removeObserver(thermalObserver)
      self.thermalObserver = nil
    }
    cameraService.stop()
    pipeline.stop()
    poseEngine.close()
    UIApplication.shared.isIdleTimerDisabled = false
  }
}
