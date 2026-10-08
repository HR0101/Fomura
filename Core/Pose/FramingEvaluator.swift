//
//  FramingEvaluator.swift
//  Fomura
//
//  撮影ガイド（フレーミング補助）。
//  種目ごとの推奨アングルを定義し、現在の映り方から「もう少し上／左」などの
//  具体的な補正指示をリアルタイムに算出する。適切なアングルはフォーム判定の
//  精度を大きく左右するため、判定モデルの前提条件チェックも兼ねる。
//  squat/deadlift/bench_pressの移植元: frontend/lib/pose/framing.ts（しきい値・文言は無変更）。
//  それ以外はモバイル版で追加した種目（設計レビュー済み）。
//

import Foundation

// 撮影ガイドの1メッセージ。severity で表示色を切り替える。
struct FramingHint: Sendable, Equatable, Identifiable {
  let id: String
  let label: String
  let severity: Severity
}

struct FramingResult: Sendable, Equatable {
  // すべての条件を満たし、判定に適した映りかどうか。
  let ok: Bool
  let hints: [FramingHint]
}

// 種目ごとの推奨アングル（開始前の案内カードに表示する静的情報）。
struct RecommendedView: Sendable {
  let view: String          // 推奨する立ち位置・向き
  let cameraHeight: String  // カメラの高さ
  let distance: String      // 距離の目安
  let reason: String        // なぜその向きが必要か
}

// 種目ごとに必要な撮影条件が異なるため、フレーミング判定をプロファイル単位に分ける。
private enum FramingProfile {
  case standingFullBody       // 頭から足首まで縦に収まる必要がある（squat/deadlift/other/overheadPress/bentOverRow/lunge）
  case standingFullBodyReach  // standingFullBody + 頭上に伸びる手首も見切れ判定に含める（overheadPress専用）
  case upperBodyOnly          // 肩・肘・手首の可視性のみ確認（benchPress）
  case upperBodyWithHip       // upperBodyOnly + 股関節の可視性も必要（bicepCurl。反動評価に股関節座標を使うため）
  case prone                  // 横たわった姿勢。肩肘手首＋股関節足首の可視性のみ確認（pushup）
  case reclined                // 仰向けに近い姿勢。肩・股関節・膝の可視性のみ確認（hipThrust）
}

enum FramingEvaluator {
  // MARK: - 静的データ（RECOMMENDED_VIEWS を拡張）

  static let recommendedViews: [ExerciseType: RecommendedView] = [
    .squat: RecommendedView(
      view: "体の真横から（全身を横向きで）",
      cameraHeight: "腰の高さ",
      distance: "全身が収まる距離（約2〜3m）",
      reason: "しゃがむ深さ・膝の前後位置・背中の角度を正確に測るため"
    ),
    .deadlift: RecommendedView(
      view: "体の真横から（全身を横向きで）",
      cameraHeight: "腰の高さ",
      distance: "全身が収まる距離（約2〜3m）",
      reason: "股関節の折りたたみ（ヒンジ）と背中の角度を見るため"
    ),
    .benchPress: RecommendedView(
      view: "ベンチの真横から",
      cameraHeight: "ベンチと同じ高さ",
      distance: "上半身（肩・肘・手首）が収まる距離",
      reason: "肘の曲げ角度とバーの上下軌道を見るため"
    ),
    .overheadPress: RecommendedView(
      view: "体の真横から（全身を横向きで）",
      cameraHeight: "腰の高さ",
      distance: "頭上に伸ばした腕まで収まる距離（約2〜3m）",
      reason: "肘の角度と体の反りを正確に測るため"
    ),
    .pushup: RecommendedView(
      view: "体の真横から（頭から足まで収まるように）",
      cameraHeight: "床と同じ高さ",
      distance: "全身が収まる距離（約1.5〜2.5m）",
      reason: "肘の曲げ角度と体幹の一直線姿勢を見るため"
    ),
    .bicepCurl: RecommendedView(
      view: "体の真横から",
      cameraHeight: "肘の高さ",
      distance: "上半身が収まる距離",
      reason: "肘の曲げ角度と肘の位置のブレを見るため"
    ),
    .bentOverRow: RecommendedView(
      view: "体の真横から（全身を横向きで）",
      cameraHeight: "腰の高さ",
      distance: "全身が収まる距離（約2〜3m）",
      reason: "肘の引き幅と上体の安定性を見るため"
    ),
    .lunge: RecommendedView(
      view: "体の真横から（前に出す脚がよく見える向きで）",
      cameraHeight: "膝の高さ",
      distance: "全身が収まる距離（約2〜3m）",
      reason: "前足の曲げ角度と膝の前後位置を測るため"
    ),
    .hipThrust: RecommendedView(
      view: "体の真横から",
      cameraHeight: "床に近い低い位置",
      distance: "肩から膝までが収まる距離",
      reason: "腰の伸び（ロックアウト）と膝の角度を見るため"
    ),
    .other: RecommendedView(
      view: "体の真横から",
      cameraHeight: "動作の中心の高さ",
      distance: "動作範囲が収まる距離",
      reason: "関節の可動域を正確に測るため"
    ),
  ]

  // MARK: - 定数（framing.ts と同値、追加分はモバイル版で新設）

  // 画面端とみなす余白（正規化座標）。この内側に主要点が無いと見切れと判定する。
  private static let edgeMargin = 0.04
  // 横方向で「中央」とみなす範囲（0.5±この値）。
  private static let centerTolerance = 0.18
  // 全身種目で被写体が十分な大きさとみなす最小の縦幅（正規化）。
  private static let minBodyHeight = 0.55

  // MARK: - 内部計算

  private static func visibilityOf(_ lms: [Landmark], _ idx: Int) -> Double {
    lms[idx].visibility ?? 1
  }

  private static func isVisible(_ lms: [Landmark], _ idx: Int) -> Bool {
    visibilityOf(lms, idx) >= PoseConstants.visibilityFloor
  }

  private static func anyVisible(_ lms: [Landmark], _ left: Int, _ right: Int) -> Bool {
    isVisible(lms, left) || isVisible(lms, right)
  }

  // 胴体の左右中心（肩中点と股関節中点の平均X）。
  private static func bodyCenterX(_ lms: [Landmark]) -> Double {
    let shoulderX = (lms[LandmarkIndex.leftShoulder].x + lms[LandmarkIndex.rightShoulder].x) / 2
    let hipX = (lms[LandmarkIndex.leftHip].x + lms[LandmarkIndex.rightHip].x) / 2
    return (shoulderX + hipX) / 2
  }

  // 横方向の寄りを補正するヒント（共通）。
  private static func centeringHint(_ lms: [Landmark]) -> FramingHint? {
    let cx = bodyCenterX(lms)
    if cx < 0.5 - centerTolerance {
      return FramingHint(
        id: "center-x", label: "被写体が左に寄っています。右に移動してください", severity: .warn
      )
    }
    if cx > 0.5 + centerTolerance {
      return FramingHint(
        id: "center-x", label: "被写体が右に寄っています。左に移動してください", severity: .warn
      )
    }
    return nil
  }

  // 横向き撮影を促すヒント（種目共通で真横が推奨）。
  private static func sideViewHint(_ lms: [Landmark]) -> FramingHint? {
    if FeatureExtractor.sideViewConfidence(lms) < PoseConstants.sideViewMin {
      return FramingHint(id: "view", label: "体の真横からカメラに映してください", severity: .warn)
    }
    return nil
  }

  // スクワット等：全身が縦に収まっているかを確認する。
  // includeWristInTopCheck: true の場合、頭上に伸びる手首も上端見切れ判定に含める
  // （overheadPress専用。設計レビュー: ロックアウト時に手首が上端で見切れるリスクへの対処）。
  private static func fullBodyHints(_ lms: [Landmark], includeWristInTopCheck: Bool = false) -> [FramingHint] {
    var hints: [FramingHint] = []

    // 上端（頭、必要なら手首も）の見切れ
    var topCandidates = [
      lms[LandmarkIndex.nose].y, lms[LandmarkIndex.leftShoulder].y, lms[LandmarkIndex.rightShoulder].y,
    ]
    if includeWristInTopCheck {
      topCandidates.append(lms[LandmarkIndex.leftWrist].y)
      topCandidates.append(lms[LandmarkIndex.rightWrist].y)
    }
    let topY = topCandidates.min() ?? 0
    if topY < edgeMargin {
      let label = includeWristInTopCheck
        ? "頭や腕が見切れています。カメラを上に向けるか少し離れてください"
        : "頭が見切れています。カメラを上に向けるか少し離れてください"
      hints.append(FramingHint(id: "top-cut", label: label, severity: .warn))
    }

    // 下端（足首）の見切れ・未検出
    let ankleVisible = isVisible(lms, LandmarkIndex.leftAnkle) || isVisible(lms, LandmarkIndex.rightAnkle)
    let bottomY = max(lms[LandmarkIndex.leftAnkle].y, lms[LandmarkIndex.rightAnkle].y)
    if !ankleVisible || bottomY > 1 - edgeMargin {
      hints.append(FramingHint(
        id: "bottom-cut",
        label: "足元が見切れています。カメラを下に向けるか少し離れてください",
        severity: .warn
      ))
    } else {
      // 見切れていないのに小さすぎる＝遠すぎる
      let bodyHeight = bottomY - topY
      if bodyHeight < minBodyHeight {
        hints.append(FramingHint(
          id: "too-far",
          label: "被写体が小さいです。もう少し近づいてください",
          severity: .info
        ))
      }
    }

    if let centering = centeringHint(lms) {
      hints.append(centering)
    }

    return hints
  }

  // ベンチプレス用：上半身（肩・肘・手首）が映っているかを確認する。
  private static func upperBodyHints(_ lms: [Landmark]) -> [FramingHint] {
    var hints: [FramingHint] = []
    let armVisible =
      (isVisible(lms, LandmarkIndex.leftShoulder)
        && isVisible(lms, LandmarkIndex.leftElbow)
        && isVisible(lms, LandmarkIndex.leftWrist))
      || (isVisible(lms, LandmarkIndex.rightShoulder)
        && isVisible(lms, LandmarkIndex.rightElbow)
        && isVisible(lms, LandmarkIndex.rightWrist))

    if !armVisible {
      hints.append(FramingHint(
        id: "arm",
        label: "肩・肘・手首が映るように腕全体をフレームに入れてください",
        severity: .warn
      ))
    }
    return hints
  }

  // アームカール用：upperBodyHints + 股関節の可視性（反動評価に必要）。
  private static func upperBodyWithHipHints(_ lms: [Landmark]) -> [FramingHint] {
    var hints = upperBodyHints(lms)
    if !anyVisible(lms, LandmarkIndex.leftHip, LandmarkIndex.rightHip) {
      hints.append(FramingHint(
        id: "hip",
        label: "反動をチェックできるよう腰の位置も映してください",
        severity: .warn
      ))
    }
    return hints
  }

  // プッシュアップ用：肩肘手首＋股関節足首の可視性、および左右方向の見切れを確認する。
  // 体が水平に近く画面の上下端ではなく左右端で見切れやすいため、
  // fullBodyHintsの上下チェックではなく専用の左右チェックを用いる（設計レビュー対応）。
  private static func proneHints(_ lms: [Landmark]) -> [FramingHint] {
    var hints: [FramingHint] = []

    let armVisible =
      (isVisible(lms, LandmarkIndex.leftShoulder) && isVisible(lms, LandmarkIndex.leftElbow) && isVisible(lms, LandmarkIndex.leftWrist))
      || (isVisible(lms, LandmarkIndex.rightShoulder) && isVisible(lms, LandmarkIndex.rightElbow) && isVisible(lms, LandmarkIndex.rightWrist))
    if !armVisible {
      hints.append(FramingHint(
        id: "arm", label: "肩・肘・手首が映るように腕全体をフレームに入れてください", severity: .warn
      ))
    }

    let bodyLineVisible =
      anyVisible(lms, LandmarkIndex.leftHip, LandmarkIndex.rightHip)
      && anyVisible(lms, LandmarkIndex.leftAnkle, LandmarkIndex.rightAnkle)
    if !bodyLineVisible {
      hints.append(FramingHint(
        id: "body-line", label: "腰から足首まで体全体が映るようにしてください", severity: .warn
      ))
    }

    // 左右方向の見切れ（体がどちらを向いていても検出できるよう主要点全体のx範囲で判定する）。
    let xs = [
      lms[LandmarkIndex.nose].x, lms[LandmarkIndex.leftShoulder].x, lms[LandmarkIndex.rightShoulder].x,
      lms[LandmarkIndex.leftHip].x, lms[LandmarkIndex.rightHip].x,
      lms[LandmarkIndex.leftAnkle].x, lms[LandmarkIndex.rightAnkle].x,
    ]
    if let minX = xs.min(), let maxX = xs.max(), (minX < edgeMargin || maxX > 1 - edgeMargin) {
      hints.append(FramingHint(
        id: "side-cut", label: "体の一部が画面から見切れています。少し離れてください", severity: .warn
      ))
    }

    return hints
  }

  // ヒップスラスト用：肩・股関節・膝の可視性のみを確認する（仰向けに近い姿勢のため、
  // 立位種目の上下見切れチェックは適用できない）。
  private static func reclinedHints(_ lms: [Landmark]) -> [FramingHint] {
    let visible =
      anyVisible(lms, LandmarkIndex.leftShoulder, LandmarkIndex.rightShoulder)
      && anyVisible(lms, LandmarkIndex.leftHip, LandmarkIndex.rightHip)
      && anyVisible(lms, LandmarkIndex.leftKnee, LandmarkIndex.rightKnee)
    if !visible {
      return [FramingHint(
        id: "body", label: "肩・腰・膝が映るようにカメラ位置を調整してください", severity: .warn
      )]
    }
    return []
  }

  private static func profile(for exercise: ExerciseType) -> FramingProfile {
    switch exercise {
    case .squat, .deadlift, .other, .bentOverRow, .lunge:
      return .standingFullBody
    case .overheadPress:
      return .standingFullBodyReach
    case .benchPress:
      return .upperBodyOnly
    case .bicepCurl:
      return .upperBodyWithHip
    case .pushup:
      return .prone
    case .hipThrust:
      return .reclined
    }
  }

  // MARK: - 公開インターフェース

  // 現在フレームのフレーミングを評価し、補正指示を返す。
  static func evaluate(_ lms: [Landmark], exercise: ExerciseType) -> FramingResult {
    var hints: [FramingHint] = []

    // 向き（全種目で真横が推奨）
    if let view = sideViewHint(lms) {
      hints.append(view)
    }

    switch profile(for: exercise) {
    case .standingFullBody:
      hints.append(contentsOf: fullBodyHints(lms))
    case .standingFullBodyReach:
      hints.append(contentsOf: fullBodyHints(lms, includeWristInTopCheck: true))
    case .upperBodyOnly:
      hints.append(contentsOf: upperBodyHints(lms))
    case .upperBodyWithHip:
      hints.append(contentsOf: upperBodyWithHipHints(lms))
    case .prone:
      hints.append(contentsOf: proneHints(lms))
    case .reclined:
      hints.append(contentsOf: reclinedHints(lms))
    }

    return FramingResult(ok: hints.isEmpty, hints: hints)
  }
}
