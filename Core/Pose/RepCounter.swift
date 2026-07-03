//
//  RepCounter.swift
//  Fomura
//
//  レップ（反復）自動カウントのステートマシン。
//  主角度（膝/股関節/肘）の上下動から1レップを検出し、評価モデルで採点した
//  要約（サブスコア・指摘フラグ含む）を生成する。
//  移植元: frontend/lib/pose/repCounter.ts（しきい値・挙動は無変更）
//

import Foundation

// 完了した1レップの記録（DB保存とHUD表示の元データ）。
struct CompletedRep: Sendable, Identifiable {
  let repNumber: Int
  let score: Double
  // 代表特徴量（min_primary_angle / sub_* / fault_* 等。キーは生のsnake_case）
  let features: [String: FeatureValue]
  let startTimestampMs: Double
  let endTimestampMs: Double

  var id: Int { repNumber }
}

final class RepCounter {
  // 種目ごとの「立ち上がり」「最下点」しきい値（度）。Web版 THRESHOLDS と同値。
  static let thresholds: [ExerciseType: (top: Double, bottom: Double)] = [
    .squat: (top: 160, bottom: 110),
    .deadlift: (top: 165, bottom: 110),
    .benchPress: (top: 158, bottom: 95),
    .other: (top: 160, bottom: 105),
  ]

  // 下降開始とみなすマージン（top からこの分だけ下がったら計測開始）。
  static let descentMargin = 15.0

  private let exercise: ExerciseType
  private let top: Double
  private let bottom: Double

  private var repCount = 0
  private var collecting = false
  private var reachedBottom = false
  private var buffer: [Features] = []
  private var startMs = 0.0

  init(exercise: ExerciseType) {
    self.exercise = exercise
    let threshold = Self.thresholds[exercise] ?? (top: 160, bottom: 105)
    self.top = threshold.top
    self.bottom = threshold.bottom
  }

  var count: Int { repCount }

  // 現在レップの深さ進捗（0〜1）。HUDのゲージ表示に使う。
  func depthRatio(currentAngle: Double) -> Double {
    let range = top - bottom
    if range <= 0 { return 0 }
    return max(0, min(1, (top - currentAngle) / range))
  }

  // 1フレーム投入。レップが完了したら CompletedRep を返す。
  func push(_ features: Features, timestampMs: Double) -> CompletedRep? {
    let angle = features.primaryAngle

    // 計測開始: 立位から十分に下降したら
    if !collecting && angle < top - Self.descentMargin {
      collecting = true
      reachedBottom = false
      buffer = []
      startMs = timestampMs
    }

    if collecting {
      buffer.append(features)
      if angle <= bottom {
        reachedBottom = true
      }

      // 最下点を経て立位へ戻ったらレップ完了
      if reachedBottom && angle >= top {
        return finalize(timestampMs: timestampMs)
      }
    }

    return nil
  }

  private func finalize(timestampMs: Double) -> CompletedRep {
    repCount += 1
    let frames = buffer

    // 評価モデルで採点し、サブスコアと指摘を取得する。
    let evaluation = RepScorer.evaluateRep(frames: frames, exercise: exercise)
    let features = buildSummary(
      frames: frames, subScores: evaluation.subScores, faults: evaluation.faults
    )

    let rep = CompletedRep(
      repNumber: repCount,
      score: evaluation.score,
      features: features,
      startTimestampMs: round2(startMs),
      endTimestampMs: round2(timestampMs)
    )

    // 状態リセット
    collecting = false
    reachedBottom = false
    buffer = []
    return rep
  }

  // 代表特徴量を組み立てる（最深角度・サブスコア・指摘フラグ・種目別指標）。
  private func buildSummary(
    frames: [Features],
    subScores: [String: Double],
    faults: [RepFault]
  ) -> [String: FeatureValue] {
    let primaryAngles = frames.map(\.primaryAngle)
    var summary: [String: FeatureValue] = [
      "min_primary_angle": .number(round2(primaryAngles.min() ?? 0)),
      "frame_count": .number(Double(frames.count)),
    ]

    // 項目別スコア（sub_*）と検出された指摘（fault_*）を記録する。
    for (key, value) in subScores {
      summary["sub_\(key)"] = .number(value)
    }
    for fault in faults {
      summary["fault_\(fault.id)"] = .bool(true)
    }

    // 種目別の代表指標
    if exercise == .squat {
      summary["reached_parallel"] = .bool(frames.contains { $0.isParallel == true })
      summary["max_back_lean_deg"] = .number(
        round2(frames.map { $0.backLeanDeg ?? 0 }.max() ?? 0)
      )
      let avgKneeOverToe =
        frames.reduce(0.0) { $0 + max(0, $1.kneeOverToe ?? 0) } / Double(frames.count)
      summary["avg_knee_over_toe"] = .number(round2(avgKneeOverToe))
    }
    return summary
  }

  private func round2(_ v: Double) -> Double {
    (v * 100).rounded() / 100
  }
}
