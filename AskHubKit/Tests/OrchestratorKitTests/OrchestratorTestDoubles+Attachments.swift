import AskHubKit
import Foundation
@testable import OrchestratorKit

// 依頼の添付（Discussion #669）
extension FakeGitHub {
    func setAttachmentContents(_ contents: [String: Data]) {
        state.withLock { $0.attachmentContents = contents }
    }

    func setAppendAttachmentsFails(_ fails: Bool) {
        state.withLock { $0.appendAttachmentsFails = fails }
    }

    var fetchedAttachments: [String] {
        state.withLock { $0.fetchedAttachments }
    }

    var appendedAttachments: [String] {
        state.withLock { $0.appendedAttachments }
    }

    func attachmentContent(_ marker: AttachmentMarker, in repository: String) async throws -> Data {
        let data = state.withLock { state in
            state.fetchedAttachments.append(marker.name)
            return state.attachmentContents[marker.sha]
        }
        guard let data else {
            throw AttachmentFetchError.notFound
        }
        // 本物と同じく、大きさと blob SHA を確かめる
        guard data.count == marker.size, GitBlobSHA.of(data) == marker.sha else {
            throw AttachmentFetchError.shaMismatch
        }
        return data
    }

    func appendAttachments(_ markers: [AttachmentMarker], toDiscussion number: Int, in repository: String) async throws {
        try state.withLock { state in
            if state.appendAttachmentsFails {
                throw TestError()
            }
            state.appendedAttachments.append("#\(number): \(markers.map(\.name).joined(separator: ","))")
        }
    }
}

extension FakeRuntime {
    var directoryContentsDuringRun: [[String: Data]] {
        state.withLock { $0.directoryContentsDuringRun }
    }

    /// 引数のうちディレクトリであるものの中身（ファイル名 → 中身）
    static func directoryContents(in arguments: [String]) -> [String: Data] {
        var contents: [String: Data] = [:]
        for argument in arguments where FileManager.default.fileExists(atPath: argument) {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: argument)) ?? [] {
                contents[name] = FileManager.default.contents(atPath: (argument as NSString).appendingPathComponent(name))
            }
        }
        return contents
    }
}

extension AttachmentMarker {
    /// `data` の本当の blob SHA を持つ目印
    static func fixture(name: String, type: String, data: Data, id: String = "3f2504e0-4f89-11d3-9a0c-0305e82c3301") -> Self {
        AttachmentMarker(
            path: "files/\(id)/\(AttachmentFileName.sanitized(name))",
            sha: GitBlobSHA.of(data),
            commit: String(repeating: "c", count: 40),
            name: name,
            size: data.count,
            type: type
        )
    }
}
