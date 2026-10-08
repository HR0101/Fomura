//
//  WarningEvaluator.swift
//  Fomura
//
//  リアルタイムのフォーム警告判定。現在フレームの特徴量から逸脱を検出する。
//  撮影アングル（横向き確信度）と可視性でゲートし、判定できない条件では
//  誤警告を出さないようにする。
//  squat/deadlift/bench_pressの移植元: frontend/lib/pose/warnings.ts（しきい値・文言は無変更）。
//  それ以外はモバイル版で追加した種目（設計レビュー済み）。
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

    case .overheadPress:
      // 上体の反りすぎ（横向き時のみ）。指摘(fault)の閾値(35)より早期に検知するため
      // レップ確定を待たず現在フレームで軽めの閾値(30)を使う。
      if sideView && (f.backLeanDeg ?? 0) > 30 {
        warnings.append(FormWarning(id: "back", label: "上体が反りすぎています", severity: .warn))
      }

    case .pushup:
      // 体幹の一直線からのズレ（横向き時のみ。正面/斜めでは幾何前提が崩れるためゲートする）。
      if sideView && (f.bodyLineDeviation ?? 0) > 0.2 {
        warnings.append(FormWarning(id: "line", label: "体が一直線になっていません", severity: .warn))
      }

    case .bicepCurl:
      if sideView && (f.elbowDrift ?? 0) > 0.3 {
        warnings.append(FormWarning(id: "elbow", label: "肘が前に出すぎています", severity: .warn))
      }
      if sideView && (f.backLeanDeg ?? 0) > 25 {
        warnings.append(FormWarning(id: "swing", label: "反動を使わないようにしましょう", severity: .warn))
      }

    case .bentOverRow:
      // 引いている最中(肘が曲がっている)なのに前傾が浅い＝ヒンジ姿勢が崩れている。
      // 既存の単一特徴量しきい値パターンに対し2特徴量の複合条件だが、squatのdepth警告
      // (kneeAngle<140 && !isParallel)にも複合条件の前例がある（設計レビューで確認済み）。
      if sideView && (f.elbowAngle ?? 180) < 120 && (f.backLeanDeg ?? 90) < 20 {
        warnings.append(FormWarning(id: "hinge", label: "もっと前傾して行いましょう", severity: .warn))
      }

    case .lunge:
      // スクワットの警告ロジックを前脚の特徴量に適用する。
      if (f.kneeAngle ?? 180) < 140 && !(f.isParallel ?? false) {
        warnings.append(FormWarning(id: "depth", label: "前足をもっと深く曲げましょう", severity: .info))
      }
      if sideView && (f.kneeOverToe ?? 0) > 0.6 {
        warnings.append(FormWarning(id: "knee", label: "前膝が前に出すぎています", severity: .warn))
      }
      if sideView && (f.backLeanDeg ?? 0) > 60 {
        warnings.append(FormWarning(id: "back", label: "体が前に倒れすぎています", severity: .warn))
      }

    case .hipThrust:
      // 膝角度の評価はレップ完了後（ピークフレーム）でしか算出できないため、
      // ライブ中の即時警告は設けない（設計方針。無理に単一フレームで近似しない）。
      break

    case .other:
      break
    }

    return warnings
  }
}
