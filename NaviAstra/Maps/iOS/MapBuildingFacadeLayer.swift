#if os(iOS)
import Foundation
import MapLibre
import MetalKit
import OSLog
import simd

struct BuildingWallInstance {
    var origin: SIMD4<Float> // local x/y in meters, base, top
    var edge: SIMD4<Float> // local dx/dy, wall length, floor spacing
    var layout: SIMD4<Float> // window width/height, columns, floors
    var light: SIMD4<Float> // stable seed, probability, detail, eligible
    var spill: SIMD4<Float> // outward normal, ground width, ground-level facade
}

struct BuildingFacadeMesh {
    var origin = SIMD2<Double>(repeating: 0) // normalized Mercator, retained in double precision
    var metersPerWorld = 1.0
    var walls: [BuildingWallInstance] = []
    var roofs: [SIMD4<Float>] = []
    var signature = 0
}

/// One instance per wall. Window cells and soft halos are evaluated on the GPU,
/// so a tall building does not allocate a separate mesh for every window.
enum BuildingMeshGenerator {
    static let circumference = 40_075_016.68557849

    static func mercator(_ coordinate: CLLocationCoordinate2D) -> SIMD2<Double> {
        let latitude = min(85.05112878, max(-85.05112878, coordinate.latitude)) * .pi / 180
        return SIMD2((coordinate.longitude + 180) / 360,
                     (1 - log(tan(.pi / 4 + latitude / 2)) / .pi) / 2)
    }

    @MainActor private static var cache: [Int: BuildingFacadeMesh] = [:]

    @MainActor static func make(features: [MLNFeature], map: MLNMapView, heightKey: String, baseKey: String) -> BuildingFacadeMesh {
        var mesh = BuildingFacadeMesh()
        let center = mercator(map.centerCoordinate)
        mesh.origin = SIMD2((floor(center.x * 32_768) + 0.5) / 32_768,
                            (floor(center.y * 32_768) + 0.5) / 32_768)
        let latitude = atan(sinh(.pi * (1 - 2 * mesh.origin.y)))
        mesh.metersPerWorld = circumference * cos(latitude)
        var input = Hasher()
        input.combine(MapDetailPolicy.viewportKey(on: map))
        input.combine(heightKey); input.combine(baseKey)
        // Stable geometry keys also let the lamp mask reuse the facade mask.
        let identities = features.map { feature -> Int in
            var hash = Hasher()
            hash.combine(feature.identifier.map { String(describing: $0) } ?? "")
            for key in [heightKey, baseKey, "height", "render_height", "class", "subclass", "levels", "building:levels", "building:min_level"] {
                hash.combine(String(describing: feature.attributes[key] ?? ""))
            }
            let parts: [MLNPolygon]
            if let polygon = feature as? MLNPolygon { parts = [polygon] }
            else if let multi = feature as? MLNMultiPolygon { parts = multi.polygons }
            else { parts = [] }
            for polygon in parts {
                for ring in [polygon] + (polygon.interiorPolygons ?? []) {
                    for index in 0..<Int(ring.pointCount) {
                        hash.combine(ring.coordinates[index].latitude)
                        hash.combine(ring.coordinates[index].longitude)
                    }
                }
            }
            return hash.finalize()
        }.sorted()
        for identity in identities { input.combine(identity) }
        let inputKey = input.finalize()
        if let retained = cache[inputKey] { return retained }
        var seen = Set<String>()
        var signature = Hasher()
        signature.combine(mesh.origin.x)
        signature.combine(mesh.origin.y)
        let sorted = features.sorted { a, b in
            simd_length_squared(mercator(a.coordinate) - center)
                < simd_length_squared(mercator(b.coordinate) - center)
        }
        var detailedBuildings = 0
        for feature in sorted.prefix(240) {
            let attributes = feature.attributes
            func number(_ key: String) -> Double? {
                let value = (attributes[key] as? NSNumber)?.doubleValue
                    ?? (attributes[key] as? String).flatMap(Double.init)
                return value.flatMap { $0.isFinite ? $0 : nil }
            }
            // Match the native extrusion exactly; never fabricate missing geometry.
            guard let height = number(heightKey) ?? number("height") ?? number("render_height"),
                  height > 0, height <= 1_000 else { continue }
            let base = max(0, number(baseKey) ?? number("height_min") ?? number("render_min_height") ?? 0)
            guard base < height else { continue }
            let polygons: [MLNPolygon]
            if let polygon = feature as? MLNPolygon { polygons = [polygon] }
            else if let multi = feature as? MLNMultiPolygon { polygons = multi.polygons }
            else { continue }
            let facade = BuildingVisualResolver.facade(attributes: attributes)
            let levels = (number("building:levels") ?? number("levels")).flatMap {
                $0 > 0 && $0 <= 200 ? $0 : nil
            }
            let minimumLevel = max(0, min(200, number("building:min_level") ?? 0))
            let count = levels.map { Int(max(1, min(100, ($0 - minimumLevel).rounded(.down)))) }
                ?? max(1, min(100, Int(((height - base) / facade.floorHeight).rounded(.down))))
            let floorHeight = (height - base) / Double(count)
            var decorated = false
            for polygon in polygons.prefix(8) {
                let shapes = [polygon] + (polygon.interiorPolygons ?? [])
                guard shapes.allSatisfy({ $0.pointCount >= 4 && $0.pointCount <= 128 }),
                      shapes.reduce(0, { $0 + Int($1.pointCount) }) <= 256,
                      mesh.walls.count < 3_000, mesh.roofs.count < 90_000 else { continue }
                var rings: [[SIMD2<Double>]] = []
                var identityPoints: [String] = []
                for shape in shapes {
                    var ring: [SIMD2<Double>] = []
                    for index in 0..<Int(shape.pointCount) {
                        let coordinate = shape.coordinates[index]
                        guard CLLocationCoordinate2DIsValid(coordinate) else { continue }
                        var point = mercator(coordinate) - mesh.origin
                        point.x -= point.x.rounded() // nearest world copy at the antimeridian
                        point *= mesh.metersPerWorld
                        if let previous = ring.last, simd_distance(previous, point) < 0.02 { continue }
                        ring.append(point)
                        identityPoints.append("\(Int((coordinate.latitude * 1_000_000).rounded())):\(Int((coordinate.longitude * 1_000_000).rounded()))")
                    }
                    if let first = ring.first, let last = ring.last, simd_distance(first, last) < 0.02 { ring.removeLast() }
                    if ring.count >= 3 { rings.append(ring) }
                }
                guard let outer = rings.first else { continue }
                let geometryKey = identityPoints.sorted().joined(separator: ";") + ":\(height):\(base)"
                guard seen.insert(geometryKey).inserted else { continue }
                let identity = feature.identifier.map { String(describing: $0) } ?? geometryKey
                var seed: UInt64 = 14695981039346656037
                for byte in identity.utf8 { seed = (seed ^ UInt64(byte)) &* 1099511628211 }
                let center = outer.reduce(SIMD2<Double>(repeating: 0), +) / Double(outer.count)
                let screen = map.convert(polygon.coordinate, toPointTo: map)
                let radius = hypot(screen.x - map.bounds.midX, screen.y - map.bounds.midY)
                    / max(1, hypot(map.bounds.width, map.bounds.height) / 2)
                let projected = MapDetailPolicy.projectedSpan(at: polygon.coordinate, meters: 3, on: map)
                let detail = Float(max(0, min(1, (1.05 - radius) / 0.45))
                    * MapDetailPolicy.smooth(projected, from: 2, to: 6))
                let eligible = facade.hasWindows && height - base >= 3 && floorHeight >= 2.4
                    && (facade != .neutral || height - base >= 9)
                    && floorHeight >= Double(facade.windowHeight) + 0.9
                    && detailedBuildings < 90 && radius < 1.15
                    && detail > 0.02
                // All sampled buildings occlude, including those without window detail.
                for (ringIndex, ring) in rings.enumerated() {
                    let area = ring.indices.reduce(0.0) { sum, index in
                        let a = ring[index], b = ring[(index + 1) % ring.count]
                        return sum + a.x * b.y - b.x * a.y
                    }
                    let side = (area > 0 ? 1.0 : -1.0) * (ringIndex == 0 ? 1.0 : -1.0)
                    for index in ring.indices {
                        var a = ring[index]
                        var b = ring[(index + 1) % ring.count]
                        let originalEdge = b - a
                        let normal = SIMD2(originalEdge.y, -originalEdge.x) * side
                            / max(0.05, simd_length(originalEdge))
                        // Canonical direction avoids reseeding a wall when ring winding changes.
                        if a.x > b.x || (a.x == b.x && a.y > b.y) { swap(&a, &b) }
                        let edge = b - a
                        let length = simd_length(edge)
                        guard length > 0.05 else { continue }
                        let columns = max(0, Int((length - 1.4) / Double(facade.windowWidth + facade.gap)))
                        let wallSeed = (seed &+ UInt64(abs(Int(((a.x - center.x) * 10).rounded()))) &* 31
                            &+ UInt64(abs(Int(((a.y - center.y) * 10).rounded()))) &* 131) % 16_777_213
                        let windows = eligible && columns > 0 && length < 500
                        mesh.walls.append(BuildingWallInstance(
                            origin: SIMD4(Float(a.x), Float(a.y), Float(base), Float(height)),
                            edge: SIMD4(Float(edge.x), Float(edge.y), Float(length), Float(floorHeight)),
                            layout: SIMD4(facade.windowWidth, facade.windowHeight, Float(min(256, columns)), Float(count)),
                            light: SIMD4(Float(wallSeed), facade.litProbability, detail, windows ? 1 : 0),
                            spill: SIMD4(Float(normal.x), Float(normal.y), 1.5, base < 0.5 ? 1 : 0)))
                        decorated = decorated || windows
                    }
                }
                appendRoof(rings: rings, height: Float(height), to: &mesh.roofs)
            }
            if decorated { detailedBuildings += 1 }
        }
        for wall in mesh.walls {
            for vector in [wall.origin, wall.edge, wall.layout, wall.light, wall.spill] {
                for index in 0..<4 { signature.combine(vector[index]) }
            }
        }
        for vertex in mesh.roofs { for index in 0..<4 { signature.combine(vertex[index]) } }
        mesh.signature = signature.finalize()
        if cache.count >= 4 { cache.removeAll() }
        cache[inputKey] = mesh
        return mesh
    }

    /// Even-odd scanline tessellation preserves concave outlines and courtyard holes.
    /// Between adjacent vertex heights each intersection follows the same straight edge.
    private static func appendRoof(rings: [[SIMD2<Double>]], height: Float, to vertices: inout [SIMD4<Float>]) {
        let heights = Array(Set(rings.flatMap { $0.map(\.y) })).sorted()
        guard heights.count > 1 else { return }
        let edges = rings.flatMap { ring in ring.indices.map { (ring[$0], ring[($0 + 1) % ring.count]) } }
        for index in 0..<(heights.count - 1) {
            let bottom = heights[index], top = heights[index + 1], middle = (bottom + top) / 2
            guard top - bottom > 0.001 else { continue }
            let crossing = edges.filter { min($0.0.y, $0.1.y) < middle && max($0.0.y, $0.1.y) > middle }
            func x(_ edge: (SIMD2<Double>, SIMD2<Double>), _ y: Double) -> Double {
                edge.0.x + (edge.1.x - edge.0.x) * (y - edge.0.y) / (edge.1.y - edge.0.y)
            }
            let sorted = crossing.sorted { x($0, middle) < x($1, middle) }
            guard sorted.count.isMultiple(of: 2) else { continue }
            for pair in stride(from: 0, to: sorted.count, by: 2) {
                guard vertices.count + 6 <= 90_000 else { return }
                let left = sorted[pair], right = sorted[pair + 1]
                let a = SIMD4(Float(x(left, bottom)), Float(bottom), height, 1)
                let b = SIMD4(Float(x(right, bottom)), Float(bottom), height, 1)
                let c = SIMD4(Float(x(right, top)), Float(top), height, 1)
                let d = SIMD4(Float(x(left, top)), Float(top), height, 1)
                vertices.append(contentsOf: [a, b, c, a, c, d])
            }
        }
    }
}

/// Native buildings supply the body. This layer supplies only decorative facade
/// openings and restrained night lighting, composited below labels and route overlays.
/// A private depth pass prevents windows showing through roofs or other buildings
/// without relying on MapLibre's separate extrusion depth attachment.
final class MapBuildingFacadeLayer: MLNCustomStyleLayer {
    static let layerID = "naviastra-building-procedural-facades"
    private let logger = Logger(subsystem: "NaviAstra", category: "BuildingFacades")
    private let lock = NSLock()
    private var mesh = BuildingFacadeMesh()
    private var enabled = false
    private var intensity: Float = 0
    private var quiet = false
    private var dark = false
    private var navigating = false
    private var device: MTLDevice?
    private var library: MTLLibrary?
    private var wallDepthPipeline: MTLRenderPipelineState?
    private var roofDepthPipeline: MTLRenderPipelineState?
    private var facadePipeline: MTLRenderPipelineState?
    private var groundPipeline: MTLRenderPipelineState?
    private var compositePipeline: MTLRenderPipelineState?
    private var writeDepth: MTLDepthStencilState?
    private var readDepth: MTLDepthStencilState?
    private var noDepth: MTLDepthStencilState?
    private var wallsBuffer: MTLBuffer?
    private var roofsBuffer: MTLBuffer?
    private var uploadedSignature: Int?
    private var colorTarget: MTLTexture?
    private var depthTarget: MTLTexture?
    private var prepared = false
    private var failed = false

    func updateVisibility(on map: MLNMapView, settings: MapSettings, dark: Bool, renderingEnabled: Bool) {
        let lighting = MapBuildingLighting.resolve(appearance: settings.appearance, coordinate: map.centerCoordinate)
        lock.lock()
        let wasEnabled = enabled
        lock.unlock()
        let visible = renderingEnabled && settings.overlays.buildings3D && settings.cameraMode == .threeD
            && settings.baseMap != .satellite && map.zoomLevel >= (wasEnabled ? 17.2 : 17.5) && map.camera.pitch > (wasEnabled ? 30 : 35)
        lock.lock()
        let changed = enabled != visible || self.dark != dark || intensity != (dark ? Float((lighting.intensity * 20).rounded() / 20) : 0)
            || quiet != lighting.quiet || navigating != settings.context.isNavigating
        enabled = visible
        self.dark = dark
        intensity = dark ? Float((lighting.intensity * 20).rounded() / 20) : 0
        quiet = lighting.quiet
        navigating = settings.context.isNavigating
        lock.unlock()
        if changed { setNeedsDisplay() }
    }

    func updateGeometry(on map: MLNMapView, layerIDs: Set<String>, heightKey: String, baseKey: String) {
        lock.lock()
        let shouldUpdate = enabled
        lock.unlock()
        guard shouldUpdate else { return }
        let features = map.visibleFeatures(in: map.bounds, styleLayerIdentifiers: layerIDs)
        let updated = BuildingMeshGenerator.make(features: features, map: map, heightKey: heightKey, baseKey: baseKey)
        lock.lock()
        let changed = updated.signature != mesh.signature
        mesh = updated
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
        device = resource.device
        guard let device else { return }
        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            self.library = library
            func pipeline(vertex: String, fragment: String?, mapTarget: Bool = false) throws -> MTLRenderPipelineState {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: vertex)
                descriptor.fragmentFunction = fragment.flatMap { library.makeFunction(name: $0) }
                descriptor.colorAttachments[0].pixelFormat = mapTarget ? resource.mtkView.colorPixelFormat : .bgra8Unorm
                descriptor.depthAttachmentPixelFormat = mapTarget ? resource.mtkView.depthStencilPixelFormat : .depth32Float
                descriptor.stencilAttachmentPixelFormat = mapTarget ? resource.mtkView.depthStencilPixelFormat : .invalid
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
            wallDepthPipeline = try pipeline(vertex: "facadeVertex", fragment: nil)
            roofDepthPipeline = try pipeline(vertex: "roofVertex", fragment: nil)
            facadePipeline = try pipeline(vertex: "facadeVertex", fragment: "facadeFragment")
            groundPipeline = try pipeline(vertex: "groundVertex", fragment: "groundFragment")
            compositePipeline = try pipeline(vertex: "compositeVertex", fragment: "compositeFragment", mapTarget: true)
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
            logger.error("Nie udało się przygotować warstwy fasad: \(error.localizedDescription, privacy: .private)")
        }
    }

    override func willMove(from mapView: MLNMapView) {
        prepared = false
        wallsBuffer = nil
        roofsBuffer = nil
        colorTarget = nil
        depthTarget = nil
        library = nil
        device = nil
        wallDepthPipeline = nil
        roofDepthPipeline = nil
        facadePipeline = nil
        groundPipeline = nil
        compositePipeline = nil
        writeDepth = nil
        readDepth = nil
        noDepth = nil
        uploadedSignature = nil
        failed = false
        super.willMove(from: mapView)
    }

    override func preDraw(in mapView: MLNMapView, with context: MLNStyleLayerDrawingContext) {
        prepared = false
        lock.lock()
        let mesh = self.mesh, enabled = self.enabled, intensity = self.intensity
        let dark = self.dark, quiet = self.quiet, navigating = self.navigating
        lock.unlock()
        // MapLibre 6.29 passes pitch in radians through the native drawing context.
        guard enabled, context.zoomLevel >= 17.2, context.pitch > 30 * .pi / 180, !mesh.walls.isEmpty else {
            colorTarget = nil
            depthTarget = nil
            return
        }
        setup(on: mapView)
        guard let device, let commandBuffer, let wallDepthPipeline, let roofDepthPipeline, let facadePipeline,
              let writeDepth, let readDepth else { return }
        let resource = mapView.backendResource()
        let size = resource.mtkView.drawableSize
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        // Bound the two private attachments to at most 32 MiB even on large iPads.
        let targetScale = min(1, 2_048 / max(size.width, size.height))
        let width = max(1, Int(size.width * targetScale)), height = max(1, Int(size.height * targetScale))
        if colorTarget?.width != width || colorTarget?.height != height {
            let color = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            color.usage = [.renderTarget, .shaderRead]
            color.storageMode = .private
            colorTarget = device.makeTexture(descriptor: color)
            let depth = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
            depth.usage = .renderTarget
            depth.storageMode = .private
            depthTarget = device.makeTexture(descriptor: depth)
        }
        if uploadedSignature != mesh.signature {
            wallsBuffer = mesh.walls.withUnsafeBytes { bytes in
                bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: bytes.count, options: .storageModeShared) }
            }
            roofsBuffer = mesh.roofs.withUnsafeBytes { bytes in
                bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: bytes.count, options: .storageModeShared) }
            }
            uploadedSignature = mesh.signature
        }
        guard let colorTarget, let depthTarget, let wallsBuffer else { return }
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
        encoder.label = "NaviAstra — okna i maska budynków"
        var matrix = Self.localMatrix(context.projectionMatrix, mesh: mesh, zoom: context.zoomLevel,
                                      longitude: context.centerCoordinate.longitude)
        var lighting = SIMD4<Float>(dark ? 1 : 0, intensity * (quiet ? 0.55 : 1),
                                     navigating ? 0.55 : 1, Float(min(1, max(0, (context.zoomLevel - 17.2) / 0.8))
                                        * min(1, max(0, (context.pitch * 180 / .pi - 30) / 10))))
        encoder.setCullMode(.none)
        encoder.setVertexBytes(&matrix, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        encoder.setVertexBuffer(wallsBuffer, offset: 0, index: 0)
        encoder.setDepthStencilState(writeDepth)
        encoder.setRenderPipelineState(wallDepthPipeline)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: mesh.walls.count)
        if let roofsBuffer, !mesh.roofs.isEmpty {
            encoder.setRenderPipelineState(roofDepthPipeline)
            encoder.setVertexBuffer(roofsBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.roofs.count)
        }
        encoder.setDepthStencilState(readDepth)
        encoder.setDepthBias(-0.00001, slopeScale: 0, clamp: 0)
        encoder.setRenderPipelineState(facadePipeline)
        encoder.setVertexBuffer(wallsBuffer, offset: 0, index: 0)
        encoder.setFragmentBytes(&lighting, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: mesh.walls.count)
        if dark, intensity > 0, context.zoomLevel >= 18, let groundPipeline {
            encoder.setRenderPipelineState(groundPipeline)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: mesh.walls.count)
        }
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

    static func localMatrix(_ value: MLNMatrix4, mesh: BuildingFacadeMesh, zoom: Double,
                                    longitude: Double) -> simd_float4x4 {
        let projection = simd_double4x4(columns: (
            SIMD4(value.m00, value.m01, value.m02, value.m03),
            SIMD4(value.m10, value.m11, value.m12, value.m13),
            SIMD4(value.m20, value.m21, value.m22, value.m23),
            SIMD4(value.m30, value.m31, value.m32, value.m33)))
        let world = 512 * pow(2, zoom)
        let scale = world / mesh.metersPerWorld
        var originX = mesh.origin.x
        originX += (((longitude + 180) / 360) - originX).rounded()
        let local = simd_double4x4(columns: (
            SIMD4(scale, 0, 0, 0), SIMD4(0, scale, 0, 0), SIMD4(0, 0, 1, 0),
            SIMD4(originX * world, mesh.origin.y * world, 0, 1)))
        // Translate in double precision before converting local coordinates for Metal.
        let result = projection * local
        return simd_float4x4(columns: (SIMD4<Float>(result.columns.0), SIMD4<Float>(result.columns.1),
                                       SIMD4<Float>(result.columns.2), SIMD4<Float>(result.columns.3)))
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Wall { float4 origin; float4 edge; float4 layout; float4 light; float4 spill; };
    struct FacadeOut {
        float4 position [[position]];
        float2 meters;
        float4 layout [[flat]];
        float4 light [[flat]];
        float2 dimensions [[flat]];
    };
    constant float2 corners[6] = {float2(0,0), float2(1,0), float2(1,1), float2(0,0), float2(1,1), float2(0,1)};
    float4 clip(float4 p) { p.z = (p.z + p.w) * 0.5; return p; }
    vertex FacadeOut facadeVertex(uint v [[vertex_id]], uint i [[instance_id]],
                                  const device Wall *walls [[buffer(0)]], constant float4x4 &matrix [[buffer(1)]]) {
        Wall wall = walls[i]; float2 uv = corners[v];
        FacadeOut out;
        float h = wall.origin.w - wall.origin.z;
        out.position = clip(matrix * float4(wall.origin.xy + wall.edge.xy * uv.x, wall.origin.z + uv.y * h, 1));
        out.meters = float2(uv.x * wall.edge.z, uv.y * h);
        out.dimensions = float2(wall.edge.z, wall.edge.w);
        out.layout = wall.layout; out.light = wall.light;
        return out;
    }
    vertex float4 roofVertex(uint v [[vertex_id]], const device float4 *vertices [[buffer(0)]],
                             constant float4x4 &matrix [[buffer(1)]]) {
        return clip(matrix * vertices[v]);
    }
    vertex FacadeOut groundVertex(uint v [[vertex_id]], uint i [[instance_id]],
                                  const device Wall *walls [[buffer(0)]], constant float4x4 &matrix [[buffer(1)]]) {
        Wall wall = walls[i]; float2 uv = corners[v];
        FacadeOut out;
        out.position = clip(matrix * float4(wall.origin.xy + wall.edge.xy * uv.x + wall.spill.xy * uv.y * wall.spill.z, 0.03, 1));
        out.meters = uv; out.dimensions = float2(1);
        out.layout = wall.layout; out.light = wall.light;
        out.light.w *= wall.spill.w;
        return out;
    }
    fragment float4 groundFragment(FacadeOut in [[stage_in]], constant float4 &lighting [[buffer(0)]]) {
        if (in.light.w < 0.5 || in.light.z < 0.2) discard_fragment();
        float edgeFade = smoothstep(0.0, 0.12, in.meters.x) * smoothstep(0.0, 0.12, 1 - in.meters.x);
        float alpha = pow(1 - in.meters.y, 3.0) * edgeFade * in.light.y * in.light.z
            * lighting.y * lighting.z * 0.09;
        return float4(float3(1.0, 0.847, 0.659) * alpha, alpha);
    }
    uint hashCell(uint x) { x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; return x ^ (x >> 16); }
    fragment float4 facadeFragment(FacadeOut in [[stage_in]], constant float4 &lighting [[buffer(0)]]) {
        if (in.light.w < 0.5 || in.layout.z < 1) discard_fragment();
        float pitchX = (in.dimensions.x - 1.4) / in.layout.z;
        float2 grid = float2((in.meters.x - 0.7) / pitchX, in.meters.y / in.dimensions.y);
        int2 cell = int2(floor(grid));
        if (cell.x < 0 || cell.x >= int(in.layout.z) || cell.y < 0 || cell.y >= int(in.layout.w)) discard_fragment();
        float2 relative = float2((fract(grid.x) - 0.5) * pitchX,
                                 fract(grid.y) * in.dimensions.y - 0.8 - in.layout.y * 0.5);
        float2 distance = abs(relative) - in.layout.xy * 0.5;
        float aa = max(0.025, max(fwidth(relative.x), fwidth(relative.y)));
        float opening = 1 - smoothstep(-aa, aa, max(distance.x, distance.y));
        uint seed = hashCell(uint(in.light.x) ^ (uint(cell.x) * 73856093u) ^ (uint(cell.y) * 19349663u));
        bool lit = float(seed & 65535u) / 65535.0 < in.light.y * mix(0.6, 1.0, lighting.y) && lighting.y > 0;
        float halo = lit ? exp(-dot(max(distance, float2(0)), max(distance, float2(0))) / 0.12) * 0.045 * lighting.y * in.light.z : 0;
        float3 warm = float3(1.0, 0.847, 0.659);
        float3 neutral = float3(0.953, 0.914, 0.824);
        float3 cool = float3(0.867, 0.906, 1.0);
        float3 lamp = (seed % 9u == 0u) ? cool : ((seed % 3u == 0u) ? neutral : warm);
        float variation = 0.75 + float((seed >> 16) & 255u) / 1020.0;
        float alpha = opening * (lit ? 0.42 * lighting.y * variation : (lighting.x > 0 ? 0.30 : 0.10));
        float3 color = lit ? lamp : float3(0.11, 0.16, 0.21);
        // A single, weak spill per wall aggregates its windows. No light cones.
        float spill = lighting.x * lighting.y * in.light.y * in.light.z
            * exp(-in.meters.y * 2.5) * 0.035;
        float fade = lighting.z * lighting.w * mix(0.45, 1.0, in.light.z);
        float combined = clamp(alpha + halo + spill, 0.0, 0.7) * fade;
        if (combined < 0.002) discard_fragment();
        return float4((color * alpha + lamp * (halo + spill)) * fade, combined);
    }
    struct CompositeOut { float4 position [[position]]; float2 uv; };
    vertex CompositeOut compositeVertex(uint v [[vertex_id]]) {
        CompositeOut out;
        out.position = float4(corners[v] * 2 - 1, 1, 1);
        out.uv = float2(corners[v].x, 1 - corners[v].y);
        return out;
    }
    fragment float4 compositeFragment(CompositeOut in [[stage_in]], texture2d<float> image [[texture(0)]]) {
        constexpr sampler sampleFilter(filter::linear, address::clamp_to_edge);
        return image.sample(sampleFilter, in.uv);
    }
    """
}
#endif
