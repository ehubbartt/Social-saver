import SwiftUI

/// "Which of my saved spots should I try tonight?" — conversational
/// recommendations drawn only from the user's own saves.
struct AskView: View {
    @Environment(SavesStore.self) private var store

    struct Exchange: Identifiable {
        let id = UUID()
        let question: String
        let answer: String
        let saves: [Save]
    }

    @State private var question = ""
    @State private var exchanges: [Exchange] = []
    @State private var isAsking = false
    @State private var errorMessage: String?

    private let repository = SavesRepository()

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if exchanges.isEmpty && !isAsking {
                            intro
                        }
                        ForEach(exchanges) { exchange in
                            exchangeView(exchange)
                                .id(exchange.id)
                        }
                        if isAsking {
                            ProgressView("Looking through your saves…")
                                .frame(maxWidth: .infinity)
                        }
                        if let errorMessage {
                            Text(errorMessage).foregroundStyle(.red).font(.footnote)
                        }
                    }
                    .padding()
                }
                .onChange(of: exchanges.count) {
                    if let last = exchanges.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .top) }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                inputBar
            }
            .navigationTitle("Ask your saves")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Can't decide?")
                .font(.headline)
            Text("Ask things like “where should I eat this weekend?” or “what did I save for Tokyo?” — answers come only from what you've saved.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private func exchangeView(_ exchange: Exchange) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(exchange.question)
                .font(.subheadline.weight(.semibold))
                .padding(10)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            Text(exchange.answer)
            if !exchange.saves.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(exchange.saves) { save in
                            NavigationLink {
                                SaveDetailView(save: save)
                            } label: {
                                SaveCardView(save: save)
                                    .frame(width: 170)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask about your saves…", text: $question, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
            Button {
                Task { await ask() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(isAsking || question.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding()
        .background(.bar)
    }

    private func ask() async {
        let asked = question.trimmingCharacters(in: .whitespaces)
        guard !asked.isEmpty else { return }
        question = ""
        isAsking = true
        errorMessage = nil
        defer { isAsking = false }
        do {
            let response = try await repository.ask(question: asked)
            // Preserve the model's best-first ordering and drop duplicates.
            let byId = Dictionary(uniqueKeysWithValues: store.saves.map { ($0.id, $0) })
            var seen = Set<UUID>()
            let matched = response.saveIds.compactMap { id -> Save? in
                guard !seen.contains(id), let save = byId[id] else { return nil }
                seen.insert(id)
                return save
            }
            exchanges.append(Exchange(question: asked, answer: response.answer, saves: matched))
        } catch {
            errorMessage = "Couldn't get an answer. Try again."
        }
    }
}
