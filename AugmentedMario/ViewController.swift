
import UIKit
import Metal
import MetalKit
import ARKit

class ViewController: UIViewController, MTKViewDelegate, ARSessionDelegate {
    
    var session: ARSession!
    var renderer: Renderer!
    
    override func viewDidLoad() {
        super.viewDidLoad()

        session = ARSession()
        session.delegate = self

        if let view = self.view as? MTKView {
            view.device = MTLCreateSystemDefaultDevice()
            view.backgroundColor = UIColor.clear
            view.delegate = self
            
            guard view.device != nil else {
                print("Metal is not supported on this device")
                return
            }

            renderer = Renderer(session: session, metalDevice: view.device!, renderDestination: view)
            
            renderer.drawRectResized(size: view.bounds.size)
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        let configuration = ARWorldTrackingConfiguration()

        session.run(configuration)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        session.pause()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        renderer.drawRectResized(size: size)
    }
    
    func draw(in view: MTKView) {
        renderer.update()
    }
    
    // MARK: - ARSessionDelegate
    
    func session(_ session: ARSession, didFailWithError error: Error) {
    }
    
    func sessionWasInterrupted(_ session: ARSession) {
    }
    
    func sessionInterruptionEnded(_ session: ARSession) {
    }
}
