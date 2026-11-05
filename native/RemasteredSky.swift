import AppKit
import SceneKit

/// Directional daytime sky at native output resolution. The generated image is
/// reused for detailed cloud sectors instead of magnifying a small 360-degree
/// panorama. One opaque draw, no animation or gameplay RNG; night art retained.
enum RemasteredSky {
    static func makeNode(image: NSImage, night: Bool) -> SCNNode {
        // Background pass ignores depth; keeping the dome inside the fog start
        // avoids applying terrain distance haze to the already atmospheric sky.
        let geometry = SCNSphere(radius: 100)
        geometry.segmentCount = 64
        let material = SCNMaterial()
        material.name = night ? "HD:night-panorama" : "HD:directional-day-sky"
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        material.diffuse.contents = NSColor.white
        for (key, contents) in [("skyNoise", noiseImage), ("skyReference", image)] {
            let property = SCNMaterialProperty(contents: contents)
            property.wrapS = .repeat; property.wrapT = .repeat
            property.minificationFilter = .linear; property.magnificationFilter = .linear
            property.mipFilter = .linear; property.maxAnisotropy = 4
            material.setValue(property, forKey: key)
        }
        material.setValue(Float(night ? 1 : 0), forKey: "skyNight")
        material.setValue(Float(0), forKey: "skyDusk")
        material.setValue(NSValue(scnVector3: SCNVector3(0.59, 0.44, -0.67)), forKey: "skySun")
        material.setValue(Float(0),forKey:"skyTime")
        material.shaderModifiers = [.geometry: rayGeometry, .surface: skySurface]
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.position.y = 8.2
        node.name = night ? "RemasteredSkyNight" : "RemasteredSkyDay"
        node.isHidden = night; node.renderingOrder = -1100; node.castsShadow = false
        return node
    }

    /// A tiny seamless, smoothly interpolated noise lookup. It is generated once
    /// from a local integer hash; no source game random stream is touched.
    private static let noiseImage: NSImage = {
        let side = 512, cells = 64, channels = 4
        var bytes = [UInt8](repeating: 0, count: side * side * channels)
        func value(_ x: Int, _ y: Int, _ salt: UInt32) -> Double {
            var v = UInt32(x & 63) &* 0x9e3779b9 ^ UInt32(y & 63) &* 0x85ebca6b ^ salt
            v ^= v >> 16; v = v &* 0x7feb352d; v ^= v >> 15
            v = v &* 0x846ca68b; v ^= v >> 16
            return Double(v & 65535) / 65535
        }
        for y in 0..<side {
            let py = Double(y) * Double(cells) / Double(side), iy = Int(py), fy = py - Double(iy)
            let sy = fy * fy * fy * (fy * (fy * 6 - 15) + 10)
            for x in 0..<side {
                let px = Double(x) * Double(cells) / Double(side), ix = Int(px), fx = px - Double(ix)
                let sx = fx * fx * fx * (fx * (fx * 6 - 15) + 10)
                for c in 0..<3 {
                    let salt = UInt32(c + 1) &* 0xa511e9b3
                    let a = value(ix, iy, salt), b = value(ix + 1, iy, salt)
                    let d = value(ix, iy + 1, salt), e = value(ix + 1, iy + 1, salt)
                    let n = (a + (b - a) * sx) * (1 - sy) + (d + (e - d) * sx) * sy
                    bytes[(y * side + x) * channels + c] = UInt8(max(0, min(255, (n * 255).rounded())))
                }
                bytes[(y * side + x) * channels + 3] = 255
            }
        }
        let data = Data(bytes) as CFData
        let cg = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                         bytesPerRow: side * channels, space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                         provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: true,
                         intent: .defaultIntent)!
        return NSImage(cgImage: cg, size: NSSize(width: side, height: side))
    }()

    private static let rayGeometry = """
    #pragma varyings
    float3 skyRay;
    #pragma body
    out.skyRay = (scn_node.modelTransform * _geometry.position).xyz - scn_frame.inverseViewTransform[3].xyz;
    """

    private static let skySurface = """
    #pragma arguments
    texture2d<float> skyNoise;
    texture2d<float> skyReference;
    float skyNight;
    float skyDusk;
    float3 skySun;
    float skyTime;
    #pragma varyings
    float3 skyRay;
    #pragma body
    constexpr sampler cloudSampler(coord::normalized, address::repeat, filter::linear, mip_filter::linear, max_anisotropy(4));
    float3 ray = normalize(in.skyRay);
    float elevation = max(ray.y, 0.0);
    float3 horizon = mix(float3(0.48,0.66,0.82), float3(0.075,0.105,0.17), skyNight);
    float3 zenith = mix(float3(0.055,0.25,0.58), float3(0.008,0.020,0.055), skyNight);
    float3 colour = mix(horizon, zenith, pow(saturate(elevation), 0.43));

    // Stereographic world-direction coordinates have no longitude seam and
    // avoid stretching the horizon into horizontal bands. Derivative-driven
    // mip filtering handles distant detail. Advection is driven by simulation
    // time, never camera motion or an independently running animation.
    float2 p = ray.xz / max(ray.y + 1.0, 0.25);
    p = float2(p.x * 0.91 + p.y * 0.42, -p.x * 0.42 + p.y * 0.91);
    float2 wind=float2(skyTime*0.000055,skyTime*0.000021);
    float2 uv = p * 0.10 + float2(0.213,0.579)+wind;
    // NSImage uploads carry sRGB metadata; undo that transfer only for noise
    // values, whose distribution is numerical rather than displayed colour.
    float2 warp = pow(skyNoise.sample(cloudSampler, uv * 0.57).rg, float2(0.454545)) - 0.5;
    uv += warp * 0.012;
    float n0 = pow(skyNoise.sample(cloudSampler, uv).r, 0.454545);
    float n1 = pow(skyNoise.sample(cloudSampler, uv * 2.03 + float2(0.153,0.671)).g, 0.454545);
    float n2 = pow(skyNoise.sample(cloudSampler, uv * 4.17 + float2(0.721,0.239)).b, 0.454545);
    float n3 = pow(skyNoise.sample(cloudSampler, uv * 8.31 + float2(0.311,0.853)).r, 0.454545);
    float n4 = pow(skyNoise.sample(cloudSampler, uv * 17.13 + float2(0.517,0.119)).g, 0.454545);
    float field = n0 * 0.49 + n1 * 0.26 + n2 * 0.14 + n3 * 0.075 + n4 * 0.035;
    float edgeAA = max(fwidth(field) * 1.4, 0.007);
    float density = smoothstep(0.48 - edgeAA, 0.565 + edgeAA, field);
    density *= smoothstep(-0.025, 0.06, ray.y) * (1.0 - smoothstep(0.74, 0.98, ray.y));
    float shade = saturate((field - 0.49) * 5.8 + (n2 - n1) * 0.50 + 0.35);

    // The photograph is a rectangular crop. Overlap its first and last 12%
    // before repeating: wrapping raw edge texels produced a hard line at all
    // three sector boundaries. Derivatives are from the unwrapped direction,
    // so crossing the atan2 branch cannot suddenly select the coarsest mip.
    float longitude = atan2(ray.x, -ray.z) * 0.159154943;
    float2 longitudeGradient = float2(-ray.z,ray.x) / max(dot(ray.xz,ray.xz),0.0001);
    float cycles = skyNight > 0.5 ? 1.0 : 3.0;
    float u = longitude * cycles + 0.5;
    // Keep the final rows out of the sky dome: clamping the top row
    // vertically used to smear its bright texels into shafts at high pitch.
    float photoV = 0.98 - pow(elevation,0.8)*2.0 + warp.y*0.008;
    float photoCoverage = smoothstep(0.025,0.23,photoV) * smoothstep(-0.015,0.055,ray.y);
    float v;
    float drift = skyNight > 0.5 ? 0.0 : 0.015;
    u += warp.x * drift + (skyNight > 0.5 ? 0.0 : skyTime * 0.00035);
    v = skyNight > 0.5 ? 0.5 - asin(clamp(ray.y,-1.0,1.0)) * 0.318309886 :
                         clamp(photoV,0.01,0.99);
    constexpr float tileLength = 0.88;
    constexpr float overlap = 1.0 - tileLength;
    float sampleX = fract(u) * tileLength + overlap;
    float2 dx = float2((dot(longitudeGradient,dfdx(ray.xz))*0.159154943*cycles+dfdx(warp.x)*drift)*tileLength,dfdx(v));
    float2 dy = float2((dot(longitudeGradient,dfdy(ray.xz))*0.159154943*cycles+dfdy(warp.x)*drift)*tileLength,dfdy(v));
    constexpr sampler photoSampler(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear, max_anisotropy(4));
    float3 reference = skyReference.sample(photoSampler,float2(sampleX,v),gradient2d(dx,dy)).rgb;
    if (sampleX > tileLength) {
        float3 start = skyReference.sample(photoSampler,float2(sampleX-tileLength,v),gradient2d(dx,dy)).rgb;
        reference = mix(reference,start,smoothstep(tileLength,1.0,sampleX));
    }
    float3 cloudShadow=mix(float3(0.23,0.31,0.40),float3(0.055,0.073,0.12),skyNight);
    float3 cloudLight=mix(float3(0.90,0.85,0.73),float3(0.13,0.17,0.25),skyNight);
    float3 cloudColour=mix(cloudShadow,cloudLight,shade);
    float3 highClouds = mix(colour,cloudColour,density*0.70);
    colour = mix(highClouds,reference,photoCoverage);

    // Gentle directional atmospheric glow. It is anchored to the world and
    // contains no tiny unfiltered stars/noise that shimmer while aiming.
    float sunFacing = pow(saturate(dot(ray, normalize(skySun))), 20.0);
    colour += sunFacing * float3(0.085,0.055,0.015) * (1.0 - density) * (1.0 - skyNight);
    if (skyDusk > 0.5) {
        float3 luminance = float3(0.2126,0.7152,0.0722);
        float lum = mix(dot(highClouds,luminance),dot(reference,luminance),photoCoverage);
        float3 coldHorizon = float3(0.12,0.177,0.255);
        float3 coolCloud = float3(0.019,0.036,0.074) + lum * float3(0.25,0.33,0.46);
        float3 twilight = mix(coldHorizon, coolCloud, smoothstep(0.0,0.11,elevation));
        twilight = mix(twilight,float3(0.025,0.057,0.115), smoothstep(0.48,0.88,elevation));
        float3 sunRay = normalize(skySun);
        float facing = saturate(dot(normalize(ray.xz + float2(0.00001,0)),normalize(sunRay.xz)));
        float belt = pow(facing,24.0) * exp(-abs(ray.y - sunRay.y) * 10.0);
        // Shallow orange light also reaches the undersides of clouds above a
        // ridge that occludes the sun itself; only the solar sector receives it.
        float underside = pow(facing,42.0) * exp(-abs(ray.y - sunRay.y - 0.087) * 16.0);
        twilight += belt * float3(0.53,0.185,0.06) * (0.36 + lum * 0.78);
        twilight += underside * float3(0.24,0.084,0.022) * smoothstep(0.11,0.55,lum);
        colour = twilight;
    }
    if (skyNight > 0.5) {
        colour = reference*(1.0-density*0.55)+cloudColour*density*0.28;
    }
    _surface.diffuse = float4(colour, 1.0);
    _surface.emission = float4(0.0);
    """
}
