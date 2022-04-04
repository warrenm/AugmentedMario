import Metal
import simd
import ARKit

class Camera {
    var viewTransform = matrix_identity_float4x4
    var projectionTransform = matrix_identity_float4x4
}

class Mesh {
    var vertexDescriptor: MTLVertexDescriptor
    var vertexBuffer: MTLBuffer
    var vertexCount: Int
    var texture: MTLTexture?
    var modelTransform = matrix_identity_float4x4

    init(vertexDescriptor: MTLVertexDescriptor, vertexBuffer: MTLBuffer, vertexCount: Int) {
        self.vertexDescriptor = vertexDescriptor
        self.vertexBuffer = vertexBuffer
        self.vertexCount = vertexCount
    }
}

class SuperMarioWorld {
    let device: MTLDevice
    let camera = Camera()
    var inputs = SM64MarioInputs()

    private var collisionMesh: Mesh!
    private var marioMesh: Mesh!
    private var worldRenderPipelineState: MTLRenderPipelineState!
    private var marioRenderPipelineState: MTLRenderPipelineState!
    private var depthStencilState: MTLDepthStencilState!
    private let marioVertexDescriptor = MTLVertexDescriptor()
    private let collisionVertexDescriptor = MTLVertexDescriptor()
    private var marioTexture: MTLTexture?
    private var marioID: Int32 = -1
    private let worldScaleFactor: Float = 1000.0
    private var marioState = SM64MarioState()
    private var marioGeometry = SM64MarioGeometryBuffers()

    struct MeshUniforms {
        var model: simd_float4x4
        var view: simd_float4x4
        var projection: simd_float4x4
    }

    init(_ device: MTLDevice) {
        self.device = device

        guard let romURL = Bundle.main.url(forResource: "baserom.us.z64", withExtension: nil) else {
            fatalError("Failed to find ROM file in app bundle")
        }

        guard let romData = NSMutableData(contentsOf: romURL) else {
            fatalError("Failed to load data from ROM file: \(romURL)")
        }

        let textureData = UnsafeMutableRawPointer.allocate(byteCount: 4 * SM64_TEXTURE_WIDTH * SM64_TEXTURE_HEIGHT,
                                                           alignment: 4)

        sm64_global_init(romData.mutableBytes, textureData, nil)

        initVertexDescriptors()
        makePipelines()

        marioTexture = makeMarioTexture(textureData)
        textureData.deallocate()

        marioGeometry.position = UnsafeMutablePointer<Float>.allocate(capacity: 9 * SM64_GEO_MAX_TRIANGLES)
        marioGeometry.color    = UnsafeMutablePointer<Float>.allocate(capacity: 9 * SM64_GEO_MAX_TRIANGLES)
        marioGeometry.normal   = UnsafeMutablePointer<Float>.allocate(capacity: 9 * SM64_GEO_MAX_TRIANGLES)
        marioGeometry.uv       = UnsafeMutablePointer<Float>.allocate(capacity: 6 * SM64_GEO_MAX_TRIANGLES)

        marioMesh = makeMarioMesh()
        marioMesh.modelTransform = simd_float4x4(diagonal: SIMD4<Float>(1 / worldScaleFactor,
                                                                        1 / worldScaleFactor,
                                                                        1 / worldScaleFactor,
                                                                        1.0))
    }

    deinit {
        marioGeometry.position.deallocate()
        marioGeometry.color.deallocate()
        marioGeometry.normal.deallocate()
        marioGeometry.uv.deallocate()

        sm64_global_terminate()
    }

    func spawnMario(at position: SIMD3<Float>) -> Bool {
        marioID = sm64_mario_create(Int16(position.x), Int16(position.y), Int16(position.z))
        return marioID >= 0
    }

    func update(at time: TimeInterval) {
        guard marioID >= 0 else { return }

        sm64_mario_tick(marioID, &inputs, &marioState, &marioGeometry)
        updateMarioMesh()
    }

    func draw(renderCommandEncoder: MTLRenderCommandEncoder) {
        guard marioID >= 0 else { return }

        renderCommandEncoder.setFrontFacing(.counterClockwise)
        renderCommandEncoder.setCullMode(.back)
        renderCommandEncoder.setDepthStencilState(depthStencilState)

        let view = camera.viewTransform
        let projection = camera.projectionTransform

        var worldUniforms = MeshUniforms(model: collisionMesh.modelTransform, view: view, projection: projection)
        renderCommandEncoder.setRenderPipelineState(worldRenderPipelineState)
        renderCommandEncoder.setVertexBuffer(collisionMesh.vertexBuffer, offset: 0, index: 0)
        renderCommandEncoder.setVertexBytes(&worldUniforms, length: MemoryLayout<MeshUniforms>.size, index: 1)
        renderCommandEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: collisionMesh.vertexCount)

        var marioUniforms = MeshUniforms(model: collisionMesh.modelTransform * marioMesh.modelTransform, view: view, projection: projection)
        renderCommandEncoder.setRenderPipelineState(marioRenderPipelineState)
        renderCommandEncoder.setVertexBuffer(marioMesh.vertexBuffer, offset: 0, index: 0)
        renderCommandEncoder.setVertexBytes(&marioUniforms, length: MemoryLayout<MeshUniforms>.size, index: 1)
        renderCommandEncoder.setFragmentTexture(marioMesh.texture, index: 0)
        renderCommandEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: marioMesh.vertexCount)
    }

    private func initVertexDescriptors() {
        marioVertexDescriptor.attributes[0].format = .float3 // position
        marioVertexDescriptor.attributes[0].bufferIndex = 0
        marioVertexDescriptor.attributes[0].offset = 0
        marioVertexDescriptor.attributes[1].format = .float3 // normal
        marioVertexDescriptor.attributes[1].bufferIndex = 0
        marioVertexDescriptor.attributes[1].offset = 12
        marioVertexDescriptor.attributes[2].format = .float3 // color
        marioVertexDescriptor.attributes[2].bufferIndex = 0
        marioVertexDescriptor.attributes[2].offset = 24
        marioVertexDescriptor.attributes[3].format = .float2 // uv
        marioVertexDescriptor.attributes[3].bufferIndex = 0
        marioVertexDescriptor.attributes[3].offset = 36
        marioVertexDescriptor.layouts[0].stride = 44

        collisionVertexDescriptor.attributes[0].format = .float3 // position
        collisionVertexDescriptor.attributes[0].bufferIndex = 0
        collisionVertexDescriptor.attributes[0].offset = 0
        collisionVertexDescriptor.attributes[1].format = .float3 // normal
        collisionVertexDescriptor.attributes[1].bufferIndex = 0
        collisionVertexDescriptor.attributes[1].offset = 12
        collisionVertexDescriptor.layouts[0].stride = 24
    }

    private func makePipelines() {
        guard let library = device.makeDefaultLibrary() else {
            fatalError("Could not find default Metal shader library in app bundle")
        }

        let renderPipelineDescriptor = MTLRenderPipelineDescriptor()
        renderPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        renderPipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

        renderPipelineDescriptor.vertexDescriptor = marioVertexDescriptor
        renderPipelineDescriptor.vertexFunction = library.makeFunction(name: "vertex_mario")!
        renderPipelineDescriptor.fragmentFunction = library.makeFunction(name: "fragment_mario")!
        marioRenderPipelineState = try! device.makeRenderPipelineState(descriptor: renderPipelineDescriptor)

        renderPipelineDescriptor.vertexDescriptor = collisionVertexDescriptor
        renderPipelineDescriptor.vertexFunction = library.makeFunction(name: "vertex_world")!
        renderPipelineDescriptor.fragmentFunction = library.makeFunction(name: "fragment_world")!
        renderPipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        renderPipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        renderPipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        renderPipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        renderPipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        renderPipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        renderPipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        worldRenderPipelineState = try! device.makeRenderPipelineState(descriptor: renderPipelineDescriptor)

        let depthStencilDescriptor = MTLDepthStencilDescriptor()
        depthStencilDescriptor.depthCompareFunction = .less
        depthStencilDescriptor.isDepthWriteEnabled = true
        depthStencilState = device.makeDepthStencilState(descriptor: depthStencilDescriptor)
    }

    func updateCollisionMesh(_ anchor: ARPlaneAnchor) {
        let wantSpawn = collisionMesh == nil

        let geometry = anchor.geometry

        let vertexCount = geometry.triangleCount * 3

        var positions = [Float](repeating: 0.0, count: 3 * 3 * geometry.triangleCount)
        var normals = [Float](repeating: 0.0, count: 3 * 3 * geometry.triangleCount)

        var surfaces = [SM64Surface]()
        for t in 0..<geometry.triangleCount {
            let i0 = Int(geometry.triangleIndices[t * 3 + 0])
            let i1 = Int(geometry.triangleIndices[t * 3 + 1])
            let i2 = Int(geometry.triangleIndices[t * 3 + 2])

            positions[t * 9 + 0] = geometry.vertices[i0].x
            positions[t * 9 + 1] = geometry.vertices[i0].y
            positions[t * 9 + 2] = geometry.vertices[i0].z
            positions[t * 9 + 3] = geometry.vertices[i1].x
            positions[t * 9 + 4] = geometry.vertices[i1].y
            positions[t * 9 + 5] = geometry.vertices[i1].z
            positions[t * 9 + 6] = geometry.vertices[i2].x
            positions[t * 9 + 7] = geometry.vertices[i2].y
            positions[t * 9 + 8] = geometry.vertices[i2].z

            normals[t * 9 + 0] = 0.0
            normals[t * 9 + 1] = 1.0
            normals[t * 9 + 2] = 0.0
            normals[t * 9 + 3] = 0.0
            normals[t * 9 + 4] = 1.0
            normals[t * 9 + 5] = 0.0
            normals[t * 9 + 6] = 0.0
            normals[t * 9 + 7] = 1.0
            normals[t * 9 + 8] = 0.0

            let x0 = Int16(geometry.vertices[i0].x * worldScaleFactor)
            let y0 = Int16(geometry.vertices[i0].y * worldScaleFactor)
            let z0 = Int16(geometry.vertices[i0].z * worldScaleFactor)

            let x1 = Int16(geometry.vertices[i1].x * worldScaleFactor)
            let y1 = Int16(geometry.vertices[i1].y * worldScaleFactor)
            let z1 = Int16(geometry.vertices[i1].z * worldScaleFactor)

            let x2 = Int16(geometry.vertices[i2].x * worldScaleFactor)
            let y2 = Int16(geometry.vertices[i2].y * worldScaleFactor)
            let z2 = Int16(geometry.vertices[i2].z * worldScaleFactor)

            let surface = SM64Surface(type: Int16(SURFACE_DEFAULT), force: 0, terrain: UInt16(TERRAIN_SNOW),
                                      vertices: ((x0, y0, z0), (x1, y1, z1), (x2, y2, z2)))
            surfaces.append(surface)
        }

        sm64_static_surfaces_load(&surfaces, UInt32(surfaces.count))

        let vertexDescriptor = collisionVertexDescriptor

        let vertexBuffer = device.makeBuffer(length: vertexCount * vertexDescriptor.layouts[0].stride,
                                             options: [.storageModeShared])!

        let vertexStride = vertexDescriptor.layouts[0].stride
        vertexBuffer.copyStrided(from: positions, elementSize: 12, count: vertexCount,
                                 destStride: vertexStride, destOffset: vertexDescriptor.attributes[0].offset)
        vertexBuffer.copyStrided(from: normals, elementSize: 12, count: vertexCount,
                                 destStride: vertexStride, destOffset: vertexDescriptor.attributes[1].offset)

        collisionMesh = Mesh(vertexDescriptor: vertexDescriptor, vertexBuffer: vertexBuffer, vertexCount: vertexCount)

        collisionMesh.modelTransform = anchor.transform

        if (wantSpawn) {
            print("Autospawning...")
            let didSpawn = spawnMario(at: anchor.center * worldScaleFactor)
            print(didSpawn ? "Success" : "Failed")
        }
    }

    private func makeMarioTexture(_ textureData: UnsafeRawPointer) -> MTLTexture {
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                         width: SM64_TEXTURE_WIDTH,
                                                                         height: SM64_TEXTURE_HEIGHT,
                                                                         mipmapped: true)
        textureDescriptor.usage = .shaderRead
        let texture = device.makeTexture(descriptor: textureDescriptor)!
        let region = MTLRegion(origin: MTLOrigin(),
                               size: MTLSize(width: SM64_TEXTURE_WIDTH,
                                             height: SM64_TEXTURE_HEIGHT,
                                             depth: 1))
        texture.replace(region: region, mipmapLevel: 0, withBytes: textureData, bytesPerRow: SM64_TEXTURE_WIDTH * 4)
        return texture
    }

    private func makeMarioMesh() -> Mesh? {
        let vertexCount = 3 * SM64_GEO_MAX_TRIANGLES

        let vertexDescriptor = marioVertexDescriptor
        let vertexBuffer = device.makeBuffer(length: 3 * SM64_GEO_MAX_TRIANGLES * vertexDescriptor.layouts[0].stride,
                                             options: [.storageModeShared])!

        let mario = Mesh(vertexDescriptor: vertexDescriptor, vertexBuffer: vertexBuffer, vertexCount: vertexCount)
        mario.texture = marioTexture
        return mario
    }

    private func updateMarioMesh() {
        let vertexCount = Int(3 * marioGeometry.numTrianglesUsed)
        let vertexDescriptor = marioMesh.vertexDescriptor
        let vertexBuffer = marioMesh.vertexBuffer
        let vertexStride = vertexDescriptor.layouts[0].stride

        vertexBuffer.copyStrided(from: marioGeometry.position, elementSize: 12, count: vertexCount,
                                 destStride: vertexStride, destOffset: vertexDescriptor.attributes[0].offset)
        vertexBuffer.copyStrided(from: marioGeometry.normal, elementSize: 12, count: vertexCount,
                                 destStride: vertexStride, destOffset: vertexDescriptor.attributes[1].offset)
        vertexBuffer.copyStrided(from: marioGeometry.color, elementSize: 12, count: vertexCount,
                                 destStride: vertexStride, destOffset: vertexDescriptor.attributes[2].offset)
        vertexBuffer.copyStrided(from: marioGeometry.uv, elementSize: 8, count: vertexCount,
                                 destStride: vertexStride, destOffset: vertexDescriptor.attributes[3].offset)

        marioMesh.vertexCount = vertexCount
    }
}

fileprivate extension MTLBuffer {
    func copyStrided(from source: UnsafeRawPointer, elementSize: Int, count: Int, destStride: Int, destOffset: Int) {
        let sourceStride = elementSize // Assume source is packed
        for i in 0..<count {
            self.contents().advanced(by: destOffset + destStride * i)
                .copyMemory(from: source.advanced(by: sourceStride * i), byteCount: elementSize)
        }
    }
}
