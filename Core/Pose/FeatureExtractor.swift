//
//  FeatureExtractor.swift
//  Fomura
//
//  特徴量抽出（フォーム判定モデルの入力層）。
//  MediaPipe の 33 関節座標から、フォーム評価に直結する角度・距離・撮影条件を算出する。
//  移植元: frontend/lib/pose/features.ts（数式・しきい値は無変更）
//  設計方針:
//    - 左右は「見えている側」を採用し、横向き撮影でも精度が落ちないようにする。
//    - 水平方向の距離は下腿長などで正規化し、画面内の被写体サイズに依存しないようにする。
//    - 肩幅と胴長の比から撮影アングル（正面/横向き）を推定し、後段の判定をゲートする。
//

import Foundation

// 1フレーム分の特徴量（Web版 Features 型と同一構成）。
struct Features: Sendable {
  // レップ検出に使う主角度（種目により膝/股関節/肘）
  let primaryAngle: Double
  var kneeAngle: Double?
  var hipAngle: Double?
  var elbowAngle: Double?
  // 股関節Y - 膝Y（正なら股関節が膝より下＝パラレル以上）
  var hipBelowKnee: Double?
  var isParallel: Bool?
  // 膝が前方（つま先方向）へ出た量。下腿長で正規化した比（正=つま先より前）。
  var kneeOverToe: Double?
  // 胴体（肩-股関節）の鉛直からの前傾角度（度）。横向き撮影でのみ信頼できる。
  var backLeanDeg: Double?
  // 左右の肘角度差（度）。ベンチプレスの左右バランス指標。
  var elbowSymmetryDeg: Double?
  // 横向き撮影である確信度（0=正面 〜 1=真横）。前傾など奥行き系判定のゲートに使う。
  var sideViewConfidence: Double?
  // 評価に用いた主要関節の平均可視性（0〜1）。低いと判定を保留する。
  var visibility: Double?
}

enum FeatureExtractor {
  private typealias Vec2 = (x: Double, y: Double)

  // MARK: - 基本計算

  private static func vec(_ lms: [Landmark], _ idx: Int) -> Vec2 {
    (lms[idx].x, lms[idx].y)
  }

  private static func visibilityOf(_ lms: [Landmark], _ idx: Int) -> Double {
    lms[idx].visibility ?? 1
  }

  // 3点 a-b-c がなす、頂点 b における角度（度）。
  static func calculateAngle(
    _ a: (x: Double, y: Double),
    _ b: (x: Double, y: Double),
    _ c: (x: Double, y: Double)
  ) -> Double {
    let baX = a.x - b.x
    let baY = a.y - b.y
    let bcX = c.x - b.x
    let bcY = c.y - b.y
    let dot = baX * bcX + baY * bcY
    let denom = hypot(baX, baY) * hypot(bcX, bcY) + PoseConstants.epsilon
    let cosine = max(-1, min(1, dot / denom))
    return acos(cosine) * 180 / .pi
  }

  private static func distance(_ a: Vec2, _ b: Vec2) -> Double {
    hypot(a.x - b.x, a.y - b.y)
  }

  // 主要関節の平均可視性。
  private static func averageVisibility(_ lms: [Landmark], _ indices: [Int]) -> Double {
    indices.reduce(0.0) { $0 + visibilityOf(lms, $1) } / Double(indices.count)
  }

  // MARK: - 人物妥当性判定

  // 体幹コアの4点。どの種目でも人が映っていれば高い可視性を持つ。
  private static let personCore = [
    LandmarkIndex.leftShoulder,
    LandmarkIndex.rightShoulder,
    LandmarkIndex.leftHip,
    LandmarkIndex.rightHip,
  ]

  // 検出された姿勢が「実際に人である」確からしさを判定する。
  // MediaPipe が人以外に骨格を当ててしまった場合を、体幹コアの可視性で足切りする。
  static func isLikelyPerson(_ lms: [Landmark]?) -> Bool {
    guard let lms, lms.count >= 33 else { return false }
    return averageVisibility(lms, personCore) >= PoseConstants.personMinVisibility
  }

  // MARK: - 側の選択

  private enum Side { case left, right }

  // 下半身（股関節・膝・足首）の可視性が高い側を返す。横向き撮影で手前側を選ぶ。
  private static func pickLegSide(_ lms: [Landmark]) -> Side {
    let left = visibilityOf(lms, LandmarkIndex.leftHip)
      + visibilityOf(lms, LandmarkIndex.leftKnee)
      + visibilityOf(lms, LandmarkIndex.leftAnkle)
    let right = visibilityOf(lms, LandmarkIndex.rightHip)
      + visibilityOf(lms, LandmarkIndex.rightKnee)
      + visibilityOf(lms, LandmarkIndex.rightAnkle)
    return right > left ? .right : .left
  }

  // 選択した側の関節インデックス束。
  private static func legJoints(_ side: Side)
    -> (shoulder: Int, hip: Int, knee: Int, ankle: Int, heel: Int, foot: Int) {
    switch side {
    case .left:
      return (
        LandmarkIndex.leftShoulder, LandmarkIndex.leftHip, LandmarkIndex.leftKnee,
        LandmarkIndex.leftAnkle, LandmarkIndex.leftHeel, LandmarkIndex.leftFootIndex
      )
    case .right:
      return (
        LandmarkIndex.rightShoulder, LandmarkIndex.rightHip, LandmarkIndex.rightKnee,
        LandmarkIndex.rightAnkle, LandmarkIndex.rightHeel, LandmarkIndex.rightFootIndex
      )
    }
  }

  // MARK: - 共通特徴量

  // 胴体（肩中点-股関節中点）の鉛直からの前傾角度。
  static func backLeanDeg(_ lms: [Landmark]) -> Double {
    let shoulderX = (lms[LandmarkIndex.leftShoulder].x + lms[LandmarkIndex.rightShoulder].x) / 2
    let shoulderY = (lms[LandmarkIndex.leftShoulder].y + lms[LandmarkIndex.rightShoulder].y) / 2
    let hipX = (lms[LandmarkIndex.leftHip].x + lms[LandmarkIndex.rightHip].x) / 2
    let hipY = (lms[LandmarkIndex.leftHip].y + lms[LandmarkIndex.rightHip].y) / 2
    let torsoX = shoulderX - hipX
    let torsoY = shoulderY - hipY
    // 画像座標の「上」= (0, -1)
    let dot = torsoY * -1
    let denom = hypot(torsoX, torsoY) + PoseConstants.epsilon
    let cosine = max(-1, min(1, dot / denom))
    return acos(cosine) * 180 / .pi
  }

  // 横向き撮影である確信度（0〜1）。肩幅が胴長に対して狭いほど「真横」とみなす。
  static func sideViewConfidence(_ lms: [Landmark]) -> Double {
    let shoulderMid: Vec2 = (
      (lms[LandmarkIndex.leftShoulder].x + lms[LandmarkIndex.rightShoulder].x) / 2,
      (lms[LandmarkIndex.leftShoulder].y + lms[LandmarkIndex.rightShoulder].y) / 2
    )
    let hipMid: Vec2 = (
      (lms[LandmarkIndex.leftHip].x + lms[LandmarkIndex.rightHip].x) / 2,
      (lms[LandmarkIndex.leftHip].y + lms[LandmarkIndex.rightHip].y) / 2
    )
    let shoulderWidth = abs(lms[LandmarkIndex.leftShoulder].x - lms[LandmarkIndex.rightShoulder].x)
    let torsoLen = distance(shoulderMid, hipMid) + PoseConstants.epsilon
    let ratio = shoulderWidth / torsoLen
    // ratio<=0.20 を真横(1.0)、ratio>=0.45 を正面(0.0) として線形に補間する。
    let sideRatio = 0.2
    let frontRatio = 0.45
    return max(0, min(1, (frontRatio - ratio) / (frontRatio - sideRatio)))
  }

  // MARK: - 種目別特徴量

  private static func squatFeatures(_ lms: [Landmark]) -> Features {
    let j = legJoints(pickLegSide(lms))

    let kneeAngle = calculateAngle(vec(lms, j.hip), vec(lms, j.knee), vec(lms, j.ankle))
    let hipAngle = calculateAngle(vec(lms, j.shoulder), vec(lms, j.hip), vec(lms, j.knee))

    let hipY = lms[j.hip].y
    let kneeY = lms[j.knee].y

    // 足の向き（つま先が踵よりどちら側か）で「前方」符号を決める。
    let footDelta = lms[j.foot].x - lms[j.heel].x
    let forwardSign: Double = footDelta > 0 ? 1 : (footDelta < 0 ? -1 : 1)
    // 下腿長で正規化した膝の前方突出量（正=つま先より前）。
    let shankLen = distance(vec(lms, j.knee), vec(lms, j.ankle)) + PoseConstants.epsilon
    let kneeOverToe = ((lms[j.knee].x - lms[j.foot].x) * forwardSign) / shankLen

    return Features(
      primaryAngle: kneeAngle,
      kneeAngle: kneeAngle,
      hipAngle: hipAngle,
      hipBelowKnee: hipY - kneeY,
      isParallel: hipY >= kneeY,
      kneeOverToe: kneeOverToe,
      backLeanDeg: backLeanDeg(lms),
      sideViewConfidence: sideViewConfidence(lms),
      visibility: averageVisibility(lms, [j.hip, j.knee, j.ankle, j.shoulder])
    )
  }

  private static func deadliftFeatures(_ lms: [Landmark]) -> Features {
    let j = legJoints(pickLegSide(lms))

    let hipAngle = calculateAngle(vec(lms, j.shoulder), vec(lms, j.hip), vec(lms, j.knee))
    let kneeAngle = calculateAngle(vec(lms, j.hip), vec(lms, j.knee), vec(lms, j.ankle))

    // デッドリフトはヒンジ動作のため股関節角度を主角度にする
    return Features(
      primaryAngle: hipAngle,
      kneeAngle: kneeAngle,
      hipAngle: hipAngle,
      backLeanDeg: backLeanDeg(lms),
      sideViewConfidence: sideViewConfidence(lms),
      visibility: averageVisibility(lms, [j.hip, j.knee, j.ankle, j.shoulder])
    )
  }

  private static func benchPressFeatures(_ lms: [Landmark]) -> Features {
    let elbowLeft = calculateAngle(
      vec(lms, LandmarkIndex.leftShoulder),
      vec(lms, LandmarkIndex.leftElbow),
      vec(lms, LandmarkIndex.leftWrist)
    )
    let elbowRight = calculateAngle(
      vec(lms, LandmarkIndex.rightShoulder),
      vec(lms, LandmarkIndex.rightElbow),
      vec(lms, LandmarkIndex.rightWrist)
    )

    // 見えている腕を優先して主角度に採用する。
    let visLeft = averageVisibility(lms, [
      LandmarkIndex.leftShoulder, LandmarkIndex.leftElbow, LandmarkIndex.leftWrist,
    ])
    let visRight = averageVisibility(lms, [
      LandmarkIndex.rightShoulder, LandmarkIndex.rightElbow, LandmarkIndex.rightWrist,
    ])
    let bothVisible = visLeft > PoseConstants.visibilityFloor && visRight > PoseConstants.visibilityFloor
    let elbowAngle = bothVisible
      ? (elbowLeft + elbowRight) / 2
      : (visLeft >= visRight ? elbowLeft : elbowRight)

    return Features(
      primaryAngle: elbowAngle,
      elbowAngle: elbowAngle,
      // 左右差は両腕が見えているときのみ意味を持つ。
      elbowSymmetryDeg: bothVisible ? abs(elbowLeft - elbowRight) : 0,
      visibility: max(visLeft, visRight)
    )
  }

  // 種目に応じた特徴量を算出する（Web版 computeFeatures と同一）。
  static func compute(_ lms: [Landmark], exercise: ExerciseType) -> Features {
    switch exercise {
    case .squat:
      return squatFeatures(lms)
    case .deadlift:
      return deadliftFeatures(lms)
    case .benchPress:
      return benchPressFeatures(lms)
    case .other:
      return deadliftFeatures(lms)
    }
  }
}
