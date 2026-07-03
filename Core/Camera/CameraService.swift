//
//  CameraService.swift
//  Fomura
//
//  AVFoundation によるカメラ制御。
//  Web版 getUserMedia の設定（1280x720・背面既定）と揃え、遅延フレームは
//  破棄して最新フレーム優先で推論へ渡す（モバイル設計書.md 第5.2節）。
//

import Foundation
import AVFoundation

// カメラの向き（Web版 facing: "user" | "environment" に対応）。
enum CameraFacing: String, Sendable {
  case front
  case back
}

final class CameraService: NSObject, @unchecked Sendable {
  enum CameraError: LocalizedError {
    case permissionDenied
    case deviceNotFound
    case configurationFailed

    var errorDescription: String? {
      switch self {
      case .permissionDenied:
        return "カメラへのアクセスが許可されていません．設定アプリから許可してください．"
      case .deviceNotFound:
        return "利用できるカメラが見つかりません．"
      case .configurationFailed:
        return "カメラの初期化に失敗しました．"
      }
    }
  }

  let session = AVCaptureSession()

  // フレーム受領コールバック（camera.queue 上で呼ばれる）。
  var onSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)?

  private(set) var facing: CameraFacing = .back

  // セッション構成・起動停止を直列化するキュー。
  private let sessionQueue = DispatchQueue(label: "com.fomura.camera.session")
  // フレーム受領専用キュー（推論投入もこの上で行う）。
  private let outputQueue = DispatchQueue(label: "com.fomura.camera.output")

  private let videoOutput = AVCaptureVideoDataOutput()
  private var currentInput: AVCaptureDeviceInput?

  // MARK: - 権限

  static func requestPermission() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      return true
    case .notDetermined:
      return await AVCaptureDevice.requestAccess(for: .video)
    default:
      return false
    }
  }

  // MARK: - 構成

  // 指定の向きでセッションを構成する（beginConfiguration/commit で原子化）。
  func configure(facing: CameraFacing) throws {
    self.facing = facing

    guard let device = AVCaptureDevice.default(
      .builtInWideAngleCamera,
      for: .video,
      position: facing == .front ? .front : .back
    ) else {
      throw CameraError.deviceNotFound
    }

    session.beginConfiguration()
    defer { session.commitConfiguration() }

    // 既存入力を外して付け替える（カメラ切替時）。
    if let currentInput {
      session.removeInput(currentInput)
      self.currentInput = nil
    }

    // 解像度: Web版 getUserMedia の ideal 1280x720 と一致。
    session.sessionPreset = .hd1280x720

    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else {
      throw CameraError.configurationFailed
    }
    session.addInput(input)
    currentInput = input

    // フレームレートを30fpsに固定（推論負荷とのバランス）。
    do {
      try device.lockForConfiguration()
      device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
      device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
      device.unlockForConfiguration()
    } catch {
      // フレームレート固定に失敗しても動作は継続できる。
    }

    if !session.outputs.contains(videoOutput) {
      // BGRA: MediaPipe MPImage が直接受理するフォーマット。
      videoOutput.videoSettings = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
      ]
      // 推論が追いつかない場合は最新フレーム優先で破棄する。
      videoOutput.alwaysDiscardsLateVideoFrames = true
      videoOutput.setSampleBufferDelegate(self, queue: outputQueue)
      guard session.canAddOutput(videoOutput) else {
        throw CameraError.configurationFailed
      }
      session.addOutput(videoOutput)
    }

    // 縦持ち前提のためフレームを90度回転させて出力する（正規化座標も縦基準になる）。
    if let connection = videoOutput.connection(with: .video),
       connection.isVideoRotationAngleSupported(90) {
      connection.videoRotationAngle = 90
    }
  }

  // MARK: - 起動・停止・切替

  func start() {
    sessionQueue.async { [weak self] in
      guard let self, !self.session.isRunning else { return }
      self.session.startRunning()
    }
  }

  func stop() {
    sessionQueue.async { [weak self] in
      guard let self, self.session.isRunning else { return }
      self.session.stopRunning()
    }
  }

  // 前面/背面を切り替える（beginConfiguration/commit で原子化されるため動作中でも安全）。
  func switchFacing() throws {
    try configure(facing: facing == .back ? .front : .back)
  }

  // フレームレートを変更する（熱状態に応じた動的制御用。モバイル設計書.md 11.1節）。
  func setFrameRate(_ fps: Int32) {
    sessionQueue.async { [weak self] in
      guard let device = self?.currentInput?.device else { return }
      do {
        try device.lockForConfiguration()
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: fps)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: fps)
        device.unlockForConfiguration()
      } catch {
        // 変更に失敗しても現行フレームレートで動作継続できる。
      }
    }
  }
}

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    onSampleBuffer?(sampleBuffer)
  }
}
