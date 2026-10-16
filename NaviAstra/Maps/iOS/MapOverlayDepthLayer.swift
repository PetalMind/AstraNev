#if os(iOS)
import MapLibre
import Metal
import OSLog

/// Geographic fills may write coplanar depth even when their pattern is transparent.
/// Keep their color, but start a fresh depth plane for map names and navigation.
final class MapOverlayDepthLayer: MLNCustomStyleLayer {
    static let layerID = "naviastra-map-overlay-depth"
    private let logger = Logger(subsystem: "NaviAstra", category: "MapOverlayDepth")
    private var pipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?
    private var failed = false

    static func install(in style: MLNStyle) {
        guard style.layer(withIdentifier: layerID) == nil else { return }
        // Liberty's one-way arrows are ground markings, preceding the buildings.
        // Text labels begin after the geographic geometry, including buildings.
        let anchor = style.layers.first {
            if ["naviastra-active-route-", "naviastra-completed-route-", "naviastra-alternative-route-",
                "naviastra-route-traffic-", "naviastra-incident-", "com.mapbox.annotations", "org.maplibre.annotations"]
                .contains(where: $0.identifier.hasPrefix) { return true }
            guard let symbol = $0 as? MLNSymbolStyleLayer,
                  symbol.sourceLayerIdentifier != "transportation", let text = symbol.text else { return false }
            // The native getter may supply the default empty text for icon-only layers.
            if let literal = text.mgl_jsonExpressionObject as? String { return !literal.isEmpty }
            return true
        }
        let layer = MapOverlayDepthLayer(identifier: layerID)
        if let anchor { style.insertLayer(layer, below: anchor) }
        else { style.addLayer(layer) }
    }

    override func didMove(to mapView: MLNMapView) {
        super.didMove(to: mapView)
        prepare(on: mapView)
    }

    private func prepare(on mapView: MLNMapView) {
        guard pipeline == nil, !failed else { return }
        let resource = mapView.backendResource()
        guard let device = resource.device else { return }
        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "NaviAstra — głębokość przed etykietami i trasą"
            descriptor.vertexFunction = library.makeFunction(name: "overlayDepthVertex")
            descriptor.colorAttachments[0].pixelFormat = resource.mtkView.colorPixelFormat
            descriptor.colorAttachments[0].writeMask = []
            let format = resource.mtkView.depthStencilPixelFormat
            descriptor.depthAttachmentPixelFormat = format
            descriptor.stencilAttachmentPixelFormat = format == .depth32Float_stencil8 ? format : .invalid
            descriptor.rasterSampleCount = max(1, resource.mtkView.sampleCount)
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            let depth = MTLDepthStencilDescriptor()
            depth.depthCompareFunction = .always
            depth.isDepthWriteEnabled = true
            // Stencil remains untouched: native tile clipping still applies above us.
            depthState = device.makeDepthStencilState(descriptor: depth)
        } catch {
            failed = true
            logger.error("Nie udało się przygotować warstwy głębokości mapy: \(error.localizedDescription, privacy: .private)")
        }
    }

    override func draw(in mapView: MLNMapView, with context: MLNStyleLayerDrawingContext) {
        prepare(on: mapView)
        guard !failed, let renderEncoder, let pipeline, let depthState else { return }
        renderEncoder.setRenderPipelineState(pipeline)
        renderEncoder.setDepthStencilState(depthState)
        renderEncoder.setCullMode(.none)
        renderEncoder.setDepthBias(0, slopeScale: 0, clamp: 0)
        // One fullscreen triangle writes only the far depth. No color, texture,
        // building geometry, label placement or route coordinates are changed.
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    override func willMove(from mapView: MLNMapView) {
        pipeline = nil
        depthState = nil
        failed = false
        super.willMove(from: mapView)
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    vertex float4 overlayDepthVertex(uint index [[vertex_id]]) {
        const float2 positions[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
        return float4(positions[index], 1, 1);
    }
    """
}
#endif
