//
//  PoseEngine.swift
//  Fomura
//
//  MediaPipe Tasks Vision（PoseLandmarker）のラッパー。
//  Web版 usePoseLandmarker.ts と同値の設定で初期化し、GPU初期化失敗時は
//  CPUへフォールバックする。モデルはアプリバンドル同梱（オフライン動作保証）で、
//  標準（lite）と高精度（full）を設定で切替できる。
//

import Foundation
import AVFoundation
import MediaPipeTasksVision

final class PoseEngine: NSObject, @unchecked Sendable {
  enum PoseEngineError: LocalizedError {
    case modelNotFound
    case initializationFailed(String)

    var errorDescription: String? {
      switch self {
      case .modelNotFound:
        return "姿勢推定モデルが見つかりません．アプリを再インストールしてください．"
      case .initializationFailed(let message):
        return "推論エンジンの初期化に失敗しました: \(message)"
      }
    }
  }

  // 検出結果（33点変換済み。検出なしは nil）とタイムスタンプms を返すコールバック。
  // MediaPipe の内部スレッドから呼ばれる点に注意。
  var onResult: (@Sendable (_ landmarks: [Landmark]?, _ timestampMs: Double) -> Void)?

  private var landmarker: PoseLandmarker?

  // モデルファイルのバンドル内パス。
  static func modelPath(type: PoseModelType) throws -> String {
    guard let path = Bundle.main.path(
      forResource: type.fileName,
      ofType: PoseConstants.modelFileExtension
    ) else {
      throw PoseEngineError.modelNotFound
    }
    return path
  }

  // 共通オプション（Web版 usePoseLandmarker.ts と同値）。
  private static func makeOptions(
    modelPath: String,
    runningMode: RunningMode,
    delegate: Delegate
  ) -> PoseLandmarkerOptions {
    let options = PoseLandmarkerOptions()
    options.baseOptions.modelAssetPath = modelPath
    options.baseOptions.delegate = delegate
    options.runningMode = runningMode
    options.numPoses = 1
    options.minPoseDetectionConfidence = PoseConstants.minPoseDetectionConfidence
    options.minPosePresenceConfidence = PoseConstants.minPosePresenceConfidence
    options.minTrackingConfidence = PoseConstants.minTrackingConfidence
    return options
  }

  // ライブ配信モードで初期化する（GPU→CPUフォールバック付き）。
  func initializeLiveStream(modelType: PoseModelType) throws {
    let path = try Self.modelPath(type: modelType)

    let gpuOptions = Self.makeOptions(modelPath: path, runningMode: .liveStream, delegate: .GPU)
    gpuOptions.poseLandmarkerLiveStreamDelegate = self
    do {
      landmarker = try PoseLandmarker(options: gpuOptions)
    } catch {
      // GPU初期化に失敗した端末ではCPUで再初期化する（Web版と同じフォールバック）。
      let cpuOptions = Self.makeOptions(modelPath: path, runningMode: .liveStream, delegate: .CPU)
      cpuOptions.poseLandmarkerLiveStreamDelegate = self
      do {
        landmarker = try PoseLandmarker(options: cpuOptions)
      } catch {
        throw PoseEngineError.initializationFailed(error.localizedDescription)
      }
    }
  }

  // カメラフレームを非同期推論に投入する（camera.queue から呼ぶ）。
  func detectAsync(sampleBuffer: CMSampleBuffer, timestampMs: Int) {
    guard let landmarker else { return }
    do {
      let image = try MPImage(sampleBuffer: sampleBuffer)
      try landmarker.detectAsync(image: image, timestampInMilliseconds: timestampMs)
    } catch {
      // 単一フレームの失敗は無視する（次フレームで回復するため）。
    }
  }

  func close() {
    landmarker = nil
  }

  // 動画ファイル解析用のランドマーカーを生成する（videoモード）。
  static func makeVideoLandmarker(modelType: PoseModelType) throws -> PoseLandmarker {
    let path = try modelPath(type: modelType)
    let gpuOptions = makeOptions(modelPath: path, runningMode: .video, delegate: .GPU)
    do {
      return try PoseLandmarker(options: gpuOptions)
    } catch {
      let cpuOptions = makeOptions(modelPath: path, runningMode: .video, delegate: .CPU)
      do {
        return try PoseLandmarker(options: cpuOptions)
      } catch {
        throw PoseEngineError.initializationFailed(error.localizedDescription)
      }
    }
  }

  // PoseLandmarkerResult → 内部表現へ変換する（1人分・33点）。
  static func convert(result: PoseLandmarkerResult?) -> [Landmark]? {
    guard let pose = result?.landmarks.first, pose.count >= 33 else { return nil }
    return pose.map { lm in
      Landmark(
        x: Double(lm.x),
        y: Double(lm.y),
        z: Double(lm.z),
        visibility: lm.visibility?.doubleValue
      )
    }
  }
}

extension PoseEngine: PoseLandmarkerLiveStreamDelegate {
  func poseLandmarker(
    _ poseLandmarker: PoseLandmarker,
    didFinishDetection result: PoseLandmarkerResult?,
    timestampInMilliseconds: Int,
    error: Error?
  ) {
    guard error == nil else {
      onResult?(nil, Double(timestampInMilliseconds))
      return
    }
    onResult?(Self.convert(result: result), Double(timestampInMilliseconds))
  }
}
