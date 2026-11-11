#!/bin/bash
# 司令塔・ワーカー・非常口を、版とコミットを実行ファイルに埋め込んでビルドする（docs/renewal/operations.md の「版」）。
#
#   scripts/machine/build.sh <プロダクト> ...（askhub-commander・askhub-worker・askhub）
#
# 版は `git describe --tags --match 'machine-v*'` から作る。タグそのものなら 0.2.0、その後のコミットなら 0.2.0-3-gabc1234。
# machine-v のタグがまだ無いときは 0.0.0-<コミットの数>-g<短いハッシュ>（タグの後のコミットと同じ形にし、コミットが分かるようにする）。
# 識別子・版・コミットを Info.plist にして実行ファイルの __TEXT,__info_plist に入れ、CommanderVersion がそれを読む。
# 埋め込まずに `swift build` をそのまま流したものは 0.0.0-dev になる。
# できた実行ファイルは AskHubKit/.build/release/<プロダクト>
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
if [ $# -eq 0 ]; then
    echo "使い方: scripts/machine/build.sh askhub-commander|askhub-worker|askhub ..." >&2
    exit 64
fi

commit=$(git rev-parse HEAD)
if described=$(git describe --tags --match 'machine-v*' 2>/dev/null); then
    version="${described#machine-v}"
else
    version="0.0.0-$(git rev-list --count HEAD)-g$(git rev-parse --short HEAD)"
fi

INFO_DIR="AskHubKit/.build/machine-info"
mkdir -p "$INFO_DIR"

for product in "$@"; do
    case "$product" in
        askhub-commander) identifier="jp.shilokuma.askhub.commander" ;;
        askhub-worker) identifier="jp.shilokuma.askhub.worker" ;;
        askhub) identifier="jp.shilokuma.askhub.cli" ;;
        *)
            echo "知らないプロダクト: $product（askhub-commander・askhub-worker・askhub のどれか）" >&2
            exit 64
            ;;
    esac

    draft="$INFO_DIR/$product.plist.draft"
    rm -f "$draft"
    plutil -create xml1 "$draft"
    plutil -insert CFBundleInfoDictionaryVersion -string "6.0" "$draft"
    plutil -insert CFBundleIdentifier -string "$identifier" "$draft"
    plutil -insert CFBundleName -string "$product" "$draft"
    plutil -insert CFBundleShortVersionString -string "$version" "$draft"
    plutil -insert AskHubCommit -string "$commit" "$draft"
    # SwiftPM は -Xlinker で渡したファイルの中身を見ないので、中身が変わってもパスが同じだとリンクし直さず、前の版が残る。
    # パスに中身のハッシュを入れ、版が変わったらリンクのコマンドも変わるようにする
    info="$PWD/$INFO_DIR/$product-$(shasum -a 256 "$draft" | cut -c1-16).plist"
    mv "$draft" "$info"

    swift build -c release --package-path AskHubKit --product "$product" \
        -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$info"

    binary="AskHubKit/.build/release/$product"
    embedded=$(launchctl plist __TEXT,__info_plist "$binary")
    if [[ "$embedded" != *"\"$version\""* || "$embedded" != *"\"$commit\""* ]]; then
        echo "$binary に版（$version）とコミット（$commit）が入っていない" >&2
        exit 1
    fi
    echo "$product: 版 $version（コミット $commit）→ $binary"
done
