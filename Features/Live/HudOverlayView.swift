//
//  HudOverlayView.swift
//  Fomura
//
//  判定中のHUD（レップ数・スコア・深さゲージ・警告・撮影ガイドバナー）。
//  Web版 Hud.tsx / live/page.tsx のモバイルレイアウトを踏襲する。
//  isJudging=false（プレビュー中）は撮影ガイドバナーのみ表示する。
//

import SwiftUI

struct HudOverlayView: View {
  let snapshot: Snapshot?
  let currentScore: Double?
  let showAngleDebug: Bool
  let isJudging: Bool

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top) {
        framingBanner
        Spacer()
        if isJudging {
          statsBadges
        }
      }
      .padding(.horizontal, 12)
      .padding(.top, 8)

      Spacer()

      if isJudging {
        VStack(spacing: 8) {
          depthGauge
          warningList
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
      }
    }
  }

  // MARK: - 撮影ガイドバナー（左上・先頭1件のみ表示）

  @ViewBuilder
  private var framingBanner: some View {
    if let snapshot {
      if !snapshot.detected {
        bannerLabel("全身がカメラに映るように立ってください", severity: .warn)
      } else if let hint = snapshot.framing?.hints.first {
        bannerLabel(hint.label, severity: hint.severity)
      } else if !isJudging {
        // プレビュー中で問題なし → 位置OKを明示して開始を後押しする
        Label("撮影位置OK", systemImage: "checkmark.circle.fill")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.white)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(.green.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
      }
    }
  }

  private func bannerLabel(_ text: String, severity: Severity) -> some View {
    Label(text, systemImage: "camera.fill")
      .font(.footnote.weight(.semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(
        (severity == .warn ? Color.orange : Color.blue).opacity(0.85),
        in: RoundedRectangle(cornerRadius: 8)
      )
      .frame(maxWidth: 240, alignment: .leading)
  }

  // MARK: - レップ数・スコアバッジ（右上）

  private var statsBadges: some View {
    VStack(alignment: .trailing, spacing: 6) {
      VStack(spacing: 0) {
        Text("\(snapshot?.repCount ?? 0)")
          .font(.system(size: 34, weight: .bold, design: .rounded))
          .monospacedDigit()
        Text("レップ")
          .font(.caption2)
      }
      .foregroundStyle(.white)
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))

      if let score = currentScore {
        VStack(spacing: 0) {
          Text(String(format: "%.1f", score))
            .font(.system(size: 22, weight: .bold, design: .rounded))
            .monospacedDigit()
          Text("スコア")
            .font(.caption2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
      }

      if showAngleDebug, let angle = snapshot?.primaryAngle {
        Text("主角度 \(angle)°")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.white)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
      }
    }
  }

  // MARK: - 深さゲージ

  @ViewBuilder
  private var depthGauge: some View {
    if let snapshot, snapshot.detected {
      VStack(alignment: .leading, spacing: 3) {
        Text("しゃがみの深さ \(Int((snapshot.depthRatio * 100).rounded()))%")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.white)
        GeometryReader { geometry in
          ZStack(alignment: .leading) {
            Capsule()
              .fill(.white.opacity(0.25))
            Capsule()
              .fill(Color(red: 0x22 / 255.0, green: 0xC5 / 255.0, blue: 0x5E / 255.0))
              .frame(width: geometry.size.width * snapshot.depthRatio)
          }
        }
        .frame(height: 8)
      }
      .padding(10)
      .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }
  }

  // MARK: - フォーム警告（warn=赤系 / info=アンバー系。Web版の配色区分を踏襲）

  @ViewBuilder
  private var warningList: some View {
    if let warnings = snapshot?.warnings, !warnings.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(warnings) { warning in
          Label(warning.label, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
              (warning.severity == .warn ? Color.red : Color.orange).opacity(0.85),
              in: RoundedRectangle(cornerRadius: 8)
            )
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
