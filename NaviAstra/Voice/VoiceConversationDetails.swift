#if os(iOS)
import SwiftUI

/// Full text is available on demand, without occupying the navigation map.
struct VoiceConversationDetails: View {
    @Environment(\.dismiss) private var dismiss
    let assistant: VoiceAssistant

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !assistant.transcript.isEmpty {
                        textSection("Twoja wypowiedź", text: assistant.transcript)
                    }
                    textSection("Odpowiedź", text: assistant.response)
                    if assistant.isCapturingSpeech {
                        Button("Zakończ wypowiedź", systemImage: "checkmark") {
                            assistant.finishUtterance()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationTitle("Rozmowa z nawigacją")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Zamknij", systemImage: "xmark") { dismiss() }
                }
            }
        }
    }

    private func textSection(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).foregroundStyle(.secondary)
            Text(text).font(.body).textSelection(.enabled)
        }
    }
}
#endif
