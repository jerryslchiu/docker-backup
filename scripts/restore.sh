#!/usr/bin/env bash
set -euo pipefail

_here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ -f "$_here/common.sh" ]]; then
  # shellcheck source=common.sh
  source "$_here/common.sh"
else
  # shellcheck source=/dev/null
  source /usr/local/lib/docker-backup/common.sh
fi

usage() {
  cat <<'EOF'
Usage:
  docker-restore snapshots
  docker-restore restore [--snapshot latest] [--include PATH] --target DIR
  docker-restore volume --volume NAME [--snapshot latest] [--force]

  snapshots   List restic snapshots.
  restore     Restore files from a snapshot into --target (restic layout preserved).
  volume      Restore a named Docker volume into /var/lib/docker/volumes/NAME/_data.
              Stop the stack first. Refuses if a container using the volume is running
              unless --force is set.
EOF
}

cmd_snapshots() {
  restic snapshots
}

cmd_restore() {
  local snapshot=latest include="" target=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --snapshot)
        snapshot=$2
        shift 2
        ;;
      --include)
        include=$2
        shift 2
        ;;
      --target)
        target=$2
        shift 2
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done
  [[ -n "$target" ]] || die "--target is required"
  mkdir -p "$target"
  local -a args=(restore "$snapshot" --target "$target")
  if [[ -n "$include" ]]; then
    args+=(--include "$include")
  fi
  log "restic ${args[*]}"
  restic "${args[@]}"
  log "restored into $target"
}

volume_in_use() {
  local volume=$1
  docker ps --filter "volume=$volume" --format '{{.Names}}'
}

cmd_volume() {
  local snapshot=latest volume="" force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --snapshot)
        snapshot=$2
        shift 2
        ;;
      --volume)
        volume=$2
        shift 2
        ;;
      --force)
        force=1
        shift
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done
  [[ -n "$volume" ]] || die "--volume is required"

  local dest="$BACKUP_VOLUME_ROOT/$volume/_data"
  [[ -d "$BACKUP_VOLUME_ROOT/$volume" ]] || die "named volume directory missing: $BACKUP_VOLUME_ROOT/$volume (create the compose project first)"

  local users
  users=$(volume_in_use "$volume" || true)
  if [[ -n "$users" && "$force" -ne 1 ]]; then
    die "volume $volume is in use by running containers: $users (stop the stack or pass --force)"
  fi

  local tmp
  tmp=$(mktemp -d /tmp/docker-restore.XXXXXX)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT

  local include="$BACKUP_VOLUME_ROOT/$volume/_data"
  log "restoring $include from snapshot $snapshot"
  restic restore "$snapshot" --target "$tmp" --include "$include"

  local src="$tmp$include"
  if [[ ! -d "$src" ]]; then
    die "snapshot does not contain $include"
  fi

  mkdir -p "$dest"
  log "replacing $dest"
  find "$dest" -mindepth 1 -delete
  cp -a "$src"/. "$dest"/
  log "volume $volume restored"
}

main() {
  require_root
  load_config
  require_cmds restic docker
  require_password_file
  check_mount

  local cmd=${1:-}
  [[ -n "$cmd" ]] || { usage; exit 1; }
  shift || true
  case "$cmd" in
    snapshots|list)
      cmd_snapshots
      ;;
    restore)
      cmd_restore "$@"
      ;;
    volume)
      cmd_volume "$@"
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage
      die "unknown command: $cmd"
      ;;
  esac
}

main "$@"
