import AskHubKit
import Foundation

/// リリースのワークフローの起動に失敗したときの説明。リリース準備と最新情報の確定で、同じ HTTP の状態を同じ作りの文言にする
extension ReleaseWorkflow {
    /// 画面に出す名前（「リリース準備を起動できませんでした」の「リリース準備」）
    nonisolated var actionName: String {
        switch self {
        case .prepare: "リリース準備"
        case .notes: "最新情報の確定"
        case .finish: "リリース後作業"
        case .sync: "ビルドの紐付けと配信の検知"
        }
    }

    /// アプリが送る inputs の名前（422 の説明に出す）
    nonisolated var inputNames: String {
        switch self {
        case .prepare, .finish: "version"
        case .notes: "version・whats_new"
        case .sync: "なし"
        }
    }

    /// 起動（`workflow_dispatch`）の失敗の説明。`ref` は起動したブランチ
    func dispatchFailureMessage(_ error: WorkflowError, ref: String) -> String {
        let prefix = "\(actionName)を起動できませんでした。"
        switch error {
        case .permissionDenied:
            // レート制限の 403 は GitHubClient が rateLimited にするのでここには来ない
            return prefix + "トークンに、このリポジトリの Actions の Read and write と Contents の Read があるか確かめてください。"
                + "設定で権限を付けたトークンを保存し直してください"

        case .workflowNotFound:
            return "このリポジトリには\(actionName)のワークフロー（\(file)）がありません（Actions が無効か、トークンから見えないときも同じです）"

        case .dispatchNotSupported:
            break
        }
        switch error.dispatchRejection {
        case .workflowDisabled:
            return prefix + "\(actionName)のワークフローが無効にされています。GitHub のリポジトリの Actions で有効にしてください"

        case .noWorkflowDispatchTrigger:
            return prefix + "\(ref) の \(file) に手動実行（workflow_dispatch）がありません"

        case .refNotFound:
            return prefix + "このリポジトリに \(ref) ブランチがありません"

        case .invalidInputs:
            return prefix + "ワークフローの入力（\(inputNames)）が、このアプリの送るものと合いません。ワークフローかアプリを新しくしてください"
                + Self.detail(of: error)

        case .other, nil:
            return prefix + "GitHub が受け付けませんでした" + Self.detail(of: error)
        }
    }

    private static func detail(of error: WorkflowError) -> String {
        guard case .dispatchNotSupported(let message?) = error else {
            return ""
        }
        return "（\(message)）"
    }
}

extension ReleaseRequestModel {
    /// リリースの状態を読むときの失敗の説明。読む段階の 403 は起動の失敗ではないので、起動の文言にしない。
    /// `workflow` は読んだワークフローの名前とファイル名（`nil` ならリリース準備。進み具合の各段は、その段のワークフローを渡す）
    static func readingMessage(for error: any Error, workflow: (name: String, file: String)? = nil) -> String {
        switch error {
        case WorkflowError.permissionDenied:
            // レート制限の 403 は GitHubClient が rateLimited にするのでここには来ない
            return "リリースの状態を読めませんでした。トークンに、このリポジトリの Actions の Read and write と Contents の Read があるか確かめてください。"
                + "設定で権限を付けたトークンを保存し直してください"

        case WorkflowError.workflowNotFound:
            guard let workflow else {
                return message(for: error)
            }
            return "このリポジトリには\(workflow.name)のワークフロー（\(workflow.file)）がありません（Actions が無効か、トークンから見えないときも同じです）"

        case WorkflowError.dispatchNotSupported(let detail):
            guard let workflow else {
                return message(for: error)
            }
            // 読み取りで 422 が来ても、起動の文言（リリース準備を起動できませんでした）にしない
            return "\(workflow.name)の run を読めませんでした" + (detail.map { "（\($0)）" } ?? "")

        default:
            return message(for: error)
        }
    }

    /// 失敗の説明。トークンの値は含めない
    static func message(for error: any Error) -> String {
        switch error {
        case is IdeaRequestModel.MissingTokenError:
            return "トークンが未設定です。設定で保存してください"

        case ReleaseReadError.permissionDenied:
            return "リリースの状態を読めませんでした。トークンに、このリポジトリの Contents の Read があるか確かめてください"

        case WorkflowError.workflowNotFound, ReleaseReadError.repositoryNotFound:
            return "このリポジトリにはリリースのワークフロー（\(ReleaseWorkflow.prepare.file)）がありません（Actions が無効か、トークンから見えないときも同じです）"

        case let error as WorkflowError:
            return ReleaseWorkflow.prepare.dispatchFailureMessage(error, ref: dispatchRef)

        case let ReleaseReadError.unsupportedDraftSchema(version):
            return "最新情報の下書きの形（schemaVersion \(version)）に、このアプリは対応していません。アプリを新しくしてください"

        case let ReleaseReadError.invalidContent(path):
            return "\(path) を読めませんでした"

        default:
            return IdeaRequestModel.message(for: error)
        }
    }
}
