#if os(iOS)
import SwiftUI

struct IOSPlannedTripTimeSummary: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let departure: Date
    let arrival: Date
    let timeZone: TimeZone

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 24))
        layout {
            time("Wyjazd około", date: departure, emphasized: true)
            time("Przyjazd około", date: arrival, emphasized: false)
        }
    }

    private func time(_ title: String, date: Date, emphasized: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(PolishRegionalFormat.time(date, timeZone: timeZone))
                .font(.title2.weight(emphasized ? .bold : .semibold)).monospacedDigit()
                .foregroundStyle(emphasized ? Color.accentColor : Color.primary)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }
}

struct IOSPlannedTripWeekdayPicker: View {
    @Binding var weekdays: Set<Int>
    @ScaledMetric(relativeTo: .body) private var minimumDayWidth: CGFloat = 44

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumDayWidth), spacing: 6)], spacing: 8) {
            ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                Button {
                    if weekdays.contains(day) { weekdays.remove(day) }
                    else { weekdays.insert(day) }
                } label: {
                    Text(String(PolishRegionalFormat.weekday(day).prefix(2))).font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(weekdays.contains(day) ? Color.accentColor : Color.primary)
                        .background(weekdays.contains(day) ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04), in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(weekdays.contains(day) ? Color.accentColor : .clear, lineWidth: 1.5)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(PolishRegionalFormat.weekday(day))
                .accessibilityAddTraits(weekdays.contains(day) ? .isSelected : [])
            }
        }
    }
}

struct IOSPlannedTripRouteOption: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let route: NavigationRoute
    let index: Int
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(spacing: 12))
            layout {
                Label("Wariant \(index + 1)", systemImage: selected ? "checkmark.circle.fill" : "circle")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 4) {
                    Text(TravelDurationFormatter.string(minutes: Int(ceil(route.expectedTravelTime / 60))))
                        .font(.headline).monospacedDigit()
                    Text(String(format: "%.1f km", locale: PolishRegionalFormat.locale, route.distance / 1_000))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12).frame(minHeight: 60).contentShape(Rectangle())
            .background(selected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
#endif
