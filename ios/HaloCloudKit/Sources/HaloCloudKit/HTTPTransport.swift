import Foundation

/// The network seam. Production is `URLSessionTransport`; tests inject a stub. Implementations must throw
/// `CloudError.network` (never the underlying error: its text can include the request URL, which carries
/// `?auth=<token>`), and `CancellationError` when the task is cancelled.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (data: Data, status: Int)
    /// Open a long-lived text stream (Server-Sent Events) and return its status plus lines (blank lines omitted).
    func openLines(_ request: URLRequest) async throws -> (status: Int, lines: AsyncThrowingStream<String, Error>)
}

public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let streamSession: URLSession

    public init(session: URLSession? = nil, streamSession: URLSession? = nil) {
        if let session { self.session = session } else {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 30
            c.waitsForConnectivity = false
            self.session = URLSession(configuration: c)
        }
        if let streamSession { self.streamSession = streamSession } else {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 120          // RTDB sends keep-alives every ~30 s
            c.timeoutIntervalForResource = .infinity
            self.streamSession = URLSession(configuration: c)
        }
    }

    public func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CloudError.network }
            return (data, http.statusCode)
        } catch is CancellationError { throw CancellationError() }
        catch let e as URLError where e.code == .cancelled { throw CancellationError() }
        catch { throw CloudError.network }
    }

    public func openLines(_ request: URLRequest) async throws -> (status: Int, lines: AsyncThrowingStream<String, Error>) {
        do {
            let (bytes, response) = try await streamSession.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw CloudError.network }
            let stream = AsyncThrowingStream<String, Error> { cont in
                let task = Task {
                    do { for try await line in bytes.lines { cont.yield(line) }; cont.finish() }
                    catch { cont.finish(throwing: (error is CancellationError || (error as? URLError)?.code == .cancelled) ? CancellationError() : CloudError.network) }
                }
                cont.onTermination = { _ in task.cancel() }
            }
            return (http.statusCode, stream)
        } catch is CancellationError { throw CancellationError() }
        catch let e as URLError where e.code == .cancelled { throw CancellationError() }
        catch let e as CloudError { throw e }
        catch { throw CloudError.network }
    }
}
