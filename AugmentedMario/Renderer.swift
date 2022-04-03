
import Foundation
import Metal
import MetalKit
import ARKit

let kMaxBuffersInFlight: Int = 3

enum VertexAttribute: Int {
    case Position
    case Texcoord
    case Normal
}

let kImagePlaneVertexData: [Float] = [
    -1.0, -1.0,  0.0, 1.0,
     1.0, -1.0,  1.0, 1.0,
    -1.0,  1.0,  0.0, 0.0,
     1.0,  1.0,  1.0, 0.0,
]

class Renderer {
    let session: ARSession
    let device: MTLDevice
    let inFlightSemaphore = DispatchSemaphore(value: kMaxBuffersInFlight)
    var mtkView: MTKView

    var commandQueue: MTLCommandQueue!
    var sharedUniformBuffer: MTLBuffer!
    //var anchorUniformBuffer: MTLBuffer!
    var imagePlaneVertexBuffer: MTLBuffer!
    var capturedImagePipelineState: MTLRenderPipelineState!
    var capturedImageDepthState: MTLDepthStencilState!
    var capturedImageTextureY: CVMetalTexture?
    var capturedImageTextureCbCr: CVMetalTexture?

    var capturedImageTextureCache: CVMetalTextureCache!

    var viewportSize: CGSize = CGSize()
    var viewportSizeDidChange: Bool = false

    init(session: ARSession, metalDevice device: MTLDevice, renderDestination: MTKView) {
        self.session = session
        self.device = device
        self.mtkView = renderDestination
        loadMetal()
    }
    
    func drawRectResized(size: CGSize) {
        viewportSize = size
        viewportSizeDidChange = true
    }
    
    func update() {
        let _ = inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)

        if let commandBuffer = commandQueue.makeCommandBuffer() {
            var textures = [capturedImageTextureY, capturedImageTextureCbCr]
            commandBuffer.addCompletedHandler{ [weak self] commandBuffer in
                if let strongSelf = self {
                    strongSelf.inFlightSemaphore.signal()
                }
                textures.removeAll()
            }
            
            updateGameState()
            
            if let renderPassDescriptor = mtkView.currentRenderPassDescriptor,
                let currentDrawable = mtkView.currentDrawable,
                let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
            {
                drawCapturedImage(renderEncoder: renderEncoder)
                renderEncoder.endEncoding()
                commandBuffer.present(currentDrawable)
            }
            commandBuffer.commit()
        }
    }
    
    // MARK: - Private
    
    func loadMetal() {
        mtkView.depthStencilPixelFormat = .depth32Float_stencil8
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.sampleCount = 1

        let imagePlaneVertexDataCount = kImagePlaneVertexData.count * MemoryLayout<Float>.size
        imagePlaneVertexBuffer = device.makeBuffer(bytes: kImagePlaneVertexData, length: imagePlaneVertexDataCount, options: [])
        imagePlaneVertexBuffer.label = "ImagePlaneVertexBuffer"
        
        let defaultLibrary = device.makeDefaultLibrary()!
        
        let capturedImageVertexFunction = defaultLibrary.makeFunction(name: "vertex_fullscreen_quad")!
        let capturedImageFragmentFunction = defaultLibrary.makeFunction(name: "fragment_camera_frame")!

        let imagePlaneVertexDescriptor = MTLVertexDescriptor()
        
        imagePlaneVertexDescriptor.attributes[0].format = .float2
        imagePlaneVertexDescriptor.attributes[0].offset = 0
        imagePlaneVertexDescriptor.attributes[0].bufferIndex = 0

        imagePlaneVertexDescriptor.attributes[1].format = .float2
        imagePlaneVertexDescriptor.attributes[1].offset = 8
        imagePlaneVertexDescriptor.attributes[1].bufferIndex = 0

        imagePlaneVertexDescriptor.layouts[0].stride = 16
        imagePlaneVertexDescriptor.layouts[0].stepRate = 1
        imagePlaneVertexDescriptor.layouts[0].stepFunction = .perVertex

        let capturedImagePipelineStateDescriptor = MTLRenderPipelineDescriptor()
        capturedImagePipelineStateDescriptor.label = "Camera Frame Pipeline"
        capturedImagePipelineStateDescriptor.sampleCount = mtkView.sampleCount
        capturedImagePipelineStateDescriptor.vertexFunction = capturedImageVertexFunction
        capturedImagePipelineStateDescriptor.fragmentFunction = capturedImageFragmentFunction
        capturedImagePipelineStateDescriptor.vertexDescriptor = imagePlaneVertexDescriptor
        capturedImagePipelineStateDescriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
        capturedImagePipelineStateDescriptor.depthAttachmentPixelFormat = mtkView.depthStencilPixelFormat
        capturedImagePipelineStateDescriptor.stencilAttachmentPixelFormat = mtkView.depthStencilPixelFormat
        
        do {
            try capturedImagePipelineState = device.makeRenderPipelineState(descriptor: capturedImagePipelineStateDescriptor)
        } catch let error {
            print("Failed to created captured image pipeline state, error \(error)")
        }
        
        let capturedImageDepthStateDescriptor = MTLDepthStencilDescriptor()
        capturedImageDepthStateDescriptor.depthCompareFunction = .always
        capturedImageDepthStateDescriptor.isDepthWriteEnabled = false
        capturedImageDepthState = device.makeDepthStencilState(descriptor: capturedImageDepthStateDescriptor)

        var textureCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        capturedImageTextureCache = textureCache

        commandQueue = device.makeCommandQueue()
    }

    func updateGameState() {
        guard let currentFrame = session.currentFrame else {
            return
        }
        
        updateSharedUniforms(frame: currentFrame)
        updateAnchors(frame: currentFrame)
        updateCapturedImageTextures(frame: currentFrame)
        
        if viewportSizeDidChange {
            viewportSizeDidChange = false
            
            updateImagePlane(frame: currentFrame)
        }
    }
    
    func updateSharedUniforms(frame: ARFrame) {

        //  uniforms.pointee.viewMatrix = frame.camera.viewMatrix(for: .landscapeRight)
        //  uniforms.pointee.projectionMatrix = frame.camera.projectionMatrix(for: .landscapeRight, viewportSize: viewportSize, zNear: 0.001, zFar: 1000)
    }
    
    func updateAnchors(frame: ARFrame) {
    }
    
    func updateCapturedImageTextures(frame: ARFrame) {
        let pixelBuffer = frame.capturedImage
        
        if (CVPixelBufferGetPlaneCount(pixelBuffer) < 2) {
            return
        }
        
        capturedImageTextureY = createTexture(fromPixelBuffer: pixelBuffer, pixelFormat:.r8Unorm, planeIndex:0)
        capturedImageTextureCbCr = createTexture(fromPixelBuffer: pixelBuffer, pixelFormat:.rg8Unorm, planeIndex:1)
    }
    
    func createTexture(fromPixelBuffer pixelBuffer: CVPixelBuffer, pixelFormat: MTLPixelFormat, planeIndex: Int) -> CVMetalTexture? {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
        
        var texture: CVMetalTexture? = nil
        let _ = CVMetalTextureCacheCreateTextureFromImage(nil, capturedImageTextureCache, pixelBuffer, nil,
                                                          pixelFormat, width, height, planeIndex, &texture)
        return texture
    }
    
    func updateImagePlane(frame: ARFrame) {

        let orientation = mtkView.window?.windowScene?.interfaceOrientation ?? UIInterfaceOrientation.portrait

        let displayToCameraTransform = frame.displayTransform(for: orientation, viewportSize: viewportSize).inverted()

        let vertexData = imagePlaneVertexBuffer.contents().assumingMemoryBound(to: Float.self)
        for index in 0...3 {
            let textureCoordIndex = 4 * index + 2
            let textureCoord = CGPoint(x: CGFloat(kImagePlaneVertexData[textureCoordIndex]), y: CGFloat(kImagePlaneVertexData[textureCoordIndex + 1]))
            let transformedCoord = textureCoord.applying(displayToCameraTransform)
            vertexData[textureCoordIndex] = Float(transformedCoord.x)
            vertexData[textureCoordIndex + 1] = Float(transformedCoord.y)
        }
    }
    
    func drawCapturedImage(renderEncoder: MTLRenderCommandEncoder) {
        guard let textureY = capturedImageTextureY, let textureCbCr = capturedImageTextureCbCr else {
            return
        }

        renderEncoder.pushDebugGroup("Draw Camera Frame")

        renderEncoder.setCullMode(.none)
        renderEncoder.setRenderPipelineState(capturedImagePipelineState)
        renderEncoder.setDepthStencilState(capturedImageDepthState)
        
        renderEncoder.setVertexBuffer(imagePlaneVertexBuffer, offset: 0, index: 0)

        renderEncoder.setFragmentTexture(CVMetalTextureGetTexture(textureY), index: 0)
        renderEncoder.setFragmentTexture(CVMetalTextureGetTexture(textureCbCr), index: 1)

        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        
        renderEncoder.popDebugGroup()
    }
}
