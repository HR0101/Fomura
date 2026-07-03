//
//  AnalysisPipeline.swift
//  Fomura
//
//  推論結果（33点ランドマーク）を受け取り、特徴量抽出→レップ計数→採点→
//  警告→撮影ガイドまでを直列に処理する解析パイプライン。
//  RepCounter が状態を持つため、専用シリアルキューで直列化する
//  （モバイル設計書.md 第7.2節のスレッド分担）。
//
//  2モード構成:
//    - preview: 骨格描画＋撮影ガイドのみ（開始前の立ち位置合わせ用）
//    - judging: レップ計数・採点・警告まで全処理
//

import Foundation

// HUD更新用スナップショット（Web版 CameraView.tsx の Snapshot 型と同一構成）。
struct Snapshot: Sendable {
  let detected: Bool            // 人物検出済みか
  let repCount: Int             // 現在のレップ数
  let depthRatio: Double        // 深さゲージ（0〜1）
  let warnings: [FormWarning]   // 現在フレームの警告
  let primaryAngle: Int?        // 主要関節角度（丸め済み、デバッグ表示用）
  let framing: FramingResult?   // 撮影ガイド評価
}

final class AnalysisPipeline: @unchecked Sendable {
  enum Mode {
    case preview   // 骨格＋撮影ガイドのみ
    case judging   // レップ計数・採点・警告まで実施
  }

  // 解析状態を直列化するキュー（このキュー上でのみ状態に触れる）。
  private let queue = DispatchQueue(label: "com.fomura.analysis")

  private var exercise: ExerciseType = .squat
  private var mode: Mode = .preview
  private var repCounter: RepCounter?
  private var running = false
  private var lastSnapshotMs = -Double.infinity

  // 平滑化（One Euro Filter）。OFF時はWeb版と完全互換の生座標で判定する。
  private let smoother = LandmarkSmoother()
  private var smoothingEnabled = true

  // コールバック（呼び出しスレッドは解析キュー。UI反映側で MainActor へ切り替えること）。
  var onSnapshot: (@Sendable (Snapshot) -> Void)?
  var onRepCompleted: (@Sendable (CompletedRep) -> Void)?
  var onSkeleton: (@Sendable ([Landmark]?) -> Void)?

  // プレビューを開始する（骨格＋撮影ガイドのみ。開始前の位置合わせ用）。
  func startPreview(exercise: ExerciseType, smoothingEnabled: Bool) {
    queue.async { [weak self] in
      guard let self else { return }
      self.exercise = exercise
      self.smoothingEnabled = smoothingEnabled
      self.mode = .preview
      self.repCounter = nil
      self.running = true
      self.lastSnapshotMs = -.infinity
      self.smoother.reset()
    }
  }

  // 判定を開始する（レップ計数を新規生成。種目はプレビューで確定済み）。
  func beginJudging() {
    queue.async { [weak self] in
      guard let self else { return }
      self.repCounter = RepCounter(exercise: self.exercise)
      self.mode = .judging
      self.lastSnapshotMs = -.infinity
    }
  }

  // 判定を終えてプレビューへ戻る（カメラは動作継続）。
  func endJudging() {
    queue.async { [weak self] in
      guard let self else { return }
      self.mode = .preview
      self.repCounter = nil
    }
  }

  // 種目変更（プレビュー中のみ有効。判定中の変更は不可）。
  func updateExercise(_ exercise: ExerciseType) {
    queue.async { [weak self] in
      guard let self, self.mode == .preview else { return }
      self.exercise = exercise
    }
  }

  func stop() {
    queue.async { [weak self] in
      guard let self else { return }
      self.running = false
      self.repCounter = nil
      self.smoother.reset()
    }
  }

  // 推論結果を1フレーム分投入する（どのスレッドから呼んでもよい）。
  func process(landmarks: [Landmark]?, timestampMs: Double) {
    queue.async { [weak self] in
      self?.processOnQueue(landmarks: landmarks, timestampMs: timestampMs)
    }
  }

  private func processOnQueue(landmarks: [Landmark]?, timestampMs: Double) {
    guard running else { return }

    // 人物妥当性の足切り（人以外への誤描画・誤判定防止。Web版と同じ）。
    guard let rawLms = landmarks, FeatureExtractor.isLikelyPerson(rawLms) else {
      // 追跡が切れたらフィルタ履歴を破棄する（再検出時に古い座標へ引っ張られないように）。
      smoother.reset()
      onSkeleton?(nil)
      publishSnapshotIfNeeded(
        timestampMs: timestampMs,
        snapshot: Snapshot(
          detected: false,
          repCount: repCounter?.count ?? 0,
          depthRatio: 0,
          warnings: [],
          primaryAngle: nil,
          framing: nil
        )
      )
      return
    }

    // 平滑化（設定ON時のみ。ジッタ低減による描画・判定の安定化）。
    let lms = smoothingEnabled ? smoother.smooth(rawLms, timestampMs: timestampMs) : rawLms

    // 人物確認済みの姿勢のみ骨格を描画する。
    onSkeleton?(lms)

    let framing = FramingEvaluator.evaluate(lms, exercise: exercise)

    switch mode {
    case .preview:
      // プレビュー中は撮影ガイドだけを提示する（警告・計数はしない）。
      publishSnapshotIfNeeded(
        timestampMs: timestampMs,
        snapshot: Snapshot(
          detected: true,
          repCount: 0,
          depthRatio: 0,
          warnings: [],
          primaryAngle: nil,
          framing: framing
        )
      )

    case .judging:
      let features = FeatureExtractor.compute(lms, exercise: exercise)

      // レップ計数（完了したら即時通知。ハプティクス・音声カウント用）。
      if let rep = repCounter?.push(features, timestampMs: timestampMs) {
        onRepCompleted?(rep)
      }

      let warnings = WarningEvaluator.evaluate(features, exercise: exercise)

      publishSnapshotIfNeeded(
        timestampMs: timestampMs,
        snapshot: Snapshot(
          detected: true,
          repCount: repCounter?.count ?? 0,
          depthRatio: repCounter?.depthRatio(currentAngle: features.primaryAngle) ?? 0,
          warnings: warnings,
          primaryAngle: Int(features.primaryAngle.rounded()),
          framing: framing
        )
      )
    }
  }

  // UI更新は100ms間隔に間引く（SNAPSHOT_INTERVAL_MS を踏襲。推論自体は毎フレーム）。
  private func publishSnapshotIfNeeded(timestampMs: Double, snapshot: Snapshot) {
    guard timestampMs - lastSnapshotMs >= PoseConstants.snapshotIntervalMs else { return }
    lastSnapshotMs = timestampMs
    onSnapshot?(snapshot)
  }
}
