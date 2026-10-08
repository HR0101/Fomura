//
//  RepScorer.swift
//  Fomura
//
//  フォーム判定モデル（採点層）。
//  1レップ分のフレーム特徴量から、種目別の段階的サブスコアと重大度付きの
//  指摘（faults）を算出する。学習データ不要のルールベースだが、生体力学的な
//  基準（可動域・深さ・ロックアウト・左右対称性）に基づいて多面的に評価する。
//  squat/deadlift/bench_pressの移植元: frontend/lib/pose/scoring.ts（配点・しきい値は無変更）。
//  それ以外はモバイル版で追加した種目（設計レビュー済み）。
//
//  【設計レビューで判明した既知の注意点】
//  指摘(fault)の閾値をRepCounterのFSMが保証するmin/max primaryAngleの範囲と
//  同じ側に置くと、確定済みレップでは条件が恒真/恒偽になり指摘が絶対に発火しない
//  デッドコードになる（例: bottom=90のとき`minElbow>115`は確定レップのminElbowが
//  常に90以下なので絶対にfalse）。squat/deadlift/bench_pressの既存fault(depth/
//  hinge/lockout等)の一部はWeb版由来でこの問題を抱えているが、パリティ維持のため
//  ここでは変更しない。追加種目（overheadPress以降）はパリティ制約が無いため、
//  PoseConstants.shallowFaultMargin/lockoutFaultMarginを使い、FSMのbottom/topから
//  意図的に離した閾値（「ぎりぎり合格」の一帯だけを検出する設計）を採用している。
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

  // MARK: - ショルダープレス（モバイル追加種目）

  private static func evaluateOverheadPress(_ frames: [Features]) -> RepEvaluation {
    let minElbow = frames.map(\.primaryAngle).min() ?? 0
    let maxElbow = frames.map { $0.elbowAngle ?? 0 }.max() ?? 0
    let maxLean = frames.map { $0.backLeanDeg ?? 0 }.max() ?? 0
    let sideView = isSideView(frames)

    // 深さ(0〜40): 満点アンカーをFSMのbottom(90)より深い75に置き、
    // 「ぎりぎり合格(90)」と「深いラック位置(75以下)」で点差が付くようにする
    // （設計レビュー: アンカーがbottomと同値だと確定レップが常に満点飽和するバグの修正）。
    let depthScore = linMap(minElbow, 140, 75, 0, 40)
    // ロックアウト(0〜35): FSMのtop(160)より緩い175を満点アンカーにしているため
    // ぎりぎり合格〜完全ロックアウトまで段階的に評価できる。
    let lockoutScore = linMap(maxElbow, 150, 175, 0, 35)
    // 背中の反り(0〜25): 横向き時のみ評価(バーを頭上へ押す際に背中で代償していないか)。
    let backScore = sideView ? 25 * (1 - linMap(maxLean, 20, 40, 0, 1)) : 25

    var faults: [RepFault] = []
    // 深さ不足: bottom(90)から shallowFaultMargin だけ手前 = 「ラックの浅い位置で止まった」を検出。
    if minElbow > 90 - PoseConstants.shallowFaultMargin {
      faults.append(RepFault(id: "depth", label: "もう少し肘を深く曲げてから押し上げましょう", severity: .warn))
    }
    // ロックアウト不足: top(160)から lockoutFaultMargin だけ先 = 「ぎりぎり合格」を検出。
    if maxElbow < 160 + PoseConstants.lockoutFaultMargin {
      faults.append(RepFault(id: "lockout", label: "腕が伸び切っていません", severity: .warn))
    }
    if sideView && maxLean > 35 {
      faults.append(RepFault(id: "back", label: "上体が反りすぎています", severity: .warn))
    }

    return RepEvaluation(
      score: round1(min(100, depthScore + lockoutScore + backScore)),
      subScores: [
        "depth": round1(depthScore),
        "lockout": round1(lockoutScore),
        "back": round1(backScore),
      ],
      faults: faults
    )
  }

  // MARK: - 腕立て伏せ（モバイル追加種目）

  private static func evaluatePushup(_ frames: [Features]) -> RepEvaluation {
    let minElbow = frames.map(\.primaryAngle).min() ?? 0
    let maxElbow = frames.map { $0.elbowAngle ?? 0 }.max() ?? 0
    let avgDeviation = mean(frames.map { $0.bodyLineDeviation ?? 0 })
    let sideView = isSideView(frames)

    let depthScore = linMap(minElbow, 130, 80, 0, 45)
    let lockoutScore = linMap(maxElbow, 150, 175, 0, 30)
    // 体幹ライン(0〜25): 横向き時のみ評価。正面/斜めではbodyLineDeviationの
    // 幾何前提(矢状面への正対)が崩れるため固定満点にする
    // （設計レビュー: sideViewゲート欠落の修正）。
    let lineScore = sideView ? linMap(avgDeviation, 0.05, 0.25, 25, 0) : 25

    var faults: [RepFault] = []
    if minElbow > 90 - PoseConstants.shallowFaultMargin {
      faults.append(RepFault(id: "depth", label: "下ろしが浅いです（胸を床に近づけましょう）", severity: .warn))
    }
    if maxElbow < 160 + PoseConstants.lockoutFaultMargin {
      faults.append(RepFault(id: "lockout", label: "腕が伸び切っていません", severity: .warn))
    }
    if sideView && avgDeviation > 0.15 {
      faults.append(RepFault(id: "line", label: "体が一直線になっていません", severity: .warn))
    }

    return RepEvaluation(
      score: round1(min(100, depthScore + lockoutScore + lineScore)),
      subScores: [
        "depth": round1(depthScore),
        "lockout": round1(lockoutScore),
        "line": round1(lineScore),
      ],
      faults: faults
    )
  }

  // MARK: - アームカール（モバイル追加種目）

  private static func evaluateBicepCurl(_ frames: [Features]) -> RepEvaluation {
    let minElbow = frames.map(\.primaryAngle).min() ?? 0
    let avgDrift = mean(frames.map { $0.elbowDrift ?? 0 })
    let maxLean = frames.map { $0.backLeanDeg ?? 0 }.max() ?? 0
    let sideView = isSideView(frames)

    // 可動域(0〜50): 満点アンカーをFSMのbottom(50)より深い25に置く
    // （設計レビュー: アンカーがbottomと同値だと確定レップが常に40〜50点に張り付くバグの修正）。
    let romScore = linMap(minElbow, 75, 25, 0, 50)
    // 肘の安定性(0〜30)・反動なし(0〜20): 横向き時のみ評価。
    let elbowScore = sideView ? linMap(avgDrift, 0.15, 0.45, 30, 0) : 30
    let swingScore = sideView ? linMap(maxLean, 10, 30, 20, 0) : 20

    var faults: [RepFault] = []
    if minElbow > 50 - PoseConstants.shallowFaultMargin {
      faults.append(RepFault(id: "rom", label: "最後まで曲げ切れていません", severity: .warn))
    }
    if sideView && avgDrift > 0.35 {
      faults.append(RepFault(id: "elbow", label: "肘が前に流れています", severity: .warn))
    }
    if sideView && maxLean > 25 {
      faults.append(RepFault(id: "swing", label: "反動を使っています", severity: .warn))
    }

    return RepEvaluation(
      score: round1(min(100, romScore + elbowScore + swingScore)),
      subScores: [
        "rom": round1(romScore),
        "elbow": round1(elbowScore),
        "swing": round1(swingScore),
      ],
      faults: faults
    )
  }

  // MARK: - ベントオーバーロー（モバイル追加種目）

  private static func evaluateBentOverRow(_ frames: [Features]) -> RepEvaluation {
    let minElbow = frames.map(\.primaryAngle).min() ?? 0
    let maxElbow = frames.map { $0.elbowAngle ?? 0 }.max() ?? 0
    let leanStd = std(frames.map { $0.backLeanDeg ?? 0 })
    let sideView = isSideView(frames)

    let romScore = linMap(minElbow, 100, 60, 0, 50)
    let backScore = sideView ? 30 * (1 - linMap(leanStd, 5, 20, 0, 1)) : 30
    let lockoutScore = linMap(maxElbow, 150, 175, 0, 20)

    var faults: [RepFault] = []
    if minElbow > 70 - PoseConstants.shallowFaultMargin {
      faults.append(RepFault(id: "rom", label: "肘を十分に引けていません", severity: .warn))
    }
    if sideView && leanStd > 18 {
      faults.append(RepFault(id: "back", label: "上体が安定していません", severity: .warn))
    }
    if maxElbow < 165 + PoseConstants.lockoutFaultMargin {
      faults.append(RepFault(id: "lockout", label: "腕が伸びきっていません", severity: .info))
    }

    return RepEvaluation(
      score: round1(min(100, romScore + backScore + lockoutScore)),
      subScores: [
        "rom": round1(romScore),
        "back": round1(backScore),
        "lockout": round1(lockoutScore),
      ],
      faults: faults
    )
  }

  // MARK: - ランジ（モバイル追加種目。スクワットと同型のロジックを前脚に適用）

  private static func evaluateLunge(_ frames: [Features]) -> RepEvaluation {
    let minKnee = frames.map(\.primaryAngle).min() ?? 0
    // isParallelはRepCounterのbottom閾値とは独立した幾何指標（設計レビュー対応）。
    let reachedDeep = frames.contains { $0.isParallel == true }
    let bottomFrames = frames.filter { ($0.kneeAngle ?? 180) < 130 }
    let kneeFrames = bottomFrames.isEmpty ? frames : bottomFrames
    let avgKneeOverToe = mean(kneeFrames.map { max(0, $0.kneeOverToe ?? 0) })
    let maxLean = frames.map { $0.backLeanDeg ?? 0 }.max() ?? 0
    let leanStd = std(frames.map { $0.backLeanDeg ?? 0 })
    let sideView = isSideView(frames)

    let depthScore = reachedDeep ? 45 : linMap(minKnee, 140, 95, 0, 44)
    let kneeScore = sideView ? linMap(avgKneeOverToe, 0.35, 0.9, 30, 0) : 30
    var backScore = 25.0
    if sideView {
      let leanPenalty = linMap(maxLean, 45, 70, 0, 1)
      let stabPenalty = linMap(leanStd, 4, 15, 0, 1)
      backScore = max(0, 25 * (1 - 0.6 * leanPenalty - 0.4 * stabPenalty))
    }

    var faults: [RepFault] = []
    // FSMのbottom(100)から離した閾値を使う（squatの同種fault(115 vs bottom110)は
    // 実は到達不能なデッドコードだが、パリティ制約のため変更しない。lungeは
    // パリティ対象外なので正しく到達可能な閾値(bottom-margin)を採用する）。
    if !reachedDeep && minKnee > 100 - PoseConstants.shallowFaultMargin {
      faults.append(RepFault(id: "depth", label: "前足の曲げが浅いです（もう少し深く）", severity: .warn))
    }
    if sideView && avgKneeOverToe > 0.6 {
      faults.append(RepFault(id: "knee", label: "前膝がつま先より前に出すぎています", severity: .warn))
    }
    if sideView && maxLean > 65 {
      faults.append(RepFault(id: "back", label: "体が前に倒れすぎています", severity: .warn))
    }
    if sideView && leanStd > 15 {
      faults.append(RepFault(id: "back-stability", label: "姿勢が安定していません", severity: .info))
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

  // MARK: - ヒップスラスト（モバイル追加種目）

  private static func evaluateHipThrust(_ frames: [Features]) -> RepEvaluation {
    let minHip = frames.map(\.primaryAngle).min() ?? 0
    let maxHip = frames.map(\.primaryAngle).max() ?? 0

    // ロックアウト(0〜50): FSMのtop(170)より緩い178を満点アンカーにする。
    let lockoutScore = linMap(maxHip, 150, 178, 0, 50)
    // 可動域(0〜20): 満点アンカーをFSMのbottom(100)より深い75に置く
    // （設計レビュー相当の検証で発見: アンカーがbottomに近すぎるとスコアが張り付くため）。
    let romScore = linMap(minHip, 140, 75, 0, 20)

    // 膝角度の安定性(0〜30): レップ中で股関節角度が最大(ロックアウト付近)になる
    // フレームの膝角度を90度と比較する。ピーク付近の窓平均ではなく単一フレームで
    // 判定するシンプルな実装にする（実装・テストの容易さを優先）。
    let peakFrame = frames.max(by: { $0.primaryAngle < $1.primaryAngle })
    let kneeDeviation = abs((peakFrame?.kneeAngle ?? 90) - 90)
    let kneeScore = 30 - linMap(kneeDeviation, 5, 30, 0, 30)

    var faults: [RepFault] = []
    if maxHip < 170 + PoseConstants.lockoutFaultMargin {
      faults.append(RepFault(id: "lockout", label: "腰が伸び切っていません", severity: .warn))
    }
    if kneeDeviation > 25 {
      faults.append(RepFault(id: "knee", label: "膝の角度がずれています（90度を意識）", severity: .info))
    }
    if minHip > 100 - PoseConstants.shallowFaultMargin {
      faults.append(RepFault(id: "rom", label: "腰を十分に下げられていません", severity: .info))
    }

    return RepEvaluation(
      score: round1(min(100, lockoutScore + kneeScore + romScore)),
      subScores: [
        "lockout": round1(lockoutScore),
        "knee": round1(kneeScore),
        "rom": round1(romScore),
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
    case .overheadPress:
      return evaluateOverheadPress(frames)
    case .pushup:
      return evaluatePushup(frames)
    case .bicepCurl:
      return evaluateBicepCurl(frames)
    case .bentOverRow:
      return evaluateBentOverRow(frames)
    case .lunge:
      return evaluateLunge(frames)
    case .hipThrust:
      return evaluateHipThrust(frames)
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
    case (.overheadPress, "depth"): return "もう少し肘を深く曲げてから押し上げましょう"
    case (.overheadPress, "lockout"): return "腕が伸び切っていません"
    case (.overheadPress, "back"): return "上体が反りすぎています"
    case (.pushup, "depth"): return "下ろしが浅いです（胸を床に近づけましょう）"
    case (.pushup, "lockout"): return "腕が伸び切っていません"
    case (.pushup, "line"): return "体が一直線になっていません"
    case (.bicepCurl, "rom"): return "最後まで曲げ切れていません"
    case (.bicepCurl, "elbow"): return "肘が前に流れています"
    case (.bicepCurl, "swing"): return "反動を使っています"
    case (.bentOverRow, "rom"): return "肘を十分に引けていません"
    case (.bentOverRow, "back"): return "上体が安定していません"
    case (.bentOverRow, "lockout"): return "腕が伸びきっていません"
    case (.lunge, "depth"): return "前足の曲げが浅いです（もう少し深く）"
    case (.lunge, "knee"): return "前膝がつま先より前に出すぎています"
    case (.lunge, "back"): return "体が前に倒れすぎています"
    case (.lunge, "back-stability"): return "姿勢が安定していません"
    case (.hipThrust, "lockout"): return "腰が伸び切っていません"
    case (.hipThrust, "knee"): return "膝の角度がずれています（90度を意識）"
    case (.hipThrust, "rom"): return "腰を十分に下げられていません"
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
    case "line": return "姿勢"
    case "elbow": return "肘の安定性"
    case "swing": return "反動"
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
    case (.overheadPress, "depth"): return 40
    case (.overheadPress, "lockout"): return 35
    case (.overheadPress, "back"): return 25
    case (.pushup, "depth"): return 45
    case (.pushup, "lockout"): return 30
    case (.pushup, "line"): return 25
    case (.bicepCurl, "rom"): return 50
    case (.bicepCurl, "elbow"): return 30
    case (.bicepCurl, "swing"): return 20
    case (.bentOverRow, "rom"): return 50
    case (.bentOverRow, "back"): return 30
    case (.bentOverRow, "lockout"): return 20
    case (.lunge, "depth"): return 45
    case (.lunge, "knee"): return 30
    case (.lunge, "back"): return 25
    case (.hipThrust, "lockout"): return 50
    case (.hipThrust, "knee"): return 30
    case (.hipThrust, "rom"): return 20
    case (.other, "rom"): return 100
    default: return 100
    }
  }
}
