#!/usr/bin/env bash
# Shared helpers for docker-backup. Sourced, not executed.

: "${DOCKER_BACKUP_CONFIG:=/etc/docker-backup/backup.env}"

log() { printf '%s %s\n' "$(date -Is)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

require_root() {
  [[ $(id -u) -eq 0 ]] || die "run as root"
}

_docker_backup_root() {
  local here
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  if [[ -f "$here/common.sh" && -f "$here/parse_dumps.py" ]]; then
    printf '%s\n' "$here"
  elif [[ -d /usr/local/lib/docker-backup ]]; then
    printf '%s\n' /usr/local/lib/docker-backup
  else
    printf '%s\n' "$here"
  fi
}

load_config() {
  if [[ -n "${DOCKER_BACKUP_CONFIG_LOADED:-}" ]]; then
    return 0
  fi
  if [[ ! -f "$DOCKER_BACKUP_CONFIG" ]]; then
    die "config not found: $DOCKER_BACKUP_CONFIG (copy backup.env.example)"
  fi
  # shellcheck disable=SC1090
  set -a
  # shellcheck source=/dev/null
  source "$DOCKER_BACKUP_CONFIG"
  set +a

  : "${BACKUP_MOUNT:=/mnt/backup}"
  : "${RESTIC_REPOSITORY:=${BACKUP_MOUNT}/restic-docker}"
  : "${RESTIC_PASSWORD_FILE:=/root/.restic-password}"
  : "${BACKUP_VOLUME_ROOT:=/var/lib/docker/volumes}"
  : "${BACKUP_ALL_VOLUMES:=1}"
  : "${BACKUP_VOLUME_NAMES:=}"
  : "${BACKUP_VOLUME_EXCLUDE:=}"
  : "${BACKUP_BIND_PATHS:=}"
  : "${BACKUP_COMPOSE_PATHS:=}"
  : "${BACKUP_DUMPS_DIR:=/var/backups/docker-dumps}"
  : "${DUMPS_CONFIG:=/etc/docker-backup/dumps.yaml}"
  : "${FREEZE_LABEL:=backup.freeze=true}"
  : "${RESTIC_KEEP_DAILY:=7}"
  : "${RESTIC_KEEP_WEEKLY:=4}"
  : "${RESTIC_KEEP_MONTHLY:=6}"
  : "${HEALTHCHECKS_URL:=}"
  : "${BACKUP_WARN_UNMAPPED_DBS:=1}"

  export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE
  export RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/var/cache/restic}"
  DOCKER_BACKUP_LIB="$(_docker_backup_root)"
  DOCKER_BACKUP_CONFIG_LOADED=1
}

require_cmds() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing command: $cmd"
  done
}

check_mount() {
  if ! findmnt -n "$BACKUP_MOUNT" >/dev/null 2>&1; then
    die "NAS is not mounted at $BACKUP_MOUNT"
  fi
  if [[ ! -w "$BACKUP_MOUNT" ]]; then
    die "NAS mount is not writable: $BACKUP_MOUNT"
  fi
}

require_password_file() {
  [[ -f "$RESTIC_PASSWORD_FILE" ]] || die "restic password file missing: $RESTIC_PASSWORD_FILE"
  local mode
  mode=$(stat -c '%a' "$RESTIC_PASSWORD_FILE")
  if [[ "$mode" != "600" && "$mode" != "400" ]]; then
    die "restic password file must be mode 600 or 400 (is $mode)"
  fi
}

split_words() {
  local raw=$1
  if [[ -z "${raw// }" ]]; then
    return 0
  fi
  # shellcheck disable=SC2086
  printf '%s\n' $raw | tr ',' '\n' | awk 'NF { gsub(/^[ \t]+|[ \t]+$/, ""); print }'
}

expand_paths() {
  local raw=$1 spec path
  while read -r spec; do
    [[ -z "$spec" ]] && continue
    # Intentionally unquoted so globs in config expand.
    # shellcheck disable=SC2086
    for path in $spec; do
      if [[ -e "$path" ]]; then
        printf '%s\n' "$path"
      else
        log "WARN: path does not exist, skipping: $path" >&2
      fi
    done
  done < <(split_words "$raw")
}

hc_ping() {
  local suffix=$1
  [[ -n "$HEALTHCHECKS_URL" ]] || return 0
  local url=$HEALTHCHECKS_URL
  if [[ -n "$suffix" ]]; then
    url="${url%/}/${suffix}"
  fi
  curl -fsS -m 10 --retry 2 "$url" >/dev/null 2>&1 || log "WARN: healthchecks ping failed ($url)"
}
