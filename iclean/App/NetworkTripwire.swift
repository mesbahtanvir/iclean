#if DEBUG
    import Foundation

    /// DEBUG-only: when launched with `-NetworkTripwire`, records any attempt to load
    /// a URL so the NoNetwork UI test can assert there were none (SC-006).
    /// This file is the single allowed exception in scripts/check-no-network.sh.
    final class NetworkTripwire: URLProtocol {
        nonisolated(unsafe) static var attempts: [String] = []

        static func installIfRequested() {
            guard ProcessInfo.processInfo.arguments.contains("-NetworkTripwire") else { return }
            URLProtocol.registerClass(NetworkTripwire.self)
        }

        override class func canInit(with request: URLRequest) -> Bool {
            attempts.append(request.url?.absoluteString ?? "?")
            return true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }

        override func stopLoading() {}
    }
#endif
