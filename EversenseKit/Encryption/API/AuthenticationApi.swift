// AuthenticationApi.swift
// Handles DMS OAuth token requests.
// Both async (for onboarding UI) and synchronous (for background BLE queue) variants.

import Foundation

enum AuthenticationApi {
    private static let tokenUrl    = "https://usiamapi.eversensedms.com/connect/token"
    private static let clientId    = "eversenseMMAAndroid"
    private static let clientSecret = "6ksPx#]~wQ3U"

    private static let logger = EversenseLogger(category: "AuthenticationApi")

    // MARK: - Async (used by onboarding UI)

    static func login(username: String, password: String) async throws -> AuthResponse {
        guard let url = URL(string: tokenUrl) else {
            logger.error("Could not create URL...")
            throw NSError(domain: "Could not create URL...", code: -1)
        }

        let message = buildFormBody(username: username, password: password)
        logger.debug("Logging in to eversensedms API...")

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = message.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = "Got invalid response from Authentication: \((response as? HTTPURLResponse)?.statusCode ?? -1) \(String(data: data, encoding: .utf8) ?? "No data")"
            logger.error(msg)
            throw NSError(domain: msg, code: -1)
        }

        logger.debug("Login completed!")
        return try JSONDecoder().decode(AuthResponse.self, from: data)
    }

    // MARK: - Synchronous (used by DMSUploadApi.getOrRefreshToken from BLE queue)
    // Mirrors Kotlin EversenseHttp365Util.login() which is called synchronously
    // from networkExecutor.submit{}.get() in authV2flow().

    static func loginSync(username: String, password: String) -> AuthResponse? {
        guard let url = URL(string: tokenUrl) else {
            logger.error("Could not create URL...")
            return nil
        }

        let message = buildFormBody(username: username, password: password)
        logger.debug("loginSync: logging in to eversensedms API...")

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = message.data(using: .utf8)

        var result: AuthResponse?
        let sema = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { sema.signal() }
            if let error = error {
                self.logger.error("loginSync error: \(error.localizedDescription)")
                return
            }
            guard let data = data,
                  let http = response as? HTTPURLResponse else { return }
            if http.statusCode >= 400 {
                self.logger.error("loginSync failed — status: \(http.statusCode), body: \(String(data: data, encoding: .utf8) ?? "")")
                return
            }
            result = try? JSONDecoder().decode(AuthResponse.self, from: data)
            self.logger.info("loginSync success — status: \(http.statusCode)")
        }.resume()
        sema.wait()
        return result
    }

    // MARK: - Helpers

    /// Build the OAuth form body, percent-encoding username and password.
    /// Mirrors Kotlin: URLEncoder.encode(state.username, "UTF-8").
    private static func buildFormBody(username: String, password: String) -> String {
        let encodedUsername = username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? username
        let encodedPassword = password.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? password
        return [
            "grant_type=password",
            "client_id=\(clientId)",
            "client_secret=\(clientSecret)",
            "username=\(encodedUsername)",
            "password=\(encodedPassword)"
        ].joined(separator: "&")
    }
}
