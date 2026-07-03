//
//  RepScorer.swift
//  Fomura
//
//  フォーム判定モデル（採点層）。
//  1レップ分のフレーム特徴量から、種目別の段階的サブスコアと重大度付きの
//  指摘（faults）を算出する。学習データ不要のルールベースだが、生体力学的な
//  基準（可動域・深さ・ロックアウト・左右対称性）に基づいて多面的に評価する。
//  移植元: frontend/lib/pose/scoring.ts（配点・しきい値は無変更）
//

import Foundation

// 個々のフォーム上の問題点。
struct RepFault: Sendable, Equatable {
  let id: String
  let label: String
  let severity: Severity
}

// 1レップの評価結果。
struct RepEvaluation: Sendable {
  let score: Double                  // 0〜100
  let subScores: [String: Double]    // 項目別スコア（HUD/保存用）
  let faults: [RepFault]
}

enum RepScorer {
  // MARK: - 汎用計算

  private static func mean(_ values: [Double]) -> Double {
    if values.isEmpty { return 0 }
    return values.reduce(0, +) / Double(values.count)
  }

  private static func std(_ values: [Double]) -> Double {
    if values.count < 2 { return 0 }
    let m = mean(values)
    return sqrt(mean(values.map { ($0 - m) * ($0 - m) }))
  }

  private static func round1(_ v: Double) -> Double {
    (v * 10).rounded() / 10
  }

  // v を区間 [x0,x1] から [y0,y1] へ線形写像し、0〜1 の範囲でクランプする。
  // x0>x1（降順）にも対応する。
  static func linMap(_ v: Double, _ x0: Double, _ x1: Double, _ y0: Double, _ y1: Double) -> Double {
    if x1 == x0 { return y0 }
    let t = max(0, min(1, (v - x0) / (x1 - x0)))
    return y0 + t * (y1 - y0)
  }

  // 横向き撮影として信頼できるレップかどうか（フレーム平均で判定）。
  private static func isSideView(_ frames: [Features]) -> Bool {
    mean(frames.map { $0.sideViewConfidence ?? 0 }) >= PoseConstants.sideViewMin
  }

  // MARK: - スクワット

  private static func evaluateSquat(_ frames: [Features]) -> RepEvaluation {
    let minKnee = frames.map(\.primaryAngle).min() ?? 0
    let reachedParallel = frames.contains { $0.isParallel == true }
    // しゃがみ最中（膝が曲がっている局面）の膝前突を平均する。
    let bottomFrames = frames.filter { ($0.kneeAngle ?? 180) < 130 }
    let kneeFrames = bottomFrames.isEmpty ? frames : bottomFrames
    let avgKneeOverToe = mean(kneeFrames.map { max(0, $0.kneeOverToe ?? 0) })
    let maxLean = frames.map { $0.backLeanDeg ?? 0 }.max() ?? 0
    let leanStd = std(frames.map { $0.backLeanDeg ?? 0 })
    let sideView = isSideView(frames)

    // 深さ(0〜45): パラレル到達で満点、未到達は最深膝角度で部分点。
    let depthScore = reachedParallel ? 45 : linMap(minKnee, 140, 95, 0, 44)
    // 膝の前方突出(0〜30): 下腿長比0.35までは許容、0.9で0点。正面撮影では減点しない。
    let kneeScore = sideView ? linMap(avgKneeOverToe, 0.35, 0.9, 30, 0) : 30
    // 背中(0〜25): 前傾しすぎ・不安定を減点。横向き時のみ評価。
    var backScore = 25.0
    if sideView {
      let leanPenalty = linMap(maxLean, 45, 70, 0, 1)
      let stabPenalty = linMap(leanStd, 4, 15, 0, 1)
      backScore = max(0, 25 * (1 - 0.6 * leanPenalty - 0.4 * stabPenalty))
    }

    var faults: [RepFault] = []
    if !reachedParallel && minKnee > 115 {
      faults.append(RepFault(id: "depth", label: "しゃがみが浅い（もう少し深く）", severity: .warn))
    }
    if sideView && avgKneeOverToe > 0.6 {
      faults.append(RepFault(id: "knee", label: "膝がつま先より前に出すぎています", severity: .warn))
    }
    if sideView && maxLean > 65 {
      faults.append(RepFault(id: "back", label: "背中が前に倒れすぎています", severity: .warn))
    }
    if sideView && leanStd > 15 {
      faults.append(RepFault(id: "back-stability", label: "背中の角度が安定していません", severity: .info))
    }

    return RepEvaluation(
      score: round1(min(100, depthScore + kneeScore + backScore)),
      subScores: [
        "depth": round1(depthScore),
        "knee": round1(kneeScore),
        "back": round1(backScore),
      ],
      faults: faults
    )
  }

  // MARK: - デッドリフト

  private static func evaluateDeadlift(_ frames: [Features]) -> RepEvaluation {
    let minHip = frames.map(\.primaryAngle).min() ?? 0        // 最下点のヒンジ
    let maxHip = frames.map { $0.hipAngle ?? 0 }.max() ?? 0   // ロックアウト
    let maxKnee = frames.map { $0.kneeAngle ?? 0 }.max() ?? 0
    let leanStd = std(frames.map { $0.backLeanDeg ?? 0 })
    let sideView = isSideView(frames)

    // ヒンジの深さ(0〜40)
    let hingeScore = linMap(minHip, 160, 70, 0, 40)
    // ロックアウト(0〜35): 股関節と膝の伸展
    let hipLock = linMap(maxHip, 150, 178, 0, 1)
    let kneeLock = linMap(maxKnee, 150, 178, 0, 1)
    let lockoutScore = 35 * (0.6 * hipLock + 0.4 * kneeLock)
    // 背中の安定性(0〜25): 横向き時のみ評価
    let backScore = sideView ? 25 * (1 - linMap(leanStd, 5, 20, 0, 1)) : 25

    var faults: [RepFault] = []
    if maxHip < 155 {
      faults.append(RepFault(id: "lockout", label: "最後まで立ち上がり切れていません", severity: .warn))
    }
    if minHip > 140 {
      faults.append(RepFault(id: "hinge", label: "股関節を十分に折り込めていません", severity: .info))
    }
    if sideView && leanStd > 18 {
      faults.append(RepFault(id: "back", label: "背中の角度が不安定です（丸まりに注意）", severity: .warn))
    }

    return RepEvaluation(
      score: round1(min(100, hingeScore + lockoutScore + backScore)),
      subScores: [
        "hinge": round1(hingeScore),
        "lockout": round1(lockoutScore),
        "back": round1(backScore),
      ],
      faults: faults
    )
  }

  // MARK: - ベンチプレス

  private static func evaluateBenchPress(_ frames: [Features]) -> RepEvaluation {
    let minElbow = frames.map(\.primaryAngle).min() ?? 0       // 胸へ下ろした最下点
    let maxElbow = frames.map { $0.elbowAngle ?? 0 }.max() ?? 0 // 挙上ロックアウト
    let avgSym = mean(frames.map { $0.elbowSymmetryDeg ?? 0 })

    // 下ろしの深さ(0〜45)
    let depthScore = linMap(minElbow, 120, 80, 0, 45)
    // ロックアウト(0〜30)
    let lockoutScore = linMap(maxElbow, 150, 175, 0, 30)
    // 左右対称性(0〜25)
    let symScore = 25 * (1 - linMap(avgSym, 0, 25, 0, 1))

    var faults: [RepFault] = []
    if minElbow > 105 {
      faults.append(RepFault(id: "depth", label: "下ろしが浅いです（胸まで下ろしましょう）", severity: .warn))
    }
    if maxElbow < 155 {
      faults.append(RepFault(id: "lockout", label: "挙上時に肘が伸び切っていません", severity: .warn))
    }
    if avgSym > 15 {
      faults.append(RepFault(id: "symmetry", label: "左右の腕の動きが非対称です", severity: .warn))
    }

    return RepEvaluation(
      score: round1(min(100, depthScore + lockoutScore + symScore)),
      subScores: [
        "depth": round1(depthScore),
        "lockout": round1(lockoutScore),
        "symmetry": round1(symScore),
      ],
      faults: faults
    )
  }

  // MARK: - その他（可動域ベース）

  private static func evaluateGeneric(_ frames: [Features]) -> RepEvaluation {
    let angles = frames.map(\.primaryAngle)
    let rom = (angles.max() ?? 0) - (angles.min() ?? 0)
    let score = round1(min(100, rom / 1.8))
    return RepEvaluation(score: score, subScores: ["rom": score], faults: [])
  }

  // MARK: - 公開インターフェース

  // 1レップを総合評価する。
  static func evaluateRep(frames: [Features], exercise: ExerciseType) -> RepEvaluation {
    if frames.isEmpty {
      return RepEvaluation(score: 0, subScores: [:], faults: [])
    }
    switch exercise {
    case .squat:
      return evaluateSquat(frames)
    case .deadlift:
      return evaluateDeadlift(frames)
    case .benchPress:
      return evaluateBenchPress(frames)
    case .other:
      return evaluateGeneric(frames)
    }
  }

  // セッション全体のスコア = 各レップスコアの平均。
  static func sessionScore(repScores: [Double]) -> Double? {
    if repScores.isEmpty { return nil }
    return (mean(repScores) * 10).rounded() / 10
  }

  // MARK: - 表示用カタログ（保存された fault_* / sub_* キーの日本語化）

  // 指摘IDの日本語ラベル（種目でIDが重複するため種目込みで解決する）。
  static func faultLabel(id: String, exercise: ExerciseType) -> String {
    switch (exercise, id) {
    case (.squat, "depth"): return "しゃがみが浅い（もう少し深く）"
    case (.squat, "knee"): return "膝がつま先より前に出すぎています"
    case (.squat, "back"): return "背中が前に倒れすぎています"
    case (.squat, "back-stability"): return "背中の角度が安定していません"
    case (.deadlift, "lockout"): return "最後まで立ち上がり切れていません"
    case (.deadlift, "hinge"): return "股関節を十分に折り込めていません"
    case (.deadlift, "back"): return "背中の角度が不安定です（丸まりに注意）"
    case (.benchPress, "depth"): return "下ろしが浅いです（胸まで下ろしましょう）"
    case (.benchPress, "lockout"): return "挙上時に肘が伸び切っていません"
    case (.benchPress, "symmetry"): return "左右の腕の動きが非対称です"
    default: return id
    }
  }

  // サブスコア項目の表示名。
  static func subScoreName(_ key: String) -> String {
    switch key {
    case "depth": return "深さ"
    case "knee": return "膝"
    case "back": return "背中"
    case "hinge": return "ヒンジ"
    case "lockout": return "ロックアウト"
    case "symmetry": return "対称性"
    case "rom": return "可動域"
    default: return key
    }
  }

  // サブスコア項目の満点（内訳バーの分母表示用）。
  static func subScoreMax(_ key: String, exercise: ExerciseType) -> Double {
    switch (exercise, key) {
    case (.squat, "depth"): return 45
    case (.squat, "knee"): return 30
    case (.squat, "back"): return 25
    case (.deadlift, "hinge"): return 40
    case (.deadlift, "lockout"): return 35
    case (.deadlift, "back"): return 25
    case (.benchPress, "depth"): return 45
    case (.benchPress, "lockout"): return 30
    case (.benchPress, "symmetry"): return 25
    case (.other, "rom"): return 100
    default: return 100
    }
  }
}
