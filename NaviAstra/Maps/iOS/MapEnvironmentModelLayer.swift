#if os(iOS)
import MapLibre
import MetalKit
import OSLog
import simd

/// Indexed source models are expanded once, then instanced in the map's camera.
/// A depth-only pass of observed buildings preserves occlusion across native and
/// custom geometry. Labels and the route retain their existing overlay pass.
final class MapEnvironmentModelLayer: MLNCustomStyleLayer {
    static let layerID = MapEnvironmentStyle.prefix + "external-models"
    private struct Instance {
        var origin: SIMD4<Float>
        var scale: SIMD4<Float>
        var rotation: SIMD4<Float>
        var roof: SIMD4<Float>
    }
    private struct Batch {
        let id: String
        let vertices: MTLBuffer
        let instances: MTLBuffer
        let vertexCount: Int
        let instanceCount: Int
    }
    private let lock = NSLock()
    private let logger = Logger(subsystem: "NaviAstra", category: "EnvironmentModels")
    private var device: MTLDevice?
    private var pipeline: MTLRenderPipelineState?
    private var wallPipeline: MTLRenderPipelineState?
    private var roofPipeline: MTLRenderPipelineState?
    private var depth: MTLDepthStencilState?
    private var meshBuffers: [String: MTLBuffer] = [:]
    private var batches: [Batch] = []
    private var walls: MTLBuffer?
    private var roofs: MTLBuffer?
    private var geometry = BuildingFacadeMesh()
    private var lighting = SIMD4<Float>(0, 0, 0, 0)
    private var ready = false
    private var key = ""
    private var lastDrawLog = 0.0
    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return ready }

    func updateVisibility(settings: MapSettings, dark: Bool) {
        lock.lock()
        let next = SIMD4<Float>(dark ? 1 : 0, settings.overlays.poi ? 1 : 0, settings.overlays.buildings3D ? 1 : 0, 0)
        let changed = lighting != next
        lighting = next
        lock.unlock()
        if changed { setNeedsDisplay() }
    }

    @MainActor func update(on map: MLNMapView, instances: [MapEnvironmentModelInstance],
                           occluders: [MLNFeature], dark: Bool) -> Bool {
        guard let device, isReady else { return false }
        guard !instances.isEmpty else { clear(); return true }
        let geometry = BuildingMeshGenerator.make(features: occluders, map: map, heightKey: "_top", baseKey: "_base")
        let next = "\(geometry.origin):\(geometry.signature):\(dark):" + instances.map {
            "\($0.key):\($0.mesh.id):\($0.pose.key):\($0.base):\(String(describing: $0.roofColor))"
        }.joined(separator: "|")
        guard key != next else { return true }
        var groups: [String: [(MapEnvironmentMesh, Instance)]] = [:]
        for model in instances {
            let p = BuildingMeshGenerator.mercator(model.pose.coordinate)
            var delta = p - geometry.origin; delta.x -= delta.x.rounded()
            let origin = delta * geometry.metersPerWorld
            let angle = model.pose.bearing * .pi / 180
            let scale = model.pose.scale
            let roof = model.roofColor ?? SIMD3<Float>(0.43, 0.39, 0.35)
            let instance = Instance(origin: SIMD4(Float(origin.x), Float(origin.y), Float(model.base), 1),
                scale: SIMD4(Float(scale.x), Float(scale.y), Float(scale.z), 0),
                rotation: SIMD4(Float(cos(angle)), Float(sin(angle)), model.isTree ? 1 : 0, model.isBuilding ? 1 : 0),
                roof: SIMD4(roof, 1))
            groups[model.mesh.id, default: []].append((model.mesh, instance))
        }
        func buffer<T>(_ values: [T]) -> MTLBuffer? {
            guard !values.isEmpty else { return nil }
            return values.withUnsafeBytes { bytes in
                bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: bytes.count, options: .storageModeShared) }
            }
        }
        var batches: [Batch] = []
        for id in groups.keys.sorted() {
            guard let group = groups[id], let mesh = group.first?.0 else { continue }
            if meshBuffers[id] == nil { meshBuffers[id] = buffer(mesh.vertices) }
            guard let vertices = meshBuffers[id], let instances = buffer(group.map(\.1)) else {
                logger.error("Brak pamięci dla modelu otoczenia: \(id, privacy: .public)")
                clear(); return false
            }
            batches.append(Batch(id: id, vertices: vertices, instances: instances,
                vertexCount: mesh.vertices.count, instanceCount: group.count))
        }
        let walls = buffer(geometry.walls), roofs = buffer(geometry.roofs)
        guard geometry.walls.isEmpty || walls != nil, geometry.roofs.isEmpty || roofs != nil else {
            clear(); return false
        }
        lock.lock()
        self.batches = batches; self.geometry = geometry; self.walls = walls; self.roofs = roofs
        lighting.x = dark ? 1 : 0
        key = next
        lock.unlock()
        setNeedsDisplay()
        return true
    }

    func clear() {
        lock.lock()
        let changed = !batches.isEmpty || !key.isEmpty
        batches = []; walls = nil; roofs = nil; key = ""
        lock.unlock()
        if changed { setNeedsDisplay() }
    }

    override func didMove(to mapView: MLNMapView) {
        super.didMove(to: mapView)
        let resource = mapView.backendResource()
        guard let device = resource.device else { return }
        self.device = device
        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            func make(_ vertex: String, fragment: String?) throws -> MTLRenderPipelineState {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.label = "NaviAstra — modele otoczenia Kenney"
                descriptor.vertexFunction = library.makeFunction(name: vertex)
                descriptor.fragmentFunction = fragment.flatMap { library.makeFunction(name: $0) }
                descriptor.colorAttachments[0].pixelFormat = resource.mtkView.colorPixelFormat
                descriptor.colorAttachments[0].writeMask = fragment == nil ? [] : .all
                let format = resource.mtkView.depthStencilPixelFormat
                descriptor.depthAttachmentPixelFormat = format
                descriptor.stencilAttachmentPixelFormat = format == .depth32Float_stencil8 ? format : .invalid
                descriptor.rasterSampleCount = max(1, resource.mtkView.sampleCount)
                return try device.makeRenderPipelineState(descriptor: descriptor)
            }
            pipeline = try make("environmentVertex", fragment: "environmentFragment")
            wallPipeline = try make("environmentWall", fragment: nil)
            roofPipeline = try make("environmentRoof", fragment: nil)
            let descriptor = MTLDepthStencilDescriptor()
            descriptor.depthCompareFunction = .lessEqual; descriptor.isDepthWriteEnabled = true
            depth = device.makeDepthStencilState(descriptor: descriptor)
            lock.lock(); ready = depth != nil; lock.unlock()
        } catch {
            logger.error("Nie udało się przygotować modeli otoczenia: \(error.localizedDescription, privacy: .private)")
        }
    }

    override func draw(in mapView: MLNMapView, with context: MLNStyleLayerDrawingContext) {
        guard let encoder = renderEncoder, let pipeline, let wallPipeline, let roofPipeline, let depth else { return }
        lock.lock()
        let batches = self.batches, geometry = self.geometry, walls = self.walls, roofs = self.roofs
        var lighting = self.lighting
        lock.unlock()
        guard !batches.isEmpty else { return }
        // Match native extrusions' near plane; the flat-map projection uses a
        // different depth range and can hide an otherwise submitted 3D model.
        var matrix = MapBuildingFacadeLayer.localMatrix(context.nearClippedProjectionMatrix, mesh: geometry,
            zoom: context.zoomLevel, longitude: context.centerCoordinate.longitude)
        if let target = renderPassDesc?.colorAttachments[0].texture {
            encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(target.width),
                height: Double(target.height), znear: 0, zfar: 1))
            encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: target.width, height: target.height))
        }
        encoder.setDepthStencilState(depth); encoder.setCullMode(.none)
        encoder.setDepthBias(0, slopeScale: 0, clamp: 0)
        encoder.setVertexBytes(&matrix, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        // The same projection and depth are used for imported models and occluders.
        if let walls, !geometry.walls.isEmpty {
            encoder.setRenderPipelineState(wallPipeline); encoder.setVertexBuffer(walls, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: geometry.walls.count)
        }
        if let roofs, !geometry.roofs.isEmpty {
            encoder.setRenderPipelineState(roofPipeline); encoder.setVertexBuffer(roofs, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: geometry.roofs.count)
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&lighting, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        for batch in batches {
            encoder.setVertexBuffer(batch.vertices, offset: 0, index: 0)
            encoder.setVertexBuffer(batch.instances, offset: 0, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: batch.vertexCount, instanceCount: batch.instanceCount)
        }
        #if DEBUG
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastDrawLog >= 10 {
            lastDrawLog = now
            let counts = batches.map { "\($0.id)=\($0.instanceCount)" }.joined(separator: ", ")
            print("Zewnętrzne modele Metal — rysowanie: \(counts); widoczność POI=\(lighting.y), budynki=\(lighting.z)")
        }
        #endif
    }

    override func willMove(from mapView: MLNMapView) {
        lock.lock(); ready = false; batches = []; walls = nil; roofs = nil; key = ""; lock.unlock()
        meshBuffers = [:]; pipeline = nil; wallPipeline = nil; roofPipeline = nil; depth = nil; device = nil
        super.willMove(from: mapView)
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct ModelVertex { float4 position; float4 normal; float4 color; };
    struct ModelInstance { float4 origin; float4 scale; float4 rotation; float4 roof; };
    struct ModelOut { float4 position [[position]]; float3 normal; float3 color; float height; float tree [[flat]]; float building [[flat]]; float3 roof [[flat]]; };
    float4 environmentClip(float4 p) { p.z = (p.z + p.w) * 0.5; return p; }
    vertex ModelOut environmentVertex(uint v [[vertex_id]], uint i [[instance_id]],
        const device ModelVertex *vertices [[buffer(0)]], constant float4x4 &matrix [[buffer(1)]],
        const device ModelInstance *instances [[buffer(2)]]) {
        ModelVertex point = vertices[v]; ModelInstance instance = instances[i];
        float3 p = point.position.xyz * instance.scale.xyz;
        float c = instance.rotation.x, s = instance.rotation.y;
        float3 world = float3(c*p.x + s*p.y, s*p.x - c*p.y, p.z) + instance.origin.xyz;
        float3 n = point.normal.xyz / max(instance.scale.xyz, float3(0.001));
        ModelOut out; out.position = environmentClip(matrix * float4(world, 1));
        out.normal = normalize(float3(c*n.x + s*n.y, s*n.x - c*n.y, n.z));
        out.color = point.color.rgb; out.height = point.position.z; out.tree = instance.rotation.z; out.building = instance.rotation.w;
        out.roof = instance.roof.rgb;
        return out;
    }
    fragment float4 environmentFragment(ModelOut in [[stage_in]], constant float4 &lighting [[buffer(0)]]) {
        if (in.tree < 0.5 && ((in.building > 0.5 && lighting.z < 0.5) || (in.building < 0.5 && lighting.y < 0.5))) discard_fragment();
        float diffuse = max(0.0, dot(normalize(in.normal), normalize(float3(-0.4, -0.55, 0.8))));
        float ambient = mix(0.66, 0.34, lighting.x);
        float shade = ambient + diffuse * mix(0.34, 0.16, lighting.x);
        float3 color = in.color;
        // A muted palette fits the map. Facets and branches remain source geometry.
        if (in.tree > 0.5) {
            float green = step(color.r * 1.2, color.g);
            color = mix(color, float3(0.30, 0.49, 0.25), green * 0.65);
            shade *= mix(0.77, 1.0, smoothstep(0.0, 0.7, in.height));
        }
        if (in.building > 0.5 && color.g > color.r * 1.35 && color.g > color.b * 1.05 && in.height > 0.28) {
            color = in.roof;
        }
        return float4(color * shade, 1);
    }
    struct Wall { float4 origin; float4 edge; float4 layout; float4 light; float4 spill; };
    constant float2 corners[6] = {float2(0,0), float2(1,0), float2(1,1), float2(0,0), float2(1,1), float2(0,1)};
    vertex float4 environmentWall(uint v [[vertex_id]], uint i [[instance_id]],
        const device Wall *walls [[buffer(0)]], constant float4x4 &matrix [[buffer(1)]]) {
        Wall wall = walls[i]; float2 uv = corners[v];
        return environmentClip(matrix * float4(wall.origin.xy + wall.edge.xy * uv.x,
            mix(wall.origin.z, wall.origin.w, uv.y), 1));
    }
    vertex float4 environmentRoof(uint v [[vertex_id]], const device float4 *vertices [[buffer(0)]],
        constant float4x4 &matrix [[buffer(1)]]) { return environmentClip(matrix * vertices[v]); }
    """
}
#endif
