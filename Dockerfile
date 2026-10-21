FROM vaultwarden/server:latest

# rclone (Google Drive 同期) と sqlite3 (稼働中DBの安全なスナップショット取得) をインストール
RUN apt-get update \
    && apt-get install -y --no-install-recommends rclone sqlite3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# 起動および同期用スクリプトの配置
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# スクリプトをコンテナのメインプロセスとして指定
# (ベースイメージの dumb-init はプロセスグループ全体にシグナルを転送してしまい、
#  最終同期より先に Vaultwarden / rclone が止まるため使わない)
ENTRYPOINT ["/entrypoint.sh"]
