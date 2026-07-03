//
//  VideoAnalyzer.swift
//  Fomura
//
//  録画動画の端末内解析。
//  Web版ではバックエンドへアップロードして解析していたが、「処理はアプリ内で完結」
//  方針のため、AVAssetReader でフレームを取り出し MediaPipe（videoモード）で
//  ライブ判定と同一のパイプライン（特徴量→レップ計数→採点）に通す。
//  モデル種別（標準/高精度）と平滑化はライブ判定と同じ設定を適用する。
//

import Foundation
import AVFoundation
import UIKit
import MediaPipeTasksVision

final class VideoAnalyzer: Sendable {
  struct AnalysisResult: Sendable {
    let reps: [CompletedRep]
    let totalScore: Double?
    let durationMs: Double
  }

  enum AnalysisError: LocalizedError {
    case noVideoTrack
    case readerFailed
    case cancelled

    var errorDescription: String? {
      switch self {
      case .noVideoTrack:
        return "動画トラックが見つかりません．対応形式（mp4 / mov 等）か確認してください．"
      case .readerFailed:
        return "動画の読み込みに失敗しました．"
      case .cancelled:
        return "解析をキャンセルしました．"
      }
    }
  }

  // 動画ファイルを解析する。progress は 0.0〜1.0（メインスレッド保証なし）。
  func analyze(
    url: URL,
    exercise: ExerciseType,
    modelType: PoseModelType,
    smoothingEnabled: Bool,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> AnalysisResult {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    let durationMs = duration.seconds * 1000

    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      throw AnalysisError.noVideoTrack
    }
    // 撮影時の回転情報を読み取り、MediaPipe に画像の向きとして伝える。
    let transform = try await track.load(.preferredTransform)
    let orientation = Self.imageOrientation(from: transform)

    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
      ]
    )
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
      throw AnalysisError.readerFailed
    }
    reader.add(output)
    guard reader.startReading() else {
      throw AnalysisError.readerFailed
    }

    let landmarker = try PoseEngine.makeVideoLandmarker(modelType: modelType)
    let repCounter = RepCounter(exercise: exercise)
    let smoother = LandmarkSmoother()
    var reps: [CompletedRep] = []
    var lastTimestampMs = -1

    while let sampleBuffer = output.copyNextSampleBuffer() {
      if Task.isCancelled {
        reader.cancelReading()
        throw AnalysisError.cancelled
      }

      let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
      let timestampMs = Int((pts.seconds * 1000).rounded())
      // videoモードはタイムスタンプの単調増加が必須のため、重複フレームは飛ばす。
      guard timestampMs > lastTimestampMs else { continue }
      lastTimestampMs = timestampMs

      guard let image = try? MPImage(sampleBuffer: sampleBuffer, orientation: orientation) else {
        continue
      }
      guard let result = try? landmarker.detect(
        videoFrame: image, timestampInMilliseconds: timestampMs
      ) else {
        continue
      }

      // ライブ判定と同一のパイプラインに通す（人物足切り→平滑化→特徴量→レップ計数）。
      if let rawLms = PoseEngine.convert(result: result), FeatureExtractor.isLikelyPerson(rawLms) {
        let lms = smoothingEnabled
          ? smoother.smooth(rawLms, timestampMs: Double(timestampMs))
          : rawLms
        let features = FeatureExtractor.compute(lms, exercise: exercise)
        if let rep = repCounter.push(features, timestampMs: Double(timestampMs)) {
          reps.append(rep)
        }
      } else {
        smoother.reset()
      }

      if durationMs > 0 {
        progress(min(1.0, Double(timestampMs) / durationMs))
      }
    }

    if reader.status == .failed {
      throw AnalysisError.readerFailed
    }

    progress(1.0)
    return AnalysisResult(
      reps: reps,
      totalScore: RepScorer.sessionScore(repScores: reps.map(\.score)),
      durationMs: durationMs
    )
  }

  // preferredTransform の回転角から UIImage.Orientation を求める。
  private static func imageOrientation(from transform: CGAffineTransform) -> UIImage.Orientation {
    let angle = atan2(transform.b, transform.a) * 180 / .pi
    switch Int(angle.rounded()) {
    case 90: return .right    // 縦持ち撮影
    case -90, 270: return .left
    case 180, -180: return .down
      default: return .up
    }
  }
}
