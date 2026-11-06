# Node.js 2026年11月セキュリティリリースを、公式イメージを待たずに出す

> 想定読者：CVE が出たら公式イメージの更新を待っている、Docker と GitHub Actions を使う人。

Node.js プロジェクトは、**26.x / 24.x / 22.x の修正版を 2026-11-11（水）以降に出す**と予告しています（[予告](https://nodejs.org/en/blog/vulnerability/november-2026-security-releases)。最高深刻度は HIGH）。このリポジトリは、修正版が nodejs.org に出たら**バージョン番号を上げて push するだけ**で、署名と SBOM（イメージの部品表）付きのイメージを ghcr.io に出すためのものです。予告から当日までの間に、パイプラインを今のバージョン（26.13.0 / 24.22.2 / 22.23.4）で動かしておきます。

## 構成

| | 中身 |
|---|---|
| 本体 | nodejs.org の**公式バイナリ**を、melange で Wolfi の apk に詰め直す（コンパイルなし） |
| 改ざんの確認 | `SHASUMS256.txt` の **GPG 署名を Node.js のリリース担当者の鍵で検証**し、その sha256 と照合 |
| イメージ | apko で組む。ランタイム（`:24`、node のみ）/ `-dev`（npm とシェル付き） |
| 配布 | cosign のキーレス署名、SBOM、Trivy / Grype のスキャン結果の添付 |
| 対象 | 26 / 24 / 22。20.x 以前の EOL ラインは公式の修正が出ないので対象外 |

公式バイナリを使うのは、Node のソースビルドは 1 バージョン × 1 アーキテクチャで数十分かかり、当日すぐ出すという目的に合わないためです。Wolfi は glibc なので、公式の linux バイナリがそのまま動きます。修正パッチが公開されるのはリリースと同時なので、パッチを先に当てて出すこともできません。

## リリース当日にやること

1. nodejs.org に修正版が出たことを確認する。

   ```sh
   curl -fsSL https://nodejs.org/dist/index.json | jq -r '[.[] | select(.version | test("^v(26|24|22)\\."))] | group_by(.version | split(".")[0]) | map(.[0] | "\(.version) security=\(.security)") | .[]'
   ```

2. `.github/workflows/build.yml` の `DEFAULT_VERSIONS` を修正版に上げて main に入れる。sha256 と署名検証は `scripts/render.sh` が行う。
3. 1 バージョンだけ先に出したいときは、Actions の `workflow_dispatch` で `versions` に `["24.22.3"]` のような JSON を渡す。

`render.sh` が「署名が active な releaser のものではない」で止まったら、新しい担当者が署名した可能性があります。[nodejs/release-keys](https://github.com/nodejs/release-keys) にその鍵が入ったコミットを確かめて、`render.sh` の `RELEASE_KEYS_REF` を上げてください。

## 使い方

```sh
docker run --rm ghcr.io/yowatari/node-nov2026-hotfix:24 -v
```

ランタイムイメージにはシェルも npm もないので、依存のインストールは `-dev` イメージでやって、成果物を `COPY` で載せます。

```dockerfile
FROM ghcr.io/yowatari/node-nov2026-hotfix:24-dev AS build
COPY --chown=65532:65532 package*.json ./
RUN npm ci --omit=dev
COPY --chown=65532:65532 . .

FROM ghcr.io/yowatari/node-nov2026-hotfix:24
COPY --from=build /app /app
CMD ["server.js"]
```

最小の例は [examples/copy-app](examples/copy-app) です。

### タグ

| タグ | 中身 |
|---|---|
| `24`, `24.22.2`, `24.22.2-r0` | node だけ。uid 65532、シェルなし、`WORKDIR /app`、`NODE_ENV=production` |
| `24-dev`, `24.22.2-dev`, `24.22.2-r0-dev` | 上に npm / npx（と、同梱されていれば corepack）と busybox を追加 |

26 / 22 も同じ形です。どれも linux/amd64 と linux/arm64 のマルチアーキテクチャです。

### 署名の確認

```sh
cosign verify ghcr.io/yowatari/node-nov2026-hotfix:24 \
  --certificate-identity-regexp '^https://github.com/yowatari/node-nov2026-hotfix/.github/workflows/build.yml@' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## 保証しないこと

- 中身は Node.js プロジェクトの公式バイナリそのものです。このリポジトリが足すのは、取得元の検証、最小のベース、署名、SBOM、スキャン結果です。Node 本体の修正内容は Node.js プロジェクトのリリースに依存します。
- 20.x 以前の EOL ラインは扱いません。
- 脆弱性スキャナが「修正済み」と判定するかはスキャナのデータ次第です。パッケージ名が独自（`node-hotfix`）なので、スキャン結果は修正の証明になりません。バージョンと SBOM で確かめてください。
- デモなので、イメージは個人アカウント（`yowatari`）の ghcr に置きます。本番で使うなら自分たちの organization に fork してください。ワークフローは `ghcr.io/<リポジトリ名>` に出すので、そのまま動きます。

## ファイル

| パス | 内容 |
|---|---|
| `scripts/render.sh` | 署名を検証し、バージョンから melange / apko の設定とハッシュを作る |
| `melange.tmpl.yaml` | 公式バイナリを `node-hotfix` / `node-hotfix-npm` の apk にする定義とテスト |
| `apko.tmpl.yaml` | イメージの定義（ランタイムと `-dev`） |
| `scripts/smoke.sh` | イメージのスモークテスト（バージョン、uid、シェルと npm がないこと、HTTP 応答、`-dev` の npm） |
| `.github/workflows/build.yml` | ビルド・publish・署名・スキャン |

### ローカルでのビルド

```sh
scripts/render.sh 24.22.2
docker run --rm -v "$PWD":/work -w /work cgr.dev/chainguard/melange keygen melange.rsa
docker run --privileged --rm -v "$PWD":/work -w /work cgr.dev/chainguard/melange \
  build build/24.22.2/melange.yaml --arch x86_64 --signing-key melange.rsa \
  --out-dir build/24.22.2/packages
docker run --privileged --rm -v "$PWD":/work -w /work cgr.dev/chainguard/melange \
  test build/24.22.2/melange.yaml --arch x86_64 \
  --repository-append /work/build/24.22.2/packages --keyring-append /work/melange.rsa.pub
docker run --rm -v "$PWD":/work -w /work cgr.dev/chainguard/apko \
  build build/24.22.2/apko.yaml node-hotfix:rt build/24.22.2/image-rt.tar --arch x86_64 \
  -r /work/build/24.22.2/packages -k /work/melange.rsa.pub   # -dev は apko-dev.yaml
docker load < build/24.22.2/image-rt.tar
scripts/smoke.sh node-hotfix:rt-amd64 node-hotfix:dev-amd64 24.22.2
```
