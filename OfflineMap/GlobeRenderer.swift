import CoreGraphics
import Foundation
import Metal
import simd

/// What one picture of the globe shows.
public struct GlobeScene: Equatable, Sendable {
    public var camera: MapCamera
    /// The view's size in points
    public var size: CGSize
    public var dark: Bool
    /// Day and night by the Sun's place at `date`
    public var lighting: Bool
    /// Relief exaggerated (heights ×40 on land, ×6 under the sea, strong hillshade); else at true scale with a soft hillshade
    public var exaggerated: Bool
    public var date: Date
    /// How much of the cloud cover shows (0 none … 1 all)
    public var clouds: Double
    /// The tilted camera's vertical angle of view (degrees; `GlobeProjection.lens`)
    public var lens = GlobeProjection.fieldOfView
    /// No sky and no space: the picture is transparent around the Earth and
    /// its air (the website's hero, laid over the page; `snapshot` keeps the
    /// alpha, premultiplied)
    public var transparent = false

    public init(camera: MapCamera, size: CGSize, dark: Bool = false, lighting: Bool = false, exaggerated: Bool = true, date: Date = Date(),
                clouds: Double = 0) {
        self.camera = camera
        self.size = size
        self.dark = dark
        self.lighting = lighting
        self.exaggerated = exaggerated
        self.date = date
        self.clouds = clouds
    }

    /// The clouds as they show: thinner the closer the camera comes (the
    /// ground stays readable), none on the flat map.
    public var cloudOpacity: Double {
        let close = GlobeProjection.smoothstep((camera.zoom - 3) / 3.5)
        return clouds * (1 - 0.65 * close) * (1 - projection.flatness)
    }

    /// The relief's exaggeration: ×40 far out, down to ×6 in low orbit (a
    /// mountain stays a mountain), ×1 at true scale.
    public var reliefFactor: Double {
        guard exaggerated else { return 1 }
        let close = GlobeProjection.smoothstep((camera.zoom - 3) / 4)
        return 40 * pow(6.0 / 40, close)
    }

    public var projection: GlobeProjection { GlobeProjection(camera: camera, size: size, lens: lens) }

    /// How visible the night sky is: fully while the Earth is small in the
    /// view, gone once it fills it (and while the map flattens).
    public var skyOpacity: Double {
        let fill = 2 * projection.radius / Double(max(1, min(size.width, size.height)))
        let x = min(1, max(0, (fill - 0.9) / 0.7))
        // Tilted, space shows above the horizon however close the camera is
        let straightDown = (1 - x * x * (3 - 2 * x)) * (1 - projection.flatness)
        return straightDown + (1 - straightDown) * projection.perspective
    }

    /// The colour of space behind the Earth (the same in both appearances).
    public static let space = MapColor("#04060b")
}

/// The CPU side of the shaders' `Uniforms` (GlobeShaders.swift): the same
/// fields in the same order, all 16-byte aligned.
struct GlobeUniforms {
    var viewport: SIMD4<Float>
    var center: SIMD4<Float>
    var camPos: SIMD4<Float>
    var camForward: SIMD4<Float>
    var camRight: SIMD4<Float>
    var camUp: SIMD4<Float>
    var orthoRight: SIMD4<Float>
    var orthoUp: SIMD4<Float>
    var orthoToward: SIMD4<Float>
    var sun: SIMD4<Float>
    var relief: SIMD4<Float>
    var mapTiles: SIMD4<Float>
    var sky: SIMD4<Float>
    var heightTexel: SIMD4<Float>
    var satTiles: SIMD4<Float>
    var mesh: SIMD4<Float>
    var northColor: SIMD4<Float>
    var southColor: SIMD4<Float>
    var starMatrix: simd_float4x4
}

/// Draws the globe with Metal: the map's own tiles (`MapRenderer`, the
/// light or dark palette) as the sphere's texture, Web Mercator sampled
/// directly (a world texture of zoom 3 at 2× and, where a pixel needs more,
/// the tiles of zoom 4 … 6 the view needs, `GlobeTextures`), the relief
/// from a heightmap (displacement in the vertex shader, hillshade in the
/// fragment shader), day and night by the Sun, the atmosphere's rim and the
/// night sky (`GlobeData.sky`, in right ascension and declination) turned by
/// the sidereal time and the precession, seen through a camera of 90°
/// along the view. The sphere is a mesh of 360 × 180 cells of a degree in
/// longitude and latitude, its vertices on whole degrees of the Earth
/// (`meshMiddle`); each vertex
/// is placed on the sphere and on the flat map and blended by the
/// projection's flatness, so the picture at `GlobeProjection.flatZoom` is the
/// flat map's (the same tiles, no lighting or relief).
public final class GlobeRenderer: @unchecked Sendable {
    public let device: MTLDevice
    let queue: MTLCommandQueue
    let globePipeline: MTLRenderPipelineState
    let cloudPipeline: MTLRenderPipelineState
    let atmospherePipeline: MTLRenderPipelineState
    let skyPipeline: MTLRenderPipelineState
    let overDepthState: MTLDepthStencilState
    let depthState: MTLDepthStencilState
    let noDepthState: MTLDepthStencilState
    let baseSampler: MTLSamplerState
    let detailSampler: MTLSamplerState
    let heightSampler: MTLSamplerState
    let meshVertices: MTLBuffer
    let meshIndices: MTLBuffer
    let meshIndexCount: Int
    public let textures: GlobeTextures

    public static let colorFormat = MTLPixelFormat.bgra8Unorm
    public static let depthFormat = MTLPixelFormat.depth32Float
    public static let sampleCount = 4

    /// Nil without a Metal device (or when the shaders don't compile).
    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice(), map: MapRenderer?, data: GlobeData = .bundled()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: GlobeShaders.source, options: nil) } catch {
            NSLog("Globe shaders: %@", "\(error)")
            return nil
        }
        func pipeline(_ vertex: String, _ fragment: String, blend: Bool, vertexDescriptor: MTLVertexDescriptor? = nil) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.vertexDescriptor = vertexDescriptor
            d.rasterSampleCount = Self.sampleCount
            d.colorAttachments[0].pixelFormat = Self.colorFormat
            d.depthAttachmentPixelFormat = Self.depthFormat
            if blend {
                // Premultiplied colours added over what is there
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .one
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one
                c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float2
        vd.attributes[0].offset = 0
        vd.attributes[0].bufferIndex = 0
        vd.layouts[0].stride = MemoryLayout<SIMD2<Float>>.stride
        guard let globe = pipeline("globeVertex", "globeFragment", blend: false, vertexDescriptor: vd),
              let clouds = pipeline("cloudVertex", "cloudFragment", blend: true, vertexDescriptor: vd),
              let atmosphere = pipeline("screenVertex", "atmosphereFragment", blend: true),
              let sky = pipeline("screenVertex", "skyFragment", blend: true) else { return nil }
        globePipeline = globe
        cloudPipeline = clouds
        atmospherePipeline = atmosphere
        skyPipeline = sky
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .less
        depth.isDepthWriteEnabled = true
        let none = MTLDepthStencilDescriptor()
        none.depthCompareFunction = .always
        none.isDepthWriteEnabled = false
        let over = MTLDepthStencilDescriptor()
        over.depthCompareFunction = .lessEqual
        over.isDepthWriteEnabled = false
        guard let ds = device.makeDepthStencilState(descriptor: depth), let nds = device.makeDepthStencilState(descriptor: none),
              let ods = device.makeDepthStencilState(descriptor: over) else { return nil }
        depthState = ds
        noDepthState = nds
        overDepthState = ods
        func sampler(repeatX: Bool, mip: Bool) -> MTLSamplerState? {
            let s = MTLSamplerDescriptor()
            s.minFilter = .linear
            s.magFilter = .linear
            s.mipFilter = mip ? .linear : .notMipmapped
            s.sAddressMode = repeatX ? .repeat : .clampToEdge
            s.tAddressMode = .clampToEdge
            s.maxAnisotropy = mip ? 8 : 1
            return device.makeSamplerState(descriptor: s)
        }
        guard let bs = sampler(repeatX: true, mip: true), let dts = sampler(repeatX: false, mip: true),
              let hs = sampler(repeatX: true, mip: false) else { return nil }
        baseSampler = bs
        detailSampler = dts
        heightSampler = hs

        // The mesh: longitudes −180 ... 180 from its middle (`meshMiddle`), latitudes −90 ... 90, a degree apart
        let columns = 360, rows = 180
        var vertices: [SIMD2<Float>] = []
        vertices.reserveCapacity((columns + 1) * (rows + 1))
        for j in 0...rows {
            for i in 0...columns { vertices.append(SIMD2(Float(i - columns / 2), Float(90 - j))) }
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(columns * rows * 6)
        for j in 0..<rows {
            for i in 0..<columns {
                let a = UInt32(j * (columns + 1) + i), b = a + 1, c = a + UInt32(columns + 1), d = c + 1
                indices += [a, c, b, b, c, d]
            }
        }
        guard let vb = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<SIMD2<Float>>.stride),
              let ib = device.makeBuffer(bytes: indices, length: indices.count * 4) else { return nil }
        meshVertices = vb
        meshIndices = ib
        meshIndexCount = indices.count

        textures = GlobeTextures(device: device, queue: queue, map: map, data: data)
    }

    /// The longitude the mesh is laid out from (−180 … 180 degrees around
    /// it): the whole degree nearest the centre. Its vertices lie on whole
    /// degrees of the Earth whatever the centre, so a vertex keeps its height
    /// while the globe turns; only the one seam on the far side moves.
    static func meshMiddle(forCenterLongitude longitude: Double) -> Double {
        (longitude.isFinite ? longitude : 0).rounded()
    }

    func uniforms(for scene: GlobeScene) -> GlobeUniforms {
        let projection = scene.projection
        let t = projection.flatness
        let fr = projection.frame
        func f4(_ v: SIMD3<Double>, _ w: Double = 0) -> SIMD4<Float> { SIMD4(Float(v.x), Float(v.y), Float(v.z), Float(w)) }
        let sunVector = GlobeGeometry.unitVector(Astronomy.subsolarPoint(at: scene.date))
        let m = Astronomy.celestialToEarth(at: scene.date)
        var starMatrix = matrix_identity_float4x4
        for c in 0..<3 { for r in 0..<3 { starMatrix[c][r] = Float(m[c][r]) } }
        let heights = textures.heightTexture
        let mapTiles = textures.mapTiles(dark: scene.dark)
        let satTiles = textures.satelliteTiles
        let palette = MapPalette.appearance(dark: scene.dark)
        func color(_ c: MapColor) -> SIMD4<Float> { SIMD4(Float(c.red), Float(c.green), Float(c.blue), 1) }
        let k = scene.reliefFactor
        let distance = simd_length(fr.position)
        let anchor = Self.meshMiddle(forCenterLongitude: scene.camera.center.longitude)
        return GlobeUniforms(
            viewport: SIMD4(Float(scene.size.width), Float(scene.size.height), Float(projection.radius), Float(t)),
            center: SIMD4(Float(scene.camera.center.latitude * .pi / 180), Float(scene.camera.center.longitude * .pi / 180),
                          Float(projection.worldSize), Float(GlobeGeometry.mercatorY(scene.camera.center.latitude))),
            camPos: f4(fr.position, projection.perspective), camForward: f4(fr.forward, fr.focal),
            camRight: f4(fr.right, max(1e-4, (distance - 1.2) * 0.5)), camUp: f4(fr.up, distance + 2),
            orthoRight: f4(fr.flatRight), orthoUp: f4(fr.flatUp), orthoToward: f4(fr.flatToward),
            sun: f4(sunVector, scene.lighting ? 1 : 0),
            relief: SIMD4(Float(k), Float(max(1, k * 0.15)), scene.exaggerated ? 14 : 4, heights == nil ? 0 : 1),
            mapTiles: SIMD4(mapTiles == nil ? 0 : 1, Float(GlobeTilePlan.mapFinest), Float(GlobeTilePlan.mapLevels), 0),
            sky: SIMD4(Float(scene.skyOpacity), Float((1 - t) * (1 - t)), Float(scene.cloudOpacity), textures.lightsTexture == nil ? 0 : 1),
            heightTexel: SIMD4(heights.map { 1 / Float($0.width) } ?? 0, heights.map { 1 / Float($0.height) } ?? 0, scene.dark ? 1 : 0,
                               textures.satelliteBaseTexture == nil ? 0 : 1),
            satTiles: SIMD4(satTiles == nil ? 0 : 1, Float(GlobeTilePlan.satelliteLevels), 0, 0),
            mesh: SIMD4(Float(anchor), Float(anchor - scene.camera.center.longitude), 0, 0),
            northColor: color(palette.water), southColor: color(palette.glacier),
            starMatrix: starMatrix)
    }

    /// Encodes the picture into a render pass whose colour and depth
    /// attachments are set (multisampled, `sampleCount`): the sky, the
    /// globe, the clouds, then the air and the Sun over both.
    public func encode(_ scene: GlobeScene, pass: MTLRenderPassDescriptor, into buffer: MTLCommandBuffer) {
        let s = GlobeScene.space
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = scene.transparent ? MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            : MTLClearColor(red: s.red, green: s.green, blue: s.blue, alpha: 1)
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var u = uniforms(for: scene)
        let size = MemoryLayout<GlobeUniforms>.stride
        encoder.setVertexBytes(&u, length: size, index: 1)
        encoder.setFragmentBytes(&u, length: size, index: 1)
        encoder.setDepthStencilState(noDepthState)
        if let sky = textures.skyTexture, u.sky.x > 0.001, !scene.transparent {
            encoder.setRenderPipelineState(skyPipeline)
            encoder.setFragmentTexture(sky, index: 0)
            encoder.setFragmentSamplerState(baseSampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.setDepthStencilState(depthState)
        encoder.setRenderPipelineState(globePipeline)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(meshVertices, offset: 0, index: 0)
        let heights = textures.heightTexture ?? textures.blank
        encoder.setVertexTexture(heights, index: 0)
        encoder.setVertexSamplerState(heightSampler, index: 0)
        encoder.setFragmentTexture(textures.base(dark: scene.dark) ?? textures.placeholder(dark: scene.dark), index: 0)
        let mapTiles = textures.mapTiles(dark: scene.dark), satTiles = textures.satelliteTiles
        encoder.setFragmentTexture(mapTiles?.slots ?? textures.blankArray, index: 1)
        encoder.setFragmentTexture(heights, index: 2)
        encoder.setFragmentTexture(textures.lightsTexture ?? textures.blank, index: 3)
        encoder.setFragmentTexture(textures.satelliteBaseTexture ?? textures.blank, index: 4)
        encoder.setFragmentTexture(satTiles?.slots ?? textures.blankArray, index: 5)
        encoder.setFragmentTexture(mapTiles?.index ?? textures.blankIndex, index: 6)
        encoder.setFragmentTexture(satTiles?.index ?? textures.blankIndex, index: 7)
        encoder.setFragmentSamplerState(baseSampler, index: 0)
        encoder.setFragmentSamplerState(detailSampler, index: 1)
        encoder.setFragmentSamplerState(heightSampler, index: 2)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: meshIndexCount, indexType: .uint32, indexBuffer: meshIndices, indexBufferOffset: 0)
        if let clouds = textures.cloudsTexture, u.sky.z > 0.001 {
            encoder.setDepthStencilState(overDepthState)
            encoder.setRenderPipelineState(cloudPipeline)
            encoder.setFragmentTexture(clouds, index: 0)
            encoder.setFragmentSamplerState(baseSampler, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: meshIndexCount, indexType: .uint32, indexBuffer: meshIndices, indexBufferOffset: 0)
        }
        if u.sky.y > 0.001 {
            encoder.setDepthStencilState(noDepthState)
            encoder.setRenderPipelineState(atmospherePipeline)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
    }

    /// Render targets for an offscreen picture of `width` × `height` pixels.
    func offscreenPass(width: Int, height: Int) -> (MTLRenderPassDescriptor, MTLTexture)? {
        func texture(_ format: MTLPixelFormat, samples: Int, usage: MTLTextureUsage, storage: MTLStorageMode) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.textureType = samples > 1 ? .type2DMultisample : .type2D
            d.sampleCount = samples
            d.usage = usage
            d.storageMode = storage
            return device.makeTexture(descriptor: d)
        }
        guard let msaa = texture(Self.colorFormat, samples: Self.sampleCount, usage: .renderTarget, storage: .private),
              let resolve = texture(Self.colorFormat, samples: 1, usage: [.renderTarget, .shaderRead], storage: .shared),
              let depth = texture(Self.depthFormat, samples: Self.sampleCount, usage: .renderTarget, storage: .private) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = msaa
        pass.colorAttachments[0].resolveTexture = resolve
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.depthAttachment.texture = depth
        return (pass, resolve)
    }

    /// The picture as an image of the scene's size × `scale` pixels (for
    /// tests and snapshots), and the GPU's time for it in seconds.
    public func snapshot(_ scene: GlobeScene, scale: CGFloat = 2) -> (image: CGImage, gpuSeconds: Double)? {
        let w = Int(scene.size.width * scale), h = Int(scene.size.height * scale)
        guard w > 0, h > 0, let (pass, resolve) = offscreenPass(width: w, height: h), let buffer = queue.makeCommandBuffer() else { return nil }
        encode(scene, pass: pass, into: buffer)
        buffer.commit()
        buffer.waitUntilCompleted()
        guard buffer.status == .completed else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        resolve.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        if scene.transparent {
            // The Sun's glare adds light without covering (premultiplied colour above its alpha), and
            // an image takes a pixel without coverage for empty: it covers as much as it shines
            for i in stride(from: 0, to: bytes.count, by: 4) {
                bytes[i + 3] = max(bytes[i + 3], bytes[i], bytes[i + 1], bytes[i + 2])
            }
        }
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: MapColor.sRGB,
                                  bitmapInfo: (scene.transparent ? CGImageAlphaInfo.premultipliedFirst : .noneSkipFirst).rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue),
              let image = ctx.makeImage() else { return nil }
        return (image, buffer.gpuEndTime - buffer.gpuStartTime)
    }

    /// The GPU's time for `frames` pictures of the scene at `scale`, each
    /// on its own (the median, seconds).
    public func frameTime(_ scene: GlobeScene, scale: CGFloat = 2, frames: Int = 15) -> Double? {
        let w = Int(scene.size.width * scale), h = Int(scene.size.height * scale)
        guard let (pass, _) = offscreenPass(width: w, height: h) else { return nil }
        var times: [Double] = []
        for k in 0..<frames {
            guard let buffer = queue.makeCommandBuffer() else { return nil }
            var s = scene
            // A slightly different view each time, as while turning
            s.camera.center.longitude += Double(k) * 0.7
            encode(s, pass: pass, into: buffer)
            buffer.commit()
            buffer.waitUntilCompleted()
            times.append(buffer.gpuEndTime - buffer.gpuStartTime)
        }
        return times.sorted()[times.count / 2]
    }
}

/// The globe's textures: the map's tiles as a world texture per palette
/// (zoom 3 at 2×, 4096 px square, made once off the main thread) and its
/// tiles at zoom 4 … 6 (`mapTiles`, 512 px each, in a `TileAtlas` of
/// `mapCapacity`), the heightmap (in km as half floats; the bundled one or
/// the placeholder from the map), the city lights, the night sky, the
/// clouds and the satellite picture (`SatelliteTiles`: the whole world at
/// 2700 × 1350, and its tiles of 1350 px, 45° from level 1 and 22.5° from
/// level 2, in a `TileAtlas` of `satelliteCapacity`). Which tiles a view
/// needs is worked out off the main thread from the view itself
/// (`GlobeTilePlan`), with the cameras ahead of a throw or a drag; each
/// tile is made once and kept until its place is needed, so turning the
/// globe makes only the tiles coming into view, and those ahead of the
/// motion before they arrive. With the satellite picture the map's own
/// textures are made only once the globe starts to flatten. `didChange`
/// reports a texture that became ready.
public final class GlobeTextures: @unchecked Sendable {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let map: MapRenderer?
    private let lock = NSLock()
    private var bases: [Bool: MTLTexture] = [:]
    private var basesRunning: Set<Bool> = []
    private var mapAtlases: [Bool: TileAtlas] = [:]
    private var satelliteAtlas: TileAtlas?
    private var heights: MTLTexture?
    private var lights: MTLTexture?
    private var skyMap: MTLTexture?
    private var cloudMap: MTLTexture?
    private var satelliteBase: MTLTexture?
    let satellite: SatelliteTiles?
    var cloudsTexture: MTLTexture? { lock.withLock { cloudMap } }
    var satelliteBaseTexture: MTLTexture? { lock.withLock { satelliteBase } }
    var heightTexture: MTLTexture? { lock.withLock { heights } }
    var lightsTexture: MTLTexture? { lock.withLock { lights } }
    var skyTexture: MTLTexture? { lock.withLock { skyMap } }
    private var heightsRunning = false
    private var placeholders: [Bool: MTLTexture] = [:]
    let blank: MTLTexture
    /// Bound where no tile atlas is (a texture array of one black pixel, an index of one empty entry)
    let blankArray: MTLTexture
    let blankIndex: MTLTexture
    let work = DispatchQueue(label: "Globe textures", qos: .userInitiated, attributes: .concurrent)
    /// Posted on the main queue when a texture is ready (every view of a shared renderer draws again)
    public static let didChange = Notification.Name("GlobeTexturesDidChange")

    public static let baseZoom = 3
    public static let baseScale = 2
    /// How many satellite tiles are kept (1350 px with mipmaps, 9.7 MB each: 233 MB)
    static let satelliteCapacity = 24
    /// How many map tiles are kept per palette (512 px with mipmaps, 1.4 MB each: 90 MB)
    static let mapCapacity = 64

    /// What a plan depends on (not the time: the Sun doesn't change which tiles a view needs)
    struct PlanKey: Equatable {
        var camera: MapCamera
        var size: CGSize
        var lens: Double
        var dark: Bool
        var ahead: [MapCamera]
        init(_ scene: GlobeScene, ahead: [MapCamera]) {
            camera = scene.camera
            size = scene.size
            lens = scene.lens
            dark = scene.dark
            self.ahead = ahead
        }
        func isSameView(_ other: PlanKey) -> Bool {
            camera == other.camera && size == other.size && lens == other.lens && dark == other.dark
        }
    }
    private let planQueue = DispatchQueue(label: "Globe tile plans", qos: .userInitiated)
    /// The plans made last, the newest last (a view asked for again finds its plan)
    private var plans: [(key: PlanKey, plan: GlobeTilePlan.Plan)] = []
    private var planWaiting: (key: PlanKey, scene: GlobeScene)?
    private var planning = false

    init(device: MTLDevice, queue: MTLCommandQueue, map: MapRenderer?, data: GlobeData) {
        self.device = device
        self.queue = queue
        self.map = map
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: 1, height: 1, mipmapped: false)
        blank = device.makeTexture(descriptor: d)!
        var zero: UInt16 = 0
        blank.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 2)
        let a = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: GlobeRenderer.colorFormat, width: 1, height: 1, mipmapped: false)
        a.textureType = .type2DArray
        a.arrayLength = 1
        blankArray = device.makeTexture(descriptor: a)!
        var black: UInt32 = 0
        blankArray.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, slice: 0, withBytes: &black, bytesPerRow: 4, bytesPerImage: 4)
        let i = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Uint, width: 1, height: 1, mipmapped: false)
        blankIndex = device.makeTexture(descriptor: i)!
        blankIndex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 2)
        if let heightmap = data.heightmap { heights = Self.texture(device: device, heightmap: heightmap) }
        if let image = data.cityLights { lights = Self.texture(device: device, grey: image) }
        if let image = data.sky { skyMap = Self.texture(device: device, queue: queue, colour: image) }
        if let image = data.clouds { cloudMap = Self.texture(device: device, queue: queue, colour: image) }
        satellite = data.satellite
        if let image = data.satellite?.image(named: "base") { satelliteBase = Self.texture(device: device, queue: queue, colour: image) }
    }

    /// Whether the map's own textures are needed: always without the satellite picture, else once the globe flattens.
    static func needsMap(_ scene: GlobeScene, satellite: Bool) -> Bool {
        !satellite || scene.projection.flatness > 0
    }

    func base(dark: Bool) -> MTLTexture? { lock.withLock { bases[dark] } }

    /// The map's tiles of the palette (nil until the first is wanted).
    func mapTiles(dark: Bool) -> TileAtlas? { lock.withLock { mapAtlases[dark] } }

    /// The satellite picture's tiles (nil until the first is wanted).
    var satelliteTiles: TileAtlas? { lock.withLock { satelliteAtlas } }

    /// One pixel of the palette's land colour until the world texture is made.
    func placeholder(dark: Bool) -> MTLTexture {
        lock.withLock {
            if let t = placeholders[dark] { return t }
            let c = MapPalette.appearance(dark: dark).land
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: GlobeRenderer.colorFormat, width: 1, height: 1, mipmapped: false)
            let t = device.makeTexture(descriptor: d)!
            var px: [UInt8] = [UInt8(c.blue * 255), UInt8(c.green * 255), UInt8(c.red * 255), 255]
            t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
            placeholders[dark] = t
            return t
        }
    }

    /// The plan made for the view (nil while it is being made).
    func plan(for scene: GlobeScene) -> GlobeTilePlan.Plan? {
        let key = PlanKey(scene, ahead: [])
        return lock.withLock { plans.last { $0.key.isSameView(key) }?.plan }
    }

    /// Whether everything the scene needs is made: the world textures, and
    /// every tile of the view itself (not the margin's or those ahead).
    public func isReady(for scene: GlobeScene) -> Bool {
        let key = PlanKey(scene, ahead: [])
        let (plan, satTiles, mapTiles, ready): (GlobeTilePlan.Plan?, TileAtlas?, TileAtlas?, Bool) = lock.withLock {
            let plan = plans.last { $0.key.isSameView(key) }?.plan
            guard map != nil else { return (plan, satelliteAtlas, nil, true) }
            guard heights != nil else { return (plan, nil, nil, false) }
            let ready = !Self.needsMap(scene, satellite: satelliteBase != nil) || bases[scene.dark] != nil
            return (plan, satelliteAtlas, mapAtlases[scene.dark], ready)
        }
        guard ready else { return false }
        guard let plan else { return satellite == nil && map == nil }
        if !plan.satelliteRequired.isEmpty, !(satTiles?.has(plan.satelliteRequired) ?? false) { return false }
        if !plan.mapRequired.isEmpty, !(mapTiles?.has(plan.mapRequired) ?? false) { return false }
        return true
    }

    /// Starts making what the scene needs and isn't there (off the calling
    /// thread), and the tiles of the cameras `ahead` (where the view is
    /// moving) after the view's own.
    public func prepare(for scene: GlobeScene, ahead: [MapCamera] = []) {
        let dark = scene.dark
        let key = PlanKey(scene, ahead: ahead)
        lock.lock()
        let mapWanted = map != nil && Self.needsMap(scene, satellite: satelliteBase != nil)
        let needBase = mapWanted && bases[dark] == nil && !basesRunning.contains(dark)
        if needBase { basesRunning.insert(dark) }
        // Only the palette shown keeps its textures (each world texture is about 90 MB)
        bases[!dark] = nil
        mapAtlases[!dark] = nil
        let needHeights = map != nil && heights == nil && !heightsRunning
        if needHeights { heightsRunning = true }
        let planned = plans.last { $0.key == key }?.plan
        if planned == nil {
            planWaiting = (key, scene)
        }
        let startPlanning = planned == nil && !planning
        if startPlanning { planning = true }
        lock.unlock()
        if let planned { request(planned, dark: dark) }
        if startPlanning { planQueue.async { [weak self] in self?.makePlans() } }
        guard let map else { return }
        if needBase {
            let began = Date()
            work.async { [weak self] in
                guard let self else { return }
                let texture = self.makeTiles(map: map, zoom: Self.baseZoom, x0: 0, y0: 0, count: 1 << Self.baseZoom, scale: Self.baseScale, dark: dark)
                MapMotion.trace?(String(format: "globe: world texture made in %.0f ms", Date().timeIntervalSince(began) * 1000))
                self.lock.withLock {
                    self.basesRunning.remove(dark)
                    if let texture { self.bases[dark] = texture }
                }
                self.changed()
            }
        }
        if needHeights {
            work.async { [weak self] in
                guard let self else { return }
                let heightmap = Heightmap.placeholder(from: map)
                let texture = Self.texture(device: self.device, heightmap: heightmap)
                self.lock.withLock {
                    self.heightsRunning = false
                    if self.heights == nil { self.heights = texture }
                }
                self.changed()
            }
        }
    }

    /// Makes the plan asked for last, then the one asked for meanwhile, and so on (on `planQueue`).
    private func makePlans() {
        while true {
            let next: (key: PlanKey, scene: GlobeScene)? = lock.withLock {
                guard let w = planWaiting else { planning = false; return nil }
                planWaiting = nil
                return w
            }
            guard let (key, scene) = next else { return }
            let mapWanted = map != nil && Self.needsMap(scene, satellite: satelliteBase != nil)
            let plan = GlobeTilePlan.plan(for: scene, ahead: key.ahead, satellite: satellite != nil, map: mapWanted,
                                          satelliteCapacity: Self.satelliteCapacity, mapCapacity: Self.mapCapacity)
            lock.withLock {
                plans.removeAll { $0.key == key }
                plans.append((key, plan))
                if plans.count > 8 { plans.removeFirst(plans.count - 8) }
            }
            request(plan, dark: scene.dark)
        }
    }

    /// Hands the plan's tiles to the atlases (made when first needed).
    private func request(_ plan: GlobeTilePlan.Plan, dark: Bool) {
        var sat: TileAtlas?, mapTiles: TileAtlas?
        if !plan.satellite.isEmpty, let satellite {
            sat = lock.withLock {
                if satelliteAtlas == nil {
                    satelliteAtlas = TileAtlas(device: device, queue: queue, side: 1350, capacity: Self.satelliteCapacity,
                                               columns: GlobeTilePlan.satelliteColumns, rows: GlobeTilePlan.satelliteRows,
                                               levels: GlobeTilePlan.satelliteLevels, concurrency: 4, name: "Globe satellite tiles",
                                               make: { key in Self.drawSatelliteTile(key, from: satellite) },
                                               changed: { [weak self] in self?.changed() })
                }
                return satelliteAtlas
            }
        }
        if !plan.map.isEmpty, let map {
            mapTiles = lock.withLock {
                if mapAtlases[dark] == nil {
                    let palette = MapPalette.appearance(dark: dark)
                    mapAtlases[dark] = TileAtlas(device: device, queue: queue, side: GlobeTilePlan.mapTileSide, capacity: Self.mapCapacity,
                                                 columns: 1 << GlobeTilePlan.mapFinest, rows: 1 << GlobeTilePlan.mapFinest,
                                                 levels: GlobeTilePlan.mapLevels, concurrency: max(2, ProcessInfo.processInfo.activeProcessorCount - 2),
                                                 name: "Globe map tiles", make: { key in Self.drawMapTile(key, map: map, palette: palette) },
                                                 changed: { [weak self] in self?.changed() })
                }
                return mapAtlases[dark]
            }
        }
        sat?.request(plan.satellite)
        mapTiles?.request(plan.map)
    }

    /// A satellite tile (level 1 or 2 of the tile pack) as the atlas keeps it.
    static func drawSatelliteTile(_ key: TileAtlas.Key, from satellite: SatelliteTiles) -> CGContext? {
        let level = GlobeTilePlan.satelliteLevels - key.level
        guard let tile = satellite.image(named: "\(level)-\(key.y)-\(key.x)"), let ctx = MapRenderer.context(width: 1350, height: 1350) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(tile, in: CGRect(x: 0, y: 0, width: 1350, height: 1350))
        return ctx
    }

    /// A map tile (zoom `mapFinest` − level) at 2×.
    static func drawMapTile(_ key: TileAtlas.Key, map: MapRenderer, palette: MapPalette) -> CGContext? {
        let side = GlobeTilePlan.mapTileSide, scale = side / 256
        guard let ctx = MapRenderer.context(width: side, height: side) else { return nil }
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        ctx.translateBy(x: 0, y: 256)
        ctx.scaleBy(x: 1, y: -1)
        map.drawTile(TileKey(z: GlobeTilePlan.mapFinest - key.level, x: key.x, y: key.y), in: ctx, palette: palette, tolerance: 0.5 / Double(scale))
        return ctx
    }

    /// Makes everything the scene needs and waits for it (tests, snapshots).
    public func prepareAndWait(for scene: GlobeScene, timeout: Double = 60) {
        let end = Date().addingTimeInterval(timeout)
        while !isReady(for: scene), Date() < end {
            prepare(for: scene)
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    private func changed() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    /// count × count tiles of a zoom from (x0, y0) drawn into one texture
    /// with mipmaps, the tiles in parallel.
    private func makeTiles(map: MapRenderer, zoom: Int, x0: Int, y0: Int, count: Int, scale: Int, dark: Bool) -> MTLTexture? {
        let side = 256 * scale
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: GlobeRenderer.colorFormat, width: side * count, height: side * count, mipmapped: true)
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        let palette = MapPalette.appearance(dark: dark)
        let n = 1 << zoom
        DispatchQueue.concurrentPerform(iterations: count * count) { k in
            let tx = k % count, ty = k / count
            guard let ctx = MapRenderer.context(width: side, height: side) else { return }
            ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            ctx.translateBy(x: 0, y: 256)
            ctx.scaleBy(x: 1, y: -1)
            map.drawTile(TileKey(z: zoom, x: ((x0 + tx) % n + n) % n, y: y0 + ty), in: ctx, palette: palette, tolerance: 0.5 / Double(scale))
            guard let data = ctx.data else { return }
            texture.replace(region: MTLRegionMake2D(tx * side, ty * side, side, side), mipmapLevel: 0, withBytes: data, bytesPerRow: ctx.bytesPerRow)
        }
        guard let buffer = queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() else { return texture }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        return texture
    }

    /// The heightmap in kilometres as half floats.
    static func texture(device: MTLDevice, heightmap: Heightmap) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: heightmap.width, height: heightmap.height, mipmapped: false)
        d.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        let km = heightmap.metres.map { Float16(Float($0) / 1000) }
        km.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, heightmap.width, heightmap.height), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: heightmap.width * 2)
        }
        return texture
    }

    /// A colour picture (the sky) as a texture with mipmaps.
    static func texture(device: MTLDevice, queue: MTLCommandQueue, colour image: CGImage) -> MTLTexture? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= 16_384, h <= 16_384, let ctx = MapRenderer.context(width: w, height: h) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: GlobeRenderer.colorFormat, width: w, height: h, mipmapped: true)
        d.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: d), let data = ctx.data else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: ctx.bytesPerRow)
        if let buffer = queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
        }
        return texture
    }

    /// A grey picture (city lights) as a single-channel texture.
    static func texture(device: MTLDevice, grey image: CGImage) -> MTLTexture? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= 16_384, h <= 16_384,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: d), let data = ctx.data else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w)
        return texture
    }
}
