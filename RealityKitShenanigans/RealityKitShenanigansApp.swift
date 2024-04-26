//
//  RealityKitShenanigansApp.swift
//  RealityKitShenanigans
//
//  Created by Max Thomas on 4/24/24.
//

import SwiftUI
import CompositorServices

struct ContentStageConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
        configuration.depthFormat = .depth32Float
        configuration.colorFormat = .bgra8Unorm_srgb
    
        let foveationEnabled = capabilities.supportsFoveation
        configuration.isFoveationEnabled = foveationEnabled
        
        let options: LayerRenderer.Capabilities.SupportedLayoutsOptions = foveationEnabled ? [.foveationEnabled] : []
        let supportedLayouts = capabilities.supportedLayouts(options: options)
        
        configuration.layout = supportedLayouts.contains(.layered) ? .layered : .dedicated
        
        configuration.colorFormat = .rgba16Float
    }
}

@main
struct RealityKitShenanigansApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        
        ImmersiveSpace(id: "DummyImmersiveSpace") {
            CompositorLayer(configuration: ContentStageConfiguration()) { layerRenderer in
                let renderer = DummyMetalRenderer(layerRenderer)
                renderer.startRenderLoop()
            }
        }.immersionStyle(selection: .constant(.full), in: .full)

        ImmersiveSpace(id: "ImmersiveSpace") {
            ImmersiveView()
        }.immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
