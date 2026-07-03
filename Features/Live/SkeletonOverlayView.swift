//
//  SkeletonOverlayView.swift
//  Fomura
//
//  骨格スケルトンのオーバーレイ描画（モバイル設計書.md 第5.4節）。
//  CAShapeLayer 2枚（接続線・関節点）を毎フレーム直接更新し、
//  SwiftUI の再描画を経由せず遅延を抑える。
//  スタイルはWeb版 DrawingUtils と同値（線 #22C55E 3pt・関節点 白 半径3pt）。
//

import SwiftUI
import UIKit

final class SkeletonOverlayUIView: UIView {
  private let lineLayer = CAShapeLayer()
  private let jointLayer = CAShapeLayer()

  // 前面カメラ時のみ true（プレビューの鏡像表示に描画を合わせる）。
  var mirrored = false

  // 回転後フレームのアスペクト比（幅/高さ）。720x1280 の縦向きが既定。
  var videoAspect: CGFloat = 720.0 / 1280.0

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    backgroundColor = .clear

    // 接続線: #22C55E・3pt
    lineLayer.strokeColor = UIColor(red: 0x22 / 255.0, green: 0xC5 / 255.0, blue: 0x5E / 255.0, alpha: 1).cgColor
    lineLayer.lineWidth = 3
    lineLayer.fillColor = UIColor.clear.cgColor
    lineLayer.lineCap = .round
    layer.addSublayer(lineLayer)

    // 関節点: 白・半径3pt
    jointLayer.fillColor = UIColor.white.cgColor
    jointLayer.strokeColor = UIColor.clear.cgColor
    layer.addSublayer(jointLayer)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    lineLayer.frame = bounds
    jointLayer.frame = bounds
  }

  // 33点ランドマークを描画する（nil で全消去。人物未確認時の誤描画防止）。
  func render(landmarks: [Landmark]?) {
    // 暗黙アニメーションを無効化して追随遅延を排除する。
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }

    guard let landmarks, landmarks.count >= 33, bounds.width > 0, bounds.height > 0 else {
      lineLayer.path = nil
      jointLayer.path = nil
      return
    }

    let points = landmarks.map { convert($0) }

    let linePath = UIBezierPath()
    for (from, to) in PoseConnections.edges {
      linePath.move(to: points[from])
      linePath.addLine(to: points[to])
    }
    lineLayer.path = linePath.cgPath

    let jointPath = UIBezierPath()
    for point in points {
      jointPath.append(UIBezierPath(
        arcCenter: point, radius: 3, startAngle: 0, endAngle: .pi * 2, clockwise: true
      ))
    }
    jointLayer.path = jointPath.cgPath
  }

  // 正規化座標 → aspectFill プレビュー上のビュー座標へ変換する。
  // aspectFill でクロップされる分のオフセットを考慮する。
  private func convert(_ lm: Landmark) -> CGPoint {
    let viewW = bounds.width
    let viewH = bounds.height
    let viewAspect = viewW / viewH

    var x: CGFloat
    var y: CGFloat
    if videoAspect > viewAspect {
      // 映像の方が横長 → 左右がクロップされる
      let displayedW = viewH * videoAspect
      let offsetX = (displayedW - viewW) / 2
      x = CGFloat(lm.x) * displayedW - offsetX
      y = CGFloat(lm.y) * viewH
    } else {
      // 映像の方が縦長 → 上下がクロップされる
      let displayedH = viewW / videoAspect
      let offsetY = (displayedH - viewH) / 2
      x = CGFloat(lm.x) * viewW
      y = CGFloat(lm.y) * displayedH - offsetY
    }

    if mirrored {
      x = viewW - x
    }
    return CGPoint(x: x, y: y)
  }
}

// SwiftUI ラッパー。ViewModel に描画先ビューを渡し、以後は直接更新する。
struct SkeletonOverlayView: UIViewRepresentable {
  let viewModel: LiveSessionViewModel

  func makeUIView(context: Context) -> SkeletonOverlayUIView {
    let view = SkeletonOverlayUIView()
    viewModel.skeletonView = view
    return view
  }

  func updateUIView(_ uiView: SkeletonOverlayUIView, context: Context) {
    uiView.mirrored = (viewModel.facing == .front)
  }
}
