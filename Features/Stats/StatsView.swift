//
//  StatsView.swift
//  Fomura
//
//  統計ダッシュボード（モバイル新機能。設計書付録A「時系列比較」の第一歩）。
//  今週のサマリー・スコア推移・週別レップ数・種目内訳を表示する。
//  種目の色は固定割当（エンティティに追従し、フィルタで塗り替えない）。
//

import SwiftUI
import SwiftData
import Charts

// 種目の固定カラー（全チャート・全画面で共通。順序も固定）。
extension ExerciseType {
  var chartColor: Color {
    switch self {
    case .squat: return .green
    case .deadlift: return .blue
    case .benchPress: return .orange
    case .other: return .gray
    }
  }
}

struct StatsView: View {
  @Query(sort: \TrainingSession.createdAt) private var sessions: [TrainingSession]

  // スコア推移の種目フィルタ（nil = 全種目）
  @State private var selectedExercise: ExerciseType?

  // チャートの固定カラースケール（表示名 → 色。順序固定）
  private var exerciseScaleDomain: [String] {
    ExerciseType.allCases.map(\.displayName)
  }
  private var exerciseScaleRange: [Color] {
    ExerciseType.allCases.map(\.chartColor)
  }

  var body: some View {
    Group {
      if sessions.isEmpty {
        ContentUnavailableView(
          "まだ統計がありません",
          systemImage: "chart.xyaxis.line",
          description: Text("トレーニングを記録すると，スコアの推移やレップ数の統計が表示されます．")
        )
      } else {
        List {
          weeklySummarySection
          scoreTrendSection
          weeklyRepsSection
          exerciseBreakdownSection
        }
      }
    }
    .navigationTitle("統計")
  }

  // MARK: - 今週のサマリー

  private var thisWeekSessions: [TrainingSession] {
    guard let weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start else {
      return []
    }
    return sessions.filter { $0.createdAt >= weekStart }
  }

  private var weeklySummarySection: some View {
    Section("今週") {
      HStack(spacing: 12) {
        summaryTile(title: "セッション", value: "\(thisWeekSessions.count)")
        summaryTile(
          title: "総レップ",
          value: "\(thisWeekSessions.reduce(0) { $0 + $1.sortedReps.count })"
        )
        summaryTile(
          title: "平均スコア",
          value: weeklyAverageScore.map { String(format: "%.1f", $0) } ?? "—"
        )
      }
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets())
    }
  }

  private var weeklyAverageScore: Double? {
    let scores = thisWeekSessions.compactMap(\.totalScore)
    guard !scores.isEmpty else { return nil }
    return scores.reduce(0, +) / Double(scores.count)
  }

  private func summaryTile(title: String, value: String) -> some View {
    VStack(spacing: 4) {
      Text(value)
        .font(.system(size: 26, weight: .bold, design: .rounded))
        .monospacedDigit()
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 14)
    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
  }

  // MARK: - スコア推移（直近20セッション）

  private struct ScorePoint: Identifiable {
    let id: UUID
    let date: Date
    let score: Double
    let exerciseName: String
  }

  private var scorePoints: [ScorePoint] {
    sessions
      .filter { selectedExercise == nil || $0.exerciseType == selectedExercise }
      .compactMap { session -> ScorePoint? in
        guard let score = session.totalScore else { return nil }
        return ScorePoint(
          id: session.id,
          date: session.createdAt,
          score: score,
          exerciseName: session.exerciseType.displayName
        )
      }
      .suffix(20)
  }

  private var scoreTrendSection: some View {
    Section("スコア推移（直近20セッション）") {
      Picker("種目", selection: $selectedExercise) {
        Text("全種目").tag(ExerciseType?.none)
        ForEach(ExerciseType.allCases) { exercise in
          Text(exercise.displayName).tag(ExerciseType?.some(exercise))
        }
      }
      .pickerStyle(.menu)

      if scorePoints.isEmpty {
        Text("スコア付きのセッションがまだありません")
          .font(.footnote)
          .foregroundStyle(.secondary)
      } else {
        Chart(scorePoints) { point in
          LineMark(
            x: .value("日時", point.date),
            y: .value("スコア", point.score)
          )
          .foregroundStyle(by: .value("種目", point.exerciseName))
          .lineStyle(StrokeStyle(lineWidth: 2))

          PointMark(
            x: .value("日時", point.date),
            y: .value("スコア", point.score)
          )
          .foregroundStyle(by: .value("種目", point.exerciseName))
          .symbolSize(40)
        }
        .chartForegroundStyleScale(domain: exerciseScaleDomain, range: exerciseScaleRange)
        .chartYScale(domain: 0...100)
        // 単一種目表示なら凡例は不要（タイトルが系列名を兼ねる）
        .chartLegend(selectedExercise == nil ? .visible : .hidden)
        .frame(height: 200)
        .padding(.vertical, 8)
      }
    }
  }

  // MARK: - 週別レップ数（直近8週・種目積み上げ）

  private struct WeeklyReps: Identifiable {
    let weekStart: Date
    let exerciseName: String
    let reps: Int
    var id: String { "\(weekStart.timeIntervalSince1970)-\(exerciseName)" }
  }

  private var weeklyReps: [WeeklyReps] {
    let calendar = Calendar.current
    guard let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: Date())?.start,
          let rangeStart = calendar.date(byAdding: .weekOfYear, value: -7, to: currentWeekStart)
    else { return [] }

    // (週開始日, 種目) ごとにレップ数を集計する。
    var buckets: [Date: [ExerciseType: Int]] = [:]
    for session in sessions where session.createdAt >= rangeStart {
      guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: session.createdAt)?.start
      else { continue }
      buckets[weekStart, default: [:]][session.exerciseType, default: 0] += session.sortedReps.count
    }

    return buckets
      .sorted { $0.key < $1.key }
      .flatMap { weekStart, byExercise in
        ExerciseType.allCases.compactMap { exercise -> WeeklyReps? in
          guard let reps = byExercise[exercise], reps > 0 else { return nil }
          return WeeklyReps(weekStart: weekStart, exerciseName: exercise.displayName, reps: reps)
        }
      }
  }

  private var weeklyRepsSection: some View {
    Section("週別レップ数（直近8週）") {
      if weeklyReps.isEmpty {
        Text("この期間の記録がありません")
          .font(.footnote)
          .foregroundStyle(.secondary)
      } else {
        Chart(weeklyReps) { item in
          BarMark(
            x: .value("週", item.weekStart, unit: .weekOfYear),
            y: .value("レップ", item.reps)
          )
          .foregroundStyle(by: .value("種目", item.exerciseName))
          .cornerRadius(3)
        }
        .chartForegroundStyleScale(domain: exerciseScaleDomain, range: exerciseScaleRange)
        .chartXAxis {
          AxisMarks(values: .stride(by: .weekOfYear)) { _ in
            AxisGridLine()
            AxisValueLabel(format: .dateTime.month(.defaultDigits).day(), centered: true)
          }
        }
        .frame(height: 180)
        .padding(.vertical, 8)
      }
    }
  }

  // MARK: - 種目内訳（全期間のレップ数）

  private struct ExerciseShare: Identifiable {
    let exercise: ExerciseType
    let reps: Int
    var id: String { exercise.rawValue }
  }

  private var exerciseShares: [ExerciseShare] {
    var counts: [ExerciseType: Int] = [:]
    for session in sessions {
      counts[session.exerciseType, default: 0] += session.sortedReps.count
    }
    // 表示順は固定（カテゴリ色の割当順と一致させる）
    return ExerciseType.allCases.compactMap { exercise in
      guard let reps = counts[exercise], reps > 0 else { return nil }
      return ExerciseShare(exercise: exercise, reps: reps)
    }
  }

  private var exerciseBreakdownSection: some View {
    Section("種目内訳（総レップ数）") {
      if exerciseShares.isEmpty {
        Text("まだレップの記録がありません")
          .font(.footnote)
          .foregroundStyle(.secondary)
      } else {
        Chart(exerciseShares) { share in
          BarMark(
            x: .value("レップ", share.reps),
            y: .value("種目", share.exercise.displayName)
          )
          .foregroundStyle(share.exercise.chartColor)
          .cornerRadius(3)
          .annotation(position: .trailing, alignment: .leading) {
            Text("\(share.reps)")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }
        .chartXAxis(.hidden)
        .frame(height: CGFloat(exerciseShares.count) * 44 + 16)
        .padding(.vertical, 8)
      }
    }
  }
}
