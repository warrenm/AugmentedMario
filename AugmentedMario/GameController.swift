
import Foundation
import ARKit
import Metal
import MetalKit
import simd
import GameController

class GameWorldController {
    let device: MTLDevice
    let view: MTKView!

    private var virtualController: Any? /*GCVirtualController*/
    private var controller: GCController?
    private var lastMarioTick: TimeInterval = 0.0
    private var marioWorld: SuperMarioWorld
    private var preferredPlane: ARPlaneAnchor?

    init(device: MTLDevice, view: MTKView) {
        self.device = device
        self.view = view
        marioWorld = SuperMarioWorld(device)

        NotificationCenter.default.addObserver(self, selector: #selector(controllerDidConnect(_:)),
                                               name: NSNotification.Name.GCControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(controllerDidDisconnect(_:)),
                                               name: NSNotification.Name.GCControllerDidDisconnect, object: nil)
        if #available(iOS 15.0, *) {
            connectVirtualController()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self,
                                                  name: NSNotification.Name.GCControllerDidConnect, object: nil)
        NotificationCenter.default.removeObserver(self,
                                                  name: NSNotification.Name.GCControllerDidDisconnect, object: nil)
    }

    func update(at time: TimeInterval, frame: ARFrame) {
        for anchor in frame.anchors {
            if let planeAnchor = anchor as? ARPlaneAnchor {
                if preferredPlane == nil || preferredPlane == planeAnchor {
                    preferredPlane = planeAnchor
                    marioWorld.updateCollisionMesh(planeAnchor)
                }
            }
        }

        let orientation = view.window?.windowScene?.interfaceOrientation ?? UIInterfaceOrientation.portrait
        marioWorld.camera.viewTransform = frame.camera.viewMatrix(for: orientation)
        marioWorld.camera.projectionTransform = frame.camera.projectionMatrix(for: orientation,
                                                                              viewportSize: view.drawableSize,
                                                                              zNear: 0.01,
                                                                              zFar: 200)

        pollControllerInputs()

        if (time - lastMarioTick > (1.0 / 30.0)) {
            marioWorld.update(at: time)
            lastMarioTick = time
        }
    }

    func draw(renderCommandEncoder: MTLRenderCommandEncoder, commandBuffer: MTLCommandBuffer) {
        marioWorld.draw(renderCommandEncoder: renderCommandEncoder)
    }

    @available(iOS 15.0, *)
    private func connectVirtualController() {
        let controllerConfig = GCVirtualController.Configuration()
        controllerConfig.elements = [
            GCInputLeftThumbstick,
            GCInputButtonA,
            GCInputButtonB,
            GCInputRightTrigger
        ]
        let virtualController = GCVirtualController(configuration: controllerConfig)
        virtualController.connect()
        self.virtualController = virtualController
    }

    @available(iOS 15.0, *)
    private func disconnectVirtualController() {
        (virtualController as? GCVirtualController)?.disconnect()
        virtualController = nil
    }

    private func pollControllerInputs() {
        guard let gamepad = controller?.extendedGamepad else { return }

        let cameraWorldTransform = marioWorld.camera.viewTransform.inverse
        let cameraX = cameraWorldTransform.columns.0.xyz
        let cameraZ = -cameraWorldTransform.columns.2.xyz

        let xAxis = gamepad.leftThumbstick.xAxis.value * cameraX
        let yAxis = gamepad.leftThumbstick.yAxis.value * cameraZ

        marioWorld.inputs.buttonA = gamepad.buttonA.isPressed ? 1 : 0
        marioWorld.inputs.buttonB = gamepad.buttonB.isPressed ? 1 : 0
        marioWorld.inputs.buttonZ = gamepad.rightTrigger.isPressed ? 1 : 0
        marioWorld.inputs.camLookX = cameraX.x
        marioWorld.inputs.camLookZ = cameraZ.z
        marioWorld.inputs.stickX = xAxis.x
        marioWorld.inputs.stickY = yAxis.z
    }

    // MARK: - GController Notifications

    @objc
    func controllerDidConnect(_ notification: Notification) {
        if let connectedController = notification.object as? GCController {
            self.controller = connectedController
        }
    }

    @objc
    func controllerDidDisconnect(_ notification: Notification) {
        self.controller = nil
    }
}
