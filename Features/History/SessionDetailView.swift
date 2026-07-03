//
//  SessionDetailView.swift
//  Fomura
//
//  セッション詳細画面（モバイル設計書.md 第4.6節をローカル保存向けに適応）。
//  レップ別スコアの棒グラフ（Swift Charts）＋サブスコア内訳＋指摘一覧を表示する。
//

import SwiftUI
import Charts

struct SessionDetailView: View {
  let session: TrainingSession

  var body: some View {
    List {
      // サマリー
      Section {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Label(session.exerciseType.displayName, systemImage: "figure.strengthtraining.traditional")
              .font(.headline)
            Spacer()
            Text(session.source.displayName)
              .font(.caption.weight(.semibold))
              .padding(.horizontal, 8)
              .padding(.vertical, 3)
              .background(
                (session.source == .live ? Color.green : Color.blue).opacity(0.15),
                in: Capsule()
              )
              .foregroundStyle(session.source == .live ? .green : .blue)
          }

          HStack(spacing: 20) {
            statItem(title: "総合スコア", value: session.totalScore.map { String(format: "%.1f", $0) } ?? "—")
            statItem(title: "レップ数", value: "\(session.sortedReps.count)")
            if let durationMs = session.durationMs {
              statItem(title: "時間", value: formatDuration(durationMs))
            }
          }

          Text(session.createdAt.formatted(date: .complete, time: .shortened))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
      }

      // レップ別スコアの棒グラフ
      if !session.sortedReps.isEmpty {
        Section("レップ別スコア") {
          Chart(session.sortedReps, id: \.repNumber) { rep in
            BarMark(
              x: .value("レップ", rep.repNumber),
              y: .value("スコア", rep.score)
            )
            .foregroundStyle(barColor(rep.score))
            .cornerRadius(4)
          }
          .chartYScale(domain: 0...100)
          .chartXAxis {
            AxisMarks(values: session.sortedReps.map(\.repNumber)) { value in
              AxisValueLabel {
                if let repNumber = value.as(Int.self) {
                  Text("\(repNumber)")
                }
              }
            }
          }
          .frame(height: 180)
          .padding(.vertical, 8)
        }

        // レップごとの内訳
        Section("レップ詳細") {
          ForEach(session.sortedReps, id: \.repNumber) { rep in
            RepSummaryRow(rep: rep, exercise: session.exerciseType)
          }
        }
      }
    }
    .navigationTitle("セッション詳細")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func statItem(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value)
        .font(.title3.bold().monospacedDigit())
      Text(title)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }

  private func barColor(_ score: Double) -> Color {
    if score >= 80 { return .green }
    if score >= 60 { return .orange }
    return .red
  }

  private func formatDuration(_ durationMs: Double) -> String {
    let seconds = Int((durationMs / 1000).rounded())
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}
