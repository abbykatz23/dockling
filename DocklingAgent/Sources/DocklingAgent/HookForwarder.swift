import Foundation

/// Shared by Dispatcher (forwarding real hook events to session children)
/// and SessionChildDelegate (forwarding synthesized events to babies, and
/// to itself during a self-relaunch handoff) — same POST-with-retry logic
/// either way, since both are talking to a local child's own hook port
/// that might not be listening yet.
final class HookForwarder {
    private let urlSession = URLSession(configuration: .ephemeral)

    /// Freshly spawned children need a beat to bind their listener, so a
    /// forward can arrive before the port is ready; retry briefly rather
    /// than dropping the event that triggered the spawn.
    func forward(rawJSON: [String: Any], to port: UInt16, attemptsLeft: Int) {
        guard let body = try? JSONSerialization.data(withJSONObject: rawJSON) else { return }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hook?token=\(sharedSecret)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 2

        urlSession.dataTask(with: request) { [weak self] _, response, error in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            if !ok, attemptsLeft > 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self?.forward(rawJSON: rawJSON, to: port, attemptsLeft: attemptsLeft - 1)
                }
            } else if !ok {
                fputs("[dockling] gave up forwarding to port \(port): \(error?.localizedDescription ?? "no response")\n", stderr)
            }
        }.resume()
    }
}
