#if os(iOS)
import Foundation
import MapLibre
import MetalKit
import OSLog
import simd

struct MapStreetLampPlacement {
    let coordinate: CLLocationCoordinate2D
    let offset: SIMD3<Float>
}

/// Decorative light at real lamp locations: a luminous core, bloom and a pool
/// on the ground. A private building depth pass keeps light behind walls/roofs.
/// No inference about a particular lamp's operating state or measured luminance.
final class MapStreetLampLightLayer: MLNCustomStyleLayer {
    static let layerID = MapEnvironmentStyle.prefix + "street-lamp-light"
    private let logger = Logger(subsystem: "NaviAstra", category: "StreetLampLight")
    private let lock = NSLock()
    private var mesh = BuildingFacadeMesh()
    private var lamps: [SIMD4<Float>] = []
    private var signature = 0
    private var enabled = false
    private var intensity: Float = 0
    private var strength: Float = 1
    private var device: MTLDevice?
    private var library: MTLLibrary?
    private var wallPipeline: MTLRenderPipelineState?
    private var roofPipeline: MTLRenderPipelineState?
    private var haloPipeline: MTLRenderPipelineState?
    private var groundPipeline: MTLRenderPipelineState?
    private var compositePipeline: MTLRenderPipelineState?
    private var writeDepth: MTLDepthStencilState?
    private var readDepth: MTLDepthStencilState?
    private var noDepth: MTLDepthStencilState?
    private var wallsBuffer: MTLBuffer?
    private var roofsBuffer: MTLBuffer?
    private var lampsBuffer: MTLBuffer?
    private var uploadedSignature: Int?
    private var colorTarget: MTLTexture?
    private var depthTarget: MTLTexture?
    private var prepared = false
    private var failed = false
    private var lastGeometryUpdate = Date.distantPast
    private var geometryKey = ""

    func updateVisibility(on map: MLNMapView, settings: MapSettings, renderingEnabled: Bool) {
        let lighting = MapBuildingLighting.resolve(appearance: settings.appearance, coordinate: map.centerCoordinate)
        let visible = renderingEnabled && settings.overlays.poi && settings.cameraMode == .threeD
            && settings.baseMap != .satellite && map.zoomLevel >= MapStreetFurnitureRenderer.minimumZoom
        // Do not schedule a new frame for every fractional second of twilight.
        let nextIntensity = Float((lighting.intensity * 20).rounded() / 20)
        let nextStrength: Float = settings.context.isNavigating ? 0.65 : 1
        lock.lock()
        let changed = enabled != visible || intensity != nextIntensity || strength != nextStrength
        enabled = visible
        intensity = nextIntensity
        strength = nextStrength
        lock.unlock()
        if changed { setNeedsDisplay() }
    }

    func updateGeometry(on map: MLNMapView, lamps placements: [MapStreetLampPlacement], treeFeatures: [MLNFeature] = [], furnitureFeatures: [MLNFeature] = []) {
        lock.lock()
        let active = enabled && intensity > 0
        lock.unlock()
        guard active, let style = map.style else { return }
        if placements.isEmpty {
            geometryKey = ""
            lastGeometryUpdate = .distantPast
            lock.lock()
            let changed = !lamps.isEmpty
            lamps = []
            lock.unlock()
            if changed { setNeedsDisplay() }
            return
        }
        let constrained = MapDetailPolicy.constrained
        let boundedCoordinates = Array(placements.prefix(constrained ? 24 : 64))
        let key = MapDetailPolicy.viewportKey(on: map) + boundedCoordinates.map {
            ":\($0.coordinate.latitude):\($0.coordinate.longitude):\($0.offset)"
        }.joined() + furnitureFeatures.compactMap { $0.identifier.map(String.init(describing:)) }.joined(separator: ":") + treeFeatures.compactMap { $0.identifier.map(String.init(describing:)) }.joined(separator: ":")
        let elapsed = Date().timeIntervalSince(lastGeometryUpdate)
        // The matrix reprojects cached occluders every frame; rebuilding their
        // geometry need not run at the faster model/POI selection cadence.
        guard elapsed >= (constrained ? 1.5 : 0.8), key != geometryKey || elapsed >= 2 else { return }
        geometryKey = key
        lastGeometryUpdate = .now
        let buildingIDs = Set(style.layers.compactMap { layer -> String? in
            guard let body = layer as? MLNFillExtrusionStyleLayer, body.isVisible,
                  MapTilerEnvironmentStyle.isBuildingLayer(body),
                  !body.identifier.hasPrefix("naviastra-building-roof-color-") else { return nil }
            return body.identifier
        })
        // The common generator handles concave outlines and courtyard holes.
        let buildings = buildingIDs.isEmpty ? [] : map.visibleFeatures(in: map.bounds, styleLayerIdentifiers: buildingIDs)
        var updated = BuildingMeshGenerator.make(features: buildings, map: map, heightKey: "height", baseKey: "height_min")
        if !treeFeatures.isEmpty {
            // Reuse the generated crown/trunk parts rather than an opaque
            // bounding cylinder that would hide light in the gaps below a crown.
            let origin = updated.origin
            let nearest = treeFeatures.sorted {
                simd_length_squared(BuildingMeshGenerator.mercator($0.coordinate) - origin)
                    < simd_length_squared(BuildingMeshGenerator.mercator($1.coordinate) - origin)
            }.prefix(240)
            let trees = BuildingMeshGenerator.make(features: Array(nearest), map: map, heightKey: "_top", baseKey: "_base")
            updated.walls.append(contentsOf: trees.walls)
            updated.roofs.append(contentsOf: trees.roofs)
            var hash = Hasher()
            hash.combine(updated.signature)
            hash.combine(trees.signature)
            updated.signature = hash.finalize()
        }
        // Give opaque street objects their own budget; trees and buildings keep theirs.
        let nearestFurniture = furnitureFeatures.sorted {
            simd_length_squared(BuildingMeshGenerator.mercator($0.coordinate) - updated.origin)
                < simd_length_squared(BuildingMeshGenerator.mercator($1.coordinate) - updated.origin)
        }.prefix(constrained ? 80 : 200)
        if !nearestFurniture.isEmpty {
            let bodies = BuildingMeshGenerator.make(features: Array(nearestFurniture), map: map, heightKey: "_top", baseKey: "_base")
            updated.walls += bodies.walls
            updated.roofs += bodies.roofs
            var hash = Hasher(); hash.combine(updated.signature); hash.combine(bodies.signature)
            updated.signature = hash.finalize()
        }
        let updatedLamps = boundedCoordinates.map { placement -> SIMD4<Float> in
            var local = BuildingMeshGenerator.mercator(placement.coordinate) - updated.origin
            local.x -= local.x.rounded()
            local *= updated.metersPerWorld
            return SIMD4(Float(local.x) + placement.offset.x, Float(local.y) + placement.offset.y,
                         placement.offset.z, 0.8)
        }
        var hash = Hasher()
        hash.combine(updated.signature)
        for lamp in updatedLamps { hash.combine(lamp) }
        let nextSignature = hash.finalize()
        lock.lock()
        let changed = signature != nextSignature
        mesh = updated
        lamps = updatedLamps
        signature = nextSignature
        lock.unlock()
        if changed { setNeedsDisplay() }
    }

    override func didMove(to mapView: MLNMapView) {
        super.didMove(to: mapView)
        setup(on: mapView)
    }

    private func setup(on map: MLNMapView) {
        guard library == nil, !failed else { return }
        let resource = map.backendResource()
        guard let device = resource.device else { return }
        self.device = device
        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            self.library = library
            func pipeline(_ vertex: String, _ fragment: String?, mapTarget: Bool = false) throws -> MTLRenderPipelineState {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: vertex)
                descriptor.fragmentFunction = fragment.flatMap { library.makeFunction(name: $0) }
                descriptor.colorAttachments[0].pixelFormat = mapTarget ? resource.mtkView.colorPixelFormat : .bgra8Unorm
                let format = resource.mtkView.depthStencilPixelFormat
                descriptor.depthAttachmentPixelFormat = mapTarget ? format : .depth32Float
                descriptor.stencilAttachmentPixelFormat = mapTarget && format == .depth32Float_stencil8 ? format : .invalid
                descriptor.rasterSampleCount = mapTarget ? max(1, resource.mtkView.sampleCount) : 1
                let color = descriptor.colorAttachments[0]!
                color.writeMask = fragment == nil ? [] : .all
                color.isBlendingEnabled = fragment != nil
                color.sourceRGBBlendFactor = .one
                color.destinationRGBBlendFactor = .oneMinusSourceAlpha
                color.sourceAlphaBlendFactor = .one
                color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                return try device.makeRenderPipelineState(descriptor: descriptor)
            }
            wallPipeline = try pipeline("lampWallVertex", nil)
            roofPipeline = try pipeline("lampRoofVertex", nil)
            haloPipeline = try pipeline("lampHaloVertex", "lampHaloFragment")
            groundPipeline = try pipeline("lampGroundVertex", "lampGroundFragment")
            compositePipeline = try pipeline("lampCompositeVertex", "lampCompositeFragment", mapTarget: true)
            let depth = MTLDepthStencilDescriptor()
            depth.depthCompareFunction = .lessEqual
            depth.isDepthWriteEnabled = true
            writeDepth = device.makeDepthStencilState(descriptor: depth)
            depth.isDepthWriteEnabled = false
            readDepth = device.makeDepthStencilState(descriptor: depth)
            depth.depthCompareFunction = .always
            noDepth = device.makeDepthStencilState(descriptor: depth)
        } catch {
            failed = true
            logger.error("Nie udało się przygotować światła latarni: \(error.localizedDescription, privacy: .private)")
        }
    }

    override func preDraw(in mapView: MLNMapView, with context: MLNStyleLayerDrawingContext) {
        prepared = false
        lock.lock()
        let mesh = self.mesh, lamps = self.lamps, signature = self.signature
        let enabled = self.enabled, intensity = self.intensity, strength = self.strength
        lock.unlock()
        guard enabled, intensity > 0, context.zoomLevel >= MapStreetFurnitureRenderer.minimumZoom, !lamps.isEmpty else {
            colorTarget = nil
            depthTarget = nil
            return
        }
        setup(on: mapView)
        guard !failed, let device, let commandBuffer, let wallPipeline, let roofPipeline,
              let haloPipeline, let groundPipeline, let writeDepth, let readDepth else { return }
        let size = mapView.backendResource().mtkView.drawableSize
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        // At most 18 MiB for color/depth, independent of device resolution.
        let scale = min(1, 1_536 / max(size.width, size.height))
        let width = max(1, Int(size.width * scale)), height = max(1, Int(size.height * scale))
        if colorTarget?.width != width || colorTarget?.height != height {
            let color = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            color.storageMode = .private
            color.usage = [.renderTarget, .shaderRead]
            colorTarget = device.makeTexture(descriptor: color)
            let depth = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
            depth.storageMode = .private
            depth.usage = .renderTarget
            depthTarget = device.makeTexture(descriptor: depth)
        }
        if uploadedSignature != signature {
            func buffer<T>(_ values: [T]) -> MTLBuffer? {
                values.withUnsafeBytes { bytes in
                    bytes.baseAddress.flatMap { bytes.count > 0 ? device.makeBuffer(bytes: $0, length: bytes.count, options: .storageModeShared) : nil }
                }
            }
            wallsBuffer = buffer(mesh.walls)
            roofsBuffer = buffer(mesh.roofs)
            lampsBuffer = buffer(lamps)
            uploadedSignature = signature
        }
        guard let colorTarget, let depthTarget, let lampsBuffer else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colorTarget
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.depthAttachment.texture = depthTarget
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "NaviAstra — światło latarni i maska budynków"
        var matrix = MapBuildingFacadeLayer.localMatrix(context.projectionMatrix, mesh: mesh,
            zoom: context.zoomLevel, longitude: context.centerCoordinate.longitude)
        var lighting = SIMD4<Float>(Float(width), Float(height), intensity * strength,
                                    Float(min(1, max(0, context.zoomLevel - MapStreetFurnitureRenderer.minimumZoom))))
        encoder.setCullMode(.none)
        encoder.setVertexBytes(&matrix, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        encoder.setVertexBytes(&lighting, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
        encoder.setFragmentBytes(&lighting, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setDepthStencilState(writeDepth)
        if let wallsBuffer, !mesh.walls.isEmpty {
            encoder.setRenderPipelineState(wallPipeline)
            encoder.setVertexBuffer(wallsBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: mesh.walls.count)
        }
        if let roofsBuffer, !mesh.roofs.isEmpty {
            encoder.setRenderPipelineState(roofPipeline)
            encoder.setVertexBuffer(roofsBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.roofs.count)
        }
        encoder.setDepthStencilState(readDepth)
        encoder.setVertexBuffer(lampsBuffer, offset: 0, index: 0)
        encoder.setRenderPipelineState(groundPipeline)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: lamps.count)
        encoder.setRenderPipelineState(haloPipeline)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: lamps.count)
        encoder.endEncoding()
        prepared = true
    }

    override func draw(in mapView: MLNMapView, with context: MLNStyleLayerDrawingContext) {
        guard prepared, let renderEncoder, let compositePipeline, let noDepth, let colorTarget else { return }
        renderEncoder.setRenderPipelineState(compositePipeline)
        renderEncoder.setDepthStencilState(noDepth)
        renderEncoder.setCullMode(.none)
        renderEncoder.setDepthBias(0, slopeScale: 0, clamp: 0)
        renderEncoder.setFragmentTexture(colorTarget, index: 0)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    override func willMove(from mapView: MLNMapView) {
        prepared = false
        uploadedSignature = nil
        lastGeometryUpdate = .distantPast
        geometryKey = ""
        wallsBuffer = nil
        roofsBuffer = nil
        lampsBuffer = nil
        colorTarget = nil
        depthTarget = nil
        device = nil
        library = nil
        wallPipeline = nil
        roofPipeline = nil
        haloPipeline = nil
        groundPipeline = nil
        compositePipeline = nil
        writeDepth = nil
        readDepth = nil
        noDepth = nil
        failed = false
        super.willMove(from: mapView)
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Wall { float4 origin; float4 edge; float4 layout; float4 light; float4 spill; };
    struct LightOut { float4 position [[position]]; float2 uv; };
    constant float2 lampCorners[6] = {float2(0,0), float2(1,0), float2(1,1), float2(0,0), float2(1,1), float2(0,1)};
    float4 lampClip(float4 p) { p.z = (p.z + p.w) * 0.5; return p; }
    vertex float4 lampWallVertex(uint v [[vertex_id]], uint i [[instance_id]],
                                 const device Wall *walls [[buffer(0)]], constant float4x4 &matrix [[buffer(1)]]) {
        Wall wall = walls[i]; float2 uv = lampCorners[v];
        return lampClip(matrix * float4(wall.origin.xy + wall.edge.xy * uv.x,
            mix(wall.origin.z, wall.origin.w, uv.y), 1));
    }
    vertex float4 lampRoofVertex(uint v [[vertex_id]], const device float4 *vertices [[buffer(0)]],
                                 constant float4x4 &matrix [[buffer(1)]]) {
        return lampClip(matrix * vertices[v]);
    }
    vertex LightOut lampGroundVertex(uint v [[vertex_id]], uint i [[instance_id]],
        const device float4 *lamps [[buffer(0)]], constant float4x4 &matrix [[buffer(1)]]) {
        LightOut out; out.uv = lampCorners[v] * 2 - 1;
        out.position = lampClip(matrix * float4(lamps[i].xy + out.uv * float2(4.0, 5.0), 0.04, 1));
        return out;
    }
    vertex LightOut lampHaloVertex(uint v [[vertex_id]], uint i [[instance_id]],
        const device float4 *lamps [[buffer(0)]], constant float4x4 &matrix [[buffer(1)]],
        constant float4 &lighting [[buffer(2)]]) {
        float4 lamp = lamps[i];
        float4 center = lampClip(matrix * float4(lamp.xyz, 1));
        float4 edge = lampClip(matrix * float4(lamp.xyz + float3(lamp.w, 0, 0), 1));
        LightOut out; out.uv = lampCorners[v] * 2 - 1;
        if (center.w <= 0.001 || edge.w <= 0.001) { out.position = float4(2,2,2,1); return out; }
        float radius = clamp(length((edge.xy / edge.w - center.xy / center.w) * lighting.xy * 0.5), 3.0, 22.0);
        out.position = center;
        out.position.xy += out.uv * radius * 2 / lighting.xy * center.w;
        return out;
    }
    fragment float4 lampGroundFragment(LightOut in [[stage_in]], constant float4 &lighting [[buffer(0)]]) {
        float radius = length(in.uv);
        float alpha = exp(-dot(in.uv, in.uv) * 3.2) * (1 - smoothstep(0.75, 1.0, radius))
            * 0.26 * lighting.z * lighting.w;
        return float4(float3(1.0, 0.81, 0.49) * alpha, alpha);
    }
    fragment float4 lampHaloFragment(LightOut in [[stage_in]], constant float4 &lighting [[buffer(0)]]) {
        float radius = length(in.uv);
        float core = exp(-dot(in.uv, in.uv) * 90.0) * 0.95;
        float halo = exp(-dot(in.uv, in.uv) * 4.0) * 0.28;
        float alpha = min(0.96, core + halo) * (1 - smoothstep(0.75, 1.0, radius)) * lighting.z * lighting.w;
        float3 color = mix(float3(1.0, 0.79, 0.43), float3(1.0, 0.97, 0.83), core);
        return float4(color * alpha, alpha);
    }
    vertex LightOut lampCompositeVertex(uint v [[vertex_id]]) {
        LightOut out; out.position = float4(lampCorners[v] * 2 - 1, 1, 1);
        out.uv = float2(lampCorners[v].x, 1 - lampCorners[v].y); return out;
    }
    fragment float4 lampCompositeFragment(LightOut in [[stage_in]], texture2d<float> image [[texture(0)]]) {
        constexpr sampler sampleFilter(filter::linear, address::clamp_to_edge);
        return image.sample(sampleFilter, in.uv);
    }
    """
}
#endif
