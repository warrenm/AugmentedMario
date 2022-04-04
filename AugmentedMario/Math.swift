import simd

extension simd_float4x4 {
    init(translation t: SIMD3<Float>) {
        let X = SIMD4<Float>(1, 0, 0, 0)
        let Y = SIMD4<Float>(0, 1, 0, 0)
        let Z = SIMD4<Float>(0, 0, 1, 0)
        let W = SIMD4<Float>(t.x, t.y, t.z, 1)
        self.init(X, Y, Z, W)
    }

    init(perspectiveProjectionFOV fovy: Float, aspectRatio aspect: Float, nearZ near: Float, farZ far: Float) {
        let fovRadians = (fovy * .pi) / 180
        let yScale = 1 / tan(fovRadians * 0.5)
        let xScale = yScale / aspect
        let zRange = far - near
        let zScale = -(far + near) / zRange
        let zTrans = -2 * far * near / zRange

        let X = SIMD4<Float>(xScale, 0, 0, 0)
        let Y = SIMD4<Float>(0, yScale, 0, 0)
        let Z = SIMD4<Float>(0, 0, zScale, -1)
        let W = SIMD4<Float>(0, 0, zTrans, 0)

        self.init(X, Y, Z, W)
    }

    static func look(at: SIMD3<Float>, from: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let zNeg = normalize(at - from)
        let x = normalize(cross(zNeg, up))
        let y = normalize(cross(x, zNeg))
        let z = -zNeg
        let M = simd_float4x4(
            SIMD4<Float>(x, 0.0),
            SIMD4<Float>(y, 0.0),
            SIMD4<Float>(z, 0.0),
            SIMD4<Float>(from, 1.0)
        )
        return M
    }
}

extension SIMD3 {
    init(_ v: (Scalar, Scalar, Scalar)) {
        self.init(v.0, v.1, v.2)
    }
}

extension SIMD4 {
    var xyz: SIMD3<Scalar> {
        return SIMD3<Scalar>(x, y, z)
    }
}
