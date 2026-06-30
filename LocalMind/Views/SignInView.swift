//
//  SignInView.swift
//  LocalMind
//
//  First-launch / signed-out screen. Sign in with Apple is real (native
//  AuthenticationServices, no backend needed). Google is presented as a
//  local-profile shortcut with a clear disclosure that real Google OAuth
//  would require a backend. Email is a plain local profile.
//

import SwiftUI
import AuthenticationServices

struct SignInView: View {
    let profileStore: ProfileStore

    @State private var mode: Mode = .options
    @State private var email: String = ""
    @State private var name: String = ""
    @State private var errorMessage: String = ""
    @AppStorage("isDarkMode") private var isDarkMode: Bool = true

    enum Mode: Equatable {
        case options
        case email(method: SignInMethod)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: AppTheme.Spacing.lg) {
                    switch mode {
                    case .options:
                        signInOptions
                    case .email(let method):
                        emailForm(method: method)
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.xl)
                .padding(.vertical, AppTheme.Spacing.xl)
                .frame(maxWidth: 420)
            }

            footer
        }
        .frame(minWidth: 520, minHeight: 640)
        .background(AppTheme.Colors.backgroundPrimary)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(AppTheme.Colors.accentGradient)
                .padding(.top, AppTheme.Spacing.xl)

            Text("Welcome to LocalMind")
                .font(.system(size: 26, weight: .bold, design: .serif))

            Text(headerSubtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .padding(.horizontal, AppTheme.Spacing.lg)
                .padding(.bottom, AppTheme.Spacing.md)
        }
    }

    private var headerSubtitle: String {
        switch mode {
        case .options:
            return "Create a local profile so your Personal Context follows you across every AI you connect."
        case .email(.email):
            return "We'll create a local profile. Nothing is sent over the network."
        case .email(.google):
            return "We'll create a local profile labeled with your Google email. Real Google OAuth requires a backend — see About."
        case .email(.apple), .email(.guest):
            return "" // unreachable — apple and guest don't use the email form
        }
    }

    // MARK: - Options

    private var signInOptions: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            // Real Sign in with Apple
            SignInWithAppleButton(.signIn,
                onRequest: { request in
                    request.requestedScopes = [.fullName, .email]
                },
                onCompletion: handleAppleResult
            )
            .signInWithAppleButtonStyle(isDarkMode ? .white : .black)
            .frame(height: 44)

            providerButton(
                title: "Continue with Google",
                systemImage: "g.circle.fill",
                tint: Color(red: 0.92, green: 0.27, blue: 0.20)
            ) {
                withAnimation {
                    errorMessage = ""
                    mode = .email(method: .google)
                }
            }

            providerButton(
                title: "Continue with Email",
                systemImage: "envelope.fill",
                tint: AppTheme.Colors.accentPrimary
            ) {
                withAnimation {
                    errorMessage = ""
                    mode = .email(method: .email)
                }
            }

            Button {
                continueAsGuest()
            } label: {
                Text("Continue as Guest")
                    .font(.callout)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .underline()
            }
            .buttonStyle(.plain)
            .padding(.top, AppTheme.Spacing.xs)

            if !profileStore.profiles.isEmpty {
                Divider().padding(.vertical, AppTheme.Spacing.sm)
                existingProfilesSection
            }

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.statusOffline)
                    .multilineTextAlignment(.center)
            }

            Text("LocalMind runs on your Mac. Profiles are stored locally and never leave this device.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, AppTheme.Spacing.md)
        }
    }

    private var existingProfilesSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("Or pick an existing profile")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(profileStore.profiles) { profile in
                Button {
                    profileStore.selectProfile(profile.id)
                } label: {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        AvatarCircle(initials: profile.initials, size: 32, imageData: profile.avatarImageData)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(profile.displayName)
                                .font(AppTheme.Typography.body)
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                            Text(profile.email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: methodIcon(profile.signInMethod))
                            .foregroundStyle(.secondary)
                    }
                    .padding(AppTheme.Spacing.sm)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadius)
                            .fill(AppTheme.Colors.backgroundSecondary)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Email form

    private func emailForm(method: SignInMethod) -> some View {
        VStack(spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("How should we address you?", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Email").font(.caption).foregroundStyle(.secondary)
                TextField("you@example.com", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)
                    .disableAutocorrection(true)
            }

            if method == .google {
                disclosureCard(
                    title: "About Google sign-in",
                    body: "LocalMind has no backend, so this just creates a local profile labeled with your Google email. To wire real Google OAuth you'd need to register a client ID and run a token-verification server."
                )
            }

            HStack {
                Button("Back") {
                    withAnimation {
                        mode = .options
                        errorMessage = ""
                    }
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(method == .google ? "Continue with Google" : "Create profile") {
                    submitEmailForm(method: method)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isFormValid)
            }
            .padding(.top, AppTheme.Spacing.sm)

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.statusOffline)
            }
        }
    }

    private var isFormValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        email.contains("@") && email.contains(".")
    }

    private func submitEmailForm(method: SignInMethod) {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmedName.isEmpty, trimmedEmail.contains("@") else {
            errorMessage = "Please enter a name and a valid email."
            return
        }
        profileStore.createProfile(
            displayName: trimmedName,
            email: trimmedEmail,
            method: method
        )
    }

    // MARK: - Guest

    private func continueAsGuest() {
        // Number the guest so multiple "Guest" profiles stay distinguishable.
        let existingGuests = profileStore.profiles.filter { $0.signInMethod == .guest }.count
        let name = existingGuests == 0 ? "Guest" : "Guest \(existingGuests + 1)"
        profileStore.createProfile(
            displayName: name,
            email: "",
            method: .guest
        )
    }

    // MARK: - Apple

    private func handleAppleResult(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential else {
                errorMessage = "Unexpected Apple credential."
                return
            }
            let appleID = credential.user
            // Apple only returns name/email on the FIRST sign-in. On subsequent
            // sign-ins we look the profile up by Apple ID instead.
            let givenName = credential.fullName?.givenName ?? ""
            let familyName = credential.fullName?.familyName ?? ""
            let fullName = [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " ")
            let email = credential.email ?? ""

            // Fall back to whatever we can if Apple withholds info this time
            let displayName = fullName.isEmpty ? "Apple User" : fullName
            profileStore.createProfile(
                displayName: displayName,
                email: email,
                method: .apple,
                appleUserID: appleID
            )
        case .failure(let error):
            // User cancellation is not an error worth showing.
            if (error as NSError).code == ASAuthorizationError.canceled.rawValue { return }
            errorMessage = "Apple sign-in failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Image(systemName: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Local-first. Your data stays on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, AppTheme.Spacing.xl)
        .padding(.vertical, AppTheme.Spacing.md)
        .background(AppTheme.Colors.backgroundSecondary.opacity(0.5))
    }

    // MARK: - Pieces

    private func providerButton(title: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                Text(title)
                    .fontWeight(.medium)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadius)
                    .fill(AppTheme.Colors.backgroundSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadius)
                    .stroke(AppTheme.Colors.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func disclosureCard(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(AppTheme.Colors.accentPrimary)
                Text(title).font(.caption).fontWeight(.semibold)
            }
            Text(body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Dimensions.cornerRadiusSmall)
                .fill(AppTheme.Colors.accentPrimary.opacity(0.08))
        )
    }

    private func methodIcon(_ method: SignInMethod) -> String {
        switch method {
        case .apple: return "applelogo"
        case .google: return "g.circle"
        case .email: return "envelope"
        case .guest: return "person.crop.circle.dashed"
        }
    }
}

struct AvatarCircle: View {
    let initials: String
    let size: CGFloat
    var imageData: Data? = nil

    var body: some View {
        ZStack {
            if let data = imageData, let nsImage = NSImage(data: data) {
                // Render uploaded avatar — cropped to a circle. We resize on
                // import (see ProfileSettingsView.optimizeAvatar) so the
                // SwiftUI Image doesn't need to scale down a huge bitmap on
                // every redraw.
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(AppTheme.Colors.accentGradient)
                Text(initials)
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }
}
