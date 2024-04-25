//
//  ImmersiveSystem.swift
//  RealityKitShenanigans
//
//  Created by Max Thomas on 4/24/24.
//

import RealityKit
import ARKit
import QuartzCore
import Metal
import MetalKit
import Spatial

let alignedUniformsSize = (MemoryLayout<Uniforms>.size + 0xFF) & -0x100
let alignedPlaneUniformSize = (MemoryLayout<PlaneUniform>.size + 0xFF) & -0x100
let maxBuffersInFlight = 3
let maxPlanesDrawn = 512

class DisplayLink: NSObject, ObservableObject {
    @Published var frameDuration: CFTimeInterval = 0
    @Published var frameChange: Bool = false
    
    static let sharedInstance: DisplayLink = DisplayLink()
    
    func createDisplayLink() {
        let displaylink = CADisplayLink(target: self, selector: #selector(frame))
        displaylink.add(to: .current, forMode: RunLoop.Mode.default)
    }
    
    @objc func frame(displaylink: CADisplayLink) {
        frameDuration = displaylink.targetTimestamp - displaylink.timestamp
        frameChange.toggle()
    }
    
}

class VisionPro: NSObject, ObservableObject {
    @Published var frameDuration: CFTimeInterval = 0
    @Published var frameChange: Bool = false
    
    let arSession = ARKitSession()
    let worldTracking = WorldTrackingProvider()
    let handTracking = HandTrackingProvider()
    let sceneReconstruction = SceneReconstructionProvider()
    let planeDetection = PlaneDetectionProvider()
    let displayLink = DisplayLink()
    static let sharedInstance: DisplayLink = DisplayLink()
    var nextFrameTime: TimeInterval = 0.0
    
    var planeAnchors: [UUID: PlaneAnchor] = [:]
    var planeLock = NSObject()
    
    override init() {
        super.init()
        self.createDisplayLink()
        
        Task {
            await processPlaneUpdates()
        }
    }
    
    func transformMatrix() -> simd_float4x4 {
        guard let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: nextFrameTime)
        else {
            print ("Failed to get anchor?")
            return .init()
        }
        return deviceAnchor.originFromAnchorTransform
    }
    
    func runArkitSession() async {
       let authStatus = await arSession.requestAuthorization(for: [.handTracking, .worldSensing])
        
        var trackingList: [any DataProvider] = [worldTracking]
        if authStatus[.handTracking] == .allowed {
            trackingList.append(handTracking)
        }
        if authStatus[.worldSensing] == .allowed {
            trackingList.append(sceneReconstruction)
            trackingList.append(planeDetection)
        }
        
        do {
            try await arSession.run(trackingList)
        } catch {
            fatalError("Failed to initialize ARSession")
        }
    }
    
    func createDisplayLink() {
        let displaylink = CADisplayLink(target: self, selector: #selector(frame))
        displaylink.add(to: .current, forMode: RunLoop.Mode.default)
    }
    
    @objc func frame(displaylink: CADisplayLink) {
        frameDuration = displaylink.targetTimestamp - displaylink.timestamp
        nextFrameTime = displaylink.targetTimestamp + (frameDuration * 3)
        frameChange.toggle()
        //print("vsync frame", frameDuration, displaylink.targetTimestamp - CACurrentMediaTime(), displaylink.timestamp - CACurrentMediaTime())
    }
    
    func processPlaneUpdates() async {
        for await update in planeDetection.anchorUpdates {
            //print(update.event, update.anchor.classification, update.anchor.id, update.anchor.description)
            if update.anchor.classification == .window {
                // Skip planes that are windows.
                continue
            }
            switch update.event {
            case .added, .updated:
                updatePlane(update.anchor)
            case .removed:
                removePlane(update.anchor)
            }
            
        }
    }
    
    func updatePlane(_ anchor: PlaneAnchor) {
        lockPlaneAnchors()
        planeAnchors[anchor.id] = anchor
        unlockPlaneAnchors()
    }

    func removePlane(_ anchor: PlaneAnchor) {
        lockPlaneAnchors()
        planeAnchors.removeValue(forKey: anchor.id)
        unlockPlaneAnchors()
    }
    
    func lockPlaneAnchors() {
        objc_sync_enter(planeLock)
    }
    
    func unlockPlaneAnchors() {
         objc_sync_exit(planeLock)
    }
}

// Focal depth of the timewarp panel, ideally would be adjusted based on the depth
// of what the user is looking at.
let panel_depth: Float = 1

// TODO(zhuowei): what's the z supposed to be?
// x, y, z
// u, v
let fullscreenQuadVertices:[Float] = [-panel_depth, -panel_depth, -panel_depth,
                                       panel_depth, -panel_depth, -panel_depth,
                                       -panel_depth, panel_depth, -panel_depth,
                                       panel_depth, panel_depth, -panel_depth,
                                       0, 1,
                                       0.5, 1,
                                       0, 0,
                                       0.5, 0]

class ImmersiveSystem : System {
    let visionPro = VisionPro()
    var lastUpdateTime = 0.0
    var drawableQueue: TextureResource.DrawableQueue? = nil
    private(set) var surfaceMaterial: ShaderGraphMaterial? = nil
    private var textureResource: TextureResource?
    
    public let device: MTLDevice
    let commandQueue: MTLCommandQueue
    var pipelineState: MTLRenderPipelineState
    var textureCache: CVMetalTextureCache!
    let mtlVertexDescriptor: MTLVertexDescriptor
    var depthStateAlways: MTLDepthStencilState
    var depthStateGreater: MTLDepthStencilState
    var depthTexture: MTLTexture
    var renderViewports: [MTLViewport] = [MTLViewport(originX: 0, originY: 0, width: 1.0, height: 1.0, znear: 0.1, zfar: 10.0), MTLViewport(originX: 0, originY: 0, width: 1.0, height: 1.0, znear: 0.1, zfar: 10.0)]
    var fullscreenQuadBuffer:MTLBuffer!
    
    var dynamicUniformBuffer: MTLBuffer
    var uniformBufferOffset = 0
    var uniformBufferIndex = 0
    var uniforms: UnsafeMutablePointer<Uniforms>
    
    
    var dynamicPlaneUniformBuffer: MTLBuffer
    var planeUniformBufferOffset = 0
    var planeUniformBufferIndex = 0
    var planeUniforms: UnsafeMutablePointer<PlaneUniform>
    
    required init(scene: RealityKit.Scene) {
        //visionPro.createDisplayLink()
        let desc = TextureResource.DrawableQueue.Descriptor(pixelFormat: .rgba16Float, width: 2048, height: 1024, usage: [.renderTarget, .shaderRead, .shaderWrite], mipmapsMode: .none)
        self.drawableQueue = try? TextureResource.DrawableQueue(desc)
        
        let data = Data([0x00, 0x00, 0x00, 0xFF])
        self.textureResource = try! TextureResource(
            dimensions: .dimensions(width: 1, height: 1),
            format: .raw(pixelFormat: .bgra8Unorm),
            contents: .init(
                mipmapLevels: [
                    .mip(data: data, bytesPerRow: 4),
                ]
            )
        )
        
        
        self.device = MTLCreateSystemDefaultDevice()!
        self.commandQueue = self.device.makeCommandQueue()!
        
        mtlVertexDescriptor = ImmersiveSystem.buildMetalVertexDescriptor()

        do {
            pipelineState = try ImmersiveSystem.buildRenderPipelineWithDevice(device: device,
                                                                       mtlVertexDescriptor: mtlVertexDescriptor)
        } catch {
            fatalError("Unable to compile render pipeline state.  Error info: \(error)")
        }
        
        let depthStateDescriptorAlways = MTLDepthStencilDescriptor()
        depthStateDescriptorAlways.depthCompareFunction = MTLCompareFunction.always
        depthStateDescriptorAlways.isDepthWriteEnabled = true
        self.depthStateAlways = device.makeDepthStencilState(descriptor:depthStateDescriptorAlways)!
        
        let depthStateDescriptorGreater = MTLDepthStencilDescriptor()
        depthStateDescriptorGreater.depthCompareFunction = MTLCompareFunction.greater
        depthStateDescriptorGreater.isDepthWriteEnabled = true
        self.depthStateGreater = device.makeDepthStencilState(descriptor:depthStateDescriptorGreater)!
        
        // Create depth texture descriptor
        let depthTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                                              width: 2048,
                                                                              height: 1024,
                                                                              mipmapped: false)
        depthTextureDescriptor.usage = [.renderTarget, .shaderRead]
        depthTextureDescriptor.storageMode = .private
        self.depthTexture = device.makeTexture(descriptor: depthTextureDescriptor)!
        
        // Main uniforms
        let uniformBufferSize = alignedUniformsSize * maxBuffersInFlight * 2
        self.dynamicUniformBuffer = self.device.makeBuffer(length:uniformBufferSize,
                                                           options:[MTLResourceOptions.storageModeShared])!
        self.dynamicUniformBuffer.label = "UniformBuffer"
        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffer.contents()).bindMemory(to:Uniforms.self, capacity:1)
        
        // Plane uniforms
        let planeUniformBufferSize = alignedPlaneUniformSize * maxPlanesDrawn
        self.dynamicPlaneUniformBuffer = self.device.makeBuffer(length:planeUniformBufferSize,
                                                           options:[MTLResourceOptions.storageModeShared])!
        self.dynamicPlaneUniformBuffer.label = "PlaneUniformBuffer"
        planeUniforms = UnsafeMutableRawPointer(dynamicPlaneUniformBuffer.contents()).bindMemory(to:PlaneUniform.self, capacity:1)
        
        renderViewports[0] = MTLViewport(originX: 0, originY: 0, width: 1024.0, height: 1024.0, znear: 0.1, zfar: 10.0)
        renderViewports[1] = MTLViewport(originX: 1024.0, originY: 0, width: 1024.0, height: 1024.0, znear: 0.1, zfar: 10.0)
        
        fullscreenQuadVertices.withUnsafeBytes {
            fullscreenQuadBuffer = device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)
        }
        
        Task {
            await visionPro.runArkitSession()
        }
        Task {
            self.surfaceMaterial = try! await ShaderGraphMaterial(
                named: "/Root/SBSMaterial",
                from: "SBSMaterial.usda"
            )
            let tex = MaterialParameters.Texture(self.textureResource!)
            try! self.surfaceMaterial!.setParameter(
                name: "texture",
                value: .textureResource(self.textureResource!)
            )
            textureResource!.replace(withDrawables: drawableQueue!)
        }
    }

    class func buildMetalVertexDescriptor() -> MTLVertexDescriptor {
        // Create a Metal vertex descriptor specifying how vertices will by laid out for input into our render
        //   pipeline and how we'll layout our Model IO vertices

        let mtlVertexDescriptor = MTLVertexDescriptor()

        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].format = MTLVertexFormat.float3
        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].offset = 0
        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].bufferIndex = BufferIndex.meshPositions.rawValue

        mtlVertexDescriptor.attributes[VertexAttribute.texcoord.rawValue].format = MTLVertexFormat.float2
        mtlVertexDescriptor.attributes[VertexAttribute.texcoord.rawValue].offset = 0
        mtlVertexDescriptor.attributes[VertexAttribute.texcoord.rawValue].bufferIndex = BufferIndex.meshGenerics.rawValue

        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stride = 12
        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stepRate = 1
        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stepFunction = MTLVertexStepFunction.perVertex

        mtlVertexDescriptor.layouts[BufferIndex.meshGenerics.rawValue].stride = 8
        mtlVertexDescriptor.layouts[BufferIndex.meshGenerics.rawValue].stepRate = 1
        mtlVertexDescriptor.layouts[BufferIndex.meshGenerics.rawValue].stepFunction = MTLVertexStepFunction.perVertex

        return mtlVertexDescriptor
    }

    class func buildRenderPipelineWithDevice(device: MTLDevice,
                                             mtlVertexDescriptor: MTLVertexDescriptor) throws -> MTLRenderPipelineState {
        /// Build a render state pipeline object

        let library = device.makeDefaultLibrary()

        let vertexFunction = library?.makeFunction(name: "vertexShader")
        let fragmentFunction = library?.makeFunction(name: "fragmentShader")

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "RenderPipeline"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = mtlVertexDescriptor

        pipelineDescriptor.colorAttachments[0].pixelFormat = .rgba16Float
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
        pipelineDescriptor.maxVertexAmplificationCount = 1 // todo stereo
        
        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    func update(context: SceneUpdateContext) {
        // RealityKit automatically calls this every frame for every scene.
        let plane = context.scene.findEntity(named: "video_plane") as? ModelEntity
        if let plane = plane {
            //print("frame", plane.id)
            
            let transform = visionPro.transformMatrix()
            let x = transform.columns.3.x
            let y = transform.columns.3.y
            let z = transform.columns.3.z
            plane.position = simd_float3(x - transform.columns.2.x, y - transform.columns.2.y, z - transform.columns.2.z)
            plane.orientation = simd_quatf(transform) * simd_quatf(angle: 1.5708, axis: simd_float3(1,0,0))
            //print(String(format: "%.2f, %.2f, %.2f", x, y, z), CACurrentMediaTime() - lastUpdateTime)
            lastUpdateTime = CACurrentMediaTime()
            
            if let surfaceMaterial = surfaceMaterial {
                plane.model?.materials = [surfaceMaterial]
            }
            
            do {
                let drawable = try drawableQueue?.nextDrawable()
                drawNextTexture(drawable: drawable!)
            }
            catch {
            
            }
        }
    }
    
    private func updateDynamicBufferState(_ eyeIdx: Int) {
        /// Update the state of our uniform buffers before rendering

        uniformBufferIndex = (uniformBufferIndex + 1) % maxBuffersInFlight
        uniformBufferOffset = alignedUniformsSize * ((uniformBufferIndex*2)+eyeIdx)
        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffer.contents() + uniformBufferOffset).bindMemory(to:Uniforms.self, capacity:1)
    }
    
    private func selectNextPlaneUniformBuffer() {
        /// Update the state of our uniform buffers before rendering

        planeUniformBufferIndex = (planeUniformBufferIndex + 1) % maxPlanesDrawn
        planeUniformBufferOffset = alignedPlaneUniformSize * planeUniformBufferIndex
        planeUniforms = UnsafeMutableRawPointer(dynamicPlaneUniformBuffer.contents() + planeUniformBufferOffset).bindMemory(to:PlaneUniform.self, capacity:1)
    }
    
    private func updateGameStateForVideoFrame(_ eyeIdx: Int, framePose: simd_float4x4) {
        let simdDeviceAnchor = matrix_identity_float4x4
        
        func uniforms(forViewIndex viewIndex: Int) -> Uniforms {
            //let view = self.renderViewports[viewIndex]
            let tangents = simd_float4(-1.0471973, 0.7853982, 0.7853982, -0.8726632)
            
            var framePoseNoTranslation = framePose
            var simdDeviceAnchorNoTranslation = simdDeviceAnchor
            framePoseNoTranslation.columns.3 = simd_float4(0.0, 0.0, 0.0, 1.0)
            simdDeviceAnchorNoTranslation.columns.3 = simd_float4(0.0, 0.0, 0.0, 1.0)
            let viewMatrix = (simdDeviceAnchor /** view.transform*/).inverse
            let viewMatrixFrame = (framePoseNoTranslation.inverse * simdDeviceAnchorNoTranslation).inverse
            let projection = ProjectiveTransform3D(leftTangent: Double(tangents[0]),
                                                   rightTangent: Double(tangents[1]),
                                                   topTangent: Double(tangents[2]),
                                                   bottomTangent: Double(tangents[3]),
                                                   nearZ: 0.1,
                                                   farZ: 10.0,
                                                   reverseZ: true)
            return Uniforms(projectionMatrix: .init(projection), modelViewMatrixFrame: viewMatrixFrame, modelViewMatrix: viewMatrix, tangents: tangents, which: UInt32(viewIndex))
        }
        
        self.uniforms[0] = uniforms(forViewIndex: eyeIdx)
        /*if drawable.views.count > 1 {
            self.uniforms[0].uniforms.1 = uniforms(forViewIndex: 1)
        }*/
    }
    
    func renderOverlay(eyeIdx: Int, colorTexture: MTLTexture, commandBuffer: MTLCommandBuffer, framePose: simd_float4x4)
    {
        self.updateDynamicBufferState(eyeIdx)
        self.updateGameStateForVideoFrame(eyeIdx, framePose: framePose)
        
        // Toss out the depth buffer, keep colors
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = colorTexture
        renderPassDescriptor.colorAttachments[0].loadAction = eyeIdx == 0 ? .clear : .load
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 0.0)
        renderPassDescriptor.depthAttachment.texture = depthTexture
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.storeAction = .dontCare
        renderPassDescriptor.depthAttachment.clearDepth = 0.0
        //renderPassDescriptor.rasterizationRateMap = drawable.rasterizationRateMaps.first
        
        renderPassDescriptor.renderTargetArrayLength = 1 // TODO multiview
        
        //let viewports = drawable.views.map { $0.textureMap.viewport }
        
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fatalError("Failed to create render encoder")
        }
        renderEncoder.label = "Plane Render Encoder"
        renderEncoder.pushDebugGroup("Draw planes")
        renderEncoder.setCullMode(.back)
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setViewports([renderViewports[eyeIdx]])
        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        
        /*if drawable.views.count > 1 {
            var viewMappings = (0..<drawable.views.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
        }*/
        
        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setDepthStencilState(depthStateGreater)
        
        renderEncoder.setVertexBuffer(fullscreenQuadBuffer, offset: 0, index: VertexAttribute.position.rawValue)
        renderEncoder.setVertexBuffer(fullscreenQuadBuffer, offset: (3*4)*4, index: VertexAttribute.texcoord.rawValue)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        
        /*WorldTracker.shared.lockPlaneAnchors()
        
        // Render planes
        for plane in WorldTracker.shared.planeAnchors {
            let plane = plane.value
            let faces = plane.geometry.meshFaces
            renderEncoder.setVertexBuffer(plane.geometry.meshVertices.buffer, offset: 0, index: VertexAttribute.position.rawValue)
            renderEncoder.setVertexBuffer(plane.geometry.meshVertices.buffer, offset: 0, index: VertexAttribute.texcoord.rawValue)
            
            //self.updateGameStateForVideoFrame(drawable: drawable, framePose: framePose, planeTransform: plane.originFromAnchorTransform)
            selectNextPlaneUniformBuffer()
            self.planeUniforms[0].planeTransform = plane.originFromAnchorTransform
            self.planeUniforms[0].planeColor = planeToColor(plane: plane)
            self.planeUniforms[0].planeDoProximity = 1.0
            renderEncoder.setVertexBuffer(dynamicPlaneUniformBuffer, offset:planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue)
            
            renderEncoder.setTriangleFillMode(.fill)
            renderEncoder.drawIndexedPrimitives(type: faces.primitive == .triangle ? MTLPrimitiveType.triangle : MTLPrimitiveType.line,
                                                indexCount: faces.count*3,
                                                indexType: faces.bytesPerIndex == 2 ? MTLIndexType.uint16 : MTLIndexType.uint32,
                                                indexBuffer: faces.buffer,
                                                indexBufferOffset: 0)
        }
        
        // Render lines
        for plane in WorldTracker.shared.planeAnchors {
            let plane = plane.value
            let faces = plane.geometry.meshFaces
            renderEncoder.setVertexBuffer(plane.geometry.meshVertices.buffer, offset: 0, index: VertexAttribute.position.rawValue)
            renderEncoder.setVertexBuffer(plane.geometry.meshVertices.buffer, offset: 0, index: VertexAttribute.texcoord.rawValue)
            
            //self.updateGameStateForVideoFrame(drawable: drawable, framePose: framePose, planeTransform: plane.originFromAnchorTransform)
            selectNextPlaneUniformBuffer()
            self.planeUniforms[0].planeTransform = plane.originFromAnchorTransform
            self.planeUniforms[0].planeColor = planeToLineColor(plane: plane)
            self.planeUniforms[0].planeDoProximity = 0.0
            renderEncoder.setVertexBuffer(dynamicPlaneUniformBuffer, offset:planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue)
            
            renderEncoder.setTriangleFillMode(.lines)
            renderEncoder.drawIndexedPrimitives(type: faces.primitive == .triangle ? MTLPrimitiveType.triangle : MTLPrimitiveType.line,
                                                indexCount: faces.count*3,
                                                indexType: faces.bytesPerIndex == 2 ? MTLIndexType.uint16 : MTLIndexType.uint32,
                                                indexBuffer: faces.buffer,
                                                indexBufferOffset: 0)
        }
        WorldTracker.shared.unlockPlaneAnchors()
        */
        renderEncoder.popDebugGroup()
        renderEncoder.endEncoding()
    }
    
    func drawNextTexture(drawable: TextureResource.Drawable) {
    
        autoreleasepool {
            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                return
            }
            
            renderOverlay(eyeIdx: 0, colorTexture: drawable.texture, commandBuffer: commandBuffer, framePose: matrix_identity_float4x4)
            renderOverlay(eyeIdx: 1, colorTexture: drawable.texture, commandBuffer: commandBuffer, framePose: matrix_identity_float4x4)
            
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
