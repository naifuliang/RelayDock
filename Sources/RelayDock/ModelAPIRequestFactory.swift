import Foundation

enum ModelProbeState: Equatable {
    case testing
    case available
    case failed(String)
}

enum ModelVerificationPolicy {
    static func isDefinitivelyUnavailable(statusCode: Int, responseData: Data) -> Bool {
        guard [400, 403, 404, 410, 422].contains(statusCode) else { return false }
        let message = String(data: responseData, encoding: .utf8)?.lowercased() ?? ""
        guard message.contains("model") else { return false }
        return [
            "not found", "does not exist", "unknown", "unsupported",
            "not available", "no access", "permission", "not authorized"
        ].contains(where: message.contains)
    }
}

enum ModelAPIRequestFactory {
    static func catalog(profile: GatewayProfile, apiKey: String, afterID: String? = nil) throws -> URLRequest {
        let base = try validatedBase(profile)
        let url: URL
        if profile.provider == .azureOpenAI, profile.azureDeploymentBasedURLs {
            throw ModelAPIError.azureDeploymentCatalogUnavailable
        }
        url = append(base, path: "models", underV1: true)
        var pagedURL = url
        if profile.provider == .anthropic, let afterID {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "after_id", value: afterID)]
            pagedURL = components?.url ?? url
        }
        var request = URLRequest(url: pagedURL)
        request.timeoutInterval = 15
        authorize(&request, profile: profile, apiKey: apiKey)
        return request
    }

    static func probe(profile: GatewayProfile, modelID: String, apiKey: String) throws -> URLRequest {
        let base = try validatedBase(profile)
        let url: URL
        let body: [String: Any]

        switch profile.provider {
        case .anthropic:
            url = append(base, path: "messages", underV1: true)
            body = [
                "model": modelID,
                "max_tokens": 1,
                "messages": [["role": "user", "content": "Reply OK"]]
            ]
        case .openAIResponses:
            url = append(base, path: "responses", underV1: true)
            body = ["model": modelID, "input": "Reply OK", "max_output_tokens": 16]
        case .azureOpenAI where profile.azureDeploymentBasedURLs:
            let deploymentPath = "deployments/\(modelID)/chat/completions"
            url = withAPIVersion(append(base, path: deploymentPath, underV1: false), profile: profile)
            body = [
                "messages": [["role": "user", "content": "Reply OK"]],
                "max_tokens": 1
            ]
        case .azureOpenAI, .openAICompatible:
            let endpoint = append(base, path: "chat/completions", underV1: true)
            url = profile.provider == .azureOpenAI ? withAPIVersion(endpoint, profile: profile) : endpoint
            body = [
                "model": modelID,
                "messages": [["role": "user", "content": "Reply OK"]],
                "max_completion_tokens": 1
            ]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request, profile: profile, apiKey: apiKey)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func legacyTokenFallback(
        profile: GatewayProfile,
        modelID: String,
        apiKey: String
    ) throws -> URLRequest? {
        guard profile.provider == .openAICompatible
                || (profile.provider == .azureOpenAI && !profile.azureDeploymentBasedURLs) else {
            return nil
        }
        var request = try probe(profile: profile, modelID: modelID, apiKey: apiKey)
        guard let data = request.httpBody,
              var body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        body.removeValue(forKey: "max_completion_tokens")
        body["max_tokens"] = 1
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func validatedBase(_ profile: GatewayProfile) throws -> URL {
        guard let base = EndpointValidator.normalizedURL(from: profile.baseURL) else {
            throw ModelAPIError.invalidEndpoint
        }
        return base
    }

    private static func append(_ base: URL, path: String, underV1: Bool) -> URL {
        let trimmedPath = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let lastComponent = trimmedPath.split(separator: "/").last.map(String.init) ?? ""
        let isVersionedAPIRoot = lastComponent.first?.lowercased() == "v"
            && Int(lastComponent.dropFirst()) != nil
        if underV1, !isVersionedAPIRoot {
            return base.appendingPathComponent("v1").appendingPathComponent(path)
        }
        return base.appendingPathComponent(path)
    }

    private static func withAPIVersion(_ url: URL, profile: GatewayProfile) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let version = profile.azureAPIVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        components?.queryItems = [URLQueryItem(name: "api-version", value: version.isEmpty ? "v1" : version)]
        return components?.url ?? url
    }

    private static func authorize(_ request: inout URLRequest, profile: GatewayProfile, apiKey: String) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        switch profile.provider {
        case .azureOpenAI:
            request.setValue(key, forHTTPHeaderField: "api-key")
        case .anthropic:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAICompatible, .openAIResponses:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }
}

enum ModelAPIError: LocalizedError, Equatable {
    case invalidEndpoint
    case azureDeploymentCatalogUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "端点地址无效"
        case .azureDeploymentCatalogUnavailable:
            return "Azure 旧版 deployment 模式无法自动列出 deployment ID，请手动添加"
        }
    }
}
