#if os(iOS)
import SwiftUI
import MapLibre

/// Shared presentation for downloaded resources; the stores own all transfer state.
enum OfflineStorageFormat {
    static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file).locale(PolishRegionalFormat.locale))
    }

    static func coordinate(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(4)).locale(PolishRegionalFormat.locale))
    }
}

struct OfflineMapRegionRow: View {
    let region: OfflineMapRegion
    let isDeleting: Bool
    let onToggle: () -> Void
    let onRemove: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var actionsLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(region.name, systemImage: region.state == .complete ? "checkmark.circle.fill" : "map")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(region.status)
                .font(.subheadline)
                .foregroundStyle(region.error == nil ? Color.secondary : .red)
            Text("\(region.bounds.dimensions) · \(OfflineStorageFormat.bytes(Int64(clamping: region.bytes)))")
                .font(.caption).foregroundStyle(.secondary)
            if region.state == .active {
                if let progress = region.progress {
                    ProgressView(value: progress).accessibilityLabel("Pobieranie: \(region.name)")
                } else {
                    ProgressView("Pobieranie mapy")
                }
            }
            if region.state != .complete {
                Text(region.exactResourceCount
                     ? "Zasoby: \(region.downloadedResources) / \(region.expectedResources)"
                     : "Pobrane zasoby: \(region.downloadedResources)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = region.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
            actionsLayout {
                if region.state == .active || region.state == .inactive {
                    Button(region.state == .active ? "Wstrzymaj" : "Wznów", action: onToggle)
                        .buttonStyle(.bordered)
                        .frame(minHeight: IOSLayout.minimumTarget)
                }
                Button("Usuń mapę", role: .destructive, action: onRemove)
                    .buttonStyle(.bordered)
                    .frame(minHeight: IOSLayout.minimumTarget)
            }
            .disabled(isDeleting)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }
}

struct OfflineRoutingPackRow: View {
    let pack: OfflineRoutingPack
    let isActive: Bool
    let isRemoving: Bool
    let onActivate: () -> Void
    let onRemove: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(pack.name, systemImage: isActive ? "checkmark.circle.fill" : "shippingbox")
                .font(.headline)
            Text(OfflineStorageFormat.bytes(pack.bytes)).font(.caption).foregroundStyle(.secondary)
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 12))
            layout {
                Button(isActive ? "Aktywna paczka" : "Używaj tej paczki", action: onActivate)
                    .disabled(isActive)
                Button("Usuń paczkę", role: .destructive, action: onRemove)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(.vertical, 8)
        .disabled(isRemoving)
        .accessibilityElement(children: .contain)
    }
}
#endif
