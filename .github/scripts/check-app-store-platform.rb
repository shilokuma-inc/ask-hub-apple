#!/usr/bin/env ruby
# frozen_string_literal: true

#
# App Store Connect のアプリに、指定したプラットフォーム（MAC_OS など）が追加済みかを確認する（読み取りのみ）。
# プラットフォームを追加すると、そのプラットフォームの App Store のバージョン（「提出準備中」など）が作られるので、
# バージョンが 1 つでもあれば「追加済み」とみなす。
#
# 結果は GITHUB_OUTPUT の available（true / false）に書く。
# 追加されていない・アプリが無いときは、追加の手順を Job Summary に出して終了コード 0 で終わる
# （呼び出し側はアップロードを飛ばす。iOS のアップロードには響かせない）。
# API の呼び出しに失敗したときだけ終了コード 1 で終わる。
#
# App Store Connect でのプラットフォームの追加は API で行えないため、追加そのものは Web 画面で行う。
#
# 使い方（環境変数で渡す）:
#   BUNDLE_ID=jp.shilokuma.MyApp PLATFORM=MAC_OS \
#   API_KEY_PATH=AuthKey_XXXXXXXXXX.p8 APPLE_API_KEY_ID=XXXXXXXXXX APPLE_API_ISSUER_ID=xxxxxxxx-... \
#   ruby .github/scripts/check-app-store-platform.rb
#
# Ruby の標準ライブラリだけで動く（gem のインストールは不要）。
# JWT の作り方は check-app-store-app.rb と同じ（テンプレートと見比べやすいよう、あちらは書き換えずに置く）。

require 'base64'
require 'json'
require 'net/http'
require 'openssl'
require 'uri'

PLATFORM_NAMES = { 'IOS' => 'iOS', 'MAC_OS' => 'macOS', 'TV_OS' => 'tvOS', 'VISION_OS' => 'visionOS' }.freeze

def env!(name)
  value = ENV.fetch(name, '')
  abort "環境変数 #{name} が設定されていません" if value.empty?
  value
end

def base64url(data)
  Base64.urlsafe_encode64(data, padding: false)
end

# App Store Connect API の認証に使う JWT（ES256）を作る
# https://developer.apple.com/documentation/appstoreconnectapi/generating-tokens-for-api-requests
def make_token(key_path:, key_id:, issuer_id:)
  key = OpenSSL::PKey::EC.new(File.read(key_path))
  now = Time.now.to_i
  header = { alg: 'ES256', kid: key_id, typ: 'JWT' }
  payload = { iss: issuer_id, iat: now, exp: now + (10 * 60), aud: 'appstoreconnect-v1' }
  signing_input = "#{base64url(header.to_json)}.#{base64url(payload.to_json)}"

  # OpenSSL の署名は DER 形式なので、JWT が求める r || s（各 32 バイト）に変換する
  der = key.sign(OpenSSL::Digest.new('SHA256'), signing_input)
  r, s = OpenSSL::ASN1.decode(der).value.map { |n| n.value.to_s(2).rjust(32, "\x00") }
  "#{signing_input}.#{base64url(r + s)}"
end

def get_json(path, query, token:)
  uri = URI("https://api.appstoreconnect.apple.com#{path}")
  uri.query = URI.encode_www_form(query)
  request = Net::HTTP::Get.new(uri)
  request['Authorization'] = "Bearer #{token}"
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }

  unless response.is_a?(Net::HTTPSuccess)
    # 403 / 429 はレート制限のこともある。1 回の確認なので待たずに止め、再実行に任せる
    retry_after = response['Retry-After']
    hint = retry_after ? "（Retry-After: #{retry_after} 秒）" : ''
    abort "::error::App Store Connect API の呼び出しに失敗しました（HTTP #{response.code}#{hint}）\n#{response.body}"
  end

  JSON.parse(response.body)
end

def find_app(bundle_id:, token:)
  body = get_json('/v1/apps', { 'filter[bundleId]' => bundle_id, 'fields[apps]' => 'name,bundleId' }, token: token)
  # filter が完全一致でない場合に備えて、Bundle ID が一致するものだけを見る
  body.fetch('data').find { |app| app.dig('attributes', 'bundleId') == bundle_id }
end

def platform_added?(app_id:, platform:, token:)
  body = get_json(
    "/v1/apps/#{app_id}/appStoreVersions",
    { 'filter[platform]' => platform, 'fields[appStoreVersions]' => 'platform,versionString', 'limit' => '1' },
    token: token
  )
  body.fetch('data').any? { |version| version.dig('attributes', 'platform') == platform }
end

def write_output(available)
  path = ENV.fetch('GITHUB_OUTPUT', '')
  File.write(path, "available=#{available}\n", mode: 'a') unless path.empty?
end

def write_summary(markdown)
  path = ENV.fetch('GITHUB_STEP_SUMMARY', '')
  File.write(path, "#{markdown}\n", mode: 'a') unless path.empty?
end

bundle_id = env!('BUNDLE_ID')
platform = env!('PLATFORM')
platform_name = PLATFORM_NAMES.fetch(platform) { abort "PLATFORM には #{PLATFORM_NAMES.keys.join(' / ')} のどれかを指定してください（#{platform}）" }
token = make_token(
  key_path: env!('API_KEY_PATH'),
  key_id: env!('APPLE_API_KEY_ID'),
  issuer_id: env!('APPLE_API_ISSUER_ID')
)

app = find_app(bundle_id: bundle_id, token: token)
if app.nil?
  # アプリそのものが無いときは、iOS のアップロードが作成の手順を出して止まる（check-app-store-app.rb）。ここでは飛ばすだけにする
  message = "App Store Connect に #{bundle_id} のアプリが無いため、#{platform_name} のアップロードを飛ばします（作成の手順は iOS の Upload の Job Summary）"
  puts "::notice::#{message}"
  write_summary("## #{platform_name} のアップロードを飛ばしました\n\n#{message}")
  write_output(false)
  exit 0
end

if platform_added?(app_id: app.fetch('id'), platform: platform, token: token)
  puts "App Store Connect の #{app.dig('attributes', 'name')}（#{bundle_id}）には #{platform_name} のプラットフォームがあります"
  write_output(true)
  exit 0
end

guide = <<~MARKDOWN
  ## #{platform_name} のアップロードを飛ばしました

  App Store Connect の #{app.dig('attributes', 'name')}（`#{bundle_id}`）に #{platform_name} のプラットフォームがまだ無いため、#{platform_name} のビルドはアップロードしません（iOS のアップロードには影響しません）。

  #{platform_name} 版も App Store Connect に上げるときは、[App Store Connect のアプリ一覧](https://appstoreconnect.apple.com/apps) でこのアプリを開き、
  「プラットフォームを追加」（サイドバーのプラットフォームの横の「＋」）から #{platform_name} を追加してから、このワークフローを再実行してください。
  追加すると #{platform_name} のバージョン（提出準備中）が作られ、次の実行から自動でアップロードされます。

  #{platform_name} のアップロードを止めたままにしたいときは、リポジトリ変数 `ENABLE_MACOS_DELIVERY` を `false` にすると、この確認ごと飛ばします（docs/release.md）。
MARKDOWN

puts "::notice::App Store Connect に #{platform_name} のプラットフォームが無いため、#{platform_name} のアップロードを飛ばします（手順は Job Summary）"
write_summary(guide)
write_output(false)
exit 0
