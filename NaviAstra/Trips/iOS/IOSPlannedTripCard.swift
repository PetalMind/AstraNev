#if os(iOS)
import SwiftUI

struct IOSPlannedTripCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: IOSPlannedTripLibrarySnapshot.Entry
    let regular: Bool
    let refreshing: Bool
    private var trip: PlannedTrip { entry.trip }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: trip.transportMode.symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(trip.displayTitle).font(.headline).foregroundStyle(.primary)
                    Text(trip.transportMode.title).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary).padding(.top, 5).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Label(trip.origin.name, systemImage: "circle")
                Label(trip.destination.name, systemImage: "mappin.circle.fill")
            }.font(.subheadline).foregroundStyle(.secondary)
            Divider()
            if regular {
                Text(IOSPlannedTripLibrarySnapshot.scheduleTitle(trip)).font(.subheadline.weight(.semibold))
                timeRow(trip.targetDate)
            } else if let occurrence = entry.occurrence {
                timeRow(occurrence)
                if trip.timing == .arrival, let departure = trip.departure(for: occurrence) {
                    Label("Wyjazd około \(PolishRegionalFormat.time(departure, timeZone: trip.calendar.timeZone))", systemImage: "arrow.up.forward")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Color.accentColor)
                }
                if trip.repeatRule != .never {
                    Label(IOSPlannedTripLibrarySnapshot.scheduleTitle(trip), systemImage: "repeat")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Termin minął lub został wykorzystany").font(.caption).foregroundStyle(.secondary)
            }
            if refreshing {
                ProgressView("Odświeżam trasę…").font(.caption)
            } else if trip.refreshError != nil {
                Label("Trasa wymaga odświeżenia", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            } else if let estimate = trip.estimate {
                Label(TravelDurationFormatter.string(minutes: Int(ceil(estimate.travelSeconds / 60))), systemImage: "clock")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Text("Obliczono \(PolishRegionalFormat.dateTime(estimate.updatedAt, timeZone: trip.calendar.timeZone))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Czas trasy nie został jeszcze obliczony").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .iosCardSurface(radius: 22)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Otwórz szczegóły i działania podróży")
    }

    private func timeRow(_ date: Date) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return layout {
            Text(trip.timing.title).font(.subheadline).foregroundStyle(.secondary)
            Text(PolishRegionalFormat.time(date, timeZone: trip.calendar.timeZone))
                .font(.title2.weight(.bold)).monospacedDigit()
        }
    }
}
#endif
