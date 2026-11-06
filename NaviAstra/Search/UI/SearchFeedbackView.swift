import SwiftUI

/// A presentation-only state: requests and cancellation remain owned by SearchStore.
struct SearchFeedbackView: View {
    enum State {
        case minimumQuery
        case loading(hasResults: Bool)
        case failure(message: String, canRetry: Bool)
        case noResults(query: String)
    }

    let state: State
    var onRetry: () -> Void = {}
    var onEditQuery: (() -> Void)? = nil

    var body: some View {
        Group {
            switch state {
            case .minimumQuery:
                Label("Wpisz co najmniej 2 znaki, aby wyszukać.", systemImage: "magnifyingglass")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            case .loading(let hasResults):
                ProgressView(hasResults ? "Uzupełnianie wyników…" : "Wyszukiwanie miejsc…")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            case .failure(let message, let canRetry):
                ContentUnavailableView {
                    Label("Wyszukiwanie niedostępne", systemImage: "exclamationmark.magnifyingglass")
                } description: {
                    Text(message)
                } actions: {
                    if canRetry {
                        Button("Ponów wyszukiwanie", systemImage: "arrow.clockwise", action: onRetry)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    } else {
                        Text("Możesz też zmienić obszar wyszukiwania.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            case .noResults(let query):
                ContentUnavailableView {
                    Label("Brak wyników", systemImage: "mappin.slash")
                } description: {
                    Text("Nie znaleziono miejsc dla „\(query)”. Dopisz miejscowość, zmień nazwę lub obszar wyszukiwania.")
                } actions: {
                    if let onEditQuery {
                        Button("Zmień zapytanie", systemImage: "pencil", action: onEditQuery)
                            .buttonStyle(.bordered).controlSize(.large)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
