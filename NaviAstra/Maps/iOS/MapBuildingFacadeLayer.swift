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
    var light: SIMD4<Float> // seed, probability, detail, signed facade profile (positive permits windows)
    var spill: SIMD4<Float> // outward normal, ground width, ground-level facade
}

struct BuildingRoofFinish {
    var color: SIMD4<Float> // day color, material + 4 * roof shape (only from supplied tags)
    var detail: SIMD4<Float> // local building center, detail, stable decorative variant
    var geometry: SIMD4<Float> // footprint-derived major axis and half extents; never a guessed roof height
}

struct BuildingFacadeMesh {
    var origin = SIMD2<Double>(repeating: 0) // normalized Mercator, retained in double precision
    var metersPerWorld = 1.0
    var walls: [BuildingWallInstance] = []
    var wallFinishes: [SIMD4<Float>] = []
    var roofs: [SIMD4<Float>] = []
    var roofFinishes: [BuildingRoofFinish] = []
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
        input.combine(MapDetailPolicy.constrained)
        // Stable geometry keys also let the lamp mask reuse the facade mask.
        let identities = features.map { feature -> Int in
            var hash = Hasher()
            hash.combine(feature.identifier.map { String(describing: $0) } ?? "")
            for key in [heightKey, baseKey, "height", "render_height", "class", "subclass", "levels", "building:levels", "building:min_level",
                        "building", "building:use", "group_id", "osm_id", "facade_color", "roof_color", "colour", "building:colour", "roof:colour", "roof:material", "roof_material", "roof_shape", "roof:shape"] {
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
        let detailBudget = MapDetailPolicy.constrained ? 48 : 90
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
                let seed = BuildingSurfaceFinish.seed(attributes: attributes, identifier: feature.identifier, footprint: identityPoints)
                let variation = Float(seed % 1_021) / 1_020
                let wallColor = BuildingSurfaceFinish.facade(facade, attributes: attributes, seed: seed)
                let roofColor = BuildingSurfaceFinish.roof(facade, attributes: attributes, seed: seed)
                let windowWidth = facade.windowWidth * (0.90 + variation * 0.18)
                let windowHeight = facade.windowHeight * (0.94 + variation * 0.10)
                let gap = facade.gap * (0.88 + variation * 0.24)
                let center = outer.reduce(SIMD2<Double>(repeating: 0), +) / Double(outer.count)
                let screen = map.convert(polygon.coordinate, toPointTo: map)
                let radius = hypot(screen.x - map.bounds.midX, screen.y - map.bounds.midY)
                    / max(1, hypot(map.bounds.width, map.bounds.height) / 2)
                let projected = MapDetailPolicy.projectedSpan(at: polygon.coordinate, meters: 3, on: map)
                let detail = Float(max(0, min(1, (1.05 - radius) / 0.45))
                    * MapDetailPolicy.smooth(projected, from: 1, to: 4.5))
                let surfaceEligible = height - base >= 2.4 && detailedBuildings < detailBudget
                    && radius < 1.15 && detail > 0.02
                let eligible = surfaceEligible && facade.hasWindows && height - base >= 3 && floorHeight >= 2.4
                    && (facade != .neutral || height - base >= 9)
                    && floorHeight >= Double(windowHeight) + 0.65
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
                        let columns = max(0, Int((length - 1.4) / Double(windowWidth + gap)))
                        let wallSeed = (seed &+ UInt64(abs(Int(((a.x - center.x) * 10).rounded()))) &* 31
                            &+ UInt64(abs(Int(((a.y - center.y) * 10).rounded()))) &* 131) % 16_777_213
                        let windows = eligible && columns > 0 && length < 500
                        let profile = surfaceEligible ? Float(facade.rawValue) * (windows ? 1 : -1) : 0
                        mesh.walls.append(BuildingWallInstance(
                            origin: SIMD4(Float(a.x), Float(a.y), Float(base), Float(height)),
                            edge: SIMD4(Float(edge.x), Float(edge.y), Float(length), Float(floorHeight)),
                            layout: SIMD4(windowWidth, windowHeight, Float(min(256, columns)), Float(count)),
                            light: SIMD4(Float(wallSeed), facade.litProbability, detail, profile),
                            spill: SIMD4(Float(normal.x), Float(normal.y), 1.5, base < 0.5 ? 1 : 0)))
                        mesh.wallFinishes.append(SIMD4(wallColor.x, wallColor.y, wallColor.z, variation))
                        decorated = decorated || surfaceEligible
                    }
                }
                let firstRoofVertex = mesh.roofs.count
                appendRoof(rings: rings, height: Float(height), to: &mesh.roofs)
                var axis = outer.indices.map { outer[($0 + 1) % outer.count] - outer[$0] }
                    .max(by: { simd_length_squared($0) < simd_length_squared($1) }) ?? SIMD2<Double>(1, 0)
                axis /= max(0.01, simd_length(axis))
                if axis.x < 0 || (axis.x == 0 && axis.y < 0) { axis = -axis }
                let crossAxis = SIMD2(-axis.y, axis.x)
                let along = max(1, outer.map { abs(simd_dot($0 - center, axis)) }.max() ?? 1)
                let across = max(1, outer.map { abs(simd_dot($0 - center, crossAxis)) }.max() ?? 1)
                let roofFinish = BuildingRoofFinish(
                    color: SIMD4(roofColor.x, roofColor.y, roofColor.z, BuildingSurfaceFinish.roofPattern(attributes: attributes)
                        + 4 * BuildingSurfaceFinish.roofShape(attributes: attributes)),
                    detail: SIMD4(Float(center.x), Float(center.y), surfaceEligible ? detail : 0, variation),
                    geometry: SIMD4(Float(axis.x), Float(axis.y), Float(along), Float(across)))
                mesh.roofFinishes.append(contentsOf: repeatElement(roofFinish, count: mesh.roofs.count - firstRoofVertex))
            }
            if decorated { detailedBuildings += 1 }
        }
        for wall in mesh.walls {
            for vector in [wall.origin, wall.edge, wall.layout, wall.light, wall.spill] {
                for index in 0..<4 { signature.combine(vector[index]) }
            }
        }
        for vertex in mesh.roofs { for index in 0..<4 { signature.combine(vertex[index]) } }
        for finish in mesh.wallFinishes { for index in 0..<4 { signature.combine(finish[index]) } }
        for finish in mesh.roofFinishes {
            for vector in [finish.color, finish.detail, finish.geometry] { for index in 0..<4 { signature.combine(vector[index]) } }
        }
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

/// Native buildings supply the body. This existing pass adds decorative finishes,
/// facade divisions, glazing and roof color below labels and navigation overlays.
/// A private depth pass prevents windows showing through roofs or other buildings
/// without relying on MapLibre's separate extrusion depth attachment.
final class MapBuildingFacadeLayer: MLNCustomStyleLayer {
    static let layerID = "naviastra-building-procedural-facades"
    var externalModelIdentifiers = Set<String>()
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
    private var roofFinishPipeline: MTLRenderPipelineState?
    private var facadePipeline: MTLRenderPipelineState?
    private var groundPipeline: MTLRenderPipelineState?
    private var compositePipeline: MTLRenderPipelineState?
    private var writeDepth: MTLDepthStencilState?
    private var readDepth: MTLDepthStencilState?
    private var noDepth: MTLDepthStencilState?
    private var wallsBuffer: MTLBuffer?
    private var wallFinishesBuffer: MTLBuffer?
    private var roofsBuffer: MTLBuffer?
    private var roofFinishesBuffer: MTLBuffer?
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
            && settings.baseMap != .satellite && map.zoomLevel >= (wasEnabled ? 16.8 : 17) && map.camera.pitch > (wasEnabled ? 22 : 27)
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
        let features = map.visibleFeatures(in: map.bounds, styleLayerIdentifiers: layerIDs).filter {
            !externalModelIdentifiers.contains($0.identifier.map { String(describing: $0) } ?? "")
        }
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
            roofFinishPipeline = try pipeline(vertex: "roofFinishVertex", fragment: "roofFinishFragment")
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
        wallFinishesBuffer = nil
        roofsBuffer = nil
        roofFinishesBuffer = nil
        colorTarget = nil
        depthTarget = nil
        library = nil
        device = nil
        wallDepthPipeline = nil
        roofDepthPipeline = nil
        roofFinishPipeline = nil
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
        guard enabled, context.zoomLevel >= 16.8, context.pitch > 22 * .pi / 180, !mesh.walls.isEmpty else {
            colorTarget = nil
            depthTarget = nil
            return
        }
        setup(on: mapView)
        guard let device, let commandBuffer, let wallDepthPipeline, let roofDepthPipeline, let facadePipeline,
              let roofFinishPipeline, let writeDepth, let readDepth else { return }
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
            wallFinishesBuffer = mesh.wallFinishes.withUnsafeBytes { bytes in
                bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: bytes.count, options: .storageModeShared) }
            }
            roofFinishesBuffer = mesh.roofFinishes.withUnsafeBytes { bytes in
                bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: bytes.count, options: .storageModeShared) }
            }
            uploadedSignature = mesh.signature
        }
        guard let colorTarget, let depthTarget, let wallsBuffer, let wallFinishesBuffer,
              mesh.walls.count == mesh.wallFinishes.count else { return }
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
        encoder.label = "NaviAstra — wykończenie fasad i dachów"
        var matrix = Self.localMatrix(context.projectionMatrix, mesh: mesh, zoom: context.zoomLevel,
                                      longitude: context.centerCoordinate.longitude)
        var lighting = SIMD4<Float>(dark ? 1 : 0, intensity * (quiet ? 0.55 : 1),
                                     navigating ? 0.72 : 1, Float(min(1, max(0, (context.zoomLevel - 16.8) / 0.8))
                                        * min(1, max(0, (context.pitch * 180 / .pi - 22) / 13))))
        encoder.setCullMode(.none)
        encoder.setVertexBytes(&matrix, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        encoder.setVertexBuffer(wallsBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(wallFinishesBuffer, offset: 0, index: 2)
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
        encoder.setVertexBuffer(wallFinishesBuffer, offset: 0, index: 2)
        encoder.setFragmentBytes(&lighting, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: mesh.walls.count)
        if let roofsBuffer, let roofFinishesBuffer, mesh.roofs.count == mesh.roofFinishes.count {
            encoder.setRenderPipelineState(roofFinishPipeline)
            encoder.setVertexBuffer(roofsBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(roofFinishesBuffer, offset: 0, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.roofs.count)
        }
        if dark, intensity > 0, context.zoomLevel >= 18, let groundPipeline {
            encoder.setRenderPipelineState(groundPipeline)
            encoder.setVertexBuffer(wallsBuffer, offset: 0, index: 0)
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
        float4 dimensions [[flat]];
        float4 appearance [[flat]];
        float shade [[flat]];
    };
    constant float2 corners[6] = {float2(0,0), float2(1,0), float2(1,1), float2(0,0), float2(1,1), float2(0,1)};
    float4 clip(float4 p) { p.z = (p.z + p.w) * 0.5; return p; }
    vertex FacadeOut facadeVertex(uint v [[vertex_id]], uint i [[instance_id]],
                                  const device Wall *walls [[buffer(0)]], constant float4x4 &matrix [[buffer(1)]],
                                  const device float4 *finishes [[buffer(2)]]) {
        Wall wall = walls[i]; float2 uv = corners[v];
        FacadeOut out;
        float h = wall.origin.w - wall.origin.z;
        out.position = clip(matrix * float4(wall.origin.xy + wall.edge.xy * uv.x, wall.origin.z + uv.y * h, 1));
        out.meters = float2(uv.x * wall.edge.z, uv.y * h);
        out.dimensions = float4(wall.edge.z, wall.edge.w, h, wall.origin.z);
        out.layout = wall.layout; out.light = wall.light;
        out.appearance = finishes[i];
        out.shade = 0.88 + 0.12 * dot(wall.spill.xy, normalize(float2(-0.8, -0.6)));
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
        out.meters = uv; out.dimensions = float4(1);
        out.layout = wall.layout; out.light = wall.light;
        out.appearance = float4(0); out.shade = 1;
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
    float4 over(float3 color, float alpha, float4 under) {
        return float4(color * alpha + under.rgb * (1 - alpha), alpha + under.a * (1 - alpha));
    }
    fragment float4 facadeFragment(FacadeOut in [[stage_in]], constant float4 &lighting [[buffer(0)]]) {
        if (abs(in.light.w) < 0.5) discard_fragment();
        int profile = int(abs(in.light.w));
        bool office = profile == 2, retail = profile == 4, industrial = profile == 6, landmark = profile == 7;
        float fade = lighting.z * lighting.w * mix(0.45, 1.0, in.light.z);
        float3 surface = mix(in.appearance.rgb, in.appearance.rgb * 0.24 + float3(0.018, 0.024, 0.032), lighting.x) * in.shade;
        float4 result = float4(surface * 0.26, 0.26);
        float aaY = max(0.025, fwidth(in.meters.y));
        float floorDistance = min(fract(in.meters.y / in.dimensions.y), 1 - fract(in.meters.y / in.dimensions.y)) * in.dimensions.y;
        float band = (industrial || landmark) ? 0 : 1 - smoothstep(office ? 0.10 : 0.045, (office ? 0.10 : 0.045) + aaY, floorDistance);
        float top = 1 - smoothstep(0.12, 0.12 + aaY * 1.5, in.dimensions.z - in.meters.y);
        float base = in.dimensions.w < 0.5 ? 1 - smoothstep(0.40, 0.40 + aaY, in.meters.y) : 0;
        float bayPitch = industrial ? 1.15 : (office ? 5.2 : 7.5);
        float bayDistance = abs(fract((in.meters.x + in.appearance.w * bayPitch) / bayPitch) - 0.5) * bayPitch;
        float bay = 1 - smoothstep(industrial ? 0.035 : 0.065, (industrial ? 0.035 : 0.065) + max(0.025, fwidth(in.meters.x)), bayDistance);
        float trim = max(max(top * 0.55, base * 0.42), max(band * 0.24, bay * (industrial ? 0.18 : 0.10)));
        result = over(surface * mix(0.70, 0.52, lighting.x), trim, result);
        if (in.light.w < 0 || in.layout.z < 1) return result * fade;
        float pitchX = max(0.1, (in.dimensions.x - 1.4) / in.layout.z);
        float2 grid = float2((in.meters.x - 0.7) / pitchX, in.meters.y / in.dimensions.y);
        int2 cell = int2(floor(grid));
        if (cell.x < 0 || cell.x >= int(in.layout.z) || cell.y < 0 || cell.y >= int(in.layout.w)) return result * fade;
        float sill = retail && cell.y == 0 ? 0.25 : (office ? 0.45 : 0.65);
        float windowHeight = min(in.layout.y, in.dimensions.y - sill - 0.25);
        float2 relative = float2((fract(grid.x) - 0.5) * pitchX,
                                 fract(grid.y) * in.dimensions.y - sill - windowHeight * 0.5);
        float2 distance = abs(relative) - float2(in.layout.x, windowHeight) * 0.5;
        float aa = max(0.025, max(fwidth(relative.x), fwidth(relative.y)));
        float opening = 1 - smoothstep(-aa, aa, max(distance.x, distance.y));
        float envelope = 1 - smoothstep(0.055 - aa, 0.055 + aa, max(distance.x, distance.y));
        float frame = max(0.0, envelope - opening);
        float3 frameColor = mix(surface * 0.72, float3(0.15, 0.20, 0.25), office ? 0.55 : 0.12);
        result = over(frameColor, frame * 0.70, result);
        uint seed = hashCell(uint(in.light.x) ^ (uint(cell.x) * 73856093u) ^ (uint(cell.y) * 19349663u));
        bool lit = float(seed & 65535u) / 65535.0 < in.light.y * mix(0.6, 1.0, lighting.y) && lighting.y > 0;
        float halo = lit ? exp(-dot(max(distance, float2(0)), max(distance, float2(0))) / 0.12) * 0.045 * lighting.y * in.light.z : 0;
        float3 warm = float3(1.0, 0.847, 0.659);
        float3 neutral = float3(0.953, 0.914, 0.824);
        float3 cool = float3(0.867, 0.906, 1.0);
        float3 lamp = (seed % 9u == 0u) ? cool : ((seed % 3u == 0u) ? neutral : warm);
        float variation = 0.75 + float((seed >> 16) & 255u) / 1020.0;
        float alpha = opening * (lit ? 0.65 * lighting.y * variation : (lighting.x > 0 ? 0.48 : 0.64));
        float sky = clamp(relative.y / max(0.1, windowHeight) + 0.65, 0.0, 1.0);
        float3 reflected = mix(float3(0.15, 0.25, 0.32), float3(0.46, 0.62, 0.70), sky) * variation;
        float3 color = lit ? lamp : mix(reflected, float3(0.07, 0.11, 0.16), lighting.x);
        result = over(color, alpha, result);
        bool divided = office || profile == 5 || (seed % 4u == 0u && !retail);
        float mullion = divided ? 1 - smoothstep(0.025, 0.025 + aa, abs(relative.x)) : 0;
        float transom = office ? 1 - smoothstep(0.022, 0.022 + aa, abs(relative.y - windowHeight * 0.18)) : 0;
        result = over(frameColor, max(mullion, transom) * opening * 0.55, result);
        // A single, weak spill per wall aggregates its windows. No light cones.
        float spill = lighting.x * lighting.y * in.light.y * in.light.z
            * exp(-in.meters.y * 2.5) * 0.035;
        result = over(lamp, min(0.12, halo + spill), result);
        if (result.a * fade < 0.002) discard_fragment();
        return result * fade;
    }
    struct RoofFinish { float4 color; float4 detail; float4 geometry; };
    struct RoofOut { float4 position [[position]]; float2 meters; float2 shape; float4 color [[flat]]; float2 detail [[flat]]; };
    vertex RoofOut roofFinishVertex(uint v [[vertex_id]], const device float4 *vertices [[buffer(0)]],
                                    constant float4x4 &matrix [[buffer(1)]], const device RoofFinish *finishes [[buffer(2)]]) {
        RoofOut out; RoofFinish finish = finishes[v];
        out.position = clip(matrix * vertices[v]);
        float2 relative = vertices[v].xy - finish.detail.xy;
        float2 axis = finish.geometry.xy;
        out.meters = float2(dot(relative, axis), dot(relative, float2(-axis.y, axis.x)));
        out.shape = out.meters / max(float2(1), finish.geometry.zw);
        out.color = finish.color; out.detail = finish.detail.zw;
        return out;
    }
    fragment float4 roofFinishFragment(RoofOut in [[stage_in]], constant float4 &lighting [[buffer(0)]]) {
        if (in.detail.x < 0.03) discard_fragment();
        float2 meters = in.detail.y < 0.5 ? in.meters : in.meters.yx;
        float material = fmod(in.color.w, 4.0);
        int shape = int(floor(in.color.w / 4));
        float pattern = 0;
        if (material > 0.5 && material < 1.5) {
            float seam = abs(fract(meters.x / 0.8) - 0.5) * 0.8;
            pattern = 1 - smoothstep(0.02, 0.02 + max(0.015, fwidth(meters.x)), seam);
        } else if (material > 1.5 && material < 2.5) {
            float row = floor(meters.y / 0.38);
            float2 tile = float2(fract(meters.x / 0.65 + fract(row * 0.5)), fract(meters.y / 0.38));
            float edge = min(tile.x * 0.65, tile.y * 0.38);
            pattern = 1 - smoothstep(0.012, 0.012 + max(0.012, fwidth(meters.y)), edge);
        } else if (material > 2.5) {
            float2 panel = abs(fract(meters / 3.0) - 0.5) * 3.0;
            pattern = 1 - smoothstep(0.02, 0.02 + max(0.02, fwidth(meters.x)), min(panel.x, panel.y));
        }
        float3 color = mix(in.color.rgb, in.color.rgb * 0.24 + float3(0.012, 0.020, 0.028), lighting.x);
        color *= 1 - pattern * 0.20;
        // A cartographic lighting cue for a supplied roof_shape. The native roof
        // outline and height stay exact; unknown slope/roof height is never invented.
        float2 uv = in.shape;
        float facet = 1, ridge = 0;
        float aa = max(0.005, max(fwidth(uv.x), fwidth(uv.y)));
        if (shape == 1) {
            facet = uv.y < 0 ? 0.84 : 1.10;
            ridge = 1 - smoothstep(0.005, 0.005 + aa, abs(uv.y));
        } else if (shape == 2 || shape == 3) {
            float endWeight = shape == 3 ? 1.0 : 0.62;
            bool end = abs(uv.x) * endWeight > abs(uv.y);
            facet = end ? (uv.x < 0 ? 0.92 : 1.02) : (uv.y < 0 ? 0.83 : 1.11);
            ridge = 1 - smoothstep(0.006, 0.006 + aa, abs(abs(uv.x) * endWeight - abs(uv.y)));
        } else if (shape == 4) {
            facet = clamp(1.04 + uv.x * 0.05 - uv.y * 0.13 - dot(uv, uv) * 0.055, 0.78, 1.12);
        } else if (shape == 5) {
            facet = 0.94 + clamp(uv.y, -1.0, 1.0) * 0.13;
        } else if (shape == 6) {
            facet = 0.88 + fract(uv.y * 3) * 0.20;
        }
        color *= facet + ridge * 0.10;
        float alpha = 0.68 * lighting.z * lighting.w * mix(0.45, 1.0, in.detail.x);
        return float4(color * alpha, alpha);
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
