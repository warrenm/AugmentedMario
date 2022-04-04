import Foundation
import Metal
import MetalKit
import ARKit

let kMaxBuffersInFlight: Int = 3

let kImagePlaneVertexData: [Float] = [
    -1.0, -1.0,  0.0, 1.0,
     1.0, -1.0,  1.0, 1.0,
    -1.0,  1.0,  0.0, 0.0,
     1.0,  1.0,  1.0, 0.0,
]

class ARFrameRenderer {
    let device: MTLDevice
    let mtkView: MTKView

    private var vertexBuffer: MTLBuffer!
    private var renderPipelineState: MTLRenderPipelineState!
    private var capturedImageTextureY: CVMetalTexture?
    private var capturedImageTextureCbCr: CVMetalTexture?
    private var capturedImageTextureCache: CVMetalTextureCache!

    init(device: MTLDevice, view: MTKView) {
        self.device = device
        self.mtkView = view

        makeResources()
        makePipelines()
    }

    func update(frame: ARFrame) {
        updateCapturedImageTextures(frame: frame)
        updateCameraImageGeometry(frame: frame)
    }

    func draw(renderCommandEncoder: MTLRenderCommandEncoder, commandBuffer: MTLCommandBuffer) {
        var textures = [capturedImageTextureY, capturedImageTextureCbCr]
        commandBuffer.addCompletedHandler{ _ in
            textures.removeAll()
        }

        drawCapturedImage(renderCommandEncoder)
    }

    private func drawCapturedImage(_ renderCommandEncoder: MTLRenderCommandEncoder) {
        guard let textureY = capturedImageTextureY,
              let textureCbCr = capturedImageTextureCbCr else
        {
            return
        }

        renderCommandEncoder.pushDebugGroup("Draw Camera Frame")
        renderCommandEncoder.setRenderPipelineState(renderPipelineState)
        renderCommandEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        renderCommandEncoder.setFragmentTexture(CVMetalTextureGetTexture(textureY), index: 0)
        renderCommandEncoder.setFragmentTexture(CVMetalTextureGetTexture(textureCbCr), index: 1)
        renderCommandEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderCommandEncoder.popDebugGroup()
    }

    private func makeResources() {
        let imagePlaneVertexDataCount = kImagePlaneVertexData.count * MemoryLayout<Float>.size
        vertexBuffer = device.makeBuffer(bytes: kImagePlaneVertexData, length: imagePlaneVertexDataCount, options: [])
        vertexBuffer.label = "Camera Frame Vertices"

        var textureCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        capturedImageTextureCache = textureCache
    }

    private func makePipelines() {
        guard let library = device.makeDefaultLibrary() else {
            fatalError("Could not create default Metal shader library from app bundle")
        }

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = 8
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = 16
        vertexDescriptor.layouts[0].stepRate = 1
        vertexDescriptor.layouts[0].stepFunction = .perVertex

        let renderPipelineDescriptor = MTLRenderPipelineDescriptor()
        renderPipelineDescriptor.label = "Camera Frame Pipeline"
        renderPipelineDescriptor.sampleCount = mtkView.sampleCount
        renderPipelineDescriptor.vertexFunction = library.makeFunction(name: "vertex_fullscreen_quad")!
        renderPipelineDescriptor.fragmentFunction = library.makeFunction(name: "fragment_camera_frame")!
        renderPipelineDescriptor.vertexDescriptor = vertexDescriptor
        renderPipelineDescriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
        renderPipelineDescriptor.depthAttachmentPixelFormat = mtkView.depthStencilPixelFormat
        renderPipelineDescriptor.stencilAttachmentPixelFormat = .invalid
        
        do {
            try renderPipelineState = device.makeRenderPipelineState(descriptor: renderPipelineDescriptor)
        } catch let error {
            print("Failed to created captured image pipeline state, error \(error)")
        }
    }

    private func updateCapturedImageTextures(frame: ARFrame) {
        let pixelBuffer = frame.capturedImage
        
        if CVPixelBufferGetPlaneCount(pixelBuffer) < 2 { return }
        
        capturedImageTextureY = createTexture(fromPixelBuffer: pixelBuffer, pixelFormat:.r8Unorm, planeIndex:0)
        capturedImageTextureCbCr = createTexture(fromPixelBuffer: pixelBuffer, pixelFormat:.rg8Unorm, planeIndex:1)
    }
    
    private func createTexture(fromPixelBuffer pixelBuffer: CVPixelBuffer,
                               pixelFormat: MTLPixelFormat,
                               planeIndex: Int) -> CVMetalTexture?
    {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
        
        var texture: CVMetalTexture? = nil
        let _ = CVMetalTextureCacheCreateTextureFromImage(nil, capturedImageTextureCache, pixelBuffer, nil,
                                                          pixelFormat, width, height, planeIndex, &texture)
        return texture
    }
    
    private func updateCameraImageGeometry(frame: ARFrame) {
        let orientation = mtkView.window?.windowScene?.interfaceOrientation ?? UIInterfaceOrientation.portrait

        let displayToCameraTransform = frame.displayTransform(for: orientation, viewportSize: mtkView.drawableSize).inverted()

        let vertexData = vertexBuffer.contents().assumingMemoryBound(to: Float.self)
        for index in 0...3 {
            let textureCoordIndex = 4 * index + 2
            let textureCoord = CGPoint(x: CGFloat(kImagePlaneVertexData[textureCoordIndex]),
                                       y: CGFloat(kImagePlaneVertexData[textureCoordIndex + 1]))
            let transformedCoord = textureCoord.applying(displayToCameraTransform)
            vertexData[textureCoordIndex] = Float(transformedCoord.x)
            vertexData[textureCoordIndex + 1] = Float(transformedCoord.y)
        }
    }
}
