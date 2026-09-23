import AlulaCore
import AlulaWeb
import AlulaWebTesting
import Foundation
import Testing
@testable import App

/// The upload route, driven the way the transport drives it: the multipart
/// body delivered as a live chunk stream, boundaries free to straddle chunk
/// seams.
@Suite("AttachmentController — streaming multipart upload")
struct AttachmentControllerTests {

    @Test("a file and its form fields arrive, sizes intact")
    func uploadRoundTrip() async throws {
        let client = try TestClient(
            routes: AttachmentController.alulaRoutes { _ in AttachmentController() })

        let boundary = "----DemoBoundary"
        let filePayload = String(repeating: "b", count: 50_000)
        let wire = Data(
            ("--\(boundary)\r\n"
                + "Content-Disposition: form-data; name=\"caption\"\r\n\r\n"
                + "the quarterly chart\r\n"
                + "--\(boundary)\r\n"
                + "Content-Disposition: form-data; name=\"file\"; filename=\"chart.png\"\r\n"
                + "Content-Type: image/png\r\n\r\n"
                + filePayload + "\r\n"
                + "--\(boundary)--").utf8)
        // Awkward chunk sizes on purpose: the boundary WILL straddle seams.
        let chunks = stride(from: 0, to: wire.count, by: 1_111).map {
            Data(wire[$0..<min($0 + 1_111, wire.count)])
        }

        let response = await client.post(
            "/attachments",
            headers: [.contentType: "multipart/form-data; boundary=\(boundary)"],
            bodyChunks: chunks)
        #expect(response.status == .ok)

        let received = try response.decodeJSON([AttachmentController.Received].self)
        #expect(received.count == 2)
        #expect(received[0].field == "caption")
        #expect(received[0].bytes == "the quarterly chart".utf8.count)
        #expect(received[1].filename == "chart.png")
        #expect(received[1].contentType == "image/png")
        #expect(received[1].bytes == 50_000)
    }

    @Test("a body that is not multipart is refused as a 415")
    func nonMultipartRefused() async throws {
        let client = try TestClient(
            routes: AttachmentController.alulaRoutes { _ in AttachmentController() })
        let response = await client.post(
            "/attachments",
            headers: [.contentType: "application/json"],
            bodyChunks: [Data("{}".utf8)])
        #expect(response.status == .unsupportedMediaType)
    }
}
