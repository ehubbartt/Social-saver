import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// Receives a URL (or text containing one) from the share sheet, sends it to
/// the ingest edge function, and dismisses. Auth comes from the shared
/// keychain session written by the main app.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()

        let host = UIHostingController(rootView: ShareStatusView(model: model) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        })
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        Task { await ingestSharedURL() }
    }

    private func ingestSharedURL() async {
        guard let url = await extractURL() else {
            model.state = .failed("Couldn't find a link in what you shared.")
            return
        }
        await model.ingest(url: url)
    }

    private func extractURL() async -> String? {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?
            .compactMap(\.attachments)
            .flatMap { $0 } ?? []

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let item = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier),
               let url = item as? URL {
                return url.absoluteString
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
               let item = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier),
               let text = item as? String,
               let url = Self.firstURL(in: text) {
                return url
            }
        }
        return nil
    }

    static func firstURL(in text: String) -> String? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?
            .firstMatch(in: text, range: range)?
            .url?
            .absoluteString
    }
}

@Observable
final class ShareModel {
    enum State {
        case working
        case done
        case failed(String)
    }

    var state: State = .working

    @MainActor
    func ingest(url: String) async {
        let client = SupabaseClientProvider.shared
        do {
            _ = try await client.auth.session
        } catch {
            state = .failed("Sign in to SocialSaver first, then share again.")
            return
        }
        do {
            try await SavesRepository().ingest(url: url)
            state = .done
        } catch {
            state = .failed("Couldn't save this link. Try again later.")
        }
    }
}

struct ShareStatusView: View {
    @Bindable var model: ShareModel
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            switch model.state {
            case .working:
                ProgressView()
                Text("Saving…")
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
                Text("Saved! Organizing it for you.")
                    .font(.headline)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.headline)
                    .multilineTextAlignment(.center)
            }
            Button("Done", action: dismiss)
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .onChange(of: doneStateTrigger) { _, isDone in
            guard isDone else { return }
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                dismiss()
            }
        }
    }

    private var doneStateTrigger: Bool {
        if case .done = model.state { return true }
        return false
    }
}
