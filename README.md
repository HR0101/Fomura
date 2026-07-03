# Fomura iOS

Fomura（筋トレ特化型 骨格モーション評価システム）の iOS ネイティブアプリです。
スマートフォンのカメラを用いてリアルタイムで全身の骨格推定を行い、スクワットなどのトレーニングにおけるフォームの自動判定、レップ数のカウント、および採点・警告によるコーチング機能を提供します。

## 🌟 主な機能

- **リアルタイム骨格推定 (Live Session)**
  - MediaPipe (BlazePose) を利用した高速かつ高精度な33関節のトラッキング
  - 骨格のオーバーレイ表示（Skeleton Overlay）
  - 前面・背面カメラの切り替えとミラーリング対応
- **自動レップカウント & フォーム評価**
  - 関節角度や深度などの特徴量抽出（`FeatureExtractor`）
  - ステートマシンによる自動レップ計数（`RepCounter`）
  - 種目ごとの個別スコアリング（`RepScorer`）
  - リアルタイムなフォーム警告とコーチング（`WarningEvaluator`）
- **フィードバック機能**
  - ハプティクス振動と音声によるリアルタイムフィードバック（`FeedbackService`）
  - 画面上でのHUD表示（スコア、深度ゲージなど）
- **トレーニング履歴と統計**
  - 過去のトレーニングセッションの記録と振り返り（History）
  - CSVエクスポート対応（`CSVExporter`）
  - 成長を可視化する統計画面（Stats）
- **動画解析 (Video Upload)**
  - 録画済み動画のアップロードとサーバーサイドまたはローカルでの骨格解析機能

## 🏗 アーキテクチャ

本プロジェクトは **iOS 17+ / Swift 5.10+** を対象とし、最新の **SwiftUI** と **MVVM** アーキテクチャを採用しています。

### ディレクトリ構成

- **`Core/`**: アプリの根幹となるインフラおよびドメインロジック層
  - `Camera/`: `AVFoundation` を用いたカメラ制御（`CameraService`）
  - `Pose/`: 推論と判定ロジックのコア機能（`PoseEngine`, `AnalysisPipeline`, `PoseSmoother` 等）
  - `Feedback/`: ハプティクス・音声フィードバック
  - `Storage/`: `SwiftData` や `UserDefaults` を用いた永続化
  - `Analysis/`: 動画解析モジュール
- **`Features/`**: 画面・機能ごとのプレゼンテーション層（SwiftUI View / ViewModel）
  - `Home/`: ホーム画面
  - `Live/`: カメラとHUDが統合されたリアルタイム判定画面
  - `History/`: 履歴一覧および詳細画面
  - `Stats/`: 統計情報の可視化
  - `Upload/`: 動画アップロード画面
  - `Settings/`: 各種設定画面

### 主な技術スタック

- **UI フレームワーク**: SwiftUI
- **カメラ処理**: AVFoundation
- **機械学習 (ML) エンジン**: MediaPipe Tasks Vision iOS (BlazePose)
- **データ永続化**: SwiftData, UserDefaults
- **依存性管理**: CocoaPods

## 🚀 開発セットアップ環境

1. リポジトリをクローンまたはダウンロードします。
2. CocoaPodsを用いて依存ライブラリをインストールします。
   ```bash
   pod install
   ```
3. 生成された `Fomura.xcworkspace` を Xcode 16 以上で開きます。
4. シミュレータ、または iOS 17 以上が動作する実機をターゲットにしてビルド・実行してください（※カメラ機能を使用するため、完全なテストには実機が必要です）。

## 📝 備考
本プロジェクトのコア判定ロジックはWeb版（TypeScript）との完全互換性を保つため、数式およびしきい値（`PoseConstants.swift`）を忠実に Swift へ移植して実装されています。
