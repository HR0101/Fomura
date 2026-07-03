//
//  ContentView.swift
//  Fomura
//
//  ルート画面。タブ（ホーム / 履歴 / 設定）を提供する（モバイル設計書.md 第4.1節）。
//  初回起動時に免責事項を表示する。
//

import SwiftUI
import SwiftData

struct ContentView: View {
  @AppStorage(AppSettings.hasSeenDisclaimer) private var hasSeenDisclaimer = false
  @State private var showDisclaimer = false

  var body: some View {
    TabView {
      NavigationStack {
        HomeView()
      }
      .tabItem {
        Label("ホーム", systemImage: "house.fill")
      }

      NavigationStack {
        StatsView()
      }
      .tabItem {
        Label("統計", systemImage: "chart.xyaxis.line")
      }

      NavigationStack {
        HistoryView()
      }
      .tabItem {
        Label("履歴", systemImage: "clock.arrow.circlepath")
      }

      NavigationStack {
        SettingsView()
      }
      .tabItem {
        Label("設定", systemImage: "gearshape.fill")
      }
    }
    .onAppear {
      if !hasSeenDisclaimer {
        showDisclaimer = true
      }
    }
    .alert("ご利用にあたって", isPresented: $showDisclaimer) {
      Button("同意して開始") {
        hasSeenDisclaimer = true
      }
    } message: {
      Text("本アプリの判定・スコアはトレーニング補助を目的とした参考情報であり，医療的助言ではありません．すべての処理は端末内で行われ，映像やデータが外部へ送信されることはありません．")
    }
  }
}

#Preview {
  ContentView()
    .modelContainer(for: TrainingSession.self, inMemory: true)
}
