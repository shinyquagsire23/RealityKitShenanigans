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
            let videoPlaneMesh = MeshResource.generatePlane(width: 2.0, depth: 2.0)
            let videoPlane = ModelEntity(mesh: videoPlaneMesh, materials: [material])
            //videoPlane.components.set(GroundingShadowComponent(castsShadow: true))
            videoPlane.name = "video_plane"
            videoPlane.orientation = simd_quatf(angle: 1.5708, axis: simd_float3(1,0,0))
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
