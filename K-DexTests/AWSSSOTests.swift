import Foundation
import Testing
@testable import K_Dex

/// Answers from canned responses so the flow can be exercised without an
/// identity centre — the same trick `Commands.runner` plays for subprocesses.
private struct StubTransport: HTTPTransport {
    let responses: [(status: Int, body: String)]
    let recorder: Recorder

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [URLRequest] = []
        private var _index = 0

        var calls: [URLRequest] { lock.withLock { _calls } }

        func next(_ responses: [(status: Int, body: String)], _ request: URLRequest) -> (Int, String) {
            lock.withLock {
                _calls.append(request)
                let response = responses[min(_index, responses.count - 1)]
                _index += 1
                return (response.status, response.body)
            }
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body) = recorder.next(responses, request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        return (Data(body.utf8), response)
    }
}

// The device flow's failure modes are the interesting part: AWS reports "keep
// waiting" as an HTTP 400, so a client that trusts the status code alone gives
// up at the exact moment the user is reading the approval screen.
struct AWSSSOTests {
    private func sso(_ responses: [(status: Int, body: String)]) -> (AWSSSO, StubTransport.Recorder) {
        let recorder = StubTransport.Recorder()
        return (AWSSSO(transport: StubTransport(responses: responses, recorder: recorder)), recorder)
    }

    @Test func registrationReturnsTheClientCredentials() async throws {
        let (client, recorder) = sso([(200, #"{"clientId":"cid","clientSecret":"sec"}"#)])
        let result = try await client.registerClient(region: "ap-southeast-3")
        #expect(result == AWSSSO.Client(id: "cid", secret: "sec"))
        #expect(recorder.calls.first?.url?.absoluteString
            == "https://oidc.ap-southeast-3.amazonaws.com/client/register")
    }

    @Test func deviceAuthorizationPrefersTheURLWithTheCodeAlreadyIn() async throws {
        let body = #"{"deviceCode":"dev","userCode":"ABCD-EFGH","#
            + #""verificationUri":"https://device.sso/","#
            + #""verificationUriComplete":"https://device.sso/?user_code=ABCD-EFGH","#
            + #""interval":3,"expiresIn":600}"#
        let (client, _) = sso([(200, body)])
        let auth = try await client.startDeviceAuthorization(
            region: "ap-southeast-3", startURL: "https://example.awsapps.com/start",
            client: .init(id: "cid", secret: "sec")
        )
        #expect(auth.userCode == "ABCD-EFGH")
        // Typing the code by hand is the fallback, not the plan.
        #expect(auth.verificationURI.contains("user_code=ABCD-EFGH"))
        #expect(auth.interval == 3)
    }

    @Test func aMissingIntervalMeansAWSsDefaultOfFiveSeconds() async throws {
        let (client, _) = sso([(200, #"{"deviceCode":"d","userCode":"U","verificationUri":"https://x/"}"#)])
        let auth = try await client.startDeviceAuthorization(
            region: "us-east-1", startURL: "https://x/start", client: .init(id: "c", secret: "s")
        )
        #expect(auth.interval == 5)
    }

    @Test func pendingApprovalIsNotAFailure() async throws {
        // The whole flow hinges on this: AWS says "still waiting" with a 400.
        let (client, _) = sso([(400, #"{"error":"authorization_pending"}"#)])
        await #expect(throws: AWSSSO.Failure.authorizationPending) {
            try await client.requestToken(
                region: "us-east-1", client: .init(id: "c", secret: "s"), deviceCode: "d"
            )
        }
    }

    @Test func slowDownAndExpiryAndDenialAreDistinguished() async throws {
        for (body, expected) in [
            (#"{"error":"slow_down"}"#, AWSSSO.Failure.slowDown),
            (#"{"error":"expired_token"}"#, AWSSSO.Failure.expired),
        ] {
            let (client, _) = sso([(400, body)])
            await #expect(throws: expected) {
                try await client.requestToken(
                    region: "us-east-1", client: .init(id: "c", secret: "s"), deviceCode: "d"
                )
            }
        }
        let (denied, _) = sso([(400, #"{"error":"access_denied"}"#)])
        await #expect(throws: AWSSSO.Failure.declined("You declined the sign-in request.")) {
            try await denied.requestToken(
                region: "us-east-1", client: .init(id: "c", secret: "s"), deviceCode: "d"
            )
        }
    }

    @Test func tokenIsReturnedOnApproval() async throws {
        let (client, recorder) = sso([(200, #"{"accessToken":"at","expiresIn":3600}"#)])
        let token = try await client.requestToken(
            region: "us-east-1", client: .init(id: "c", secret: "s"), deviceCode: "d"
        )
        #expect(token == "at")
        #expect(recorder.calls.first?.httpMethod == "POST")
    }

    @Test func accountsAndRolesComeFromThePortalWithItsOwnHeader() async throws {
        let (client, recorder) = sso([(200, """
        {"accountList":[{"accountId":"134604498185","accountName":"Sandbox"}]}
        """)])
        let accounts = try await client.listAccounts(region: "ap-southeast-3", accessToken: "at")
        #expect(accounts == [AWSSSO.Account(id: "134604498185", name: "Sandbox")])
        // Not `Authorization` — the portal uses a bespoke header.
        #expect(recorder.calls.first?.value(forHTTPHeaderField: "x-amz-sso_bearer_token") == "at")
    }

    @Test func roleCredentialExpiryIsMillisecondsNotSeconds() {
        // Read as seconds this lands in 1970; the credential would look
        // permanently expired and the shim would refuse every request.
        let json = try! JSONDecoder().decode(JSONValue.self, from: Data("""
        {"roleCredentials":{"accessKeyId":"AKIA","secretAccessKey":"sec",
         "sessionToken":"tok","expiration":1789689600000}}
        """.utf8))
        let credentials = AWSSSO.parseRoleCredentials(json)
        #expect(credentials?.accessKeyId == "AKIA")
        #expect(credentials?.sessionToken == "tok")
        #expect(credentials?.expiration == Date(timeIntervalSince1970: 1_789_689_600))
    }

    @Test func aCredentialResponseMissingKeysIsRejectedRatherThanHalfBuilt() {
        let json = try! JSONDecoder().decode(JSONValue.self, from: Data(
            #"{"roleCredentials":{"accessKeyId":"AKIA"}}"#.utf8))
        #expect(AWSSSO.parseRoleCredentials(json) == nil)
    }
}
