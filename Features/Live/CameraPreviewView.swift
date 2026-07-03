//
//  CameraPreviewView.swift
//  Fomura
//
//  AVCaptureVideoPreviewLayer を SwiftUI へ組み込むラッパー。
//  aspectFill 表示（Web版 object-cover 相当）。前面カメラの鏡像表示は
//  プレビューレイヤが自動で行う（判定ロジックには非反転座標が渡る）。
//

import SwiftUI
import AVFoundation

struct CameraPreviewView: UIViewRepresentable {
  let session: AVCaptureSession

  final class PreviewUIView: UIView {
    override class var layerClass: AnyClass {
      AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
      layer as! AVCaptureVideoPreviewLayer
    }
  }

  func makeUIView(context: Context) -> PreviewUIView {
    let view = PreviewUIView()
    view.previewLayer.session = session
    view.previewLayer.videoGravity = .resizeAspectFill
    applyPortraitRotation(view)
    return view
  }

  func updateUIView(_ uiView: PreviewUIView, context: Context) {
    // カメラ切替でconnectionが作り直されることがあるため毎回適用する。
    applyPortraitRotation(uiView)
  }

  // 縦持ち表示に固定する（VideoDataOutput 側の90度回転と揃える）。
  private func applyPortraitRotation(_ view: PreviewUIView) {
    if let connection = view.previewLayer.connection,
       connection.isVideoRotationAngleSupported(90) {
      connection.videoRotationAngle = 90
    }
  }
}
