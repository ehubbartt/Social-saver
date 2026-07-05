import SwiftUI

/// Chat with the trip agent: ask questions, get recommendations, and have it
/// edit the itinerary ("move the ramen place to day 2", "add my 9am flight").
struct TripChatView: View {
    @Environment(\.dismiss) private var dismiss

    let trip: Trip
    let onChanged: () async -> Void

    struct Message: Identifiable {
        enum Role {
            case user
            case assistant
        }

        let id = UUID()
        let role: Role
        let text: String
        var updatedTrip = false
    }

    @State private var messages: [Message] = []
    @State private var input = ""
    @State private var isSending = false
    @State private var errorMessage: String?

    private let repository = TripsRepository()

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if messages.isEmpty && !isSending {
                            intro
                        }
                        ForEach(messages) { message in
                            messageView(message)
                                .id(message.id)
                        }
                        if isSending {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Working on it…")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: messages.count) {
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                inputBar
            }
            .navigationTitle("Trip assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Plan \(trip.destination) together")
                .font(.headline)
            Text("Try: “what should I do on day 2?”, “move the ramen spot to day 3”, “add my flight — UA 837 landing 14:20 on day 1”, or “find a good breakfast place near my hotel and add it”.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private func messageView(_ message: Message) -> some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            Text(message.text)
                .padding(10)
                .background(
                    message.role == .user
                        ? Color.accentColor.opacity(0.12)
                        : Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12)
                )
            if message.updatedTrip {
                Label("Trip updated", systemImage: "checkmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask or make a change…", text: $input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
            Button {
                Task { await send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(isSending || input.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding()
        .background(.bar)
    }

    private func send() async {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        input = ""
        errorMessage = nil
        messages.append(Message(role: .user, text: text))
        isSending = true
        defer { isSending = false }

        let history = messages.map {
            TripChatTurn(role: $0.role == .user ? "user" : "assistant", content: $0.text)
        }
        do {
            let response = try await repository.chat(tripId: trip.id, messages: history)
            messages.append(Message(role: .assistant, text: response.reply, updatedTrip: response.changed))
            if response.changed {
                await onChanged()
            }
        } catch {
            errorMessage = "Couldn't reach the trip assistant. Try again."
        }
    }
}
