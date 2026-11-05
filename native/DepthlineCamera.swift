import SceneKit

/// Original composition for Depthline: a wider natural view and a common
/// aiming axis across both sectors, independent of window aspect and DPI.
enum DepthlineCamera {
    static let horizontalDegrees = 64.0
    static let sightFractionFromTop: CGFloat = 0.55

    static func configure(_ camera:SCNCamera,gameID:String,size:CGSize) {
        let fov=horizontalDegrees,near=0.08,far=900.0
        let focal=1 / tan(fov * .pi / 360)
        let aspect=max(1,Double(size.width))/max(1,Double(size.height))
        var p=SCNMatrix4Identity
        p.m11=CGFloat(focal);p.m22=CGFloat(focal*aspect);p.m32=2*sightFractionFromTop-1
        p.m33=CGFloat(-(far+near)/(far-near));p.m34 = -1
        p.m43=CGFloat(-2*far*near/(far-near));p.m44=0
        camera.projectionDirection = .horizontal;camera.fieldOfView=CGFloat(fov)
        camera.zNear=near;camera.zFar=far;camera.projectionTransform=p
    }
}
