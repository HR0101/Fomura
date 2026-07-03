//
//  ResultSheetView.swift
//  Fomura
//
//  保存後の結果サマリーシート（モバイル設計書.md 第4.4節）。
//  総レップ数・平均スコア・レップごとのサブスコア内訳・指摘一覧を表示する。
//

import SwiftUI

struct ResultSheetView: View {
  @Environment(\.dismiss) private var dismiss

  let session: TrainingSession

  var body: some View {
    NavigationStack {
      List {
        Section {
          HStack {
            summaryTile(title: "総レップ", value: "\(session.sortedReps.count)")
            summaryTile(
              title: "平均スコア",
              value: session.totalScore.map { String(format: "%.1f", $0) } ?? "—"
            )
          }
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets())
        }

        Section("レップ別スコア") {
          ForEach(session.sortedReps, id: \.repNumber) { rep in
            RepSummaryRow(rep: rep, exercise: session.exerciseType)
          }
        }
      }
      .navigationTitle("\(session.exerciseType.displayName)の結果")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("閉じる") {
            dismiss()
          }
        }
      }
    }
  }

  private func summaryTile(title: String, value: String) -> some View {
    VStack(spacing: 4) {
      Text(value)
        .font(.system(size: 32, weight: .bold, design: .rounded))
        .monospacedDigit()
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 16)
    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
  }
}

// 1レップ分の要約行（サブスコア内訳バー＋指摘ラベル）。
struct RepSummaryRow: View {
  let rep: RepRecord
  let exercise: ExerciseType

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Rep \(rep.repNumber)")
          .font(.subheadline.weight(.semibold))
        Spacer()
        Text(String(format: "%.1f", rep.score))
          .font(.headline.monospacedDigit())
          .foregroundStyle(scoreColor(rep.score))
      }

      // サブスコア内訳バー
      ForEach(rep.subScores, id: \.key) { item in
        let maxValue = RepScorer.subScoreMax(item.key, exercise: exercise)
        HStack(spacing: 8) {
          Text(RepScorer.subScoreName(item.key))
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 72, alignment: .leading)
          ProgressView(value: min(item.value, maxValue), total: maxValue)
            .tint(.green)
          Text(String(format: "%.0f/%.0f", item.value, maxValue))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }

      // 検出された指摘
      ForEach(rep.faultIds, id: \.self) { faultId in
        Label(
          RepScorer.faultLabel(id: faultId, exercise: exercise),
          systemImage: "exclamationmark.circle.fill"
        )
        .font(.caption)
        .foregroundStyle(.orange)
      }
    }
    .padding(.vertical, 4)
  }

  private func scoreColor(_ score: Double) -> Color {
    if score >= 80 { return .green }
    if score >= 60 { return .orange }
    return .red
  }
}
