
import UIKit
import Metal
import MetalKit
import ARKit

class ViewController: UIViewController, MTKViewDelegate, ARSessionDelegate {
    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var session: ARSession!

    private var frameRenderer: ARFrameRenderer!
    private var gameController: GameWorldController!

    var mtkView: MTKView {
        return self.view as! MTKView
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()

        device = MTLCreateSystemDefaultDevice()!
        commandQueue = device.makeCommandQueue()!

        session = ARSession()
        session.delegate = self

        mtkView.device = device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.depthStencilPixelFormat = .depth32Float
        mtkView.sampleCount = 1
        mtkView.delegate = self

        frameRenderer = ARFrameRenderer(device: device, view: mtkView)
        gameController = GameWorldController(device: device, view: mtkView)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        let configuration = ARWorldTrackingConfiguration()
        //configuration.sceneReconstruction = .mesh
        //configuration.environmentTexturing = .automatic
        //configuration.frameSemantics = .sceneDepth
        configuration.planeDetection = .horizontal

        session.run(configuration)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        session.pause()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    }
    
    func draw(in view: MTKView) {
        let time = CACurrentMediaTime()

        if let frame = session.currentFrame {
            gameController.update(at: time, frame: frame)
        }

        guard let renderPassDescriptor = view.currentRenderPassDescriptor else { return }
        let commandBuffer = commandQueue.makeCommandBuffer()!
        if let renderCommandEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
            frameRenderer.draw(renderCommandEncoder: renderCommandEncoder, commandBuffer: commandBuffer)
            gameController.draw(renderCommandEncoder: renderCommandEncoder, commandBuffer: commandBuffer)
            renderCommandEncoder.endEncoding()
        }
        commandBuffer.present(view.currentDrawable!)
        commandBuffer.commit()
    }
    
    // MARK: - ARSessionObserver
    
    func session(_ session: ARSession, didFailWithError error: Error) {
    }
    
    func sessionWasInterrupted(_ session: ARSession) {
    }
    
    func sessionInterruptionEnded(_ session: ARSession) {
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameRenderer.update(frame: frame)
    }

    //func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
    //}

    //func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
    //}

    //func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
    //}
}
