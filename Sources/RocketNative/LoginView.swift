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
        .sheet(isPresented: .constant(twoFactorChallenge != nil)) {
            if let challenge = twoFactorChallenge {
                TwoFactorSheet(
                    challenge: challenge,
                    errorText: session.loginError,
                    notice: session.twoFactorNotice,
                    isVerifying: session.isVerifyingTwoFactor,
                    onSubmit: { code in
                        Task { await session.submitTwoFactor(code: code) }
                    },
                    onCancel: { session.cancelTwoFactor() },
                    onResend: { Task { await session.resendEmailCode() } })
            }
        }
    }

    private var twoFactorChallenge: TwoFactorChallenge? {
        if case .twoFactor(let challenge) = session.loginFlow { return challenge }
        return nil
    }

    private func submit() {
        let server = server, username = username, password = password
        Task { await session.login(server: server, user: username, password: password) }
    }
}

/// Code-entry sheet for a 2FA challenge, shared by login and mid-session
/// prompts. Pure: the caller owns the flow and passes state and actions in.
/// No method picker — the server verifies with `challenge.method`.
struct TwoFactorSheet: View {
    let challenge: TwoFactorChallenge
    /// Extra context under the title (e.g. the workspace, with several).
    var subtitle: String?
    /// Error from the last attempt; a retry challenge shows its own.
    var errorText: String?
    /// Informational line, e.g. after a resend.
    var notice: String?
    var isVerifying = false
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    var onResend: (() -> Void)?

    @State private var code = ""
    @FocusState private var codeFocused: Bool

    private var method: TwoFactorMethod { challenge.method }

    private var title: String {
        method == .password ? "Please enter your password" : "Two-Factor Authentication"
    }

    private var instructions: String {
        switch method {
        case .totp: "Open your authentication app and enter the code."
        case .email: "Enter the code we just emailed you."
        case .password: "For your security, you must enter your account password to continue."
        }
    }

    private var icon: String {
        switch method {
        case .totp: "lock.shield"
        case .email: "envelope.badge.shield.half.filled"
        case .password: "key"
        }
    }

    private var displayedError: String? {
        if let errorText { return errorText }
        guard challenge.isRetry else { return nil }
        return method == .password ? "Incorrect password." : "Invalid code."
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Text(instructions)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Group {
                if method == .password {
                    SecureField("Password", text: $code)
                        .textContentType(.password)
                        .frame(width: 220)
                } else {
                    // Not digit-only: TOTP also accepts backup codes.
                    TextField("000000", text: $code)
                        .font(.system(.title2, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .frame(width: 140)
                }
            }
            .textFieldStyle(.roundedBorder)
            .focused($codeFocused)
            .disabled(isVerifying)
            .onSubmit { submit() }

            if let displayedError {
                Text(displayedError)
                    .font(.callout)
                    .foregroundStyle(Color.rcDanger)
            } else if let notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if method == .email, let onResend {
                Button("Resend email", action: onResend)
                    .buttonStyle(.link)
                    .disabled(isVerifying)
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(action: submit) {
                    if isVerifying {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Verify")
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isVerifying || trimmedCode.isEmpty)
            }
        }
        .padding(28)
        .frame(width: 360)
        .onAppear { codeFocused = true }
        .onChange(of: isVerifying) { _, verifying in
            // A rejected code comes back with an error: clear it for a fresh try.
            guard !verifying, displayedError != nil else { return }
            code = ""
            codeFocused = true
        }
    }

    private var trimmedCode: String {
        code.trimmingCharacters(in: .whitespaces)
    }

    private func submit() {
        // Passwords go as typed; only codes are trimmed.
        let value = method == .password ? code : trimmedCode
        guard !trimmedCode.isEmpty, !isVerifying else { return }
        onSubmit(value)
    }
}
