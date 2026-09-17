import Foundation

/// The seam under every HTTPS call, mirroring `CommandRunning` for
/// subprocesses: production talks to AWS, tests answer from fixtures. Without
/// it the SSO flow could only be exercised against a live identity centre.
nonisolated protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

nonisolated struct URLSessionTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AWSSSO.Failure.protocolError("response was not HTTP")
        }
        return (data, http)
    }
}

/// AWS IAM Identity Center, as far as EKS needs it.
///
/// The sandboxed build cannot run `aws sso login`, so it performs the device
/// authorization flow itself: register an OIDC client, ask for a device code,
/// let the user approve in a browser, then exchange the result for role
/// credentials. Those credentials are what `AWSSigV4` signs EKS tokens with.
///
/// Deliberately not read from `~/.aws`: the point of the store build is
/// working on a machine with no AWS CLI, and a flow that silently depends on
/// someone having run `aws sso login` recently is not that flow.
nonisolated struct AWSSSO: Sendable {
    let transport: any HTTPTransport

    init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    enum Failure: Error, Equatable {
        case protocolError(String)
        /// The user has not finished approving yet — the expected answer while
        /// polling, not a problem.
        case authorizationPending
        /// Polling faster than `interval`; AWS asks for a longer gap.
        case slowDown
        case declined(String)
        case expired
        case http(Int, String)
    }

    // MARK: Values

    struct Client: Sendable, Equatable {
        let id: String
        let secret: String
    }

    struct DeviceAuthorization: Sendable, Equatable {
        /// What the user types, shown so they can check it matches the browser.
        let userCode: String
        /// The URL with the code already embedded — what we actually open.
        let verificationURI: String
        let deviceCode: String
        /// Seconds AWS asks us to wait between polls.
        let interval: Int
        let expiresIn: Int
    }

    struct Account: Sendable, Equatable, Identifiable {
        let id: String
        let name: String
    }

    // MARK: Endpoints

    private func oidcURL(_ region: String, _ path: String) -> URL {
        URL(string: "https://oidc.\(region).amazonaws.com\(path)")!
    }

    private func portalURL(_ region: String, _ path: String) -> URL {
        URL(string: "https://portal.sso.\(region).amazonaws.com\(path)")!
    }

    private func decode(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// AWS reports flow state as a 400 with an `error` code, so the status
    /// alone cannot say whether polling should continue.
    private func failure(status: Int, body: Data) -> Failure {
        let json = try? decode(body)
        let code = json?["error"].string ?? ""
        switch code {
        case "authorization_pending": return .authorizationPending
        case "slow_down": return .slowDown
        case "expired_token": return .expired
        case "access_denied": return .declined("You declined the sign-in request.")
        default:
            let message = json?["error_description"].string ?? String(decoding: body, as: UTF8.self)
            return .http(status, message)
        }
    }

    private func post(_ url: URL, body: [String: JSONValue]) async throws -> JSONValue {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw failure(status: response.statusCode, body: data)
        }
        return try decode(data)
    }

    private func get(_ url: URL, bearer: String) async throws -> JSONValue {
        var request = URLRequest(url: url)
        // The portal uses its own header, not `Authorization`.
        request.setValue(bearer, forHTTPHeaderField: "x-amz-sso_bearer_token")
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw failure(status: response.statusCode, body: data)
        }
        return try decode(data)
    }

    // MARK: Device authorization flow

    /// Registers a public OIDC client. AWS has no pre-registration for this —
    /// every client registers itself, and the credentials are short-lived.
    func registerClient(region: String) async throws -> Client {
        let json = try await post(oidcURL(region, "/client/register"), body: [
            "clientName": .string("K-Dex"),
            "clientType": .string("public"),
            "scopes": .array([.string("sso:account:access")]),
        ])
        guard let id = json["clientId"].string, let secret = json["clientSecret"].string else {
            throw Failure.protocolError("client registration returned no credentials")
        }
        return Client(id: id, secret: secret)
    }

    func startDeviceAuthorization(
        region: String, startURL: String, client: Client
    ) async throws -> DeviceAuthorization {
        let json = try await post(oidcURL(region, "/device_authorization"), body: [
            "clientId": .string(client.id),
            "clientSecret": .string(client.secret),
            "startUrl": .string(startURL),
        ])
        guard let deviceCode = json["deviceCode"].string,
              let userCode = json["userCode"].string else {
            throw Failure.protocolError("device authorization returned no code")
        }
        // `verificationUriComplete` carries the code already filled in; the
        // bare URI would make the user type it by hand.
        let verification = json["verificationUriComplete"].string
            ?? json["verificationUri"].string
            ?? "https://device.sso.\(region).amazonaws.com/"
        return DeviceAuthorization(
            userCode: userCode,
            verificationURI: verification,
            deviceCode: deviceCode,
            // AWS omits the interval when it means the default of 5s.
            interval: json["interval"].int ?? 5,
            expiresIn: json["expiresIn"].int ?? 600
        )
    }

    /// One poll. Throws `.authorizationPending` until the user approves, which
    /// is the normal case rather than an error — the caller loops on it.
    func requestToken(
        region: String, client: Client, deviceCode: String
    ) async throws -> String {
        let json = try await post(oidcURL(region, "/token"), body: [
            "clientId": .string(client.id),
            "clientSecret": .string(client.secret),
            "deviceCode": .string(deviceCode),
            "grantType": .string("urn:ietf:params:oauth:grant-type:device_code"),
        ])
        guard let token = json["accessToken"].string else {
            throw Failure.protocolError("token response carried no access token")
        }
        return token
    }

    // MARK: Portal

    func listAccounts(region: String, accessToken: String) async throws -> [Account] {
        let json = try await get(
            portalURL(region, "/assignment/accounts?max_result=100"), bearer: accessToken
        )
        return json["accountList"].array.compactMap { entry in
            guard let id = entry["accountId"].string else { return nil }
            return Account(id: id, name: entry["accountName"].string ?? id)
        }
    }

    func listRoles(region: String, accessToken: String, accountID: String) async throws -> [String] {
        let json = try await get(
            portalURL(region, "/assignment/roles?account_id=\(accountID)&max_result=100"),
            bearer: accessToken
        )
        return json["roleList"].array.compactMap { $0["roleName"].string }
    }

    /// The temporary credentials `AWSSigV4` signs with.
    func roleCredentials(
        region: String, accessToken: String, accountID: String, roleName: String
    ) async throws -> AWSCredentials {
        let encodedRole = roleName.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed) ?? roleName
        let json = try await get(
            portalURL(region, "/federation/credentials?account_id=\(accountID)&role_name=\(encodedRole)"),
            bearer: accessToken
        )
        guard let credentials = Self.parseRoleCredentials(json) else {
            throw Failure.protocolError("credential response was missing keys")
        }
        return credentials
    }

    /// Split out from the request so the shape — including AWS's millisecond
    /// expiry, which is a decade off if read as seconds — is testable without
    /// a live identity centre.
    static func parseRoleCredentials(_ json: JSONValue) -> AWSCredentials? {
        let node = json["roleCredentials"]
        guard let id = node["accessKeyId"].string,
              let secret = node["secretAccessKey"].string else { return nil }
        let expiration = node["expiration"].double.map {
            Date(timeIntervalSince1970: $0 / 1000)
        }
        return AWSCredentials(
            accessKeyId: id,
            secretAccessKey: secret,
            sessionToken: node["sessionToken"].string,
            expiration: expiration
        )
    }
}
