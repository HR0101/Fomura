//
//  FramingEvaluator.swift
//  Fomura
//
//  撮影ガイド（フレーミング補助）。
//  種目ごとの推奨アングルを定義し、現在の映り方から「もう少し上／左」などの
//  具体的な補正指示をリアルタイムに算出する。適切なアングルはフォーム判定の
//  精度を大きく左右するため、判定モデルの前提条件チェックも兼ねる。
//  移植元: frontend/lib/pose/framing.ts（しきい値・文言は無変更）
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

enum FramingEvaluator {
  // MARK: - 静的データ（RECOMMENDED_VIEWS と同一）

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
    .other: RecommendedView(
      view: "体の真横から",
      cameraHeight: "動作の中心の高さ",
      distance: "動作範囲が収まる距離",
      reason: "関節の可動域を正確に測るため"
    ),
  ]

  // MARK: - 定数（framing.ts と同値）

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

  // スクワット・デッドリフト用：全身が縦に収まっているかを確認する。
  private static func fullBodyHints(_ lms: [Landmark]) -> [FramingHint] {
    var hints: [FramingHint] = []

    // 上端（頭）の見切れ
    let topY = min(
      lms[LandmarkIndex.nose].y,
      lms[LandmarkIndex.leftShoulder].y,
      lms[LandmarkIndex.rightShoulder].y
    )
    if topY < edgeMargin {
      hints.append(FramingHint(
        id: "top-cut",
        label: "頭が見切れています。カメラを上に向けるか少し離れてください",
        severity: .warn
      ))
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

  // MARK: - 公開インターフェース

  // 現在フレームのフレーミングを評価し、補正指示を返す。
  static func evaluate(_ lms: [Landmark], exercise: ExerciseType) -> FramingResult {
    var hints: [FramingHint] = []

    // 向き（全種目で真横が推奨）
    if let view = sideViewHint(lms) {
      hints.append(view)
    }

    // 種目別の映り込みチェック
    if exercise == .benchPress {
      hints.append(contentsOf: upperBodyHints(lms))
    } else {
      hints.append(contentsOf: fullBodyHints(lms))
    }

    return FramingResult(ok: hints.isEmpty, hints: hints)
  }
}
