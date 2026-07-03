//
//  AppSettings.swift
//  Fomura
//
//  設定画面で扱うユーザー設定のキー定義（@AppStorage 用）。
//

import Foundation

enum AppSettings {
  // 既定カメラ（"back" | "front"。Web版の既定は背面）
  static let defaultFacing = "settings.defaultFacing"
  // 主要関節角度のデバッグ表示（既定OFF）
  static let showAngleDebug = "settings.showAngleDebug"
  // レップ完了ハプティクス（既定ON）
  static let hapticsEnabled = "settings.hapticsEnabled"
  // 音声レップカウント（既定OFF）
  static let voiceCountEnabled = "settings.voiceCountEnabled"
  // 免責事項の表示済みフラグ
  static let hasSeenDisclaimer = "settings.hasSeenDisclaimer"

  // 姿勢推定モデル（"lite" | "full"。既定 lite）
  static let modelType = "settings.modelType"
  // 骨格の平滑化（One Euro Filter。既定ON。OFFでWeb版完全互換）
  static let smoothingEnabled = "settings.smoothingEnabled"
  // 開始カウントダウン秒数（0=なし / 3 / 5 / 10。既定3）
  static let countdownSeconds = "settings.countdownSeconds"
  // フォーム警告の警告音（既定OFF）
  static let warningSoundEnabled = "settings.warningSoundEnabled"
  // フォーム警告の音声読み上げ（既定OFF）
  static let warningSpeechEnabled = "settings.warningSpeechEnabled"
}
