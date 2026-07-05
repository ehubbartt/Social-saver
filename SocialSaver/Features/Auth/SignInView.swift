import SwiftUI

struct SignInView: View {
    @Environment(SessionObserver.self) private var session
    @State private var email = ""
    @State private var password = ""
    @State private var isSigningUp = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(isSigningUp ? .newPassword : .password)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }

                Section {
                    Button(isSigningUp ? "Create account" : "Sign in") {
                        Task { await submit() }
                    }
                    .disabled(isWorking || email.isEmpty || password.isEmpty)

                    Button(isSigningUp ? "I already have an account" : "Create a new account") {
                        isSigningUp.toggle()
                        errorMessage = nil
                    }
                    .font(.footnote)
                }
            }
            .navigationTitle("SocialSaver")
            .overlay { if isWorking { ProgressView() } }
        }
    }

    private func submit() async {
        isWorking = true
        defer { isWorking = false }
        do {
            if isSigningUp {
                try await session.signUp(email: email, password: password)
            } else {
                try await session.signIn(email: email, password: password)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
