#!/usr/bin/env bash
set -euo pipefail

if [[ $(id -u) -ne 0 ]]; then
  echo "run as root: sudo $0" >&2
  exit 1
fi

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LIB_DIR=/usr/local/lib/docker-backup
BIN_BACKUP=/usr/local/sbin/docker-backup
BIN_RESTORE=/usr/local/sbin/docker-restore
CONF_DIR=/etc/docker-backup
UNIT_DIR=/etc/systemd/system

strip_crlf() {
  local file=$1
  if grep -q $'\r' "$file" 2>/dev/null; then
    sed -i 's/\r$//' "$file"
  fi
}

echo "installing packages (restic, curl, cifs-utils, nfs-common)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq restic curl cifs-utils nfs-common python3 >/dev/null

mkdir -p "$LIB_DIR" "$CONF_DIR" /var/backups/docker-dumps /var/cache/restic /mnt/backup /root

install -m 0755 "$REPO_ROOT/scripts/common.sh" "$LIB_DIR/common.sh"
install -m 0755 "$REPO_ROOT/scripts/parse_dumps.py" "$LIB_DIR/parse_dumps.py"
install -m 0755 "$REPO_ROOT/scripts/backup.sh" "$BIN_BACKUP"
install -m 0755 "$REPO_ROOT/scripts/restore.sh" "$BIN_RESTORE"
strip_crlf "$LIB_DIR/common.sh"
strip_crlf "$LIB_DIR/parse_dumps.py"
strip_crlf "$BIN_BACKUP"
strip_crlf "$BIN_RESTORE"

if [[ ! -f "$CONF_DIR/backup.env" ]]; then
  install -m 0600 "$REPO_ROOT/config/backup.env.example" "$CONF_DIR/backup.env"
  echo "wrote $CONF_DIR/backup.env (edit this)"
else
  echo "keeping existing $CONF_DIR/backup.env"
fi

if [[ ! -f "$CONF_DIR/dumps.yaml" ]]; then
  install -m 0644 "$REPO_ROOT/config/dumps.yaml.example" "$CONF_DIR/dumps.yaml"
  echo "wrote $CONF_DIR/dumps.yaml (edit this)"
else
  echo "keeping existing $CONF_DIR/dumps.yaml"
fi

install -m 0644 "$REPO_ROOT/config/fstab.snippet" "$CONF_DIR/fstab.snippet"
install -m 0644 "$REPO_ROOT/systemd/docker-backup.service" "$UNIT_DIR/docker-backup.service"
install -m 0644 "$REPO_ROOT/systemd/docker-backup.timer" "$UNIT_DIR/docker-backup.timer"
install -m 0644 "$REPO_ROOT/systemd/docker-backup-notify.service" "$UNIT_DIR/docker-backup-notify.service"
strip_crlf "$UNIT_DIR/docker-backup.service"
strip_crlf "$UNIT_DIR/docker-backup.timer"
strip_crlf "$UNIT_DIR/docker-backup-notify.service"

PASS_FILE=/root/.restic-password
if [[ ! -f "$PASS_FILE" ]]; then
  umask 077
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32 >"$PASS_FILE"
  else
    head -c 32 /dev/urandom | base64 >"$PASS_FILE"
  fi
  chmod 600 "$PASS_FILE"
  echo
  echo "generated $PASS_FILE — copy this password offline. without it, snapshots cannot be restored."
  echo "----- restic password -----"
  cat "$PASS_FILE"
  echo "---------------------------"
else
  chmod 600 "$PASS_FILE"
  echo "keeping existing $PASS_FILE"
fi

systemctl daemon-reload

echo
echo "next steps:"
echo "  1. Mount the NAS at /mnt/backup (see $CONF_DIR/fstab.snippet)."
echo "  2. Edit $CONF_DIR/backup.env and $CONF_DIR/dumps.yaml."
echo "  3. sudo systemctl start docker-backup.service"
echo "  4. sudo systemctl enable --now docker-backup.timer"
echo "  5. Restore-test one small volume after the first success."
