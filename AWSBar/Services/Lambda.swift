import Foundation

struct LambdaProvider: ResourceProvider {
    let aws: AWSContext

    struct Response: Decodable { let functions: [Function] }

    struct Function: Decodable {
        let functionName: String
        let runtime: String?
        let memorySize: Int?
        let lastModified: String?
    }

    func list() async throws -> [Resource] {
        let response = try await aws.decode(Response.self, "lambda", "list-functions")
        return response.functions.sorted { $0.functionName < $1.functionName }.map { f in
            let detail = [f.runtime, f.memorySize.map { "\($0) MB" }].compactMap { $0 }.joined(separator: " · ")
            return Resource(id: f.functionName, name: f.functionName, detail: detail,
                            status: .neutral, statusText: "function", actions: [])
        }
    }

    func perform(_ action: ResourceAction, on resource: Resource) async throws {}
}
