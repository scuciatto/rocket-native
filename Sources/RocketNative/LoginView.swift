import SwiftUI
import RocketChatSDK

struct LoginView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    /// Presented as the add-server sheet (vs full-window first login).
    var isSheet = false

    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @FocusState private var focus: Field?

    private enum Field {
        case server, username, password
    }

    private var isBusy: Bool {
        if case .loggingIn = session.loginFlow { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Image(systemName: "paperplane.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text("Rocket.Chat")
                    .font(.title.weight(.semibold))
                Text(isSheet ? "Add another workspace" : "Sign in to your workspace")
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField("Server", text: $server, prompt: Text("https://chat.example.com"))
                    .textContentType(.URL)
                    .focused($focus, equals: .server)
                TextField("Username or email", text: $username)
                    .textContentType(.username)
                    .focused($focus, equals: .username)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .onSubmit { submit() }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: 380)
            .disabled(isBusy)

            if let error = session.loginError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(Color.rcDanger)
            }

            HStack {
                if isSheet {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                Button(action: submit) {
                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Sign In").frame(minWidth: 80)
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isBusy || server.isEmpty || username.isEmpty || password.isEmpty)
            }
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 420)
        .onAppear {
            server = isSheet ? "" : session.serverURLString
            focus = isSheet ? .server : .username
        }
        .sheet(isPresented: .constant(isTwoFactor)) {
            TwoFactorSheet()
        }
    }

    private var isTwoFactor: Bool {
        if case .twoFactor = session.loginFlow { return true }
        return false
    }

    private func submit() {
        let server = server, username = username, password = password
        Task { await session.login(server: server, user: username, password: password) }
    }
}

/// Code-entry sheet for TOTP or emailed 2FA codes.
struct TwoFactorSheet: View {
    @Environment(AppSession.self) private var session

    @State private var code = ""
    @State private var method: TwoFactorMethod = .totp
    @FocusState private var codeFocused: Bool

    private var challenge: TwoFactorChallenge? {
        if case .twoFactor(let challenge) = session.loginFlow { return challenge }
        return nil
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: method == .email ? "envelope.badge.shield.half.filled" : "lock.shield")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            Text("Two-Factor Authentication")
                .font(.headline)
            Text(method == .email
                ? "Enter the code we sent to your email address."
                : "Enter the code from your authenticator app.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("000000", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.system(.title2, design: .monospaced))
                .multilineTextAlignment(.center)
                .frame(width: 140)
                .focused($codeFocused)
                .onSubmit { submit() }

            if let error = session.loginError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(Color.rcDanger)
            }

            if let methods = challenge?.availableMethods, methods.count > 1 {
                Picker("Method", selection: $method) {
                    ForEach(methods, id: \.self) { method in
                        Text(method == .totp ? "Authenticator app" : "Email code")
                            .tag(method)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
            }

            if method == .email {
                Button("Resend code") {
                    Task { await session.resendEmailCode() }
                }
                .buttonStyle(.link)
            }

            HStack {
                Button("Cancel") { session.cancelTwoFactor() }
                    .keyboardShortcut(.cancelAction)
                Button("Verify") { submit() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(28)
        .frame(width: 360)
        .onAppear {
            method = challenge?.defaultMethod ?? challenge?.availableMethods.first ?? .totp
            codeFocused = true
        }
    }

    private func submit() {
        let code = code.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { return }
        let method = method
        Task { await session.submitTwoFactor(code: code, method: method) }
    }
}
