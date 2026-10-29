#if os(iOS)
import Foundation
import OSLog
import simd

/// Offline derivatives of the licensed OBJ files. No runtime model downloads.
struct MapEnvironmentMesh {
    struct Vertex {
        var position: SIMD4<Float>
        var normal: SIMD4<Float>
        var color: SIMD4<Float>
    }
    let id: String
    let vertices: [Vertex]
    let triangleCount: Int
    let aspect: SIMD2<Double>
    let lampLens: SIMD3<Double>?
}

@MainActor
enum MapEnvironmentMeshCatalog {
    private struct Document: Decodable {
        let version: Int
        let id: String
        let vertices: [[Double]]
        let triangles: [[Int]]
        let aspect: [Double]
        let lampLens: [Double]?
    }
    private static var meshes: [String: MapEnvironmentMesh] = [:]
    private static var unavailable = Set<String>()
    private static let logger = Logger(subsystem: "NaviAstra", category: "EnvironmentMeshes")

    static func mesh(_ name: String, simplified: Bool = false) -> MapEnvironmentMesh? {
        let id = name + (simplified ? "-lod" : "")
        if let mesh = meshes[id] { return mesh }
        guard !unavailable.contains(id) else { return nil }
        guard let url = Bundle.main.url(forResource: "environment-" + id, withExtension: "json"),
              let data = try? Data(contentsOf: url), data.count <= 2_000_000,
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.version == 1, document.id == id,
              !document.vertices.isEmpty, document.vertices.count <= 30_000,
              !document.triangles.isEmpty, document.triangles.count <= 15_000,
              document.aspect.count == 2, document.aspect.allSatisfy({ $0.isFinite && $0 > 0 && $0 < 10 }),
              document.vertices.allSatisfy({ $0.count == 3 && $0.allSatisfy { $0.isFinite && abs($0) <= 2 } }),
              document.triangles.allSatisfy({ $0.count == 4 && $0.prefix(3).allSatisfy { document.vertices.indices.contains($0) }
                  && (0...0xFFFFFF).contains($0[3]) }) else {
            unavailable.insert(id)
            logger.error("Brak poprawnego modelu otoczenia: \(id, privacy: .public). Pozostaje geometria mapy.")
            return nil
        }
        let points = document.vertices.map { SIMD3<Float>(Float($0[0]), Float($0[1]), Float($0[2])) }
        var output: [MapEnvironmentMesh.Vertex] = []
        output.reserveCapacity(document.triangles.count * 3)
        for triangle in document.triangles {
            let a = points[triangle[0]], b = points[triangle[1]], c = points[triangle[2]]
            let cross = simd_cross(b - a, c - a)
            guard simd_length_squared(cross) > 1e-14 else { continue }
            let normal = simd_normalize(cross)
            let color = triangle[3]
            let rgb = SIMD4<Float>(Float((color >> 16) & 255) / 255, Float((color >> 8) & 255) / 255,
                                   Float(color & 255) / 255, 1)
            for position in [a, b, c] {
                output.append(.init(position: SIMD4(position, 1), normal: SIMD4(normal, 0), color: rgb))
            }
        }
        guard !output.isEmpty else { unavailable.insert(id); return nil }
        let mesh = MapEnvironmentMesh(id: id, vertices: output, triangleCount: output.count / 3,
            aspect: SIMD2(document.aspect[0], document.aspect[1]), lampLens: document.lampLens.flatMap {
                guard $0.count == 3, $0.allSatisfy({ $0.isFinite && abs($0) <= 2 }) else { return nil }
                return SIMD3($0[0], $0[1], $0[2])
            })
        meshes[id] = mesh
        return mesh
    }

    static func furniture(kind: MapStreetFurnitureGeometry.Kind, key: String, conifer: Bool,
                          simplified: Bool = false) -> MapEnvironmentMesh? {
        let seed = key.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        func variant(_ names: [String]) -> MapEnvironmentMesh? {
            mesh(names[Int(seed % UInt64(names.count))], simplified: simplified)
        }
        switch kind {
        case .tree:
            return variant(conifer ? ["tree-conifer", "tree-pineDefaultA", "tree-pineRoundA"]
                : ["tree-rounded", "tree-branched", "tree-broad", "tree-small", "tree-tall", "tree-fat", "tree-thin", "tree-plateau"])
        case .streetLamp: return mesh("street-lamp", simplified: simplified)
        case .trafficSignals: return mesh("traffic-signal", simplified: simplified)
        case .bench: return variant(["bench", "bench-park"])
        case .bollard: return mesh("bollard-column", simplified: simplified)
        default: return nil
        }
    }
}

struct MapEnvironmentModelInstance {
    let key: String
    let mesh: MapEnvironmentMesh
    /// Scale is the physical footprint width/depth and total height in meters.
    var pose: MapObjectPose
    var base = 0.0
    var isTree = false
    var isBuilding = false
    var roofColor: SIMD3<Float>? = nil
}
#endif
