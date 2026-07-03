//
//  HomeView.swift
//  Fomura
//
//  ホーム画面（モバイル設計書.md 第4.2節をローカル完結向けに適応）。
//  モードカード2枚（リアルタイム判定 / 動画解析）を表示する。
//  認証はローカル完結方針のため廃止。
//

import SwiftUI
import SwiftData

struct HomeView: View {
  @Query(sort: \TrainingSession.createdAt, order: .reverse)
  private var sessions: [TrainingSession]

  @State private var showLiveSession = false

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        // ヘッダー
        VStack(alignment: .leading, spacing: 6) {
          Text("Fomura")
            .font(.largeTitle.bold())
          Text("骨格モーションでフォームを採点する筋トレアシスタント")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        // モードカード
        Button {
          showLiveSession = true
        } label: {
          modeCard(
            icon: "play.circle.fill",
            title: "リアルタイム判定",
            description: "カメラで骨格を検出し，レップ数・フォームをその場で採点します",
            color: .green
          )
        }
        .buttonStyle(.plain)

        NavigationLink {
          UploadView()
        } label: {
          modeCard(
            icon: "film.circle.fill",
            title: "動画ファイル解析",
            description: "撮影済みの動画を端末内で解析し，レップごとに採点します",
            color: .blue
          )
        }
        .buttonStyle(.plain)

        // 直近の記録
        if !sessions.isEmpty {
          VStack(alignment: .leading, spacing: 10) {
            Text("最近の記録")
              .font(.headline)
            ForEach(sessions.prefix(3)) { session in
              NavigationLink {
                SessionDetailView(session: session)
              } label: {
                HistoryRow(session: session)
                  .padding(12)
                  .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12)
                  )
              }
              .buttonStyle(.plain)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(20)
    }
    .background(Color(.systemGroupedBackground))
    .fullScreenCover(isPresented: $showLiveSession) {
      LiveSessionView()
    }
  }

  private func modeCard(icon: String, title: String, description: String, color: Color) -> some View {
    HStack(spacing: 16) {
      Image(systemName: icon)
        .font(.system(size: 40))
        .foregroundStyle(color)
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.headline)
          .foregroundStyle(.primary)
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.leading)
      }
      Spacer()
      Image(systemName: "chevron.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.tertiary)
    }
    .padding(16)
    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
  }
}
