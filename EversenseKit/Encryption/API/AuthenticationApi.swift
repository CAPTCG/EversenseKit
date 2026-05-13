// AuthenticationApi.swift
// Handles DMS OAuth token requests.
// Both async (for onboarding UI) and synchronous (for background BLE queue) variants.
//
// E3  transmitters use the EU DMS endpoints (ousiamapialpha.eversensedms.com)
// E365 transmitters use the US DMS endpoints (usiamapi.eversensedms.com)

import Foundation

enum AuthenticationApi {

    // MARK: - Endpoints

    /// US endpoints — used by Eversense 365
    private static let tokenUrlUS      = "https://usiamapi.eversensedms.com/connect/token"

    /// EU/OUS endpoints — used by Eversense E3
    private static let tokenUrlEU      = "https://ousiamapialpha.eversensedms.com/connect/token"

    private static let clientId        = "eversenseMMAAndroid"
    private static let clientSecret    = "6ksPx#]~wQ3U"

    private static let logger = EversenseLogger(category: "AuthenticationApi")

    // MARK: - Async (used by onboarding UI)

    static func login(username: String, password: String, isE3: Bool = false) async throws -> AuthResponse {
        let urlString = isE3 ? tokenUrlEU : tokenUrlUS
        guard let url = URL(string: urlString) else {
            logger.error("Could not create URL...")
            throw NSError(domain: "Could not create URL...", code: -1)
        }

        let message = buildFormBody(username: username, password: password)
        logger.debug("Logging in to eversensedms API (\(isE3 ? "EU/E3" : "US/365"))...")

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
    // Mirrors Kotlin EversenseHttpE3Util / EversenseHttp365Util .login()
    // which is called synchronously from networkExecutor.submit{}.get().

    static func loginSync(username: String, password: String, isE3: Bool = false) -> AuthResponse? {
        let urlString = isE3 ? tokenUrlEU : tokenUrlUS
        guard let url = URL(string: urlString) else {
            logger.error("Could not create URL...")
            return nil
        }

        let message = buildFormBody(username: username, password: password)
        logger.debug("loginSync: logging in to eversensedms API (\(isE3 ? "EU/E3" : "US/365"))...")

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
