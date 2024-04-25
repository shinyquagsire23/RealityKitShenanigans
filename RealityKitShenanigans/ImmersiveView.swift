//
//  ImmersiveView.swift
//  RealityKitShenanigans
//
//  Created by Max Thomas on 4/24/24.
//

import SwiftUI
import RealityKit
import RealityKitContent
import AVFoundation
import CoreImage

struct ImmersiveView: View {
    var texture: MaterialParameters.Texture?
    private let label = Text("frame")
    
    var body: some View {
        RealityView { content in
            ImmersiveSystem.registerSystem()
            
            let material = PhysicallyBasedMaterial()
            let videoPlaneMesh = MeshResource.generatePlane(width: 1.0, depth: 1.0)
            let videoPlane = ModelEntity(mesh: videoPlaneMesh, materials: [material])
            videoPlane.name = "video_plane"
            content.add(videoPlane)
        } update: { content in
            /*let sphere = content.entities.first(where: { entity in
                return entity.name == "video_plane"
            }) as! ModelEntity
            var material = PhysicallyBasedMaterial()
            
            material.baseColor = .init(texture: texture)
            sphere.model?.materials = [material]*/
                    
        }
    }
}

#Preview(immersionStyle: .full) {
    ImmersiveView()
}
