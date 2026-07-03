//
//  WarningEvaluator.swift
//  Fomura
//
//  リアルタイムのフォーム警告判定。現在フレームの特徴量から逸脱を検出する。
//  撮影アングル（横向き確信度）と可視性でゲートし、判定できない条件では
//  誤警告を出さないようにする。
//  移植元: frontend/lib/pose/warnings.ts（しきい値・文言は無変更）
//

import Foundation

// リアルタイム警告1件。
struct FormWarning: Sendable, Equatable, Identifiable {
  let id: String
  let label: String
  let severity: Severity
}

enum WarningEvaluator {
  static func evaluate(_ f: Features, exercise: ExerciseType) -> [FormWarning] {
    var warnings: [FormWarning] = []

    // 主要関節が十分に映っていない場合は判定しない。
    if (f.visibility ?? 1) < PoseConstants.visibilityFloor {
      return warnings
    }
    let sideView = (f.sideViewConfidence ?? 0) >= PoseConstants.sideViewMin

    switch exercise {
    case .squat:
      // しゃがみが浅い: 膝は曲がっているのにパラレル未到達
      if (f.kneeAngle ?? 180) < 140 && !(f.isParallel ?? false) {
        warnings.append(FormWarning(id: "depth", label: "もっと深くしゃがみましょう", severity: .info))
      }
      // 膝の過度な前方突出（横向き時のみ）
      if sideView && (f.kneeOverToe ?? 0) > 0.6 {
        warnings.append(FormWarning(id: "knee", label: "膝が前に出すぎています", severity: .warn))
      }
      // 背中の倒れすぎ（横向き時のみ）
      if sideView && (f.backLeanDeg ?? 0) > 60 {
        warnings.append(FormWarning(id: "back", label: "背中が倒れすぎています", severity: .warn))
      }
    case .deadlift:
      // 背中の過度な傾き（横向き時のみ、丸まりの目安）
      if sideView && (f.backLeanDeg ?? 0) > 80 {
        warnings.append(FormWarning(id: "back", label: "背中を丸めないよう注意", severity: .warn))
      }
    case .benchPress:
      // 左右の腕の非対称
      if (f.elbowSymmetryDeg ?? 0) > 20 {
        warnings.append(FormWarning(id: "symmetry", label: "左右の肘の高さを揃えましょう", severity: .warn))
      }
    case .other:
      break
    }

    return warnings
  }
}
