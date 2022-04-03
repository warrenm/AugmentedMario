import Metal
import GameController
import simd

class Mesh {
    var vertexDescriptor: MTLVertexDescriptor
    var vertexBuffer: MTLBuffer
    var vertexCount: Int
    var texture: MTLTexture?

    init(vertexDescriptor: MTLVertexDescriptor, vertexBuffer: MTLBuffer, vertexCount: Int) {
        self.vertexDescriptor = vertexDescriptor
        self.vertexBuffer = vertexBuffer
        self.vertexCount = vertexCount
    }
}

class SuperMarioWorld {
    let device: MTLDevice

    private var collisionMesh: Mesh!
    private var marioMesh: Mesh!
    private var worldRenderPipelineState: MTLRenderPipelineState!
    private var marioRenderPipelineState: MTLRenderPipelineState!
    private var depthStencilState: MTLDepthStencilState!
    private let marioId: Int32
    private var cameraPos = SIMD3<Float>()
    private var cameraRot: Float = 0.0
    private var marioInputs = SM64MarioInputs()
    private var marioState = SM64MarioState()
    private var marioGeometry = SM64MarioGeometryBuffers()
    private var virtualController: GCVirtualController!
    private var controller: GCController?

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
        defer {
            textureData.deallocate()
        }

        sm64_global_terminate()
        sm64_global_init(romData.mutableBytes, textureData, nil)
        sm64_static_surfaces_load(get_surfaces(), UInt32(surfaces_count))

        marioId = sm64_mario_create(0, 1000, 0)

        marioGeometry.position = UnsafeMutablePointer<Float>.allocate(capacity: 9 * SM64_GEO_MAX_TRIANGLES)
        marioGeometry.color    = UnsafeMutablePointer<Float>.allocate(capacity: 9 * SM64_GEO_MAX_TRIANGLES)
        marioGeometry.normal   = UnsafeMutablePointer<Float>.allocate(capacity: 9 * SM64_GEO_MAX_TRIANGLES)
        marioGeometry.uv       = UnsafeMutablePointer<Float>.allocate(capacity: 6 * SM64_GEO_MAX_TRIANGLES)

        collisionMesh = makeCollisionMesh()
        marioMesh = makeMarioMesh(textureData)
        makePipelines()
        makeController()
    }

    deinit {
        sm64_global_terminate()
        // TODO: Deallocate sm64 geometry buffers
    }

    func update(at time: TimeInterval)
    {
        if let gamepad = controller?.extendedGamepad {
            let x_axis = gamepad.leftThumbstick.xAxis.value
            let y_axis = gamepad.leftThumbstick.yAxis.value
            let x0_axis = gamepad.rightThumbstick.xAxis.value

            cameraRot += 0.1 * x0_axis
            cameraPos[0] = marioState.position.0 + 800.0 * cosf(cameraRot)
            cameraPos[1] = marioState.position.1 + 200.0
            cameraPos[2] = marioState.position.2 + 800.0 * sinf(cameraRot)

            marioInputs.buttonA = gamepad.buttonA.isPressed ? 1 : 0
            marioInputs.buttonB = gamepad.buttonB.isPressed ? 1 : 0
            marioInputs.buttonZ = gamepad.leftTrigger.isPressed ? 1 : 0
            marioInputs.camLookX = marioState.position.0 - cameraPos.x
            marioInputs.camLookZ = marioState.position.2 - cameraPos.z
            marioInputs.stickX = x_axis;
            marioInputs.stickY = -y_axis;
        }

        sm64_mario_tick(marioId, &marioInputs, &marioState, &marioGeometry)

        updateMarioMesh()
    }

    func draw(viewport: MTLViewport, renderCommandEncoder: MTLRenderCommandEncoder) {
        renderCommandEncoder.setFrontFacing(.counterClockwise)
        renderCommandEncoder.setCullMode(.back)
        renderCommandEncoder.setDepthStencilState(depthStencilState)

        let model = matrix_identity_float4x4
        let view = simd_float4x4.look(at: SIMD3<Float>(marioState.position),
                                      from: cameraPos,
                                      up: SIMD3<Float>(0, 1, 0)).inverse
        let aspectRatio = Float(viewport.width / viewport.height)
        let projection = simd_float4x4(perspectiveProjectionFOV: 65.0,
                                       aspectRatio: aspectRatio,
                                       nearZ: 100.0,
                                       farZ: 20000.0)

        struct WorldUniforms {
            var model: simd_float4x4
            var view: simd_float4x4
            var projection: simd_float4x4
        }
        var worldUniforms = WorldUniforms(model: model, view: view, projection: projection)
        renderCommandEncoder.setRenderPipelineState(worldRenderPipelineState)
        renderCommandEncoder.setVertexBuffer(collisionMesh.vertexBuffer, offset: 0, index: 0)
        renderCommandEncoder.setVertexBytes(&worldUniforms, length: MemoryLayout<WorldUniforms>.size, index: 1)
        renderCommandEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: collisionMesh.vertexCount)

        struct MarioUniforms {
            var view: simd_float4x4
            var projection: simd_float4x4
        }
        var marioUniforms = MarioUniforms(view: view, projection: projection)
        renderCommandEncoder.setRenderPipelineState(marioRenderPipelineState)
        renderCommandEncoder.setVertexBuffer(marioMesh.vertexBuffer, offset: 0, index: 0)
        renderCommandEncoder.setVertexBytes(&marioUniforms, length: MemoryLayout<MarioUniforms>.size, index: 1)
        renderCommandEncoder.setFragmentTexture(marioMesh.texture, index: 0)
        renderCommandEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: marioMesh.vertexCount)
    }

    private func makePipelines() {
        guard let library = device.makeDefaultLibrary() else {
            fatalError("Could not find default Metal shader library in app bundle")
        }

        let renderPipelineDescriptor = MTLRenderPipelineDescriptor()
        renderPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        renderPipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

        renderPipelineDescriptor.vertexDescriptor = collisionMesh.vertexDescriptor
        renderPipelineDescriptor.vertexFunction = library.makeFunction(name: "vertex_world")!
        renderPipelineDescriptor.fragmentFunction = library.makeFunction(name: "fragment_world")!
        worldRenderPipelineState = try! device.makeRenderPipelineState(descriptor: renderPipelineDescriptor)

        renderPipelineDescriptor.vertexDescriptor = marioMesh.vertexDescriptor
        renderPipelineDescriptor.vertexFunction = library.makeFunction(name: "vertex_mario")!
        renderPipelineDescriptor.fragmentFunction = library.makeFunction(name: "fragment_mario")!
        marioRenderPipelineState = try! device.makeRenderPipelineState(descriptor: renderPipelineDescriptor)

        let depthStencilDescriptor = MTLDepthStencilDescriptor()
        depthStencilDescriptor.depthCompareFunction = .less
        depthStencilDescriptor.isDepthWriteEnabled = true
        depthStencilState = device.makeDepthStencilState(descriptor: depthStencilDescriptor)
    }

    private func makeCollisionMesh() -> Mesh? {
        let vertexCount = 3 * surfaces_count
        var positions = [Float](repeating: 0.0, count: 9 * vertexCount)
        var normals = [Float](repeating: 0.0, count: 9 * vertexCount)

        for i in 0..<surfaces_count {
            let surf: SM64Surface = get_surfaces()[i]

            positions[9 * i + 0] = Float(surf.vertices.0.0)
            positions[9 * i + 1] = Float(surf.vertices.0.1)
            positions[9 * i + 2] = Float(surf.vertices.0.2)
            positions[9 * i + 3] = Float(surf.vertices.1.0)
            positions[9 * i + 4] = Float(surf.vertices.1.1)
            positions[9 * i + 5] = Float(surf.vertices.1.2)
            positions[9 * i + 6] = Float(surf.vertices.2.0)
            positions[9 * i + 7] = Float(surf.vertices.2.1)
            positions[9 * i + 8] = Float(surf.vertices.2.2)

            let x1 = positions[9 * i + 0]
            let y1 = positions[9 * i + 1]
            let z1 = positions[9 * i + 2]
            let x2 = positions[9 * i + 3]
            let y2 = positions[9 * i + 4]
            let z2 = positions[9 * i + 5]
            let x3 = positions[9 * i + 6]
            let y3 = positions[9 * i + 7]
            let z3 = positions[9 * i + 8]

            var nx = (y2 - y1) * (z3 - z2) - (z2 - z1) * (y3 - y2)
            var ny = (z2 - z1) * (x3 - x2) - (x2 - x1) * (z3 - z2)
            var nz = (x2 - x1) * (y3 - y2) - (y2 - y1) * (x3 - x2)
            let mag = sqrt(nx * nx + ny * ny + nz * nz)
            nx /= mag
            ny /= mag
            nz /= mag

            normals[9 * i + 0] = nx
            normals[9 * i + 1] = ny
            normals[9 * i + 2] = nz
            normals[9 * i + 3] = nx
            normals[9 * i + 4] = ny
            normals[9 * i + 5] = nz
            normals[9 * i + 6] = nx
            normals[9 * i + 7] = ny
            normals[9 * i + 8] = nz
        }

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[1].format = .float3
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.attributes[1].offset = 12
        vertexDescriptor.layouts[0].stride = 24

        let vertexBuffer = device.makeBuffer(length: vertexCount * vertexDescriptor.layouts[0].stride,
                                             options: [.storageModeShared])!

        let vertexStride = vertexDescriptor.layouts[0].stride
        vertexBuffer.copyStrided(from: positions, elementSize: 12, elementCount: vertexCount,
                                 sourceStride: 12, destinationStride: vertexStride,
                                 destinationOffset: vertexDescriptor.attributes[0].offset)
        vertexBuffer.copyStrided(from: normals, elementSize: 12, elementCount: vertexCount,
                                 sourceStride: 12, destinationStride: vertexStride,
                                 destinationOffset: vertexDescriptor.attributes[1].offset)

        let world = Mesh(vertexDescriptor: vertexDescriptor, vertexBuffer: vertexBuffer, vertexCount: vertexCount)
        return world
    }

    private func makeMarioMesh(_ textureData: UnsafeRawPointer) -> Mesh? {
        let vertexCount = 3 * SM64_GEO_MAX_TRIANGLES

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[1].format = .float3
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.attributes[1].offset = 12
        vertexDescriptor.attributes[2].format = .float3
        vertexDescriptor.attributes[2].bufferIndex = 0
        vertexDescriptor.attributes[2].offset = 24
        vertexDescriptor.attributes[3].format = .float2
        vertexDescriptor.attributes[3].bufferIndex = 0
        vertexDescriptor.attributes[3].offset = 36
        vertexDescriptor.layouts[0].stride = 44

        let vertexBuffer = device.makeBuffer(length: 3 * SM64_GEO_MAX_TRIANGLES * vertexDescriptor.layouts[0].stride,
                                             options: [.storageModeShared])!


        let vertexStride = vertexDescriptor.layouts[0].stride
        vertexBuffer.copyStrided(from: marioGeometry.position, elementSize: 12, elementCount: vertexCount,
                                 sourceStride: 12, destinationStride: vertexStride,
                                 destinationOffset: vertexDescriptor.attributes[0].offset)
        vertexBuffer.copyStrided(from: marioGeometry.normal, elementSize: 12, elementCount: vertexCount,
                                 sourceStride: 12, destinationStride: vertexStride,
                                 destinationOffset: vertexDescriptor.attributes[1].offset)
        vertexBuffer.copyStrided(from: marioGeometry.color, elementSize: 12, elementCount: vertexCount,
                                 sourceStride: 12, destinationStride: vertexStride,
                                 destinationOffset: vertexDescriptor.attributes[2].offset)
        vertexBuffer.copyStrided(from: marioGeometry.uv, elementSize: 8, elementCount: vertexCount,
                                 sourceStride: 8, destinationStride: vertexStride,
                                 destinationOffset: vertexDescriptor.attributes[3].offset)

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

        let mario = Mesh(vertexDescriptor: vertexDescriptor, vertexBuffer: vertexBuffer, vertexCount: vertexCount)
        mario.texture = texture
        return mario
    }

    private func updateMarioMesh() {
        let vertexCount = Int(3 * marioGeometry.numTrianglesUsed)
        let vertexDescriptor = marioMesh.vertexDescriptor
        let vertexBuffer = marioMesh.vertexBuffer
        let vertexStride = vertexDescriptor.layouts[0].stride

        vertexBuffer.copyStrided(from: marioGeometry.position, elementSize: 12, elementCount: vertexCount,
                                 sourceStride: 12, destinationStride: vertexStride,
                                 destinationOffset: vertexDescriptor.attributes[0].offset)
        vertexBuffer.copyStrided(from: marioGeometry.normal, elementSize: 12, elementCount: vertexCount,
                                 sourceStride: 12, destinationStride: vertexStride,
                                 destinationOffset: vertexDescriptor.attributes[1].offset)
        vertexBuffer.copyStrided(from: marioGeometry.color, elementSize: 12, elementCount: vertexCount,
                                 sourceStride: 12, destinationStride: vertexStride,
                                 destinationOffset: vertexDescriptor.attributes[2].offset)
        vertexBuffer.copyStrided(from: marioGeometry.uv, elementSize: 8, elementCount: vertexCount,
                                 sourceStride: 8, destinationStride: vertexStride,
                                 destinationOffset: vertexDescriptor.attributes[3].offset)

        marioMesh.vertexCount = vertexCount
    }

    private func makeController() {
        NotificationCenter.default.addObserver(self, selector: #selector(controllerDidConnect(_:)),
                                               name: NSNotification.Name.GCControllerDidConnect, object: nil)

        let controllerConfig = GCVirtualController.Configuration()
        controllerConfig.elements = [
            GCInputLeftThumbstick,
            GCInputRightThumbstick,
            GCInputButtonA,
            GCInputButtonB,
            GCInputLeftTrigger
        ]
        virtualController = GCVirtualController(configuration: controllerConfig)
        virtualController.connect()
    }

    // MARK: - GController Notifications

    @objc
    func controllerDidConnect(_ notification: Notification) {
        if let connectedController = notification.object as? GCController {
            self.controller = connectedController
        }
    }
}

fileprivate extension MTLBuffer {
    func copyStrided(from source: UnsafeRawPointer, elementSize: Int, elementCount: Int, sourceStride: Int,
                     destinationStride: Int, destinationOffset: Int)
    {
        for i in 0..<elementCount {
            self.contents().advanced(by: destinationOffset + destinationStride * i)
                .copyMemory(from: source.advanced(by: sourceStride * i), byteCount: elementSize)
        }
    }
}
