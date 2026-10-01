import SwiftUI

struct PlaceFuelPricesSection: View {
    let identity: PlaceIdentity
    @State private var quote: StationFuelPrices?
    @State private var isLoading = true
    @State private var failed = false
    @State private var retry = 0

    private var refreshKey: String {
        identity.cacheKey + "/" + (identity.brand ?? "") + "/" + (identity.operatorName ?? "") + "/\(retry)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Ceny paliw", systemImage: "fuelpump.fill")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.naviTextPrimary)
                Spacer()
                Text("zł / litr")
                    .font(.caption)
                    .foregroundStyle(Color.naviTextSecondary)
            }

            if isLoading {
                ProgressView("Pobieranie cen…")
                    .font(.caption)
            } else if failed {
                status("Nie udało się pobrać cen paliw.", symbol: "wifi.exclamationmark")
                Button("Spróbuj ponownie", systemImage: "arrow.clockwise") { retry += 1 }
                    .font(.caption.weight(.semibold))
            } else if let quote, quote.isClosed {
                status("PaliwoMapa oznacza tę stację jako zamkniętą.", symbol: "exclamationmark.triangle")
            } else if let quote, !quote.prices.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                    ForEach(StationFuel.allCases) { fuel in
                        priceTile(fuel, price: quote.prices.first { $0.fuel == fuel })
                    }
                }
                Text("Ceny zgłaszane przez społeczność. Potwierdź cenę na stacji.")
                    .font(.caption)
                    .foregroundStyle(Color.naviTextSecondary)
            } else {
                status(quote == nil ? "Brak jednoznacznie dopasowanej stacji w PaliwoMapa."
                       : "Brak zgłoszonych cen dla tej stacji.", symbol: "fuelpump.slash")
            }

            HStack {
                Link(destination: quote?.sourceURL ?? URL(string: "https://paliwomapa.pl")!) {
                    Label("PaliwoMapa.pl", systemImage: "arrow.up.right.square")
                        .font(.caption.weight(.medium))
                }
                Spacer()
                if !isLoading, !failed, quote != nil {
                    Button("Odśwież", systemImage: "arrow.clockwise") { retry += 1 }
                        .font(.caption.weight(.medium))
                }
            }
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.accentColor.opacity(0.12), lineWidth: 1)
        }
        .task(id: refreshKey) {
            quote = nil
            failed = false
            isLoading = true
            do {
                let fetched = try await PaliwoMapaFuelPriceProvider.shared.prices(for: identity, forceRefresh: retry > 0)
                guard !Task.isCancelled else { return }
                quote = fetched
                isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
                isLoading = false
            }
        }
    }

    private func status(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(Color.naviTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func priceTile(_ fuel: StationFuel, price: StationFuelPrice?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(fuel.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.naviTextSecondary)
            if let price {
                Text(price.amount.formatted(.number.locale(Locale(identifier: "pl_PL")).precision(.fractionLength(2))))
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.naviTextPrimary)
                if let date = price.reportedAt {
                    Text(date.formatted(.dateTime.day().month().year().locale(Locale(identifier: "pl_PL"))))
                        .font(.caption2)
                        .foregroundStyle(Color.naviTextSecondary)
                }
                Label(price.isRecent ? "Ostatnie 5 dni" : price.reportedAt == nil ? "Brak daty" : "Starsza cena",
                      systemImage: price.isRecent ? "checkmark.circle" : "clock")
                    .font(.caption2)
                    .foregroundStyle(price.isRecent ? Color.naviTextSecondary : Color(naviHex: NaviAstraColorPalette.warning))
            } else {
                Text("—")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.naviTextSecondary)
                Text("Brak ceny")
                    .font(.caption2)
                    .foregroundStyle(Color.naviTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
