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
import AVFoundation

let alignedUniformsSize = (MemoryLayout<Uniforms>.size + 0xFF) & -0x100
let alignedPlaneUniformSize = (MemoryLayout<PlaneUniform>.size + 0xFF) & -0x100
let maxBuffersInFlight = 3
let maxPlanesDrawn = 1024
let renderWidthReal = Int(1920)
let renderHeightReal = Int(1824)
let renderWidth = Int(renderWidthReal+256+32+8+2) // each eye is slightly spaced apart, 256px x 80px at 1x. Not sure how to calculate this.
let renderHeight = Int(renderHeightReal+80+4)
let renderScale = 2.25
let renderFormat = MTLPixelFormat.bgra8Unorm // rgba8Unorm, rgba8Unorm_srgb, bgra8Unorm, bgra8Unorm_srgb, rgba16Float
let renderZNear = 0.001
let renderZFar = 100.0

class VisionPro: NSObject, ObservableObject {
    let arSession = ARKitSession()
    let worldTracking = WorldTrackingProvider()
    let handTracking = HandTrackingProvider()
    let sceneReconstruction = SceneReconstructionProvider()
    let planeDetection = PlaneDetectionProvider()
    var nextFrameTime: TimeInterval = 0.0
    
    var planeAnchors: [UUID: PlaneAnchor] = [:]
    var planeLock = NSObject()
    var vsyncDelta: Double = (1.0 / 90.0)
    
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
        let frameDuration = displaylink.targetTimestamp - displaylink.timestamp
        nextFrameTime = displaylink.targetTimestamp + (frameDuration * 4)
        vsyncDelta = frameDuration
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
let panel_depth: Float = 70
let rk_panel_depth: Float = 100

// TODO(zhuowei): what's the z supposed to be?
// x, y, z
// u, v
let fullscreenQuadVertices:[Float] = [-panel_depth*5, -panel_depth*5, -panel_depth,
                                       panel_depth*5, -panel_depth*5, -panel_depth,
                                       -panel_depth*5, panel_depth*5, -panel_depth,
                                       panel_depth*5, panel_depth*5, -panel_depth,
                                       0, 1,
                                       1, 1,
                                       0, 0,
                                       1, 0]

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
    
    //var renderTangents: [simd_float4] = [simd_float4(-1.0471973, 0.7853982, 0.7853982, -0.8726632), simd_float4(-0.7853982, 1.0471973, 0.7853982, -0.8726632)]
    var fullscreenQuadBuffer:MTLBuffer!
    var lastTexture: MTLTexture? = nil
    
    var dynamicUniformBuffer: MTLBuffer
    var uniformBufferOffset = 0
    var uniformBufferIndex = 0
    var uniforms: UnsafeMutablePointer<Uniforms>
    
    
    var dynamicPlaneUniformBuffer: MTLBuffer
    var planeUniformBufferOffset = 0
    var planeUniformBufferIndex = 0
    var planeUniforms: UnsafeMutablePointer<PlaneUniform>
    var badAppleTexture: MTLTexture? = nil
    var badAppleLock = NSObject()
    var frameIdx: Int = 0
    
    var currentRenderWidth: Int = Int(Double(renderWidth) * renderScale)
    var currentRenderHeight: Int = Int(Double(renderHeight) * renderScale)
    var lastRenderWidth: Int = Int(Double(renderWidth) * renderScale)
    var lastRenderHeight: Int = Int(Double(renderHeight) * renderScale)
    var lastFbChangeTime: Double = 0.0
    var lockOutRaising: Bool = false
    var deltaLeftovers: Double = 0.0
    var currentRenderScale: Double = renderScale
    
    var video: VideoReader? = nil
    
    required init(scene: RealityKit.Scene) {
        //visionPro.createDisplayLink()
        let desc = TextureResource.DrawableQueue.Descriptor(pixelFormat: renderFormat, width: currentRenderWidth, height: currentRenderHeight*2, usage: [.renderTarget], mipmapsMode: .none)
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
                                                                              width: currentRenderWidth,
                                                                              height: currentRenderHeight*2,
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
        
        renderViewports[0] = MTLViewport(originX: 0, originY: Double(currentRenderHeight), width: Double(currentRenderWidth), height: Double(currentRenderHeight), znear: renderZNear, zfar: renderZFar)
        renderViewports[1] = MTLViewport(originX: 0, originY: 0, width: Double(currentRenderWidth), height: Double(currentRenderHeight), znear: renderZNear, zfar: renderZFar)
        
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
            try! self.surfaceMaterial!.setParameter(
                name: "texture",
                value: .textureResource(self.textureResource!)
            )
            textureResource!.replace(withDrawables: drawableQueue!)
        }
        
        if CVMetalTextureCacheCreate(nil, nil, self.device, nil, &textureCache) != 0 {
            fatalError("CVMetalTextureCacheCreate")
        }
                
        video = VideoReader()
        video?.sampleRead = self.readVideoSample
        //video?.readSamples()
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

        pipelineDescriptor.colorAttachments[0].pixelFormat = renderFormat
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
    
    func readVideoSample(buffer: CMSampleBuffer) {
        let pixelFormat = MTLPixelFormat.bgra8Unorm
        guard let cvImageBuffer = CMSampleBufferGetImageBuffer(buffer)
        else {
            return
        }
        guard
            let textureCache = textureCache
        else {
            return
        }

        let width = CVPixelBufferGetWidth(cvImageBuffer)
        let height = CVPixelBufferGetHeight(cvImageBuffer)
        var textureOptional: CVMetalTexture?

        let createResult = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, cvImageBuffer, nil, pixelFormat, width, height, 0, &textureOptional)

        guard
            createResult == kCVReturnSuccess,
            let texture = textureOptional,
            let resultTexture = CVMetalTextureGetTexture(texture)
        else {
            return
        }
        //print("texture!", CACurrentMediaTime(), resultTexture)
        
        objc_sync_enter(badAppleLock)
        badAppleTexture = resultTexture
        objc_sync_exit(badAppleLock)
    }

    var lastFrameFetch: Double = 0.0
    func update(context: SceneUpdateContext) {
        // RealityKit automatically calls this every frame for every scene.
        let plane = context.scene.findEntity(named: "video_plane") as? ModelEntity
        if let plane = plane {
            //print("frame", plane.id)
            
            let transform = visionPro.transformMatrix()
            
            var planeTransform = transform
            //planeTransform *= renderViewTransforms[0]
            planeTransform.columns.3 -= transform.columns.2 * rk_panel_depth
            //planeTransform.columns.3 += transform.columns.0 * 0.5
            
            do {
                let drawable = try drawableQueue?.nextDrawable()
                if drawable == nil {
                    return
                }
                
                var scale = simd_float3(DummyMetalRenderer.renderTangents[0].x + DummyMetalRenderer.renderTangents[0].y, 1.0, DummyMetalRenderer.renderTangents[0].z + DummyMetalRenderer.renderTangents[0].w)
                scale *= rk_panel_depth
                let orientation = simd_quatf(transform) * simd_quatf(angle: 1.5708, axis: simd_float3(1,0,0))
                let position = simd_float3(planeTransform.columns.3.x, planeTransform.columns.3.y, planeTransform.columns.3.z)
                
                //print(String(format: "%.2f, %.2f, %.2f", planeTransform.columns.3.x, planeTransform.columns.3.y, planeTransform.columns.3.z), CACurrentMediaTime() - lastUpdateTime)
                lastUpdateTime = CACurrentMediaTime()
                
                if let surfaceMaterial = surfaceMaterial {
                    plane.model?.materials = [surfaceMaterial]
                }
                
                video?.sampleRead = self.readVideoSample
                
                if lastSubmit == 0.0 {
                    lastSubmit = CACurrentMediaTime() - visionPro.vsyncDelta
                    lastFrameFetch = CACurrentMediaTime()
                }
                var delta = (CACurrentMediaTime() - lastFrameFetch) + deltaLeftovers
                lastFrameFetch = CACurrentMediaTime()
                //delta = 0.1
                var readAFrame = false
                var idx = 0
                while delta >= visionPro.vsyncDelta { // TODO: should be media frame delta I think
                    video?.readSamplesNext()
                    //print("frame", delta, idx)
                    frameIdx += 1
                    delta -= visionPro.vsyncDelta;
                    readAFrame = true
                    idx += 1
                }
                if readAFrame {
                    video?.readSamplesManually()
                }
                deltaLeftovers = delta
                
                objc_sync_enter(badAppleLock)
                drawNextTexture(drawable: drawable!, simdDeviceAnchor: transform, plane: plane, position: position, orientation: orientation, scale: scale)
                drawable!.presentOnSceneUpdate()
                objc_sync_exit(badAppleLock)
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
    
    private func updateGameStateForVideoFrame(_ eyeIdx: Int, framePose: simd_float4x4, simdDeviceAnchor: simd_float4x4) {
        func uniforms(forViewIndex viewIndex: Int) -> Uniforms {
            //let view = self.renderViewports[viewIndex]
            let tangents = DummyMetalRenderer.renderTangents[viewIndex]
            let viewTrans = DummyMetalRenderer.renderViewTransforms[viewIndex]
            
            var framePoseNoTranslation = framePose
            var simdDeviceAnchorNoTranslation = simdDeviceAnchor
            framePoseNoTranslation.columns.3 = simd_float4(0.0, 0.0, 0.0, 1.0)
            simdDeviceAnchorNoTranslation.columns.3 = simd_float4(0.0, 0.0, 0.0, 1.0)
            let viewMatrix = (simdDeviceAnchor * viewTrans).inverse
            let viewMatrixFrame = (framePoseNoTranslation.inverse * simdDeviceAnchorNoTranslation).inverse
            /*let projection = ProjectiveTransform3D(leftTangent: Double(tangents[0]),
                                                   rightTangent: Double(tangents[1]),
                                                   topTangent: Double(tangents[2]),
                                                   bottomTangent: Double(tangents[3]),
                                                   nearZ: renderZNear,
                                                   farZ: renderZFar,
                                                   reverseZ: true)*/
            
            let projection = ProjectiveTransform3D(leftTangent: (Double(tangents[0]) + Double(tangents[1])) * 0.5,
                                                   rightTangent: (Double(tangents[0]) + Double(tangents[1])) * 0.5,
                                                   topTangent: (Double(tangents[2]) + Double(tangents[3])) * 0.5,
                                                   bottomTangent: (Double(tangents[2]) + Double(tangents[3])) * 0.5,
                                                   nearZ: renderZNear,
                                                   farZ: renderZFar,
                                                   reverseZ: true)
            return Uniforms(projectionMatrix: .init(projection), modelViewMatrixFrame: viewMatrixFrame, modelViewMatrix: viewMatrix, tangents: tangents, which: UInt32(viewIndex), renderWidth: Float(currentRenderWidth), renderHeight: Float(currentRenderHeight))
        }
        
        self.uniforms[0] = uniforms(forViewIndex: eyeIdx)
        /*if drawable.views.count > 1 {
            self.uniforms[0].uniforms.1 = uniforms(forViewIndex: 1)
        }*/
    }
    
    func planeToColor(plane: PlaneAnchor) -> simd_float4 {
        let planeAlpha: Float = 1.0
        let subtleChange = 0.75 + ((Float(plane.id.hashValue & 0xFF) / Float(0xff)) * 0.25)
        
        switch(plane.classification) {
            case .ceiling: // #62ea80
                return simd_float4(0.3843137254901961, 0.9176470588235294, 0.5019607843137255, 1.0) * subtleChange * planeAlpha
            case .door: // #1a5ff4
                return simd_float4(0.10196078431372549, 0.37254901960784315, 0.9568627450980393, 1.0) * subtleChange * planeAlpha
            case .floor: // #bf6505
                return simd_float4(0.7490196078431373, 0.396078431372549, 0.0196078431372549, 1.0) * subtleChange * planeAlpha
            case .seat: // #ef67af
                return simd_float4(0.9372549019607843, 0.403921568627451, 0.6862745098039216, 1.0) * subtleChange * planeAlpha
            case .table: // #c937d3
                return simd_float4(0.788235294117647, 0.21568627450980393, 0.8274509803921568, 1.0) * subtleChange * planeAlpha
            case .wall: // #dced5e
                return simd_float4(0.8627450980392157, 0.9294117647058824, 0.3686274509803922, 1.0) * subtleChange * planeAlpha
            case .window: // #4aefce
                return simd_float4(0.2901960784313726, 0.9372549019607843, 0.807843137254902, 1.0) * subtleChange * planeAlpha
            case .unknown: // #0e576b
                return simd_float4(0.054901960784313725, 0.3411764705882353, 0.4196078431372549, 1.0) * subtleChange * planeAlpha
            case .undetermined: // #749606
                return simd_float4(0.4549019607843137, 0.5882352941176471, 0.023529411764705882, 1.0) * subtleChange * planeAlpha
            default:
                return simd_float4(1.0, 0.0, 0.0, 1.0) * subtleChange * planeAlpha // red
        }
    }
    
    func planeToColor2(plane: PlaneAnchor) -> simd_float4 {
        var orig = planeToColor(plane: plane)
        let val = ((orig[0]+orig[1]+orig[2])/3.0) * 1.5
        return simd_float4(val, val, val, 1.0)
    }
    
    func planeToLineColor(plane: PlaneAnchor) -> simd_float4 {
        return planeToColor2(plane: plane)
    }
    
    func renderOverlay(eyeIdx: Int, colorTexture: MTLTexture, commandBuffer: MTLCommandBuffer, framePose: simd_float4x4, simdDeviceAnchor: simd_float4x4)
    {
        self.updateDynamicBufferState(eyeIdx)
        self.updateGameStateForVideoFrame(eyeIdx, framePose: framePose, simdDeviceAnchor: simdDeviceAnchor)
        
        // Toss out the depth buffer, keep colors
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = colorTexture
        renderPassDescriptor.colorAttachments[0].loadAction = eyeIdx == 0 ? .clear : .load
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        renderPassDescriptor.depthAttachment.texture = depthTexture
        renderPassDescriptor.depthAttachment.loadAction = eyeIdx == 0 ? .clear : .load
        renderPassDescriptor.depthAttachment.storeAction = .store
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
        renderEncoder.setFragmentBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        renderEncoder.setFragmentTexture(badAppleTexture, index: 0)
        
        /*if drawable.views.count > 1 {
            var viewMappings = (0..<drawable.views.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
        }*/
        
        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setDepthStencilState(depthStateGreater)
        
        self.planeUniforms[0].planeTransform = simdDeviceAnchor
        self.planeUniforms[0].planeColor = simd_float4(0.7, 0.7, 0.7, 1.0)
        self.planeUniforms[0].planeDoProximity = 0.0
        renderEncoder.setVertexBuffer(dynamicPlaneUniformBuffer, offset:planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue)
        renderEncoder.setVertexBuffer(fullscreenQuadBuffer, offset: 0, index: VertexAttribute.position.rawValue)
        renderEncoder.setVertexBuffer(fullscreenQuadBuffer, offset: (3*4)*4, index: VertexAttribute.texcoord.rawValue)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        
        visionPro.lockPlaneAnchors()
        
        
        // Render planes
        for plane in visionPro.planeAnchors {
            let plane = plane.value
            let faces = plane.geometry.meshFaces
            renderEncoder.setVertexBuffer(plane.geometry.meshVertices.buffer, offset: 0, index: VertexAttribute.position.rawValue)
            renderEncoder.setVertexBuffer(plane.geometry.meshVertices.buffer, offset: 0, index: VertexAttribute.texcoord.rawValue)
            
            //self.updateGameStateForVideoFrame(drawable: drawable, framePose: framePose, planeTransform: plane.originFromAnchorTransform)
            selectNextPlaneUniformBuffer()
            self.planeUniforms[0].planeTransform = plane.originFromAnchorTransform
            self.planeUniforms[0].planeColor = planeToColor2(plane: plane)
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
        /*for plane in visionPro.planeAnchors {
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
        }*/
        
        visionPro.unlockPlaneAnchors()
        
        renderEncoder.popDebugGroup()
        renderEncoder.endEncoding()
    }
    
    var lastSubmit = 0.0
    var lastLastSubmit = 0.0
    func drawNextTexture(drawable: TextureResource.Drawable, simdDeviceAnchor: simd_float4x4, plane: ModelEntity, position: simd_float3, orientation: simd_quatf, scale: simd_float3) {
    
        autoreleasepool {
            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                return
            }
            
            for i in 0..<DummyMetalRenderer.renderViewTransforms.count {
                renderOverlay(eyeIdx: i, colorTexture: drawable.texture, commandBuffer: commandBuffer, framePose: matrix_identity_float4x4, simdDeviceAnchor: simdDeviceAnchor)
            }
            
            if self.lastFbChangeTime == 0.0 {
                self.lastFbChangeTime = CACurrentMediaTime()
            }
            
            let submitTime = CACurrentMediaTime()
            
            // Emergency resolution drop if we're chugging
            /*if CACurrentMediaTime() - lastSubmit > 0.02 && lastSubmit - lastLastSubmit > 0.02 && CACurrentMediaTime() - lastFbChangeTime > 0.25 {
                currentRenderScale -= 0.25
                currentRenderWidth = Int(currentRenderScale * Double(renderWidth))
                currentRenderHeight = Int(currentRenderScale * Double(renderHeight))
            }*/
            //print(CACurrentMediaTime() - lastSubmit)
            
            if lastRenderWidth != currentRenderWidth {
                // Recreate framebuffer
                let desc = TextureResource.DrawableQueue.Descriptor(pixelFormat: renderFormat, width: currentRenderWidth, height: currentRenderHeight*2, usage: [.renderTarget], mipmapsMode: .none)
                self.drawableQueue = try? TextureResource.DrawableQueue(desc)
                self.textureResource!.replace(withDrawables: self.drawableQueue!)
                
                // Create depth texture
                let depthTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                                                      width: currentRenderWidth,
                                                                                      height: currentRenderHeight*2,
                                                                                      mipmapped: false)
                depthTextureDescriptor.usage = [.renderTarget, .shaderRead]
                depthTextureDescriptor.storageMode = .private
                self.depthTexture = device.makeTexture(descriptor: depthTextureDescriptor)!
                
                renderViewports[0] = MTLViewport(originX: 0, originY: Double(currentRenderHeight), width: Double(currentRenderWidth), height: Double(currentRenderHeight), znear: renderZNear, zfar: renderZFar)
                renderViewports[1] = MTLViewport(originX: 0, originY: 0, width: Double(currentRenderWidth), height: Double(currentRenderHeight), znear: renderZNear, zfar: renderZFar)
                self.lastFbChangeTime = CACurrentMediaTime()
                
                print("Resolution changed to:", currentRenderWidth, "x", currentRenderHeight, "(", currentRenderScale, ")")
            }
            lastRenderWidth = currentRenderWidth
            lastRenderHeight = currentRenderHeight
            lastLastSubmit = lastSubmit
            lastSubmit = submitTime

            commandBuffer.addCompletedHandler { (_ commandBuffer)-> Swift.Void in
                //print("completed!", submitTime, CACurrentMediaTime() - submitTime, self.currentRenderWidth)
                
                /*if CACurrentMediaTime() - submitTime < 0.007 && CACurrentMediaTime() - self.lastFbChangeTime > 3.0 && !self.lockOutRaising {
                    //objc_sync_enter(self.badAppleLock)
                    currentRenderScale += 0.125
                    currentRenderWidth = Int(currentRenderScale * Double(renderWidth))
                    currentRenderHeight = Int(currentRenderScale * Double(renderHeight))
                    //objc_sync_exit(self.badAppleLock)
                }
                else if CACurrentMediaTime() - submitTime > 0.01 && CACurrentMediaTime() - self.lastFbChangeTime > 0.5 {
                    //objc_sync_enter(self.badAppleLock)
                    currentRenderScale -= 0.125
                    currentRenderWidth = Int(currentRenderScale * Double(renderWidth))
                    currentRenderHeight = Int(currentRenderScale * Double(renderHeight))
                    //objc_sync_exit(self.badAppleLock)
                    self.lockOutRaising = true
                }*/
            }
            
            plane.position = position
            plane.orientation = orientation
            plane.scale = scale
            
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted() // this is a load-bearing wait
        }
    }
}
