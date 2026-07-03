//
//  TrainingModels.swift
//  Fomura
//
//  トレーニング結果のローカル永続化モデル（SwiftData）。
//  「処理はアプリ内で完結」方針のため、バックエンドAPIの代わりに
//  すべての結果を端末内へ保存する。
//

import Foundation
import SwiftData

// セッションの取得元。
enum SessionSource: String, Codable, Sendable {
  case live       // リアルタイム判定
  case video      // 動画ファイル解析

  var displayName: String {
    switch self {
    case .live: return "ライブ"
    case .video: return "動画解析"
    }
  }
}

// 1回のトレーニングセッション。
@Model
final class TrainingSession {
  @Attribute(.unique) var id: UUID
  var exerciseTypeRaw: String
  var sourceRaw: String
  var totalScore: Double?
  var createdAt: Date
  // セッションの長さ（ミリ秒）。ライブは開始〜停止、動画は再生時間。
  var durationMs: Double?

  @Relationship(deleteRule: .cascade, inverse: \RepRecord.session)
  var reps: [RepRecord] = []

  init(
    id: UUID = UUID(),
    exerciseType: ExerciseType,
    source: SessionSource,
    totalScore: Double?,
    createdAt: Date = Date(),
    durationMs: Double? = nil
  ) {
    self.id = id
    self.exerciseTypeRaw = exerciseType.rawValue
    self.sourceRaw = source.rawValue
    self.totalScore = totalScore
    self.createdAt = createdAt
    self.durationMs = durationMs
  }

  var exerciseType: ExerciseType {
    ExerciseType(rawValue: exerciseTypeRaw) ?? .other
  }

  var source: SessionSource {
    SessionSource(rawValue: sourceRaw) ?? .live
  }

  // レップ番号順に並べた配列（SwiftDataのリレーションは順序を保証しないため）。
  var sortedReps: [RepRecord] {
    reps.sorted { $0.repNumber < $1.repNumber }
  }
}

// 1レップ分の記録。
@Model
final class RepRecord {
  var repNumber: Int
  var score: Double
  // 特徴量要約（min_primary_angle / sub_* / fault_* 等）をJSONで保持する。
  var featuresData: Data
  var startTimestampMs: Double
  var endTimestampMs: Double
  var session: TrainingSession?

  init(
    repNumber: Int,
    score: Double,
    featuresData: Data,
    startTimestampMs: Double,
    endTimestampMs: Double
  ) {
    self.repNumber = repNumber
    self.score = score
    self.featuresData = featuresData
    self.startTimestampMs = startTimestampMs
    self.endTimestampMs = endTimestampMs
  }

  // CompletedRep から生成する。
  convenience init(from rep: CompletedRep) {
    let data = (try? JSONEncoder().encode(rep.features)) ?? Data()
    self.init(
      repNumber: rep.repNumber,
      score: rep.score,
      featuresData: data,
      startTimestampMs: rep.startTimestampMs,
      endTimestampMs: rep.endTimestampMs
    )
  }

  // 特徴量辞書を復元する。
  var features: [String: FeatureValue] {
    (try? JSONDecoder().decode([String: FeatureValue].self, from: featuresData)) ?? [:]
  }

  // 保存済み features から fault_* キーを抽出する。
  var faultIds: [String] {
    features.keys
      .filter { $0.hasPrefix("fault_") }
      .map { String($0.dropFirst("fault_".count)) }
      .sorted()
  }

  // 保存済み features から sub_* キーを抽出する（項目名: スコア）。
  var subScores: [(key: String, value: Double)] {
    features
      .compactMap { key, value -> (String, Double)? in
        guard key.hasPrefix("sub_"), let number = value.numberValue else { return nil }
        return (String(key.dropFirst("sub_".count)), number)
      }
      .sorted { $0.0 < $1.0 }
  }
}
