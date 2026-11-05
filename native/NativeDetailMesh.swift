import SceneKit
import simd

/// Small batched visual meshes. Vertex colours keep metal, rubber, cloth and skin
/// in one material/draw without affecting the independently decoded hit volumes.
struct NativeDetailMesh {
    enum Surface:Int {case weapon,uniform,paint,fabric}
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var colors: [SIMD4<Float>] = []
    // x marks exposed machined edges; unlike screen-space noise it stays attached
    // to the mesh and is averaged naturally when a small object recedes.
    var surfaceDetail: [SIMD2<Float>] = []
    var restUV: [SIMD2<Float>] = []
    var activeSurface: Float = 0
    var indices: [UInt32] = []
    var boneIndices: [UInt16] = []
    var activeBone: UInt16 = 0

    /// Reshape a visual in its existing source coordinate system. Normals use
    /// the inverse scale; source pivots and ballistic muzzles stay untouched.
    mutating func scaleVisual(_ scale:SIMD3<Float>,rearScale:Float=1) {
        for i in positions.indices {
            let s=SIMD3(scale.x,scale.y,scale.z*(positions[i].z>0 ? rearScale:1))
            positions[i]*=s;normals[i]=simd_normalize(normals[i]/s)
        }
    }

    mutating func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, color: SIMD3<Float>) {
        let cross = simd_cross(b-a,c-a)
        guard simd_length_squared(cross) > 1e-12 else { return }
        let n = simd_normalize(cross), start = UInt32(positions.count)
        // SceneKit vertex attributes are linear, unlike NSColor's sRGB inputs.
        // Treat the authored palette as sRGB to avoid pale plastic-looking paint.
        func linear(_ c:Float)->Float {c<=0.04045 ? c/12.92:pow((c+0.055)/1.055,2.4)}
        let tint=SIMD3(linear(color.x),linear(color.y),linear(color.z))
        for p in [a,b,c] {
            positions.append(p); normals.append(n); colors.append(SIMD4(tint,1))
            surfaceDetail.append(.init(0,activeSurface));restUV.append(.init(p.x+p.z*0.67,p.y+p.z*0.38))
            boneIndices.append(activeBone)
        }
        indices.append(contentsOf: [start,start+1,start+2])
    }
    mutating func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, color: SIMD3<Float>) {
        triangle(a,b,c,color:color); triangle(a,c,d,color:color)
    }
    mutating func box(center: SIMD3<Float>, size: SIMD3<Float>, color: SIMD3<Float>) {
        let r=size/2, a=center-r, b=center+r
        quad(.init(a.x,a.y,b.z),.init(b.x,a.y,b.z),.init(b.x,b.y,b.z),.init(a.x,b.y,b.z),color:color)
        quad(.init(b.x,a.y,a.z),.init(a.x,a.y,a.z),.init(a.x,b.y,a.z),.init(b.x,b.y,a.z),color:color)
        quad(.init(a.x,a.y,a.z),.init(a.x,a.y,b.z),.init(a.x,b.y,b.z),.init(a.x,b.y,a.z),color:color)
        quad(.init(b.x,a.y,b.z),.init(b.x,a.y,a.z),.init(b.x,b.y,a.z),.init(b.x,b.y,b.z),color:color)
        quad(.init(a.x,b.y,b.z),.init(b.x,b.y,b.z),.init(b.x,b.y,a.z),.init(a.x,b.y,a.z),color:color)
        quad(.init(a.x,a.y,a.z),.init(b.x,a.y,a.z),.init(b.x,a.y,b.z),.init(a.x,a.y,b.z),color:color)
    }
    mutating func beveledBox(center: SIMD3<Float>, size: SIMD3<Float>, bevel: Float, color: SIMD3<Float>) {
        let r=size/2, b=min(bevel,min(r.x,min(r.y,r.z))*0.45)
        for axis in 0..<3 {
            let u=(axis+1)%3,v=(axis+2)%3
            for sign:Float in [-1,1] {
                var points:[SIMD3<Float>]=[]
                for pair:SIMD2<Float> in [.init(-1,-1),.init(1,-1),.init(1,1),.init(-1,1)] {
                    var p=center;p[axis]+=sign*r[axis];p[u]+=pair.x*(r[u]-b);p[v]+=pair.y*(r[v]-b);points.append(p)
                }
                if sign<0 {points.reverse()}
                quad(points[0],points[1],points[2],points[3],color:color)
            }
            for su:Float in [-1,1] {for sv:Float in [-1,1] {
                var a=center,c=center,d=center,e=center
                a[axis]-=r[axis]-b;c[axis]+=r[axis]-b;d[axis]+=r[axis]-b;e[axis]-=r[axis]-b
                a[u]+=su*r[u];c[u]+=su*r[u];d[u]+=su*(r[u]-b);e[u]+=su*(r[u]-b)
                a[v]+=sv*(r[v]-b);c[v]+=sv*(r[v]-b);d[v]+=sv*r[v];e[v]+=sv*r[v]
                // The sign pair changes the edge winding. Keep its face normal
                // outside the solid, just like the six main faces.
                if simd_dot(simd_cross(c-a,d-a),a-center)>0 {quad(a,c,d,e,color:color)}
                else {quad(e,d,c,a,color:color)}
            }}
        }
        for x:Float in [-1,1] {for y:Float in [-1,1] {for z:Float in [-1,1] {
            let s=SIMD3(x,y,z),base=center+s*(r-SIMD3(repeating:b))
            let a=base+SIMD3(x*b,0,0),c=base+SIMD3(0,y*b,0),d=base+SIMD3(0,0,z*b)
            if simd_dot(simd_cross(c-a,d-a),a-center)>0 {triangle(a,c,d,color:color)}
            else {triangle(a,d,c,color:color)}
        }}}
    }
    mutating func cylinder(from a: SIMD3<Float>, to b: SIMD3<Float>, radius: Float, endRadius: Float? = nil, sides: Int = 10, color: SIMD3<Float>, caps: Bool = true) {
        let axis=simd_normalize(b-a), helper: SIMD3<Float> = abs(axis.y)<0.95 ? .init(0,1,0):.init(1,0,0)
        let u=simd_normalize(simd_cross(axis,helper)),v=simd_cross(axis,u), r2=endRadius ?? radius
        for i in 0..<sides {
            let t=Float(i)*2*Float.pi/Float(sides), q=Float(i+1)*2*Float.pi/Float(sides)
            let d=u*cos(t)+v*sin(t),e=u*cos(q)+v*sin(q)
            quad(a+d*radius,a+e*radius,b+e*r2,b+d*r2,color:color)
            let nd=simd_normalize(d+axis*((radius-r2)/simd_length(b-a))),ne=simd_normalize(e+axis*((radius-r2)/simd_length(b-a)))
            if normals.count>=6 {normals.replaceSubrange((normals.count-6)..<normals.count,with:[nd,ne,ne,nd,ne,nd])}
            if caps {triangle(a,a+e*radius,a+d*radius,color:color);triangle(b,b+d*r2,b+e*r2,color:color)}
        }
    }
    /// Rounded machined casing, with smooth edge normals and a small curvature
    /// attribute for wear. Keep the cheaper planar bevel for distant world models.
    mutating func machinedBox(center: SIMD3<Float>, size: SIMD3<Float>, bevel: Float, color: SIMD3<Float>) {
        let r=size/2,b=min(bevel,min(r.x,min(r.y,r.z))*0.45),inner=r-SIMD3(repeating:b)
        guard b>0 else {box(center:center,size:size,color:color);return}
        func samples(_ axis:Int)->[Float] {[-r[axis],-inner[axis]-b*0.5,-inner[axis],inner[axis],inner[axis]+b*0.5,r[axis]]}
        for axis in 0..<3 {
            let u=(axis+1)%3,v=(axis+2)%3,us=samples(u),vs=samples(v)
            for sign:Float in [-1,1] {
                func vertex(_ i:Int,_ j:Int)->(SIMD3<Float>,SIMD3<Float>,Float) {
                    var p=SIMD3<Float>.zero;p[axis]=sign*r[axis];p[u]=us[i];p[v]=vs[j]
                    let core=simd_clamp(p,-inner,inner),normal=simd_normalize(p-core)
                    let edge=1-max(abs(normal.x),max(abs(normal.y),abs(normal.z)))
                    return (center+core+normal*b,normal,min(1,edge*3.4))
                }
                for i in 0..<(us.count-1) {for j in 0..<(vs.count-1) {
                    let corners=[vertex(i,j),vertex(i+1,j),vertex(i+1,j+1),vertex(i,j+1)]
                    let order=sign>0 ? [0,1,2,0,2,3]:[0,2,1,0,3,2]
                    for k in stride(from:0,to:6,by:3) {
                        let a=corners[order[k]],c=corners[order[k+1]],d=corners[order[k+2]],start=positions.count
                        triangle(a.0,c.0,d.0,color:color)
                        if positions.count==start+3 {
                            normals.replaceSubrange(start..<(start+3),with:[a.1,c.1,d.1])
                            surfaceDetail.replaceSubrange(start..<(start+3),with:[.init(a.2,activeSurface),.init(c.2,activeSurface),.init(d.2,activeSurface)])
                        }
                    }
                }}
            }
        }
    }
    mutating func ellipsoid(center:SIMD3<Float>,radii:SIMD3<Float>,segments:Int=16,rings:Int=10,upperHalf:Bool=false,color:SIMD3<Float>) {
        let total=Float.pi*(upperHalf ? 0.5:1)
        for j in 0..<rings {for i in 0..<segments {
            func point(_ ring:Int,_ side:Int)->SIMD3<Float> {
                let t=Float(ring)*total/Float(rings),a=Float(side)*2*Float.pi/Float(segments)
                return center+SIMD3(sin(t)*cos(a),cos(t),sin(t)*sin(a))*radii
            }
            let a=point(j,i),b=point(j+1,i),c=point(j+1,i+1),d=point(j,i+1),start=positions.count
            quad(a,d,c,b,color:color)
            for k in start..<positions.count {normals[k]=simd_normalize((positions[k]-center)/(radii*radii))}
        }}
    }
    mutating func plate(_ outline:[SIMD3<Float>],thickness:SIMD3<Float>,color:SIMD3<Float>) {
        guard outline.count>=3 else{return};let half=thickness/2
        for i in 1..<(outline.count-1) {
            triangle(outline[0]+half,outline[i]+half,outline[i+1]+half,color:color)
            triangle(outline[0]-half,outline[i+1]-half,outline[i]-half,color:color)
        }
        for i in outline.indices {let j=(i+1)%outline.count;quad(outline[i]-half,outline[j]-half,outline[j]+half,outline[i]+half,color:color)}
    }
    func geometry(material: SCNMaterial) -> SCNGeometry {
        func source<T>(_ values: [T], semantic: SCNGeometrySource.Semantic, components: Int) -> SCNGeometrySource {
            SCNGeometrySource(data: values.withUnsafeBytes { Data($0) }, semantic: semantic, vectorCount: values.count, usesFloatComponents: true, componentsPerVector: components, bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<T>.stride)
        }
        let element=SCNGeometryElement(data:indices.withUnsafeBytes{Data($0)},primitiveType:.triangles,primitiveCount:indices.count/3,bytesPerIndex:4)
        let result=SCNGeometry(sources:[source(positions,semantic:.vertex,components:3),source(normals,semantic:.normal,components:3),source(colors,semantic:.color,components:4),source(surfaceDetail,semantic:.texcoord,components:2),source(restUV,semantic:.texcoord,components:2)],elements:[element])
        result.materials=[material];return result
    }
    static func configureSurface(_ material:SCNMaterial,style:Surface) {
        material.setValue(Float(style.rawValue),forKey:"bhDetailStyle")
        material.setValue(Float(0),forKey:"bhDetailWreck")
        material.shaderModifiers=[.geometry:"""
        #pragma varyings
        float3 bhDetailPosition;
        float3 bhDetailTint;
        float bhDetailEdge;
        float bhDetailKind;
        float2 bhDetailRestUV;
        #pragma body
        out.bhDetailPosition = _geometry.position.xyz;
        out.bhDetailTint = _geometry.color.rgb;
        out.bhDetailEdge = _geometry.texcoords[0].x;
        out.bhDetailKind = _geometry.texcoords[0].y;
        out.bhDetailRestUV = _geometry.texcoords[1];
        """,.surface:"""
        #pragma arguments
        float bhDetailStyle;
        float bhDetailWreck;
        #pragma varyings
        float3 bhDetailPosition;
        float3 bhDetailTint;
        float bhDetailEdge;
        float bhDetailKind;
        float2 bhDetailRestUV;
        #pragma body
        float3 p=in.bhDetailPosition, c=pow(max(in.bhDetailTint,float3(0.0)),float3(1.0/2.2));
        float scale=bhDetailStyle<0.5 ? 2600.0:bhDetailStyle<1.5 ? 1650.0:480.0;
        float3 q=p*scale;
        float fade=1.0-smoothstep(0.45,2.0,length(fwidth(q)));
        float grain=(sin(dot(q,float3(0.73,1.17,0.61)))*sin(dot(q,float3(1.31,-0.57,0.91))))*0.5*fade;
        float broad=sin(p.x*43.0+sin(p.z*37.0))*sin(p.z*31.0+p.y*53.0);
        float phase=p.z*4200.0;
        float machining=sin(phase)*(1.0-smoothstep(0.5,3.0,fwidth(phase)));
        float rough=0.68,metal=0.16,height=grain*0.000003;
        float textile=0.0;
        if(bhDetailStyle<0.5){
            float brass=step(c.g*1.22,c.r)*step(c.b*1.8,c.g);
            float painted=step(c.b*1.3,c.g)*(1.0-brass);
            float rubber=(1.0-step(0.10,max(c.r,max(c.g,c.b))))*(1.0-step(c.r*1.2,c.b));
            float bare=(1.0-painted)*(1.0-rubber);
            float wear=clamp(in.bhDetailEdge,0.0,1.0)*(0.55+0.30*broad)*(1.0-rubber);
            float2 patchUV=float2(p.x*119.0+p.y*73.0,p.z*83.0-p.y*57.0);
            float2 patchCell=floor(patchUV),patchF=fract(patchUV);
            patchF=patchF*patchF*(3.0-2.0*patchF);
            float4 patchSeeds=float4(dot(patchCell,float2(127.1,311.7)),dot(patchCell+float2(1,0),float2(127.1,311.7)),dot(patchCell+float2(0,1),float2(127.1,311.7)),dot(patchCell+float2(1,1),float2(127.1,311.7)));
            float4 patchNoise=fract(sin(patchSeeds)*43758.5453);
            float patch=mix(mix(patchNoise.x,patchNoise.y,patchF.x),mix(patchNoise.z,patchNoise.w,patchF.x),patchF.y)*2.0-1.0;
            float patchFade=1.0-smoothstep(0.5,3.0,length(fwidth(patchUV)));
            patch*=patchFade;
            rough=mix(0.36,0.64,painted);rough=mix(rough,0.87,rubber);
            rough=mix(rough,0.25,wear*0.68);rough=mix(rough,0.31,brass);
            rough+=patch*0.035*(1.0-rubber);
            metal=mix(0.88,0.08,painted);metal=mix(metal,0.01,rubber);
            metal=mix(metal,0.92,brass);metal=mix(metal,0.90,wear*0.6);
            // Broad, subtle patina breaks the cast-plastic flatness; edge wear
            // reveals a brighter conductor only on actual rounded casing edges.
            height+=machining*0.000004*bare;
            _surface.diffuse.rgb*=0.97+grain*0.07+broad*0.025+patch*0.055;
            float3 exposed=float3(0.23,0.25,0.26);
            _surface.diffuse.rgb=mix(_surface.diffuse.rgb,exposed,wear*0.28);
            _surface.ambientOcclusion*=1.0-0.07*(1.0-wear)*(0.5+0.5*broad);
            if(in.bhDetailKind>6.5){
                rough=0.83+grain*0.07;metal=0.0;height=grain*0.00012;
            }
        }else if(bhDetailStyle<1.5){
            // Explicit authored material IDs: cloth, helmet, webbing, skin,
            // leather, steel. Rest-pose UVs keep camouflage fixed while limbs bend.
            float kind=in.bhDetailKind;
            textile=(1.0-step(0.4,abs(kind-1.0)))+(1.0-step(0.4,abs(kind-2.0)));
            float helmet=1.0-step(0.4,abs(kind-2.0));
            float webbing=1.0-step(0.4,abs(kind-3.0));
            float skin=1.0-step(0.4,abs(kind-4.0));
            float leather=1.0-step(0.4,abs(kind-5.0));
            float steel=1.0-step(0.4,abs(kind-6.0));
            rough=0.84;metal=0.0;
            rough=mix(rough,0.66,helmet);rough=mix(rough,0.58,skin);
            rough=mix(rough,0.73,leather);rough=mix(rough,0.39,steel);metal=mix(metal,0.82,steel);
            float2 uv=in.bhDetailRestUV*17.0;
            uv+=float2(sin(uv.y*0.57+sin(uv.x*0.41)),sin(uv.x*0.63+sin(uv.y*0.39)))*0.53;
            float2 cell=floor(uv),f=fract(uv);f=f*f*(3.0-2.0*f);
            float4 seeds=float4(dot(cell,float2(127.1,311.7)),dot(cell+float2(1,0),float2(127.1,311.7)),dot(cell+float2(0,1),float2(127.1,311.7)),dot(cell+float2(1,1),float2(127.1,311.7)));
            float4 noise=fract(sin(seeds)*43758.5453);
            float pattern=mix(mix(noise.x,noise.y,f.x),mix(noise.z,noise.w,f.x),f.y);
            float aa=max(0.018,fwidth(pattern)*0.8);
            float4 noiseB=fract(sin(seeds+67.37)*27483.392);
            float4 noiseC=fract(sin(seeds+149.13)*19873.175);
            float patternB=mix(mix(noiseB.x,noiseB.y,f.x),mix(noiseB.z,noiseB.w,f.x),f.y);
            float patternC=mix(mix(noiseC.x,noiseC.y,f.x),mix(noiseC.z,noiseC.w,f.x),f.y);
            // Independent overlapping fields avoid contour-map rings and repeated
            // identical spots. No real service camouflage or insignia is copied.
            float3 camo=mix(float3(0.105,0.127,0.062),float3(0.175,0.158,0.097),smoothstep(0.48-aa,0.48+aa,pattern));
            camo=mix(camo,float3(0.060,0.076,0.037),smoothstep(0.63-aa,0.63+aa,patternB));
            camo=mix(camo,float3(0.090,0.073,0.044),smoothstep(0.66-aa,0.66+aa,patternC));
            float camoFade=1.0-smoothstep(0.65,2.4,length(fwidth(uv)));
            camo=mix(float3(0.115,0.126,0.068),camo,camoFade);
            _surface.diffuse.rgb=mix(_surface.diffuse.rgb,camo,textile);
            float weave=sin(in.bhDetailRestUV.x*3100.0)*sin(in.bhDetailRestUV.y*2900.0)*fade;
            height+=(grain*0.00004+weave*0.000025)*(textile+webbing)*(1.0-helmet);
            _surface.diffuse.rgb*=0.985+grain*0.045+broad*0.018;
        }else if(bhDetailStyle<2.5){
            // Paint is dielectric, while neutral exposed steel remains a conductor.
            // Glass and rubber are separate surfaces even within a single batch.
            float maxC=max(c.r,max(c.g,c.b)),minC=min(c.r,min(c.g,c.b));
            float rubber=1.0-step(0.18,maxC);
            float glazing=step(c.g*1.08,c.b)*step(c.r*1.3,c.b)*step(0.20,c.b);
            float bare=(1.0-step(0.075,maxC-minC))*step(0.20,maxC)*(1.0-step(0.37,maxC));
            bare*=1.0-glazing;
            rough=mix(0.52,0.32,bare);metal=mix(0.025,0.86,bare);
            rough=mix(rough,0.88,rubber);metal=mix(metal,0.0,rubber);
            rough=mix(rough,0.13,glazing);metal=mix(metal,0.0,glazing);
            _surface.emission=float4(0.0);
            _surface.diffuse.rgb*=0.98+grain*0.035+broad*0.024;
        }else{
            rough=0.94;metal=0.0;
            float weave=sin(p.x*1800.0)*sin(p.z*1700.0)*fade;
            height+=weave*0.00003+grain*0.000035;
            _surface.diffuse.rgb*=0.985+grain*0.04+broad*0.018;
        }
        _surface.roughness=mix(clamp(rough+grain*0.05+broad*0.02,0.22,0.96),0.95,bhDetailWreck);
        _surface.metalness=mix(metal,0.04,bhDetailWreck);
        float3 dx=dfdx(_surface.position),dy=dfdy(_surface.position);
        float3 r1=cross(dy,_surface.normal),r2=cross(_surface.normal,dx);
        float determinant=dot(dx,r1);
        float3 gradient=sign(determinant)*(dfdx(height)*r1+dfdy(height)*r2);
        _surface.normal=normalize(max(abs(determinant),1e-12)*_surface.normal-gradient);
        """]
    }
}
