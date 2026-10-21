# v-warden

Google Drive と同期するポータブルな Vaultwarden 環境です。Docker が動くクラウド（Koyeb、Render、Fly.io、Railway など）なら、このリポジトリを連携して環境変数を設定するだけでデプロイできます。

- 起動時: Google Drive (`gdrive:vaultwarden_backup`) から `/data` を復元
- 稼働中: 5 分ごとに Google Drive へ同期
- 停止時 (SIGTERM/SIGINT): Vaultwarden を停止させてから最終同期

## 環境変数

| 変数 | 必須 | 説明 |
| --- | --- | --- |
| `RCLONE_CONFIG_DATA` | ○ | `rclone.conf` の中身全体。改行を入力できない環境では `base64 -w0 ~/.config/rclone/rclone.conf` の出力でも可 |
| `SIGNUPS_ALLOWED` | | 初回は `true`。自分のアカウントを作ったら `false` にする |
| `DOMAIN` | 推奨 | 公開 URL（例: `https://vault.example.com`）。添付ファイルや WebAuthn に必要 |
| `RCLONE_REMOTE` | | 同期先。既定は `gdrive:vaultwarden_backup` |
| `SYNC_INTERVAL` | | 定期同期の間隔（秒）。既定は `300` |

Vaultwarden はポート `80` で待ち受けます。クラウド側で公開ポートを `80` にしてください（Koyeb の既定は 8000）。

## rclone トークンの取得（初回のみ）

1. PC に [rclone](https://rclone.org/downloads/) をインストールし、`rclone config` を実行
2. `n`（New remote）でリモートを作り、名前を `gdrive` にする
3. Storage に Google Drive を選ぶ。scope は `drive.file` を推奨（rclone が作ったファイルにしかアクセスできなくなる）
4. ブラウザで認証を完了させる
5. `cat ~/.config/rclone/rclone.conf`（Windows は `type %APPDATA%\rclone\rclone.conf`）の出力全体を `RCLONE_CONFIG_DATA` に設定する

## 注意点

- **インスタンスは常に 1 つだけにする。** 2 つ以上が同時に動くと、互いのデータを上書きします。オートスケールは無効にしてください。
- **別のサービスに移るときは、先に旧サービスを停止する。** 旧サービスの最終同期が終わってから新サービスを起動してください。両方同時に動かすと、後から同期した側の内容で上書きされます。
- **ローリングデプロイについて:** 新しいコンテナが起動（復元）してから古いコンテナが止まるまでの間に旧コンテナへ書き込まれた変更は失われることがあります。再デプロイの直前・直後に Vault を編集するのは避けてください。
- 停止猶予が短いプラットフォームでは、最終同期が終わる前に強制終了されることがあります。設定できる場合は 30 秒程度にしてください（例: Fly.io の `kill_timeout`）。
- 起動時の復元に失敗した場合（認証切れ・ネットワークエラーなど）、空のデータでバックアップを上書きしないよう、コンテナは起動せずに終了します。Google Drive にバックアップがまだ無い場合（初回）だけ、空の状態で起動します。
- Google Drive に置かれる `db.sqlite3` は sqlite3 の `.backup` で取ったスナップショットです。`icon_cache/` と `tmp/` は同期しません。
