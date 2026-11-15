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

    public init(camera: MapCamera, size: CGSize, dark: Bool = false, lighting: Bool = false, exaggerated: Bool = true, date: Date = Date()) {
        self.camera = camera
        self.size = size
        self.dark = dark
        self.lighting = lighting
        self.exaggerated = exaggerated
        self.date = date
    }

    public var projection: GlobeProjection { GlobeProjection(camera: camera, size: size) }

    /// How visible the night sky is: fully while the Earth is small in the
    /// view, gone once it fills it (and while the map flattens).
    public var skyOpacity: Double {
        let fill = 2 * projection.radius / Double(max(1, min(size.width, size.height)))
        let x = min(1, max(0, (fill - 0.9) / 0.7))
        return (1 - x * x * (3 - 2 * x)) * (1 - projection.flatness)
    }

    /// The colour of space behind the Earth (the same in both appearances).
    public static let space = MapColor("#04060b")
}

/// The CPU side of the shaders' `Uniforms` (GlobeShaders.swift): the same
/// fields in the same order, all 16-byte aligned.
struct GlobeUniforms {
    var viewport: SIMD4<Float>
    var center: SIMD4<Float>
    var basisE: SIMD4<Float>
    var basisN: SIMD4<Float>
    var basisU: SIMD4<Float>
    var sun: SIMD4<Float>
    var relief: SIMD4<Float>
    var detail: SIMD4<Float>
    var sky: SIMD4<Float>
    var heightTexel: SIMD4<Float>
    var northColor: SIMD4<Float>
    var southColor: SIMD4<Float>
    var starMatrix: simd_float4x4
}

/// Draws the globe with Metal: the map's own tiles (`MapRenderer`, the
/// light or dark palette) as the sphere's texture, Web Mercator sampled
/// directly (a world texture of zoom 3 at 2× and, from zoom 3 on, a detail
/// texture of 8 × 8 tiles around the centre at the zoom shown), the relief
/// from a heightmap (displacement in the vertex shader, hillshade in the
/// fragment shader), day and night by the Sun, the atmosphere's rim and the
/// night sky (`GlobeData.sky`, in right ascension and declination) turned by
/// the sidereal time and the precession, seen through a camera of 90°
/// along the view. The sphere is a mesh
/// of 360 × 180 cells in longitude from the centre and latitude; each vertex
/// is placed on the sphere and on the flat map and blended by the
/// projection's flatness, so the picture at `GlobeProjection.flatZoom` is the
/// flat map's (the same tiles, no lighting or relief).
public final class GlobeRenderer: @unchecked Sendable {
    public let device: MTLDevice
    let queue: MTLCommandQueue
    let globePipeline: MTLRenderPipelineState
    let glowPipeline: MTLRenderPipelineState
    let skyPipeline: MTLRenderPipelineState
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
    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice(), map: MapRenderer?, data: GlobeData = .shared) {
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
              let glow = pipeline("glowVertex", "glowFragment", blend: true),
              let sky = pipeline("skyVertex", "skyFragment", blend: true) else { return nil }
        globePipeline = globe
        glowPipeline = glow
        skyPipeline = sky
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .less
        depth.isDepthWriteEnabled = true
        let none = MTLDepthStencilDescriptor()
        none.depthCompareFunction = .always
        none.isDepthWriteEnabled = false
        guard let ds = device.makeDepthStencilState(descriptor: depth), let nds = device.makeDepthStencilState(descriptor: none) else { return nil }
        depthState = ds
        noDepthState = nds
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

        // The mesh: longitudes from the centre −180 ... 180, latitudes −90 ... 90, a degree apart
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

    func uniforms(for scene: GlobeScene) -> GlobeUniforms {
        let projection = scene.projection
        let t = projection.flatness
        let (e, n, u) = GlobeGeometry.basis(scene.camera.center)
        func f4(_ v: SIMD3<Double>, _ w: Double = 0) -> SIMD4<Float> { SIMD4(Float(v.x), Float(v.y), Float(v.z), Float(w)) }
        let sunVector = GlobeGeometry.unitVector(Astronomy.subsolarPoint(at: scene.date))
        let m = Astronomy.celestialToEarth(at: scene.date)
        var starMatrix = matrix_identity_float4x4
        for c in 0..<3 { for r in 0..<3 { starMatrix[c][r] = Float(m[c][r]) } }
        let heights = textures.heightTexture
        let detail = textures.detail(dark: scene.dark)
        let minSide = Double(max(1, min(scene.size.width, scene.size.height)))
        let palette = MapPalette.appearance(dark: scene.dark)
        func color(_ c: MapColor) -> SIMD4<Float> { SIMD4(Float(c.red), Float(c.green), Float(c.blue), 1) }
        return GlobeUniforms(
            viewport: SIMD4(Float(scene.size.width), Float(scene.size.height), Float(projection.radius), Float(t)),
            center: SIMD4(Float(scene.camera.center.latitude * .pi / 180), Float(scene.camera.center.longitude * .pi / 180),
                          Float(projection.worldSize), Float(GlobeGeometry.mercatorY(scene.camera.center.latitude))),
            basisE: f4(e), basisN: f4(n), basisU: f4(u),
            sun: f4(sunVector, scene.lighting ? 1 : 0),
            relief: SIMD4(scene.exaggerated ? 40 : 1, scene.exaggerated ? 6 : 1, scene.exaggerated ? 14 : 4, heights == nil ? 0 : 1),
            detail: detail.map { SIMD4(Float($0.x0), Float($0.y0), Float(1 << $0.zoom), 1) } ?? .zero,
            sky: SIMD4(Float(scene.skyOpacity), Float(minSide / 2 / tan(45 * Double.pi / 180)),
                       Float((1 - t) * (1 - t)), textures.lightsTexture == nil ? 0 : 1),
            heightTexel: SIMD4(heights.map { 1 / Float($0.width) } ?? 0, heights.map { 1 / Float($0.height) } ?? 0, scene.dark ? 1 : 0, 0),
            northColor: color(palette.water), southColor: color(palette.glacier),
            starMatrix: starMatrix)
    }

    /// Encodes the picture into a render pass whose colour and depth
    /// attachments are set (multisampled, `sampleCount`).
    public func encode(_ scene: GlobeScene, pass: MTLRenderPassDescriptor, into buffer: MTLCommandBuffer) {
        let s = GlobeScene.space
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: s.red, green: s.green, blue: s.blue, alpha: 1)
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var u = uniforms(for: scene)
        let size = MemoryLayout<GlobeUniforms>.stride
        encoder.setVertexBytes(&u, length: size, index: 1)
        encoder.setFragmentBytes(&u, length: size, index: 1)
        encoder.setDepthStencilState(noDepthState)
        if let sky = textures.skyTexture, u.sky.x > 0.001 {
            encoder.setRenderPipelineState(skyPipeline)
            encoder.setFragmentTexture(sky, index: 0)
            encoder.setFragmentSamplerState(baseSampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        if u.sky.z > 0.001 {
            encoder.setRenderPipelineState(glowPipeline)
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
        encoder.setFragmentTexture(textures.detail(dark: scene.dark)?.texture ?? textures.blank, index: 1)
        encoder.setFragmentTexture(heights, index: 2)
        encoder.setFragmentTexture(textures.lightsTexture ?? textures.blank, index: 3)
        encoder.setFragmentSamplerState(baseSampler, index: 0)
        encoder.setFragmentSamplerState(detailSampler, index: 1)
        encoder.setFragmentSamplerState(heightSampler, index: 2)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: meshIndexCount, indexType: .uint32, indexBuffer: meshIndices, indexBufferOffset: 0)
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
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: MapColor.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
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
/// (zoom 3 at 2×, 4096 px square, made once off the main thread), a detail
/// texture of 8 × 8 tiles around the centre at the zoom shown (made again
/// when the centre moves two tiles away or the zoom changes), the heightmap
/// (in km as half floats; the bundled one or the placeholder from the map),
/// the city lights and the night sky. `didChange` reports a texture that became ready.
public final class GlobeTextures: @unchecked Sendable {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let map: MapRenderer?
    private let lock = NSLock()
    private var bases: [Bool: MTLTexture] = [:]
    private var basesRunning: Set<Bool> = []
    private var details: [Bool: Detail] = [:]
    private var detailRunning: [Bool: DetailKey] = [:]
    private var heights: MTLTexture?
    private var lights: MTLTexture?
    private var skyMap: MTLTexture?
    var heightTexture: MTLTexture? { lock.withLock { heights } }
    var lightsTexture: MTLTexture? { lock.withLock { lights } }
    var skyTexture: MTLTexture? { lock.withLock { skyMap } }
    private var heightsRunning = false
    private var placeholders: [Bool: MTLTexture] = [:]
    let blank: MTLTexture
    let work = DispatchQueue(label: "Globe textures", qos: .userInitiated, attributes: .concurrent)
    /// Posted on the main queue when a texture is ready (every view of a shared renderer draws again)
    public static let didChange = Notification.Name("GlobeTexturesDidChange")

    public static let baseZoom = 3
    public static let baseScale = 2

    struct DetailKey: Equatable { var zoom, x0, y0: Int; var scale: Int }
    struct Detail { var key: DetailKey; var texture: MTLTexture; var zoom: Int { key.zoom }; var x0: Int { key.x0 }; var y0: Int { key.y0 } }

    init(device: MTLDevice, queue: MTLCommandQueue, map: MapRenderer?, data: GlobeData) {
        self.device = device
        self.queue = queue
        self.map = map
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: 1, height: 1, mipmapped: false)
        blank = device.makeTexture(descriptor: d)!
        var zero: UInt16 = 0
        blank.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 2)
        if let heightmap = data.heightmap { heights = Self.texture(device: device, heightmap: heightmap) }
        if let image = data.cityLights { lights = Self.texture(device: device, grey: image) }
        if let image = data.sky { skyMap = Self.texture(device: device, queue: queue, colour: image) }
    }

    func base(dark: Bool) -> MTLTexture? { lock.withLock { bases[dark] } }

    func detail(dark: Bool) -> Detail? { lock.withLock { details[dark] } }

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

    /// Whether everything the scene needs is made.
    public func isReady(for scene: GlobeScene) -> Bool {
        guard map != nil else { return true }
        return lock.withLock {
            guard bases[scene.dark] != nil, heights != nil else { return false }
            guard let wanted = Self.detailKey(for: scene) else { return true }
            return details[scene.dark]?.key == wanted
        }
    }

    /// Starts making what the scene needs and isn't there (off the calling thread).
    public func prepare(for scene: GlobeScene) {
        guard let map else { return }
        let dark = scene.dark
        lock.lock()
        let needBase = bases[dark] == nil && !basesRunning.contains(dark)
        if needBase { basesRunning.insert(dark) }
        // Only the palette shown keeps its textures (each world texture is about 90 MB)
        bases[!dark] = nil
        details[!dark] = nil
        let needHeights = heights == nil && !heightsRunning
        if needHeights { heightsRunning = true }
        var detailKey: DetailKey?
        if let wanted = Self.detailKey(for: scene), detailRunning[dark] == nil {
            if let have = details[dark]?.key, !Self.needsNewDetail(have: have, wanted: wanted) {} else {
                detailKey = wanted
                detailRunning[dark] = wanted
            }
        }
        lock.unlock()
        if needBase {
            work.async { [weak self] in
                guard let self else { return }
                let texture = self.makeTiles(map: map, zoom: Self.baseZoom, x0: 0, y0: 0, count: 1 << Self.baseZoom, scale: Self.baseScale, dark: dark)
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
        if let key = detailKey {
            work.async { [weak self] in
                guard let self else { return }
                let texture = self.makeTiles(map: map, zoom: key.zoom, x0: key.x0, y0: key.y0, count: 8, scale: key.scale, dark: dark)
                self.lock.withLock {
                    self.detailRunning[dark] = nil
                    if let texture { self.details[dark] = Detail(key: key, texture: texture) }
                }
                self.changed()
            }
        }
    }

    /// Makes everything the scene needs and waits for it (tests, snapshots).
    public func prepareAndWait(for scene: GlobeScene, timeout: Double = 60) {
        let end = Date().addingTimeInterval(timeout)
        while !isReady(for: scene), Date() < end {
            prepare(for: scene)
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private func changed() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    /// The detail texture a scene wants: 8 × 8 tiles of the zoom shown
    /// (rounded up, from 4 to the flat zoom's) around the centre; none
    /// below zoom 3, where the world texture is sharp enough.
    static func detailKey(for scene: GlobeScene) -> DetailKey? {
        let z = scene.camera.zoom
        guard z > Double(baseZoom) else { return nil }
        let projection = scene.projection
        let zoom = max(baseZoom + 1, min(Int(ceil(projection.flatZoom - 1e-9)), Int(ceil(z - 1e-9))))
        let n = 1 << zoom
        let u = WebMercator.unitPoint(scene.camera.center)
        let x0 = Int((Double(u.x) * Double(n)).rounded()) - 4
        let y0 = min(n - 8, max(0, Int((Double(u.y) * Double(n)).rounded()) - 4))
        return DetailKey(zoom: zoom, x0: ((x0 % n) + n) % n, y0: y0, scale: 2)
    }

    static func needsNewDetail(have: DetailKey, wanted: DetailKey) -> Bool {
        guard have.zoom == wanted.zoom, have.scale == wanted.scale else { return true }
        let n = 1 << have.zoom
        var dx = abs(have.x0 - wanted.x0) % n
        dx = min(dx, n - dx)
        return dx >= 2 || abs(have.y0 - wanted.y0) >= 2
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
