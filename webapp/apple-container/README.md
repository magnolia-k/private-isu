# Apple Container

[`compose.yml`](../compose.yml) と同じ nginx / app / MySQL / Memcached の4コンテナを、
Apple の [`container`](https://github.com/apple/container) で起動します。
Docker Desktop / Docker Compose は不要です。

## 準備

- Apple Silicon Mac、macOS 26 以降
- Apple Container 1.4.1 以降（[インストール方法](https://github.com/apple/container#install)）
- ホストの `bash`、`awk`、`curl`、初期データをダウンロードするための `make`
- MySQLデータとイメージを保存できるディスク空き容量と、4コンテナのVMを動かすメモリ

リポジトリのルートで実行します。

```sh
make init
container system start
```

## 起動

元のCompose構成と同じく、環境名は`private-isu`固定で1環境を起動します。

```sh
# Ruby版を起動。Readyが表示されてコマンドが終了するまで待つ
./webapp/apple-container/compose.sh up

# 起動した環境に対してベンチマークを実行
./webapp/apple-container/bench.sh

# 計測終了後に片付ける（MySQLデータは保持）
./webapp/apple-container/compose.sh down
```

スコアはベンチマーク終了時に標準出力へ表示されます。
再計測する場合は`down`の前に`bench.sh`をもう一度実行します。
ベンチマーカーの初回ビルドには時間がかかります。詳細は[ベンチマーク](#ベンチマーク)を参照してください。

リソース名は`private-isu-app`、`private-isu-mysql`などになります。

```sh
# 引数: up [言語] [HTTPポート] [MySQLポート]
./webapp/apple-container/compose.sh up ruby 8080 13306
```

起動後は <http://127.0.0.1:8080> でアクセスできます。
公開ポートはホストの `127.0.0.1` にバインドします。

言語は `ruby`（省略時）、`golang`、`php`、`python`、`node` から選べます。
HTTPポートの省略時は `8080`、MySQLポートの省略時は `13306` です。
PHPを選ぶと専用のFastCGI設定を自動的に選択します。
既存のCompose用nginx設定を手動で切り替える必要はありません。

`up` は現在のソースからイメージをビルドし、MySQLの初期インポートが終了してから
アプリを起動し、`/login` のHTTP応答を確認します。
初回インポートの待ち時間は標準で1800秒です。必要に応じて延長してください。

```sh
MYSQL_WAIT_SECONDS=3600 ./webapp/apple-container/compose.sh up python
```

## 状態確認・停止・変更の反映

```sh
./webapp/apple-container/compose.sh status
./webapp/apple-container/compose.sh logs app
./webapp/apple-container/compose.sh logs mysql

# コンテナとネットワークを削除（MySQLのデータは保持）
./webapp/apple-container/compose.sh down

# ソース変更や言語変更を反映して再起動
./webapp/apple-container/compose.sh up node
```

`logs` の対象は `nginx` / `app` / `mysql` / `memcached`（省略時 `app`）です。
`Ctrl-C` でログの追跡を終了できます。
`down` は実行中のベンチマーカーも停止します。

データも初期化したい場合だけ、停止後にボリュームを明示的に削除してください。
次回の `up` で初期データを再インポートします。
初回インポートの途中で失敗・中断した場合も、未完成のデータが残るためこの手順でやり直します。

```sh
./webapp/apple-container/compose.sh down
container volume delete private-isu-mysql
```

## Composeとの対応

| 項目 | Apple Containerでの設定 |
| --- | --- |
| nginx / MySQL / Memcached | Composeと同じ `nginx:1.30` / `mysql:9.7` / `memcached:1.6` |
| app | `linux/arm64` でビルド。Goは専用の `Dockerfile.golang`、他4言語は既存Dockerfile |
| app / MySQLのリソース | それぞれ1 CPU、1 GiBメモリ。appには `--init` を指定 |
| DB設定 | `isuconp`、root / root。Composeと同じ環境変数 |
| SQL初期データ | `webapp/sql` を読み取り専用で `/docker-entrypoint-initdb.d` にマウント |
| MySQLデータ | `private-isu-mysql` 名前付きボリューム（16 GiB） |
| ネットワーク | `private-isu` ネットワーク |
| コンテナ名・ビルドイメージ | `private-isu-サービス名` |
| 静的ファイル | Composeと同じホストの `webapp/public` を共有。PHPではアプリ側のパスを `/var/www/public` に合わせる |

Apple Container 1.4.1の独自ネットワークではComposeのような短いサービス名の名前解決が
利用できないため、`container list --format table`の表から`awk`でIPv4アドレスを取り出し、
アプリの環境変数とnginx設定に渡します。
詳細は[公式ネットワーク文書](https://github.com/apple/container/blob/1.4.1/docs/networking.md#container-to-container-networking)を参照してください。
コンテナを個別に作り直すとIPが変わることがあるため、再起動は `down` / `up` で行います。

Apple Containerは各コンテナをVMで動かすため、Composeの実行結果とベンチマークスコアが
一致することは想定していません。アプリやベンチマーカーの処理内容は変更していません。

Goとベンチマーカーには専用Dockerfileを用意しています。
Apple Container 1.4.1では、元のDockerfileの `RUN --mount=type=bind,target=.` だけで参照する
ソースがビルドコンテキストに渡らなかったため、`COPY` で明示的に渡します。
2026-10-18にApple Container 1.5.0でも元のGo用Dockerfileを再検証し、
`go mod download`は成功する一方、`go build`は`no Go files in /src`で失敗することを確認しました。
このため、1.5.0でもGo用の専用Dockerfileを使用します。
ベースイメージと起動コマンドは元のDockerfileに合わせています。

## ベンチマーク

`make init`と`compose.sh up`が正常終了し、アプリが起動している状態で、
リポジトリのルートから実行します。ホストにGoは不要です。

```sh
./webapp/apple-container/bench.sh

# オプションを指定して計測する場合（上とは別の計測）
./webapp/apple-container/bench.sh -benchmark-timeout 1m -d
```

`Dockerfile.benchmarker` で既存のベンチマーカーをビルドし、対象環境と同じネットワークで
`private-isu-benchmarker` コンテナを起動します。引数は既存のベンチマーカーへ渡します。
nginxのIPを自動取得するため、ホスト側のHTTPポートの指定は不要です。
スコアは標準出力に表示し、終了コードをそのまま返し、実行コンテナは終了時に削除します。
イメージには既存Dockerfileと同じく `userdata` が含まれるので、初回ビルドには時間・容量が必要です。
ベンチマークは1つずつ実行してください。

ホストで既存のベンチマーカーを実行することもできます（Goが必要です）。

```sh
make -C benchmarker
cd benchmarker
./bin/benchmarker -t http://127.0.0.1:8080 -u ./userdata
```
