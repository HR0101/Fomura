//
//  HistoryView.swift
//  Fomura
//
//  履歴一覧画面（モバイル設計書.md 第4.5節をローカル保存向けに適応）。
//  SwiftData のセッションを新しい順に表示し、スワイプ削除（確認あり）に対応する。
//

import SwiftUI
import SwiftData

struct HistoryView: View {
  @Environment(\.modelContext) private var modelContext
  @Query(sort: \TrainingSession.createdAt, order: .reverse)
  private var sessions: [TrainingSession]

  // 削除確認中のセッション
  @State private var sessionPendingDeletion: TrainingSession?

  var body: some View {
    Group {
      if sessions.isEmpty {
        ContentUnavailableView(
          "まだ記録がありません",
          systemImage: "figure.strengthtraining.traditional",
          description: Text("ホームからリアルタイム判定または動画解析を実行すると，ここに結果が保存されます．")
        )
      } else {
        List {
          ForEach(sessions) { session in
            NavigationLink(value: session.id) {
              HistoryRow(session: session)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
              Button(role: .destructive) {
                sessionPendingDeletion = session
              } label: {
                Label("削除", systemImage: "trash")
              }
            }
          }
        }
        .navigationDestination(for: UUID.self) { sessionId in
          if let session = sessions.first(where: { $0.id == sessionId }) {
            SessionDetailView(session: session)
          }
        }
      }
    }
    .navigationTitle("履歴")
    .alert(
      "この記録を削除しますか？",
      isPresented: Binding(
        get: { sessionPendingDeletion != nil },
        set: { if !$0 { sessionPendingDeletion = nil } }
      )
    ) {
      Button("削除", role: .destructive) {
        if let session = sessionPendingDeletion {
          modelContext.delete(session)
          try? modelContext.save()
        }
        sessionPendingDeletion = nil
      }
      Button("キャンセル", role: .cancel) {
        sessionPendingDeletion = nil
      }
    } message: {
      Text("削除した記録は元に戻せません．")
    }
  }
}

// 履歴一覧の1行（種目・日時・スコア・取得元バッジ）。
struct HistoryRow: View {
  let session: TrainingSession

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: session.source == .live ? "video.fill" : "film")
        .font(.title3)
        .foregroundStyle(session.source == .live ? .green : .blue)
        .frame(width: 32)

      VStack(alignment: .leading, spacing: 2) {
        Text(session.exerciseType.displayName)
          .font(.headline)
        Text(session.createdAt.formatted(date: .abbreviated, time: .shortened))
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 2) {
        Text(session.totalScore.map { String(format: "%.1f", $0) } ?? "—")
          .font(.headline.monospacedDigit())
        HStack(spacing: 4) {
          Text(session.source.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
              (session.source == .live ? Color.green : Color.blue).opacity(0.15),
              in: Capsule()
            )
            .foregroundStyle(session.source == .live ? .green : .blue)
          Text("\(session.sortedReps.count)レップ")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, 2)
  }
}
