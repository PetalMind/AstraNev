#if os(iOS)
import SwiftUI

struct VoiceAssistantButton: View {
    let assistant: VoiceAssistant
    var controlSize: CGFloat = 48

    private var status: String {
        guard assistant.isPresented else { return "Gotowy do rozmowy" }
        return assistant.statusTitle
    }

    var body: some View {
        Button { assistant.isPresented ? assistant.close() : assistant.open() } label: {
            Image(systemName: assistant.isCapturingSpeech ? "mic.fill" : "mic")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(assistant.isPresented ? Color.accentColor : Color.naviTextPrimary)
                .frame(minWidth: max(44, controlSize), minHeight: max(44, controlSize))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(assistant.isPresented ? "Zakończ rozmowę z Astrą" : "Astra — asystent głosowy")
        .accessibilityValue(status)
        .accessibilityHint(assistant.isPresented
            ? "Zamyka asystenta głosowego."
            : "Możesz zapytać o trasę lub wydać polecenie po polsku.")
        .accessibilityIdentifier("voice-assistant-button")
    }
}

struct VoiceAssistantPanel: View {
    @State private var showsConversation = false
    let assistant: VoiceAssistant

    private var preview: String {
        switch assistant.phase {
        case .listening:
            if !assistant.transcript.isEmpty { return assistant.transcript }
            if assistant.speechInput.isFinalizing { return "Czekam na pełny wynik rozpoznania" }
            if !assistant.isCapturingSpeech { return "Za chwilę możesz mówić" }
            return assistant.canConfirm || assistant.isAwaitingDestinationDetails
                ? assistant.response : "Powiedz całe polecenie"
        case .working:
            return assistant.transcript.isEmpty ? "Sprawdzam Twoje polecenie" : assistant.transcript
        case .idle, .speaking:
            return assistant.response
        }
    }

    private var microphoneUnavailable: Bool {
        assistant.phase == .working || (assistant.phase == .listening && !assistant.isCapturingSpeech)
    }

    private var microphoneLabel: String {
        if assistant.isCapturingSpeech { return "Zakończ wypowiedź" }
        if assistant.phase == .speaking { return "Przerwij odpowiedź i mów" }
        return "Powiedz polecenie"
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    if assistant.isCapturingSpeech { assistant.finishUtterance() }
                    else { assistant.listen() }
                } label: {
                    VoiceActivityIndicator(
                        level: assistant.speechInput.inputLevel,
                        listening: assistant.isCapturingSpeech,
                        speaking: assistant.phase == .speaking,
                        processing: microphoneUnavailable)
                        .frame(width: 48, height: 48)
                        .background(Color.accentColor.opacity(0.12), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(microphoneUnavailable)
                .accessibilityLabel(microphoneLabel)
                .accessibilityValue(assistant.statusTitle)
                .accessibilityHint(assistant.isCapturingSpeech
                    ? "Kończy nagrywanie i czeka na pełne rozpoznanie wypowiedzi."
                    : "Możesz zapytać o trasę lub wydać polecenie.")
                .accessibilityIdentifier("voice-conversation-microphone")

                Button {
                    assistant.setConversationDetailsPresented(true)
                    showsConversation = true
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(assistant.statusTitle)
                                .font(.caption.weight(.semibold))
                            Image(systemName: "chevron.up")
                                .font(.caption2.weight(.semibold))
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(Color.naviTextSecondary)
                        Text(preview)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.naviTextPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Pokaż pełną treść rozmowy")
                .accessibilityValue(preview)
                .accessibilityIdentifier("voice-conversation-details")

                Button { assistant.close() } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.naviTextSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Zamknij rozmowę")
            }

            if assistant.canConfirm || assistant.canChooseNext {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { confirmationControls }
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(spacing: 6) { confirmationControls }
                }
                .controlSize(.large)
            }
        }
        .padding(8)
        .frame(maxWidth: 480)
        .modifier(NavigationGlassSurface(radius: 28))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice-conversation-bar")
        .sensoryFeedback(.selection, trigger: assistant.isCapturingSpeech) { _, ready in ready }
        .sheet(isPresented: $showsConversation, onDismiss: {
            assistant.setConversationDetailsPresented(false)
        }) {
            VoiceConversationDetails(assistant: assistant)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .environment(\.locale, PolishRegionalFormat.locale)
        }
    }

    @ViewBuilder private var confirmationControls: some View {
        if assistant.canConfirm {
            Button(assistant.confirmationLabel, systemImage: "checkmark") { assistant.submit("tak") }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(.white)
            Button("Anuluj") { assistant.submit("anuluj") }
                .buttonStyle(.bordered)
        }
        if assistant.canChooseNext {
            Button("Następna propozycja", systemImage: "chevron.right") { assistant.submit("następna") }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
        }
    }
}

struct VoiceAssistantSettings: View {
    @AppStorage("voiceOfflineOnly") private var offlineOnly = false
    let assistant: VoiceAssistant

    var body: some View {
        Section("Astra — polecenia głosowe") {
            Text(assistant.speechInput.commandRecognitionAvailabilityLabel)
                .font(.footnote).foregroundStyle(.secondary)
            Text("Dotknij mikrofonu i powiedz na przykład „Astra, gdzie mogę zaparkować?” lub „Astra, głośniej”. Podczas odpowiedzi dotknij mikrofonu, aby ją przerwać i mówić. Astra nie nasłuchuje w tle na swoje imię.")
                .font(.footnote).foregroundStyle(.secondary)
            Toggle("Dyktowanie w wyszukiwarce tylko na urządzeniu", isOn: $offlineOnly)
            Text(assistant.speechInput.recognitionAvailabilityLabel)
                .font(.footnote).foregroundStyle(.secondary)
            Text("Polecenie „prowadź do” od razu uruchamia prowadzenie do zapisanego miejsca, jednoznacznego adresu kontaktu lub konkretnego miejsca. Nazwa sieci, np. „Poczta Polska”, wybiera najbliższą pasującą placówkę. Przy kilku adresach powiedz np. „wybierz drugi”, aby od razu rozpocząć prowadzenie. „Następna” tylko odczytuje kolejną propozycję. Postoje i pozostałe propozycje zmian potwierdzasz słowem „tak”.")
                .font(.footnote).foregroundStyle(.secondary)
            Text("Adresy kontaktów są dostępne po udzieleniu NaviAstra dostępu do kontaktów w ustawieniach iOS. Wyszukiwanie najbliższej placówki wymaga aktualnej lokalizacji.")
                .font(.footnote).foregroundStyle(.secondary)
            Text("Rozmowa kończy się po przejściu aplikacji w tło lub zablokowaniu ekranu. Komunikaty aktywnej nawigacji nadal mogą być odtwarzane. Wyszukiwanie miejsc i nowe trasy mogą wymagać internetu także przy lokalnym rozpoznawaniu mowy.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}
#endif
