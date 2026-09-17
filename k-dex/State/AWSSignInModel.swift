import AppKit
import Foundation
import Observation

/// Drives one AWS sign-in, start to stored credential.
///
/// Shaped by three rules learned the hard way (plan requirements 16–18): the
/// flow only ever starts because someone pressed a button, the device code
/// lives here rather than only in the browser, and expiry is a state you can
/// recover from rather than a dead end.
@Observable
@MainActor
final class AWSSignInModel {
    enum Phase: Equatable {
        case idle
        case registering
        /// The code is on screen and the browser can be reopened at will.
        case awaitingApproval(AWSSSO.DeviceAuthorization)
        case exchanging
        /// More than one role is assigned; the user picks.
        case choosingRole(accountID: String, roles: [String])
        case storing
        case done
        case expired
        case failed(String)
    }

    let target: KubeconfigMirror.EKSTarget
    let user: String

    var phase: Phase = .idle
    /// The AWS access portal URL. Typed once per account and remembered —
    /// deliberately not read from `~/.aws`, since the whole point is working
    /// without the AWS CLI installed.
    var startURL: String

    private let sso: AWSSSO
    private var client: AWSSSO.Client?
    private var accessToken: String?
    private var pollTask: Task<Void, Never>?

    init(user: String, target: KubeconfigMirror.EKSTarget, sso: AWSSSO = AWSSSO()) {
        self.user = user
        self.target = target
        self.sso = sso
        self.startURL = AWSSignInStore.startURL(forAccount: target.accountID) ?? ""
    }

    // No `deinit` cancellation: `deinit` is nonisolated and cannot touch
    // MainActor state. The poll is bounded by the device code's own expiry
    // (~10 minutes) and stops on `cancel()`, so nothing runs indefinitely.

    var canStart: Bool {
        guard case .idle = phase else { return false }
        return startURL.contains("://")
    }

    /// SSO usually lives in the same region as the cluster; nothing else in
    /// the kubeconfig hints at it.
    private var region: String { target.region }

    // MARK: Flow

    func start() {
        guard canStart else { return }
        AWSSignInStore.rememberStartURL(startURL, forAccount: target.accountID)
        phase = .registering
        pollTask = Task { await run() }
    }

    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        phase = .idle
    }

    /// Requirement 17: closing the browser must cost nothing.
    func openBrowser() {
        guard case .awaitingApproval(let auth) = phase,
              let url = URL(string: auth.verificationURI) else { return }
        NSWorkspace.shared.open(url)
    }

    func copyCode() {
        guard case .awaitingApproval(let auth) = phase else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(auth.userCode, forType: .string)
    }

    func chooseRole(_ role: String) {
        guard case .choosingRole(let accountID, _) = phase else { return }
        AWSSignInStore.rememberRole(role, forAccount: accountID)
        phase = .storing
        pollTask = Task { await finish(accountID: accountID, role: role) }
    }

    // MARK: Steps

    private func run() async {
        do {
            let client = try await sso.registerClient(region: region)
            self.client = client

            let auth = try await sso.startDeviceAuthorization(
                region: region, startURL: startURL, client: client
            )
            phase = .awaitingApproval(auth)
            // Opened once, on the press that started this — never on its own.
            openBrowser()

            let token = try await poll(auth: auth, client: client)
            guard !Task.isCancelled else { return }
            accessToken = token
            phase = .exchanging

            let accountID = try await resolveAccount(token: token)
            let roles = try await sso.listRoles(
                region: region, accessToken: token, accountID: accountID
            )
            guard !roles.isEmpty else {
                phase = .failed("This AWS account has no roles assigned to you.")
                return
            }
            // One role, or one remembered from last time, needs no question.
            let remembered = AWSSignInStore.role(forAccount: accountID)
            if let only = roles.count == 1 ? roles[0] : remembered.flatMap({ roles.contains($0) ? $0 : nil }) {
                phase = .storing
                await finish(accountID: accountID, role: only)
            } else {
                phase = .choosingRole(accountID: accountID, roles: roles)
            }
        } catch is CancellationError {
            return
        } catch AWSSSO.Failure.expired {
            phase = .expired
        } catch let failure as AWSSSO.Failure {
            phase = .failed(describe(failure))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Polls at the interval AWS asked for, backing off when told to.
    private func poll(auth: AWSSSO.DeviceAuthorization, client: AWSSSO.Client) async throws -> String {
        var interval = max(1, auth.interval)
        let deadline = Date().addingTimeInterval(TimeInterval(auth.expiresIn))
        while Date() < deadline {
            try Task.checkCancellation()
            do {
                return try await sso.requestToken(
                    region: region, client: client, deviceCode: auth.deviceCode
                )
            } catch AWSSSO.Failure.authorizationPending {
                try await Task.sleep(for: .seconds(interval))
            } catch AWSSSO.Failure.slowDown {
                // AWS asks for a longer gap rather than a retry at the same rate.
                interval += 2
                try await Task.sleep(for: .seconds(interval))
            }
        }
        throw AWSSSO.Failure.expired
    }

    /// The account the cluster's ARN named, when it named one; otherwise the
    /// only account the user can see.
    private func resolveAccount(token: String) async throws -> String {
        if let known = target.accountID { return known }
        let accounts = try await sso.listAccounts(region: region, accessToken: token)
        guard let first = accounts.first else {
            throw AWSSSO.Failure.protocolError("no AWS accounts are assigned to you")
        }
        return first.id
    }

    private func finish(accountID: String, role: String) async {
        guard let token = accessToken else { return }
        do {
            let credentials = try await sso.roleCredentials(
                region: region, accessToken: token, accountID: accountID, roleName: role
            )
            try CredentialCache.store(
                CredentialCache.Entry(aws: .init(
                    accessKeyId: credentials.accessKeyId,
                    secretAccessKey: credentials.secretAccessKey,
                    sessionToken: credentials.sessionToken,
                    cluster: target.cluster,
                    region: target.region,
                    expiresAt: credentials.expiration
                )),
                for: user
            )
            phase = .done
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func describe(_ failure: AWSSSO.Failure) -> String {
        switch failure {
        case .declined(let message): return message
        case .expired: return "The sign-in request expired."
        case .http(let status, let message): return "AWS returned \(status): \(message)"
        case .protocolError(let message): return message
        case .authorizationPending, .slowDown: return "Still waiting for approval."
        }
    }
}

/// Remembers what the user told us, so a second sign-in is one press.
nonisolated enum AWSSignInStore {
    private static func key(_ prefix: String, _ account: String?) -> String {
        "aws-\(prefix)-\(account ?? "default")"
    }

    static func startURL(forAccount account: String?) -> String? {
        UserDefaults.standard.string(forKey: key("start-url", account))
            // A portal is usually shared across accounts, so one typed for any
            // account is a better guess than an empty field.
            ?? UserDefaults.standard.string(forKey: key("start-url", nil))
    }

    static func rememberStartURL(_ url: String, forAccount account: String?) {
        UserDefaults.standard.set(url, forKey: key("start-url", account))
        UserDefaults.standard.set(url, forKey: key("start-url", nil))
    }

    static func role(forAccount account: String?) -> String? {
        UserDefaults.standard.string(forKey: key("role", account))
    }

    static func rememberRole(_ role: String, forAccount account: String?) {
        UserDefaults.standard.set(role, forKey: key("role", account))
    }
}
