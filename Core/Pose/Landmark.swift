//
//  Landmark.swift
//  Fomura
//
//  MediaPipe BlazePose（33点）の正規化ランドマークと使用インデックス定義。
//  移植元: frontend/lib/pose/landmarks.ts
//

import Foundation

// MediaPipe Tasks が返す正規化ランドマーク（0〜1）。
struct Landmark: Sendable, Equatable {
  let x: Double
  let y: Double
  let z: Double
  // 可視性（0〜1）。nil の場合は 1 とみなす（Web版 `?? 1` と同じ扱い）。
  let visibility: Double?

  init(x: Double, y: Double, z: Double = 0, visibility: Double? = nil) {
    self.x = x
    self.y = y
    self.z = z
    self.visibility = visibility
  }
}

// BlazePose 33点のうち、筋トレ評価で用いる主要ランドマークのインデックス。
// Web版 landmarks.ts の LANDMARK 定数と完全一致させる。
enum LandmarkIndex {
  static let nose = 0
  static let leftShoulder = 11
  static let rightShoulder = 12
  static let leftElbow = 13
  static let rightElbow = 14
  static let leftWrist = 15
  static let rightWrist = 16
  static let leftHip = 23
  static let rightHip = 24
  static let leftKnee = 25
  static let rightKnee = 26
  static let leftAnkle = 27
  static let rightAnkle = 28
  static let leftHeel = 29
  static let rightHeel = 30
  static let leftFootIndex = 31
  static let rightFootIndex = 32
}
