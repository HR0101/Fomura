//
//  PoseConstants.swift
//  Fomura
//
//  判定ロジック全体で共有する型としきい値の集約。
//  しきい値はWeb版から抽出した確定値であり、変更する場合はWeb版・設計書・
//  パリティテストを同時に更新すること（モバイル設計書.md 第6章）。
//

import Foundation

// 対象種目（Web版 features.ts の ExerciseType と同一の生値）。
enum ExerciseType: String, CaseIterable, Codable, Identifiable, Sendable {
  case squat
  case deadlift
  case benchPress = "bench_press"
  case other

  var id: String { rawValue }

  // 画面表示名（日本語）。
  var displayName: String {
    switch self {
    case .squat: return "スクワット"
    case .deadlift: return "デッドリフト"
    case .benchPress: return "ベンチプレス"
    case .other: return "その他"
    }
  }
}

// 姿勢推定モデルの種類（設計書14章のリスク対応: liteの精度不足時にfullへ切替可能にする）。
enum PoseModelType: String, CaseIterable, Identifiable, Sendable {
  case lite
  case full

  var id: String { rawValue }

  // バンドル同梱ファイル名（拡張子なし）。
  var fileName: String { "pose_landmarker_\(rawValue)" }

  var displayName: String {
    switch self {
    case .lite: return "標準（軽量）"
    case .full: return "高精度"
    }
  }
}

// 警告・指摘の重大度（Web版 severity: "warn" | "info"）。
enum Severity: String, Codable, Sendable {
  case warn
  case info
}

// レップ要約 features 辞書の値（数値または真偽値の混在。Web版 Record<string, number | boolean>）。
enum FeatureValue: Codable, Equatable, Sendable {
  case number(Double)
  case bool(Bool)

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    // Bool を先に試す（Double は true/false をデコードできないため順序が重要）。
    if let boolValue = try? container.decode(Bool.self) {
      self = .bool(boolValue)
    } else {
      self = .number(try container.decode(Double.self))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    }
  }

  var numberValue: Double? {
    if case .number(let value) = self { return value }
    return nil
  }

  var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }
}

// 判定ロジック共通の定数（出典: Web版該当ファイル）。
enum PoseConstants {
  // 可視性が閾値未満のランドマークは信頼しない（features.ts / warnings.ts / framing.ts）。
  static let visibilityFloor = 0.5
  // 微小値（ゼロ除算防止。features.ts / framing.ts）。
  static let epsilon = 1e-9
  // 人物とみなす体幹コア（両肩・両股関節）の平均可視性の下限（features.ts）。
  static let personMinVisibility = 0.6
  // 横向き撮影とみなす確信度の下限（scoring.ts / warnings.ts / framing.ts）。
  static let sideViewMin = 0.4

  // HUDスナップショットの更新間隔ミリ秒（Web版 CameraView.tsx SNAPSHOT_INTERVAL_MS）。
  static let snapshotIntervalMs = 100.0

  // PoseLandmarker の信頼度しきい値（usePoseLandmarker.ts。人以外の誤検出対策で既定0.5から引き上げ済み）。
  static let minPoseDetectionConfidence: Float = 0.7
  static let minPosePresenceConfidence: Float = 0.7
  static let minTrackingConfidence: Float = 0.6

  // モデルファイルの拡張子（ファイル名は PoseModelType.fileName）。
  static let modelFileExtension = "task"

  // One Euro Filter のパラメータ（モバイル固有の精度向上策。Web版には無い）。
  // minCutoff: 静止時の平滑化強度（小さいほど滑らか）。
  // beta: 速度追従係数（大きいほど素早い動きに遅延なく追従）。
  static let smootherMinCutoff = 1.5
  static let smootherBeta = 0.3
  static let smootherDerivCutoff = 1.0

  // 警告フィードバック（音・読み上げ）の同一警告クールダウン秒数。
  static let warningFeedbackCooldownSec = 5.0
}
