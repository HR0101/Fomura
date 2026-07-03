//
//  PoseSmoother.swift
//  Fomura
//
//  ランドマークの時系列平滑化（One Euro Filter）。
//  MediaPipe の出力に含まれる小刻みなジッタを低減し、骨格描画の安定化と
//  レップ検出・角度計算の誤反応（1フレームのスパイク）を抑える。
//  One Euro Filter は「動きが遅いときは強く、速いときは弱く」平滑化する
//  適応フィルタで、素早いしゃがみ込みへの追従遅れを最小限にできる。
//  設定でOFFにするとWeb版と完全互換の生座標で判定する。
//

import Foundation

// 1次元の One Euro Filter。
final class OneEuroFilter {
  private let minCutoff: Double
  private let beta: Double
  private let derivCutoff: Double

  private var previousValue: Double?
  private var previousDerivative = 0.0

  init(
    minCutoff: Double = PoseConstants.smootherMinCutoff,
    beta: Double = PoseConstants.smootherBeta,
    derivCutoff: Double = PoseConstants.smootherDerivCutoff
  ) {
    self.minCutoff = minCutoff
    self.beta = beta
    self.derivCutoff = derivCutoff
  }

  // カットオフ周波数と時間刻みから指数平滑化係数を求める。
  private func alpha(cutoff: Double, dt: Double) -> Double {
    let tau = 1 / (2 * .pi * cutoff)
    return 1 / (1 + tau / dt)
  }

  func filter(_ value: Double, dt: Double) -> Double {
    guard let previous = previousValue, dt > 0 else {
      previousValue = value
      return value
    }

    // 速度（微分）を平滑化し、速度に応じてカットオフを引き上げる。
    let derivative = (value - previous) / dt
    let alphaD = alpha(cutoff: derivCutoff, dt: dt)
    let smoothedDerivative = alphaD * derivative + (1 - alphaD) * previousDerivative
    let cutoff = minCutoff + beta * abs(smoothedDerivative)

    let a = alpha(cutoff: cutoff, dt: dt)
    let filtered = a * value + (1 - a) * previous

    previousValue = filtered
    previousDerivative = smoothedDerivative
    return filtered
  }

  func reset() {
    previousValue = nil
    previousDerivative = 0
  }
}

// 33点ランドマーク全体を平滑化する（x/y/z 各軸に独立フィルタ）。
final class LandmarkSmoother {
  private var filters: [[OneEuroFilter]] = []
  private var lastTimestampMs: Double?

  func smooth(_ landmarks: [Landmark], timestampMs: Double) -> [Landmark] {
    // 点数が変わったらフィルタを作り直す（通常は33点固定）。
    if filters.count != landmarks.count {
      filters = landmarks.map { _ in
        [OneEuroFilter(), OneEuroFilter(), OneEuroFilter()]
      }
      lastTimestampMs = nil
    }

    let dt: Double
    if let last = lastTimestampMs, timestampMs > last {
      dt = (timestampMs - last) / 1000
    } else {
      dt = 1.0 / 30  // 初回はカメラの基準フレームレートを仮定
    }
    lastTimestampMs = timestampMs

    return landmarks.enumerated().map { index, lm in
      Landmark(
        x: filters[index][0].filter(lm.x, dt: dt),
        y: filters[index][1].filter(lm.y, dt: dt),
        z: filters[index][2].filter(lm.z, dt: dt),
        visibility: lm.visibility  // 可視性は平滑化しない（判定ゲートの応答性を保つ）
      )
    }
  }

  // 人物を見失ったら履歴を破棄する（別人・再検出時に古い状態へ引っ張られないように）。
  func reset() {
    filters.removeAll()
    lastTimestampMs = nil
  }
}
