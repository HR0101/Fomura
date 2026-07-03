//
//  SettingsView.swift
//  Fomura
//
//  設定画面（モバイル設計書.md 第4.8節をローカル完結向けに適応）。
//  アカウント・API接続はローカル完結方針のため廃止し、判定・フィードバック
//  関連の設定と情報表示・データ書き出しを提供する。
//

import SwiftUI
import SwiftData

struct SettingsView: View {
  @Query(sort: \TrainingSession.createdAt, order: .reverse)
  private var sessions: [TrainingSession]

  @AppStorage(AppSettings.defaultFacing) private var defaultFacing = "back"
  @AppStorage(AppSettings.showAngleDebug) private var showAngleDebug = false
  @AppStorage(AppSettings.hapticsEnabled) private var hapticsEnabled = true
  @AppStorage(AppSettings.voiceCountEnabled) private var voiceCountEnabled = false
  @AppStorage(AppSettings.modelType) private var modelTypeRaw = "lite"
  @AppStorage(AppSettings.smoothingEnabled) private var smoothingEnabled = true
  @AppStorage(AppSettings.countdownSeconds) private var countdownSeconds = 3
  @AppStorage(AppSettings.warningSoundEnabled) private var warningSoundEnabled = false
  @AppStorage(AppSettings.warningSpeechEnabled) private var warningSpeechEnabled = false

  private var appVersion: String {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    return "\(version) (\(build))"
  }

  var body: some View {
    Form {
      Section {
        Picker("既定のカメラ", selection: $defaultFacing) {
          Text("背面").tag("back")
          Text("前面").tag("front")
        }
        Picker("姿勢推定モデル", selection: $modelTypeRaw) {
          ForEach(PoseModelType.allCases) { model in
            Text(model.displayName).tag(model.rawValue)
          }
        }
        Toggle("骨格の平滑化（推奨）", isOn: $smoothingEnabled)
        Picker("開始カウントダウン", selection: $countdownSeconds) {
          Text("なし").tag(0)
          Text("3秒").tag(3)
          Text("5秒").tag(5)
          Text("10秒").tag(10)
        }
        Toggle("主要関節角度を表示（デバッグ）", isOn: $showAngleDebug)
      } header: {
        Text("判定")
      } footer: {
        Text("高精度モデルは検出が安定する一方，発熱と電池消費が増えます．モデルの変更は次に判定画面を開いたときに適用されます．")
      }

      Section {
        Toggle("レップ完了時のハプティクス", isOn: $hapticsEnabled)
        Toggle("音声レップカウント", isOn: $voiceCountEnabled)
        Toggle("フォーム警告の警告音", isOn: $warningSoundEnabled)
        Toggle("フォーム警告の読み上げ", isOn: $warningSpeechEnabled)
      } header: {
        Text("フィードバック")
      } footer: {
        Text("警告音・読み上げをONにすると，画面を見なくてもフォームの崩れに気づけます（同じ警告は\(Int(PoseConstants.warningFeedbackCooldownSec))秒間隔）．")
      }

      Section("データ") {
        ShareLink(
          item: TrainingCSVFile(csvText: CSVExporter.makeCSV(sessions: sessions)),
          preview: SharePreview("Fomuraトレーニング記録.csv")
        ) {
          Label("記録をCSVで書き出す", systemImage: "square.and.arrow.up")
        }
        .disabled(sessions.isEmpty)
        LabeledContent("保存済みセッション", value: "\(sessions.count)件")
      }

      Section("プライバシー") {
        VStack(alignment: .leading, spacing: 6) {
          Label("すべての処理は端末内で完結します", systemImage: "lock.shield")
            .font(.subheadline.weight(.semibold))
          Text("カメラ映像・動画・骨格データが端末の外へ送信されることはありません．記録はこのiPhoneの中だけに保存されます（CSV書き出しはご自身の操作でのみ行われます）．")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
      }

      Section("情報") {
        LabeledContent("バージョン", value: appVersion)
        VStack(alignment: .leading, spacing: 6) {
          Text("免責事項")
            .font(.subheadline.weight(.semibold))
          Text("本アプリの判定・スコアはトレーニング補助を目的とした参考情報であり，医療的助言ではありません．痛みや違和感がある場合は専門家に相談してください．")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        VStack(alignment: .leading, spacing: 6) {
          Text("使用ライブラリ")
            .font(.subheadline.weight(.semibold))
          Text("MediaPipe Tasks Vision (Apache License 2.0) — 姿勢推定に使用しています．")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
      }
    }
    .navigationTitle("設定")
  }
}
