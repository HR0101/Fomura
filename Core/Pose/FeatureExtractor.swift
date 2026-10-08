//
//  FeatureExtractor.swift
//  Fomura
//
//  特徴量抽出（フォーム判定モデルの入力層）。
//  MediaPipe の 33 関節座標から、フォーム評価に直結する角度・距離・撮影条件を算出する。
//  squat/deadlift/bench_press の移植元: frontend/lib/pose/features.ts（数式・しきい値は無変更）。
//  それ以外の種目（overheadPress以降）はモバイル版で追加した独自実装（設計レビュー済み）。
//  設計方針:
//    - 左右は「見えている側」を採用し、横向き撮影でも精度が落ちないようにする。
//    - 水平方向の距離は下腿長などで正規化し、画面内の被写体サイズに依存しないようにする。
//    - 肩幅と胴長の比から撮影アングル（正面/横向き）を推定し、後段の判定をゲートする。
//

import Foundation

// 1フレーム分の特徴量（Web版 Features 型を拡張。追加種目用フィールドはWeb版に対応なし）。
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
  // 肘が体幹から前方へ流れた量（前腕長で正規化、符号なし）。アームカール用。
  var elbowDrift: Double?
  // 肩-股関節-足首の一直線からのズレ（無次元比率、符号なし）。プッシュアップの体幹ライン用。
  var bodyLineDeviation: Double?
}

// 左右どちらの側のランドマークを採用するか（脚選択・腕選択で共用）。
enum BodySide: String, CaseIterable, Identifiable, Sendable {
  case left
  case right

  var id: String { rawValue }

  var displayName: String {
    self == .left ? "左足前" : "右足前"
  }
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

  // 下半身（股関節・膝・足首）の可視性が高い側を返す。横向き撮影で手前側を選ぶ。
  // 注意: これは「カメラに近い側」を選ぶだけで「前に出している脚」等の意味は持たない。
  // 左右対称運動（squat/deadlift）ではどちらを選んでも結果が同じだが、非対称運動
  // （lunge等）では意味論的に不十分（設計レビューで指摘済み）。lungeでは明示的な
  // leadingLeg指定を優先し、これはあくまで指定が無い場合のフォールバックとする。
  private static func pickLegSide(_ lms: [Landmark]) -> BodySide {
    let left = visibilityOf(lms, LandmarkIndex.leftHip)
      + visibilityOf(lms, LandmarkIndex.leftKnee)
      + visibilityOf(lms, LandmarkIndex.leftAnkle)
    let right = visibilityOf(lms, LandmarkIndex.rightHip)
      + visibilityOf(lms, LandmarkIndex.rightKnee)
      + visibilityOf(lms, LandmarkIndex.rightAnkle)
    return right > left ? .right : .left
  }

  // 上半身（肩・肘・手首）の可視性が高い側を返す（pickLegSideの腕版）。
  // アームカール・ロー等、片腕動作を1本の腕として一貫して追跡するために使う
  // （左右平均だと、片腕ずつ動くダンベル系種目で可動域が実態より圧縮される問題を避ける）。
  private static func pickArmSide(_ lms: [Landmark]) -> BodySide {
    let left = visibilityOf(lms, LandmarkIndex.leftShoulder)
      + visibilityOf(lms, LandmarkIndex.leftElbow)
      + visibilityOf(lms, LandmarkIndex.leftWrist)
    let right = visibilityOf(lms, LandmarkIndex.rightShoulder)
      + visibilityOf(lms, LandmarkIndex.rightElbow)
      + visibilityOf(lms, LandmarkIndex.rightWrist)
    return right > left ? .right : .left
  }

  // 選択した側の下半身関節インデックス束。
  private static func legJoints(_ side: BodySide)
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

  // 選択した側の上半身関節インデックス束。
  private static func armJoints(_ side: BodySide) -> (shoulder: Int, elbow: Int, wrist: Int) {
    switch side {
    case .left:
      return (LandmarkIndex.leftShoulder, LandmarkIndex.leftElbow, LandmarkIndex.leftWrist)
    case .right:
      return (LandmarkIndex.rightShoulder, LandmarkIndex.rightElbow, LandmarkIndex.rightWrist)
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

  // 肩-股関節-足首の一直線からのズレ（無次元比率、符号なし）。プッシュアップの体幹ライン評価に使う。
  // 点-直線距離の公式 |cross|/|AB| を求め、さらに |AB| で割って無次元化する
  // （kneeOverToeと同じ「距離を参照長で正規化する」設計に合わせる）。
  // 符号(腰が落ちている/上がりすぎている)は区別しない設計（v1の割り切り。設計レビューで妥当性を確認済み）。
  private static func bodyLineDeviation(shoulder: Vec2, hip: Vec2, ankle: Vec2) -> Double {
    let abX = ankle.x - shoulder.x
    let abY = ankle.y - shoulder.y
    let apX = hip.x - shoulder.x
    let apY = hip.y - shoulder.y
    let cross = abX * apY - abY * apX
    let abLen = hypot(abX, abY) + PoseConstants.epsilon
    return abs(cross) / (abLen * abLen)
  }

  // MARK: - スクワット・デッドリフト（下半身種目、squat/deadliftはWeb版と同一実装）

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

  // MARK: - ベンチプレス（Web版と同一実装。両腕とも十分可視なら平均を採用）

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

  // MARK: - ショルダープレス（オーバーヘッドプレス。モバイル追加種目）

  // ベンチプレスと同じ「両腕可視なら平均」ロジック。バーベル/ダンベルとも両腕同時動作が
  // 基本のため、ベンチプレスと同様に左右平均で問題ない（設計レビューで妥当性を確認済み）。
  private static func overheadPressFeatures(_ lms: [Landmark]) -> Features {
    let elbowLeft = calculateAngle(
      vec(lms, LandmarkIndex.leftShoulder), vec(lms, LandmarkIndex.leftElbow), vec(lms, LandmarkIndex.leftWrist)
    )
    let elbowRight = calculateAngle(
      vec(lms, LandmarkIndex.rightShoulder), vec(lms, LandmarkIndex.rightElbow), vec(lms, LandmarkIndex.rightWrist)
    )
    let visLeft = averageVisibility(lms, [
      LandmarkIndex.leftShoulder, LandmarkIndex.leftElbow, LandmarkIndex.leftWrist,
    ])
    let visRight = averageVisibility(lms, [
      LandmarkIndex.rightShoulder, LandmarkIndex.rightElbow, LandmarkIndex.rightWrist,
    ])
    let bothVisible = visLeft > PoseConstants.visibilityFloor && visRight > PoseConstants.visibilityFloor
    let elbowAngle = bothVisible ? (elbowLeft + elbowRight) / 2 : (visLeft >= visRight ? elbowLeft : elbowRight)

    return Features(
      primaryAngle: elbowAngle,
      elbowAngle: elbowAngle,
      // 上体の反り（バーを頭上へ押し上げる際に背中で代償していないか）を評価するため計算する。
      backLeanDeg: backLeanDeg(lms),
      elbowSymmetryDeg: bothVisible ? abs(elbowLeft - elbowRight) : 0,
      sideViewConfidence: sideViewConfidence(lms),
      visibility: max(visLeft, visRight)
    )
  }

  // MARK: - 腕立て伏せ（プッシュアップ。モバイル追加種目）

  // 遠位側の腕・体幹ラインは近位側に隠れやすいため、ベンチプレス式の左右平均ではなく
  // pickArmSideで片側に一本化し、肘角度・体幹ライン評価とも同じ側の関節を使う
  // （設計レビュー: 遮蔽による角度のジャンプノイズと、体幹ライン計算の左右不一致を同時に解消）。
  private static func pushupFeatures(_ lms: [Landmark]) -> Features {
    let side = pickArmSide(lms)
    let arm = armJoints(side)
    let leg = legJoints(side)

    let elbowAngle = calculateAngle(vec(lms, arm.shoulder), vec(lms, arm.elbow), vec(lms, arm.wrist))
    let deviation = bodyLineDeviation(
      shoulder: vec(lms, arm.shoulder), hip: vec(lms, leg.hip), ankle: vec(lms, leg.ankle)
    )

    return Features(
      primaryAngle: elbowAngle,
      elbowAngle: elbowAngle,
      backLeanDeg: backLeanDeg(lms),
      sideViewConfidence: sideViewConfidence(lms),
      visibility: averageVisibility(lms, [arm.shoulder, arm.elbow, arm.wrist, leg.hip, leg.ankle]),
      bodyLineDeviation: deviation
    )
  }

  // MARK: - アームカール（バイセップカール。モバイル追加種目）

  // 片腕ダンベルカール（左右非対称動作）に対応するため、ベンチプレス式の左右平均は使わず
  // pickArmSideで可視性の高い片腕のみを一貫して追跡する（設計レビューで指摘された、
  // 平均化による可動域の圧縮を避けるため）。
  private static func bicepCurlFeatures(_ lms: [Landmark]) -> Features {
    let arm = armJoints(pickArmSide(lms))

    let elbowAngle = calculateAngle(vec(lms, arm.shoulder), vec(lms, arm.elbow), vec(lms, arm.wrist))

    // 肘の体幹からの前方への流れ（前腕長で正規化。上腕長で割ると自己参照的になり
    // 上腕の傾き角と等価になってしまうため、独立した参照長として前腕長を使う）。
    let forearmLen = distance(vec(lms, arm.elbow), vec(lms, arm.wrist)) + PoseConstants.epsilon
    let elbowDrift = abs(lms[arm.elbow].x - lms[arm.shoulder].x) / forearmLen

    return Features(
      primaryAngle: elbowAngle,
      elbowAngle: elbowAngle,
      backLeanDeg: backLeanDeg(lms),
      sideViewConfidence: sideViewConfidence(lms),
      // 反動評価(backLeanDeg)が股関節座標に依存するため、可視性にも股関節を含める
      // （設計レビュー: upperBodyOnly系のプロファイルだと股関節可視性が保証されない問題への対処）。
      visibility: averageVisibility(lms, [arm.shoulder, arm.elbow, arm.wrist, LandmarkIndex.leftHip, LandmarkIndex.rightHip]),
      elbowDrift: elbowDrift
    )
  }

  // MARK: - ベントオーバーロー（モバイル追加種目）

  // アームカールと同じ理由でpickArmSideによる片腕一本化を採用する。
  private static func bentOverRowFeatures(_ lms: [Landmark]) -> Features {
    let arm = armJoints(pickArmSide(lms))

    let elbowAngle = calculateAngle(vec(lms, arm.shoulder), vec(lms, arm.elbow), vec(lms, arm.wrist))

    return Features(
      primaryAngle: elbowAngle,
      elbowAngle: elbowAngle,
      // 上体（ヒンジ姿勢）の安定性評価に必須。ベンチプレスのfeatures関数を単純流用すると
      // これらが未計算のままになる点が設計レビューで指摘されたため、明示的に計算する。
      backLeanDeg: backLeanDeg(lms),
      sideViewConfidence: sideViewConfidence(lms),
      visibility: averageVisibility(lms, [arm.shoulder, arm.elbow, arm.wrist, LandmarkIndex.leftHip, LandmarkIndex.rightHip])
    )
  }

  // MARK: - ランジ（モバイル追加種目）

  // スクワットは左右対称運動のため可視性ベースのpickLegSideで問題ないが、ランジは
  // 前脚と後脚で角度プロファイルが大きく異なる非対称運動であるため、呼び出し側
  // （UI）で明示的に前脚(leadingLeg)を指定できるようにし、精度を担保する。
  // 指定が無い場合はpickLegSideへフォールバックする（設計レビュー: フレーム間で
  // 選択脚が入れ替わるリスクがあるため、精度を優先する場合は明示指定を推奨）。
  private static func lungeFeatures(_ lms: [Landmark], leadingLeg: BodySide?) -> Features {
    let side = leadingLeg ?? pickLegSide(lms)
    let j = legJoints(side)

    let kneeAngle = calculateAngle(vec(lms, j.hip), vec(lms, j.knee), vec(lms, j.ankle))
    let hipY = lms[j.hip].y
    let kneeY = lms[j.knee].y

    let footDelta = lms[j.foot].x - lms[j.heel].x
    let forwardSign: Double = footDelta > 0 ? 1 : (footDelta < 0 ? -1 : 1)
    let shankLen = distance(vec(lms, j.knee), vec(lms, j.ankle)) + PoseConstants.epsilon
    let kneeOverToe = ((lms[j.knee].x - lms[j.foot].x) * forwardSign) / shankLen

    return Features(
      primaryAngle: kneeAngle,
      kneeAngle: kneeAngle,
      hipBelowKnee: hipY - kneeY,
      // スクワットのisParallelと同じ「独立した位置ベース指標」。RepCounterのbottom閾値と
      // 同じ角度をそのまま満点条件にすると恒真になるバグが設計レビューで見つかったため、
      // 幾何的な独立指標として算出する。
      isParallel: hipY >= kneeY,
      kneeOverToe: kneeOverToe,
      backLeanDeg: backLeanDeg(lms),
      sideViewConfidence: sideViewConfidence(lms),
      visibility: averageVisibility(lms, [j.hip, j.knee, j.ankle, j.shoulder])
    )
  }

  // MARK: - ヒップスラスト（モバイル追加種目）

  private static func hipThrustFeatures(_ lms: [Landmark]) -> Features {
    let j = legJoints(pickLegSide(lms))

    let hipAngle = calculateAngle(vec(lms, j.shoulder), vec(lms, j.hip), vec(lms, j.knee))
    let kneeAngle = calculateAngle(vec(lms, j.hip), vec(lms, j.knee), vec(lms, j.ankle))

    return Features(
      primaryAngle: hipAngle,
      kneeAngle: kneeAngle,
      hipAngle: hipAngle,
      sideViewConfidence: sideViewConfidence(lms),
      visibility: averageVisibility(lms, [j.hip, j.knee, j.shoulder])
    )
  }

  // MARK: - 公開インターフェース

  // 種目に応じた特徴量を算出する（Web版 computeFeatures を拡張）。
  // leadingLeg は lunge 専用（それ以外の種目では無視される）。
  static func compute(_ lms: [Landmark], exercise: ExerciseType, leadingLeg: BodySide? = nil) -> Features {
    switch exercise {
    case .squat:
      return squatFeatures(lms)
    case .deadlift:
      return deadliftFeatures(lms)
    case .benchPress:
      return benchPressFeatures(lms)
    case .overheadPress:
      return overheadPressFeatures(lms)
    case .pushup:
      return pushupFeatures(lms)
    case .bicepCurl:
      return bicepCurlFeatures(lms)
    case .bentOverRow:
      return bentOverRowFeatures(lms)
    case .lunge:
      return lungeFeatures(lms, leadingLeg: leadingLeg)
    case .hipThrust:
      return hipThrustFeatures(lms)
    case .other:
      return deadliftFeatures(lms)
    }
  }
}
