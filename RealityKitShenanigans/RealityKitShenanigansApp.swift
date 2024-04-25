//
//  RealityKitShenanigansApp.swift
//  RealityKitShenanigans
//
//  Created by Max Thomas on 4/24/24.
//

import SwiftUI

@main
struct RealityKitShenanigansApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }

        ImmersiveSpace(id: "ImmersiveSpace") {
            ImmersiveView()
        }.immersionStyle(selection: .constant(.full), in: .full)
    }
}
