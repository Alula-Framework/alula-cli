import Foundation
import Testing
@testable import App

/// The document the build wrote from this application's controllers.
@Suite("OpenAPI document")
struct OpenAPIDocumentTests {
    @Test("it describes the routes and the types they carry")
    func describesTheAPI() throws {
        let document = try #require(
            try JSONSerialization.jsonObject(with: Data(alulaOpenAPIJSON().utf8)) as? [String: Any])
        let paths = try #require(document["paths"] as? [String: Any])
        #expect(paths["/user"] != nil)
        let schemas = try #require(
            (document["components"] as? [String: Any])?["schemas"] as? [String: Any])
        #expect(schemas["CreateUserRequest"] != nil)
    }
}
