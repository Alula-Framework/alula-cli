import AlulaCore
import AlulaWeb
import Foundation

/// File upload, both halves of alula 0.7.0 at once: the handler takes
/// `body: RequestBodyStream`, so the transport hands bytes through as they
/// arrive instead of buffering the request — that (plus `maxBodyBytes:`
/// overriding the global cap for just this route) is what lets an upload
/// accept far more than any sane global body limit. The stream feeds
/// `request.multipart()`, which parses parts without ever holding a file
/// in memory.
///
/// The demo digests instead of storing: what to *do* with uploaded bytes
/// (disk layout, object storage, virus scanning) is an application
/// decision this template shouldn't make for you, while the wire handling
/// is exactly what you'd keep. Swap the hasher loop for writes to your
/// storage of choice and the rest stands.
@Controller
struct AttachmentController {

    struct Received: Codable, ResponseEncodable {
        let field: String
        let filename: String?
        let contentType: String?
        let bytes: Int
    }

    @PostRoute("/attachments", maxBodyBytes: 64 << 20)
    func upload(_ context: RequestContext, body: RequestBodyStream) async throws -> [Received] {
        var received: [Received] = []
        for try await part in try context.request.multipart() {
            if part.filename != nil {
                // A file part: consume the stream chunk by chunk. Constant
                // memory no matter the size — this loop is where your
                // storage write goes.
                var bytes = 0
                for try await chunk in part.body {
                    bytes += chunk.count
                }
                received.append(
                    Received(
                        field: part.name,
                        filename: part.filename,
                        contentType: part.contentType?.essence,
                        bytes: bytes))
            } else {
                // An ordinary form field riding along with the file.
                let value = try await part.text()
                received.append(
                    Received(
                        field: part.name, filename: nil, contentType: nil,
                        bytes: value.utf8.count))
            }
        }
        guard !received.isEmpty else {
            throw HTTPError(.badRequest, "multipart body had no parts")
        }
        return received
    }
}
