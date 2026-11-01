import Foundation

// Thin client for the local Go gateway (127.0.0.1:8230), the same
// console API the old Electron shell used. URLSession's shared cookie
// storage carries the m365hub_admin session cookie, so login persists
// across launches until logout.
enum API {
    static let base = URL(string: "http://127.0.0.1:8230")!

    static func request(_ path: String, method: String = "GET",
                        body: [String: Any]? = nil,
                        timeout: TimeInterval = 120,
                        completion: @escaping (Result<[String: Any], Error>) -> Void) {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = timeout
        if let body = body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                if let err = err { completion(.failure(err)); return }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                var json: [String: Any] = [:]
                if let data = data,
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    json = obj
                }
                if code >= 400 {
                    let msg = (json["message"] as? String) ?? (json["error"] as? String) ?? "HTTP \(code)"
                    completion(.failure(NSError(domain: "m365hub", code: code,
                                                userInfo: [NSLocalizedDescriptionKey: msg])))
                } else {
                    completion(.success(json))
                }
            }
        }.resume()
    }

    static func session(timeout: TimeInterval = 120, completion: @escaping (Bool) -> Void) {
        request("/api/admin/session", timeout: timeout) { r in
            if case .success(let d) = r { completion(d["loggedIn"] as? Bool ?? false) }
            else { completion(false) }
        }
    }

    static func login(password: String, completion: @escaping (Result<Bool, Error>) -> Void) {
        // Result value = mustChangePassword.
        request("/api/admin/login", method: "POST", body: ["password": password]) { r in
            switch r {
            case .success(let d):
                completion(.success(d["must_change_password"] as? Bool ?? false))
            case .failure(let e):
                completion(.failure(e))
            }
        }
    }

    static func models(completion: @escaping ([String]) -> Void) {
        request("/api/admin/models") { r in
            if case .success(let d) = r,
               let arr = d["models"] as? [[String: Any]] {
                completion(arr.compactMap { $0["id"] as? String })
            } else { completion(["gpt-4-auto"]) }
        }
    }

    static func accounts(completion: @escaping ([(id: String, email: String)]) -> Void) {
        request("/api/accounts") { r in
            if case .success(let d) = r,
               let arr = d["accounts"] as? [[String: Any]] {
                completion(arr.compactMap {
                    guard let id = $0["id"] as? String, !id.isEmpty,
                          let email = $0["email"] as? String else { return nil }
                    return (id, email)
                })
            } else { completion([]) }
        }
    }

    static func chat(model: String, messages: [[String: String]],
                     attachments: [[String: String]], accountID: String = "",
                     completion: @escaping (Result<String, Error>) -> Void) {
        var body: [String: Any] = ["model": model, "messages": messages, "attachments": attachments]
        if !accountID.isEmpty { body["account_id"] = accountID }
        request("/api/chat", method: "POST", body: body) { r in
            switch r {
            case .success(let d):
                completion(.success(d["content"] as? String ?? "(空回复)"))
            case .failure(let e):
                completion(.failure(e))
            }
        }
    }

    static func generateImage(prompt: String, model: String, accountID: String = "",
                              completion: @escaping (Result<(String, [String]), Error>) -> Void) {
        var body: [String: Any] = ["prompt": prompt, "model": model]
        if !accountID.isEmpty { body["account_id"] = accountID }
        request("/api/chat/image", method: "POST", body: body) { r in
            switch r {
            case .success(let d):
                completion(.success((d["text"] as? String ?? "已生成图片。",
                                     d["images"] as? [String] ?? [])))
            case .failure(let e):
                completion(.failure(e))
            }
        }
    }

    static func imageData(url: String, completion: @escaping (Data?) -> Void) {
        let full = url.hasPrefix("http") ? URL(string: url)! : base.appendingPathComponent(url)
        URLSession.shared.dataTask(with: full) { data, _, _ in
            DispatchQueue.main.async { completion(data) }
        }.resume()
    }
}
