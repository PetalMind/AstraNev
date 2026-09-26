import SwiftUI

struct SavedPlaceEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let place: SavedPlace
    let onSave: (String, SavedPlaceIcon, Bool) -> Void
    let onRemove: () -> Void

    @State private var name: String
    @State private var icon: SavedPlaceIcon
    @State private var isPinned: Bool
    @State private var confirmingRemoval = false

    init(place: SavedPlace, onSave: @escaping (String, SavedPlaceIcon, Bool) -> Void,
         onRemove: @escaping () -> Void) {
        self.place = place
        self.onSave = onSave
        self.onRemove = onRemove
        _name = State(initialValue: place.customName ?? (place.kind == .favorite ? place.destination.name : ""))
        _icon = State(initialValue: place.icon)
        _isPinned = State(initialValue: place.isPinned)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(place.kind == .favorite ? "Nazwa ulubionego miejsca" : "Nazwa miejsca") {
                    TextField("Wpisz nazwę", text: $name)
                }

                Section("Szczegóły miejsca") {
                    LabeledContent("Adres", value: place.destination.address ?? "Zapisane współrzędne")
                        .lineLimit(2)
                    if place.sourceContactIdentifier != nil {
                        Label("Adres powiązany z Kontaktami", systemImage: "person.crop.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if place.kind == .favorite {
                    Section("Ikona") {
                        HStack(spacing: 0) {
                            ForEach(SavedPlaceIcon.allCases) { option in
                                Button {
                                    icon = option
                                } label: {
                                    Image(systemName: option.symbol)
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(icon == option ? Color.accentColor : Color.secondary)
                                        .frame(maxWidth: .infinity, minHeight: 42)
                                        .background(icon == option ? Color.accentColor.opacity(0.1) : .clear,
                                                    in: RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(option.title)
                                .accessibilityAddTraits(icon == option ? .isSelected : [])
                            }
                        }
                    }
                } else {
                    Section("Ikona") {
                        Label(place.kind.title, systemImage: place.kind.defaultIcon.symbol)
                            .foregroundStyle(.secondary)
                    }
                }

                if place.kind == .favorite {
                    Section {
                        Toggle("Przypięte pod wyszukiwarką", isOn: $isPinned)
                    } footer: {
                        Text("Przypięte miejsca pojawiają się w szybkich skrótach.")
                    }
                }

                Section {
                    Button("Usuń miejsce", role: .destructive) { confirmingRemoval = true }
                }
            }
            .navigationTitle("Edytuj miejsce")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Anuluj") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Zapisz") {
                        onSave(name, icon, isPinned)
                        dismiss()
                    }
                }
            }
            .confirmationDialog("Usunąć to miejsce z Ulubionych?", isPresented: $confirmingRemoval,
                                titleVisibility: .visible) {
                Button("Usuń", role: .destructive) {
                    onRemove()
                    dismiss()
                }
                Button("Anuluj", role: .cancel) { }
            } message: {
                Text(place.displayName)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
