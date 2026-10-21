#!/bin/bash
set -uo pipefail

DATA_DIR="${DATA_FOLDER:-/data}"
REMOTE="${RCLONE_REMOTE:-gdrive:vaultwarden_backup}"
SYNC_INTERVAL="${SYNC_INTERVAL:-300}"
VAULTWARDEN_START="${VAULTWARDEN_START:-/start.sh}"
STAGING_DIR=/tmp/vw-staging
LOCK_FILE=/tmp/vw-sync.lock
RCLONE_CONF="${RCLONE_CONFIG:-/root/.config/rclone/rclone.conf}"
export RCLONE_CONFIG="$RCLONE_CONF"

log() { echo "[$(date '+%F %T')] [$1] $2"; }

# 1. rclone認証情報の設定
# 環境変数 RCLONE_CONFIG_DATA から設定を生成 (改行を扱えない環境向けに base64 でも可)
if [ -z "${RCLONE_CONFIG_DATA:-}" ]; then
  log ERROR "RCLONE_CONFIG_DATA is not set."
  exit 1
fi
mkdir -p "$(dirname "$RCLONE_CONF")"
if [[ "$RCLONE_CONFIG_DATA" == \[* ]]; then
  printf '%s\n' "$RCLONE_CONFIG_DATA" > "$RCLONE_CONF"
else
  printf '%s' "$RCLONE_CONFIG_DATA" | base64 -d > "$RCLONE_CONF" || {
    log ERROR "RCLONE_CONFIG_DATA is neither an rclone config nor valid base64."
    exit 1
  }
fi
chmod 600 "$RCLONE_CONF"

# 2. 起動時のデータ復元
# 復元に失敗したまま空の /data で起動すると、次の同期でバックアップを消してしまうため、
# 「バックアップが存在しない (初回起動)」以外の失敗では起動を中止する。
log INFO "Restoring data from $REMOTE ..."
mkdir -p "$DATA_DIR"
rclone copy "$REMOTE" "$DATA_DIR"
rc=$?
case $rc in
  0) log INFO "Restore complete." ;;
  3) log WARN "No backup found at $REMOTE. Starting with empty data (first run)." ;;
  *) log ERROR "Restore failed (rclone exit code $rc). Aborting to protect the backup."; exit 1 ;;
esac

# 稼働中の SQLite をそのままコピーすると壊れたDBがアップロードされ得るため、
# sqlite3 の .backup でスナップショットを取り、それを同期する。
backup() {
  (
    flock 9
    if [ ! -f "$DATA_DIR/db.sqlite3" ]; then
      log WARN "db.sqlite3 not found. Skipping sync to avoid wiping the backup."
      exit 1
    fi
    rm -rf "$STAGING_DIR" && mkdir -p "$STAGING_DIR" || exit 1
    rclone copy "$DATA_DIR" "$STAGING_DIR" \
      --exclude 'db.sqlite3*' --exclude 'icon_cache/**' --exclude 'tmp/**' || exit 1
    sqlite3 "$DATA_DIR/db.sqlite3" ".backup '$STAGING_DIR/db.sqlite3'" || exit 1
    rclone sync "$STAGING_DIR" "$REMOTE" || exit 1
  ) 9>"$LOCK_FILE"
}

# 3. 定期同期プロセス (SYNC_INTERVAL 秒ごと、既定 5 分)
sync_loop() {
  while true; do
    sleep "$SYNC_INTERVAL"
    log INFO "Auto-syncing data to $REMOTE ..."
    backup || log ERROR "Auto-sync failed."
  done
}
sync_loop &
SYNC_PID=$!

# 4. 終了時の安全な最終同期処理
# Vaultwarden を先に停止させ、DBへの書き込みが止まってから同期する。
finish() {
  kill "$SYNC_PID" 2>/dev/null # 定期同期ループを停止 (実行中の同期はロックで完了を待つ)
  log INFO "Performing final sync..."
  if backup; then
    log INFO "Final sync complete. Shutting down."
  else
    log ERROR "Final sync failed."
  fi
  exit "$1"
}

on_signal() {
  log INFO "Container termination signal received. Stopping Vaultwarden..."
  kill -TERM "$VAULT_PID" 2>/dev/null
  wait "$VAULT_PID"
  finish 0
}
trap on_signal SIGTERM SIGINT

# 5. Vaultwarden本体の起動
log INFO "Starting Vaultwarden..."
"$VAULTWARDEN_START" &
VAULT_PID=$!

# Vaultwardenのプロセスが終了するまで待機 (シグナル受信時は on_signal が処理する)
wait "$VAULT_PID"
rc=$?
log WARN "Vaultwarden exited unexpectedly (exit code $rc)."
finish "$rc"
