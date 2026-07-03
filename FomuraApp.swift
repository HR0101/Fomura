//
//  FomuraApp.swift
//  Fomura
//
//  アプリエントリポイント。SwiftData のモデルコンテナ（端末内保存）を構成する。
//

import SwiftUI
import SwiftData

@main
struct FomuraApp: App {
  var sharedModelContainer: ModelContainer = {
    let schema = Schema([
      TrainingSession.self,
      RepRecord.self,
    ])
    let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

    do {
      return try ModelContainer(for: schema, configurations: [modelConfiguration])
    } catch {
      fatalError("ModelContainer の作成に失敗しました: \(error)")
    }
  }()

  var body: some Scene {
    WindowGroup {
      ContentView()
    }
    .modelContainer(sharedModelContainer)
  }
}
