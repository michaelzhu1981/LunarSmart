//
//  LunarSmartApp.swift
//  LunarSmart
//
//  Created by 朱晓龙 on 2026/1/21.
//

import SwiftUI

@main
struct LunarSmartApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        .defaultSize(width: 860, height: 860)
        #endif
    }
}
