//
//  CSVExporter.swift
//  Fomura
//
//  トレーニング記録のCSVエクスポート（レップ単位の1行形式）。
//  共有シート経由でユーザー主導の書き出しのみを行う（自動送信はしない）。
//

import Foundation
import CoreTransferable
import UniformTypeIdentifiers

enum CSVExporter {
  // レップ単位のCSVを生成する（レップ0件のセッションもセッション行として1行残す）。
  static func makeCSV(sessions: [TrainingSession]) -> String {
    let formatter = ISO8601DateFormatter()
    var rows = [
      "session_id,created_at,exercise,source,total_score,rep_number,rep_score,start_ms,end_ms,min_primary_angle,faults"
    ]

    for session in sessions.sorted(by: { $0.createdAt > $1.createdAt }) {
      let base = [
        session.id.uuidString,
        formatter.string(from: session.createdAt),
        session.exerciseType.rawValue,
        session.source.rawValue,
        session.totalScore.map { String($0) } ?? "",
      ]

      let reps = session.sortedReps
      if reps.isEmpty {
        rows.append((base + ["", "", "", "", "", ""]).joined(separator: ","))
        continue
      }

      for rep in reps {
        let minAngle = rep.features["min_primary_angle"]?.numberValue
        let fields = base + [
          String(rep.repNumber),
          String(rep.score),
          String(rep.startTimestampMs),
          String(rep.endTimestampMs),
          minAngle.map { String($0) } ?? "",
          escape(rep.faultIds.joined(separator: ";")),
        ]
        rows.append(fields.joined(separator: ","))
      }
    }

    return rows.joined(separator: "\n") + "\n"
  }

  // CSVフィールドのエスケープ（カンマ・引用符・改行を含む場合のみ引用する）。
  private static func escape(_ field: String) -> String {
    if field.contains(",") || field.contains("\"") || field.contains("\n") {
      return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    return field
  }
}

// ShareLink 用の遅延生成CSVファイル（共有実行時に初めて生成される）。
struct TrainingCSVFile: Transferable {
  let csvText: String

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .commaSeparatedText) { file in
      let url = URL.temporaryDirectory.appending(path: "Fomuraトレーニング記録.csv")
      // Excel での文字化け防止に BOM 付き UTF-8 で書き出す。
      var data = Data([0xEF, 0xBB, 0xBF])
      data.append(Data(file.csvText.utf8))
      try data.write(to: url, options: .atomic)
      return SentTransferredFile(url)
    }
  }
}
