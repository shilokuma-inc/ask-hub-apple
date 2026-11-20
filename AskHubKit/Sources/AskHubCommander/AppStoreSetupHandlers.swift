import AskHubProtocol
import AskHubStateStore
import Foundation

// 新しいアプリを App Store に載せる準備の人の意図の処理（`docs/renewal/release.md` の「新しいアプリを載せる」）。
// どれも `app-store.json` に人の意図を写すだけで、App Store Connect への書き込みは見回り（`ReleaseWatch`）が行う
// （人の意図の処理の中で外の操作を待たない。途中で止まっても、見回りがやり直す）

/// 準備の意図に共通の確かめと書き込み
enum AppStoreSetupIntake {
    /// 対象の Apple のリポジトリでなければ、断る理由
    static func repositoryProblem(_ repo: RepositoryFullName, in context: CommanderContext) async throws(CommanderError) -> String? {
        guard let repository = try await context.read(RepositoryFile.self, at: StatePath.repository(repo)) else {
            return "\(repo) は対象のリポジトリに加えていない"
        }
        if repository.isRemoved { return "\(repo) は対象から外した" }
        if repository.platform != .apple { return "\(repo) は App Store のアプリのリポジトリでない" }
        return nil
    }

    /// 記録を書き換える。`change` が false を返したら書かない。書いた後の記録を返す
    static func update(
        _ repo: RepositoryFullName,
        message: String,
        in context: CommanderContext,
        _ change: (inout AppStoreSetupFile) -> Bool
    ) async throws(CommanderError) -> AppStoreSetupFile {
        do {
            return try await context.files.update(AppStoreSetupFile.self, at: StatePath.appStoreSetup(repo), message: message) { file in
                guard change(&file) else { return false }
                file.updatedAt = context.timestamp
                return true
            }.file
        } catch {
            throw .files(error)
        }
    }
}

/// Bundle ID を登録する（`registerBundleId`）を受け付け、`bundleIdRequest` に写す。
/// 記録が無い（まだ確かめていない）・リポジトリのビルドの設定に無い Bundle ID・前の登録を送っている途中なら断る
public struct RegisterBundleIdHandler: IntentHandler {
    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let register: RegisterBundleIdIntent
        do {
            register = try RegisterBundleIdIntent(envelope: envelope)
        } catch {
            return .reject("Bundle ID を登録する意図の形が違う（\(error.detail)）")
        }
        if let problem = try await AppStoreSetupIntake.repositoryProblem(register.repo, in: context) { return .reject(problem) }
        let path = StatePath.appStoreSetup(register.repo)
        guard let file = try await context.read(AppStoreSetupFile.self, at: path) else {
            return .reject("\(register.repo) の App Store の準備をまだ確かめていない")
        }
        // 前の周で書いた（やり直し）
        if file.bundleIdRequest?.approval == register.intent { return .accept }
        if let problem = Self.problem(registering: register, on: file) { return .reject(problem) }
        let request = AppStoreSetupFile.BundleIDRequest(
            approval: register.intent, at: context.timestamp, identifier: register.identifier, platform: register.platform
        )
        let message = "\(register.repo) の Bundle ID を登録する"
        let saved = try await AppStoreSetupIntake.update(register.repo, message: message, in: context) { file in
            guard Self.problem(registering: register, on: file) == nil else { return false }
            file.bundleIdRequest = request
            return true
        }
        guard saved.bundleIdRequest == request else { throw .changedWhileProcessing(path) }
        return .accept
    }

    static func problem(registering register: RegisterBundleIdIntent, on file: AppStoreSetupFile) -> String? {
        if !file.isActive { return "\(register.repo) は App Store に出さない・もう配信した" }
        if !file.bundleIds.contains(register.identifier) {
            return "\(register.identifier) は \(register.repo) のビルドの設定に無い"
        }
        if let request = file.bundleIdRequest, request.doneAt == nil { return "前の Bundle ID の登録を送っている途中" }
        return nil
    }
}

/// 決まった値を書く（`applyAppStoreSettings`）を受け付け、`settingsRequest` に写す。
/// App Store Connect にアプリが無い・前の書き込みを送っている途中なら断る
public struct ApplyAppStoreSettingsHandler: IntentHandler {
    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let apply: ApplyAppStoreSettingsIntent
        do {
            apply = try ApplyAppStoreSettingsIntent(envelope: envelope)
        } catch {
            return .reject("App Store Connect に書く値の形が違う（\(error.detail)）")
        }
        if let problem = try await AppStoreSetupIntake.repositoryProblem(apply.repo, in: context) { return .reject(problem) }
        let path = StatePath.appStoreSetup(apply.repo)
        guard let file = try await context.read(AppStoreSetupFile.self, at: path) else {
            return .reject("\(apply.repo) の App Store の準備をまだ確かめていない")
        }
        if file.settingsRequest?.approval == apply.intent { return .accept }
        if let problem = Self.problem(applying: apply, on: file) { return .reject(problem) }
        let request = AppStoreSetupFile.SettingsRequest(approval: apply.intent, at: context.timestamp, settings: apply.settings)
        let message = "\(apply.repo) の App Store Connect の値を書く"
        let saved = try await AppStoreSetupIntake.update(apply.repo, message: message, in: context) { file in
            guard Self.problem(applying: apply, on: file) == nil else { return false }
            file.settingsRequest = request
            return true
        }
        guard saved.settingsRequest == request else { throw .changedWhileProcessing(path) }
        return .accept
    }

    static func problem(applying apply: ApplyAppStoreSettingsIntent, on file: AppStoreSetupFile) -> String? {
        if !file.isActive { return "\(apply.repo) は App Store に出さない・もう配信した" }
        if file.app == nil { return "App Store Connect にアプリが無い。先に App Store Connect でアプリを作る" }
        if let request = file.settingsRequest, request.doneAt == nil { return "前の書き込みを送っている途中" }
        return nil
    }
}

/// App Store Connect の Web でした作業を「終わった」にする（`confirmAppStoreItem`）を受け付け、項目に `confirmed` を付ける。
/// 確かめていない項目（アプリが無いうちの、初めての版の項目など）は断る
public struct ConfirmAppStoreItemHandler: IntentHandler {
    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let confirm: ConfirmAppStoreItemIntent
        do {
            confirm = try ConfirmAppStoreItemIntent(envelope: envelope)
        } catch {
            return .reject("終わったにする意図の形が違う（\(error.detail)）")
        }
        if let problem = try await AppStoreSetupIntake.repositoryProblem(confirm.repo, in: context) { return .reject(problem) }
        let path = StatePath.appStoreSetup(confirm.repo)
        guard let file = try await context.read(AppStoreSetupFile.self, at: path) else {
            return .reject("\(confirm.repo) の App Store の準備をまだ確かめていない")
        }
        guard let item = file.item(confirm.item) else {
            return .reject("\(confirm.item.rawValue) はまだ確かめていない（先にアプリを作る）")
        }
        if item.confirmed?.approval == confirm.intent || item.confirmed != nil { return .accept }
        if !file.isActive { return .reject("\(confirm.repo) は App Store に出さない・もう配信した") }
        let confirmed = AppStoreSetupFile.Approval(approval: confirm.intent, at: context.timestamp)
        let message = "\(confirm.repo) の App Store の準備（\(confirm.item.rawValue)）を終わったにする"
        _ = try await AppStoreSetupIntake.update(confirm.repo, message: message, in: context) { file in
            guard let index = file.items.firstIndex(where: { $0.id == confirm.item }), file.items[index].confirmed == nil else {
                return false
            }
            file.items[index].confirmed = confirmed
            return true
        }
        return .accept
    }
}

/// App Store に出さない・出すに戻す（`excludeFromAppStore`）を受け付ける。記録が無ければ作る（出さないリポジトリは確かめない）
public struct ExcludeFromAppStoreHandler: IntentHandler {
    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let exclude: ExcludeFromAppStoreIntent
        do {
            exclude = try ExcludeFromAppStoreIntent(envelope: envelope)
        } catch {
            return .reject("App Store に出さない意図の形が違う（\(error.detail)）")
        }
        if let problem = try await AppStoreSetupIntake.repositoryProblem(exclude.repo, in: context) { return .reject(problem) }
        let path = StatePath.appStoreSetup(exclude.repo)
        let mark = exclude.excluded ? AppStoreSetupFile.Approval(approval: exclude.intent, at: context.timestamp) : nil
        let message = exclude.excluded ? "\(exclude.repo) を App Store に出さない" : "\(exclude.repo) を App Store に出すに戻す"
        guard try await context.read(AppStoreSetupFile.self, at: path) != nil else {
            // 出すに戻すのに記録が無ければ、何もしなくてよい（見回りが作る）
            guard let mark else { return .accept }
            let file = AppStoreSetupFile(repo: exclude.repo, excluded: mark, createdAt: context.timestamp, updatedAt: context.timestamp)
            do {
                try await context.files.create(file, at: path, message: message)
            } catch .alreadyExists {
                throw .changedWhileProcessing(path)
            } catch {
                throw .files(error)
            }
            return .accept
        }
        _ = try await AppStoreSetupIntake.update(exclude.repo, message: message, in: context) { file in
            // 同じ向きなら書かない（前の周で書いた・押し直した）
            guard (file.excluded != nil) != exclude.excluded else { return false }
            file.excluded = mark
            return true
        }
        return .accept
    }
}
