#if os(iOS)
import MapLibre
import MetalKit
import SwiftUI
import simd
import OSLog

extension RoadSignSymbol {
    var hasModelArtwork: Bool {
        switch self { case .unknown, .trafficSignal: false; default: true }
    }
}

struct MapSignFace {
    let pose: MapObjectPose
    let symbol: RoadSignSymbol
    let key: String
    var verticalOffset = 0.0
}

/// True vertical textured faces, projected by MapLibre's camera and tested
/// against native scene depth. Existing accessible road annotations remain intact.
final class MapSignFaceLayer: MLNCustomStyleLayer {
    static let layerID = MapEnvironmentStyle.prefix + "sign-faces"
    private struct Vertex { var position: SIMD4<Float>; var uv: SIMD2<Float>; var padding = SIMD2<Float>(repeating: 0) }
    private let lock = NSLock()
    private let logger = Logger(subsystem: "NaviAstra", category: "SignFaces")
    private var ready = false
    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return ready }
    private var vertices: [Vertex] = []
    private var mesh = BuildingFacadeMesh()
    private var atlas: CGImage?
    private var revision = 0
    private var uploaded = -1
    private var key = ""
    private var imagesBySymbol: [String: UIImage] = [:]
    private var atlasKey = ""
    private var atlasRevision = 0
    private var uploadedAtlas = -1
    private var buffer: MTLBuffer?
    private var texture: MTLTexture?
    private var pipeline: MTLRenderPipelineState?
    private var depth: MTLDepthStencilState?
    private var device: MTLDevice?

    @MainActor func update(on map: MLNMapView, faces: [MapSignFace]) {
        let faces = Array(faces.prefix(MapDetailPolicy.constrained ? 16 : 48))
        let next = faces.map { $0.key + $0.pose.key + String(describing: $0.symbol) + String($0.verticalOffset) }.joined(separator: "|")
        guard key != next else { return }
        key = next
        var geometry = BuildingMeshGenerator.make(features: [], map: map, heightKey: "_top", baseKey: "_base")
        geometry.walls = []; geometry.roofs = []
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1024, height: 1024), format: format)
        var cells: [String: Int] = [:], images: [UIImage] = []
        for face in faces {
            let id = String(describing: face.symbol)
            guard cells[id] == nil else { continue }
            if let cached = imagesBySymbol[id] {
                cells[id] = images.count; images.append(cached); continue
            }
            let view = RoadSignView(symbol: face.symbol, size: 112).environment(\.locale, Locale(identifier: "pl_PL"))
            let image = ImageRenderer(content: view); image.scale = 1
            guard let rendered = image.uiImage else { continue }
            imagesBySymbol[id] = rendered
            cells[id] = images.count; images.append(rendered)
        }
        let nextAtlasKey = cells.sorted { $0.value < $1.value }.map(\.key).joined(separator: "|")
        let changedAtlas = nextAtlasKey != atlasKey
        let atlas = changedAtlas ? renderer.image { _ in
            for (i, image) in images.enumerated() {
                image.draw(in: CGRect(x: (i % 8) * 128 + 4, y: (i / 8) * 128 + 4, width: 120, height: 120))
            }
        }.cgImage : self.atlas
        atlasKey = nextAtlasKey
        if imagesBySymbol.count > 96 { imagesBySymbol = imagesBySymbol.filter { cells[$0.key] != nil } }
        var output: [Vertex] = []
        for face in faces {
            guard let cell = cells[String(describing: face.symbol)] else { continue }
            let origin = (BuildingMeshGenerator.mercator(face.pose.coordinate) - geometry.origin) * geometry.metersPerWorld
            let uvOrigin = SIMD2<Float>(Float(cell % 8) / 8, Float(cell / 8) / 8)
            // Artwork is placed just in front of the neutral backing, in meters.
            for uv in [SIMD2<Double>(0, 1), SIMD2(1, 1), SIMD2(1, 0), SIMD2(0, 1), SIMD2(1, 0), SIMD2(0, 0)] {
                let xy = face.pose.horizontal(SIMD2((uv.x - 0.5) * 0.70, 0.047))
                let z = (2.01 + face.verticalOffset + (1 - uv.y) * 0.70) * face.pose.scale.z
                output.append(Vertex(position: SIMD4(Float(origin.x + xy.x), Float(origin.y - xy.y), Float(z), 1),
                                     uv: uvOrigin + SIMD2(Float(uv.x), Float(uv.y)) / 8))
            }
        }
        lock.lock(); vertices = output; mesh = geometry; self.atlas = atlas; if changedAtlas { atlasRevision &+= 1 }; revision &+= 1; lock.unlock()
        setNeedsDisplay()
    }

    override func didMove(to mapView: MLNMapView) {
        super.didMove(to: mapView)
        let resource = mapView.backendResource()
        guard let device = resource.device else { return }
        self.device = device
        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "signVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "signFragment")
            descriptor.colorAttachments[0].pixelFormat = resource.mtkView.colorPixelFormat
            let format = resource.mtkView.depthStencilPixelFormat
            descriptor.depthAttachmentPixelFormat = format
            descriptor.stencilAttachmentPixelFormat = format == .depth32Float_stencil8 ? format : .invalid
            descriptor.rasterSampleCount = max(1, resource.mtkView.sampleCount)
            let color = descriptor.colorAttachments[0]!
            color.isBlendingEnabled = true
            color.sourceRGBBlendFactor = .one; color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.sourceAlphaBlendFactor = .one; color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            let state = MTLDepthStencilDescriptor(); state.depthCompareFunction = .lessEqual; state.isDepthWriteEnabled = false
            depth = device.makeDepthStencilState(descriptor: state)
            lock.lock(); ready = pipeline != nil && depth != nil; lock.unlock()
            setNeedsDisplay()
        } catch {
            pipeline = nil
            logger.error("Nie udało się przygotować tarcz znaków: \(error.localizedDescription, privacy: .private)")
        }
    }

    override func draw(in mapView: MLNMapView, with context: MLNStyleLayerDrawingContext) {
        guard let device, let encoder = renderEncoder, let pipeline, let depth else { return }
        lock.lock(); let vertices = self.vertices, mesh = self.mesh, atlas = self.atlas, revision = self.revision, atlasRevision = self.atlasRevision; lock.unlock()
        guard !vertices.isEmpty else { return }
        if uploaded != revision {
            buffer = vertices.withUnsafeBytes { bytes in
                bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: bytes.count, options: .storageModeShared) }
            }
            uploaded = revision
        }
        if uploadedAtlas != atlasRevision {
            texture = atlas.flatMap { try? MTKTextureLoader(device: device).newTexture(cgImage: $0,
                options: [.SRGB: false, .generateMipmaps: true]) }
            uploadedAtlas = atlasRevision
        }
        guard let buffer, let texture else { return }
        var matrix = MapBuildingFacadeLayer.localMatrix(context.projectionMatrix, mesh: mesh,
            zoom: context.zoomLevel, longitude: context.centerCoordinate.longitude)
        encoder.setRenderPipelineState(pipeline); encoder.setDepthStencilState(depth)
        encoder.setCullMode(.none); encoder.setDepthBias(0, slopeScale: 0, clamp: 0)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&matrix, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
    }

    override func willMove(from mapView: MLNMapView) {
        lock.lock(); ready = false; lock.unlock()
        buffer = nil; texture = nil; pipeline = nil; depth = nil; device = nil; uploaded = -1; uploadedAtlas = -1
        super.willMove(from: mapView)
    }
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct SignVertex { float4 position; float2 uv; float2 padding; };
    struct SignOut { float4 position [[position]]; float2 uv; };
    vertex SignOut signVertex(uint id [[vertex_id]], constant SignVertex *v [[buffer(0)]], constant float4x4 &matrix [[buffer(1)]]) {
        SignOut o; o.position = matrix * v[id].position; o.uv = v[id].uv; return o;
    }
    fragment float4 signFragment(SignOut in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
        constexpr sampler s(coord::normalized, filter::linear, mip_filter::linear, address::clamp_to_edge);
        float4 color = atlas.sample(s, in.uv);
        if (color.a < 0.03) discard_fragment();
        return color;
    }
    """
}
#endif
