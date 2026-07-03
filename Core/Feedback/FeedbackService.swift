//
//  FeedbackService.swift
//  Fomura
//
//  モバイル固有のフィードバック機能（モバイル設計書.md 第7.6節）。
//  レップ完了時のハプティクス・音声カウントに加え、開始カウントダウンと
//  フォーム警告の警告音・音声読み上げを提供する（画面を見ずに使えるように）。
//

import Foundation
import UIKit
import AVFoundation
import AudioToolbox

@MainActor
final class FeedbackService {
  private let notificationGenerator = UINotificationFeedbackGenerator()
  private let synthesizer = AVSpeechSynthesizer()

  // MARK: - レップ完了

  // レップ完了時のフィードバック（設定に応じてハプティクス・音声カウント）。
  func repCompleted(count: Int, hapticsEnabled: Bool, voiceCountEnabled: Bool) {
    if hapticsEnabled {
      notificationGenerator.notificationOccurred(.success)
    }
    if voiceCountEnabled {
      speak("\(count)")
    }
  }

  // MARK: - 開始カウントダウン

  // カウントダウンの読み上げ（三脚に置いて離れる時間の確保用）。
  func countdownTick(_ remaining: Int) {
    speak("\(remaining)")
  }

  func startCue() {
    speak("スタート")
  }

  // MARK: - フォーム警告

  // warn 警告の新規発生時に呼ぶ（呼び出し側でクールダウン制御すること）。
  func warningTriggered(label: String, soundEnabled: Bool, speechEnabled: Bool) {
    if soundEnabled {
      // 短い注意音（システムサウンド）＋警告ハプティクス。
      AudioServicesPlaySystemSound(1057)
      notificationGenerator.notificationOccurred(.warning)
    }
    if speechEnabled {
      speak(label)
    }
  }

  // MARK: - 内部

  private func speak(_ text: String) {
    // 直前の読み上げが残っていたら止めて最新を優先する。
    if synthesizer.isSpeaking {
      synthesizer.stopSpeaking(at: .immediate)
    }
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
    synthesizer.speak(utterance)
  }
}
