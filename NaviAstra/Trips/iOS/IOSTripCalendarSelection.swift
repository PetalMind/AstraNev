#if os(iOS)
import SwiftUI

struct IOSTripCalendarSelection: View {
    let onBack: () -> Void
    let onSelect: (IOSTripCalendarEvent) -> Void
    @State private var model = IOSTripCalendarModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").frame(width: 44, height: 44)
                }.accessibilityLabel("Wróć do szkicu")
                Text("Dojazd na wydarzenie").font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
            }.padding(.horizontal, 8)
            List {
                if model.loading { ProgressView("Wczytuję wydarzenia…") }
                if let message = model.message {
                    ContentUnavailableView {
                        Label("Wydarzenia z kalendarza", systemImage: "calendar")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Wróć do planowania", action: onBack).buttonStyle(.bordered)
                    }
                    .listRowBackground(Color.clear)
                }
                ForEach(model.events) { event in
                    Button { onSelect(event) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "calendar")
                                .foregroundStyle(Color.accentColor).font(.title3)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(event.title).font(.headline).foregroundStyle(.primary)
                                Text(PolishRegionalFormat.dateTime(event.date)).font(.subheadline).foregroundStyle(Color.accentColor)
                                Text(event.location).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary).accessibilityHidden(true)
                        }.padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("Zaplanuj przyjazd na to wydarzenie")
                }
            }.listStyle(.insetGrouped)
        }
        .frame(maxWidth: IOSLayout.readableWidth).frame(maxWidth: .infinity)
        .task { await model.load() }
    }
}
#endif
