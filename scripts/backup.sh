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

LOCK_FILE=/run/docker-backup.lock
FROZEN=()
FAILED=1

cleanup() {
  local exit_code=$?
  unfreeze_containers
  if [[ "$FAILED" -ne 0 || "$exit_code" -ne 0 ]]; then
    hc_ping fail
  fi
}
trap cleanup EXIT

unfreeze_containers() {
  local name
  for name in "${FROZEN[@]+"${FROZEN[@]}"}"; do
    log "starting frozen container: $name"
    docker start "$name" >/dev/null || log "WARN: failed to start $name"
  done
  FROZEN=()
}

freeze_containers() {
  local name
  while read -r name; do
    [[ -z "$name" ]] && continue
    log "stopping labeled container ($FREEZE_LABEL): $name"
    docker stop "$name" >/dev/null
    FROZEN+=("$name")
  done < <(docker ps --format '{{.Names}}' --filter "label=${FREEZE_LABEL}")
}

container_env() {
  local container=$1 key=$2
  docker exec "$container" printenv "$key" 2>/dev/null || true
}

container_running() {
  local name=$1 state
  state=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo false)
  [[ "$state" == "true" ]]
}

resolve_container() {
  local spec=$1
  if container_running "$spec"; then
    printf '%s\n' "$spec"
    return 0
  fi
  if [[ "$spec" == *\* ]]; then
    local prefix=${spec%\*}
    local matches count
    matches=$(docker ps --format '{{.Names}}' | awk -v p="$prefix" 'index($0, p)==1 { print }')
    count=$(printf '%s\n' "$matches" | awk 'NF' | wc -l)
    if [[ "$count" -eq 1 ]]; then
      printf '%s\n' "$matches"
      return 0
    fi
    if [[ "$count" -gt 1 ]]; then
      die "dump container spec '$spec' matches multiple running containers"
    fi
  fi
  return 1
}

dump_postgres() {
  local container=$1 user=$2 database=$3 outdir=$4
  if [[ -z "$user" ]]; then
    user=$(container_env "$container" POSTGRES_USER)
    user=${user:-postgres}
  fi
  if [[ -z "$database" || "$database" == "all" ]]; then
    log "dumping postgres (pg_dumpall) from $container"
    docker exec -i "$container" pg_dumpall -U "$user" >"$outdir/all.sql"
  else
    log "dumping postgres database $database from $container"
    docker exec -i "$container" pg_dump -U "$user" -Fc "$database" >"$outdir/${database}.dump"
  fi
}

dump_mysql() {
  local container=$1 user=$2 password_env=$3 outdir=$4
  user=${user:-root}
  password_env=${password_env:-MYSQL_ROOT_PASSWORD}
  local pass
  pass=$(container_env "$container" "$password_env")
  log "dumping mysql/mariadb from $container"
  if [[ -n "$pass" ]]; then
    docker exec -i -e MYSQL_PWD="$pass" "$container" \
      mysqldump -u "$user" --single-transaction --routines --events --all-databases \
      >"$outdir/all.sql"
  else
    docker exec -i "$container" \
      mysqldump -u "$user" --single-transaction --routines --events --all-databases \
      >"$outdir/all.sql"
  fi
}

dump_mongo() {
  local container=$1 outdir=$2
  log "dumping mongo from $container"
  docker exec -i "$container" mongodump --archive >"$outdir/dump.archive"
}

dump_redis() {
  local container=$1 outdir=$2
  log "dumping redis from $container"
  if docker exec "$container" redis-cli --rdb /tmp/docker-backup.rdb >/dev/null 2>&1; then
    docker cp "$container:/tmp/docker-backup.rdb" "$outdir/dump.rdb"
    docker exec "$container" rm -f /tmp/docker-backup.rdb >/dev/null 2>&1 || true
    return 0
  fi
  docker exec "$container" redis-cli BGSAVE >/dev/null
  local dir
  dir=$(docker exec "$container" redis-cli CONFIG GET dir | awk 'NR==2 { print }')
  dir=${dir:-/data}
  docker cp "$container:${dir}/dump.rdb" "$outdir/dump.rdb"
}

run_one_dump() {
  local container=$1 type=$2 user=$3 database=$4 password_env=$5 command=$6
  local resolved
  if ! resolved=$(resolve_container "$container"); then
    log "WARN: dump target not running, skipping: $container"
    return 0
  fi
  local outdir="$BACKUP_DUMPS_DIR/$resolved"
  mkdir -p "$outdir"
  case "$type" in
    postgres)
      dump_postgres "$resolved" "$user" "$database" "$outdir"
      ;;
    mysql|mariadb)
      dump_mysql "$resolved" "$user" "$password_env" "$outdir"
      ;;
    mongo)
      dump_mongo "$resolved" "$outdir"
      ;;
    redis)
      dump_redis "$resolved" "$outdir"
      ;;
    custom)
      [[ -n "$command" ]] || die "custom dump for $resolved needs command"
      log "running custom dump for $resolved"
      bash -c "$command" >"$outdir/custom.out"
      ;;
    *)
      die "unknown dump type '$type' for $container"
      ;;
  esac
}

collect_yaml_dumps() {
  if [[ ! -f "$DUMPS_CONFIG" ]]; then
    return 0
  fi
  python3 "${DOCKER_BACKUP_LIB}/parse_dumps.py" --config "$DUMPS_CONFIG"
}

collect_label_dumps() {
  local name type
  while read -r name; do
    [[ -z "$name" ]] && continue
    type=$(docker inspect -f '{{index .Config.Labels "backup.dump"}}' "$name")
    [[ -z "$type" ]] && continue
    printf '%s\t%s\t\t\t\t\n' "$name" "$type"
  done < <(docker ps --format '{{.Names}}' --filter 'label=backup.dump')
}

run_dumps() {
  rm -rf "$BACKUP_DUMPS_DIR"
  mkdir -p "$BACKUP_DUMPS_DIR"

  local yaml_rows=""
  yaml_rows=$(collect_yaml_dumps) || die "failed to parse $DUMPS_CONFIG"

  local seen="" container type user database password_env command
  while IFS=$'\t' read -r container type user database password_env command; do
    [[ -z "${container:-}" ]] && continue
    if [[ " $seen " == *" $container "* ]]; then
      continue
    fi
    seen+=" $container"
    run_one_dump "$container" "$type" "${user:-}" "${database:-}" "${password_env:-}" "${command:-}"
  done < <({
    printf '%s\n' "$yaml_rows"
    collect_label_dumps
  })

  if [[ "$BACKUP_WARN_UNMAPPED_DBS" == "1" ]]; then
    warn_unmapped_dbs "$seen"
  fi
}

warn_unmapped_dbs() {
  local seen=$1 name image
  while IFS=$'\t' read -r name image; do
    [[ -z "$name" ]] && continue
    if [[ " $seen " == *" $name "* ]]; then
      continue
    fi
    case "$image" in
      *postgres*|*mysql*|*mariadb*|*mongo*|*redis*)
        log "WARN: $name ($image) looks like a database but has no dump mapping"
        ;;
    esac
  done < <(docker ps --format '{{.Names}}\t{{.Image}}')
}

volume_excluded() {
  local name=$1 ex
  while read -r ex; do
    [[ -z "$ex" ]] && continue
    [[ "$name" == "$ex" ]] && return 0
  done < <(split_words "$BACKUP_VOLUME_EXCLUDE")
  return 1
}

collect_volume_paths() {
  local name path
  if [[ "$BACKUP_ALL_VOLUMES" == "1" ]]; then
    [[ -d "$BACKUP_VOLUME_ROOT" ]] || return 0
    for path in "$BACKUP_VOLUME_ROOT"/*/_data; do
      [[ -d "$path" ]] || continue
      name=$(basename "$(dirname "$path")")
      [[ "$name" == "backingFsBlockDev" ]] && continue
      volume_excluded "$name" && continue
      printf '%s\n' "$path"
    done
    return 0
  fi
  while read -r name; do
    [[ -z "$name" ]] && continue
    path="$BACKUP_VOLUME_ROOT/$name/_data"
    if [[ ! -d "$path" ]]; then
      die "named volume not found: $name ($path)"
    fi
    printf '%s\n' "$path"
  done < <(split_words "$BACKUP_VOLUME_NAMES")
}

collect_backup_paths() {
  collect_volume_paths
  expand_paths "$BACKUP_BIND_PATHS"
  expand_paths "$BACKUP_COMPOSE_PATHS"
  if [[ -d "$BACKUP_DUMPS_DIR" ]] && [[ -n "$(find "$BACKUP_DUMPS_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    printf '%s\n' "$BACKUP_DUMPS_DIR"
  fi
}

init_repo_if_needed() {
  mkdir -p "$RESTIC_CACHE_DIR"
  if restic cat config >/dev/null 2>&1; then
    return 0
  fi
  log "initializing restic repository at $RESTIC_REPOSITORY"
  restic init
}

run_restic_backup() {
  local -a paths=()
  local p
  while read -r p; do
    [[ -z "$p" ]] && continue
    paths+=("$p")
  done < <(collect_backup_paths | awk 'NF && !seen[$0]++')

  if [[ ${#paths[@]} -eq 0 ]]; then
    die "nothing to back up (set volumes, bind paths, or compose paths)"
  fi

  log "restic backup (${#paths[@]} paths) -> $RESTIC_REPOSITORY"
  restic backup \
    --one-file-system \
    --tag docker \
    --tag "$(hostname -s)" \
    "${paths[@]}"

  log "restic forget + prune"
  restic forget --prune \
    --keep-daily "$RESTIC_KEEP_DAILY" \
    --keep-weekly "$RESTIC_KEEP_WEEKLY" \
    --keep-monthly "$RESTIC_KEEP_MONTHLY"
}

main() {
  require_root
  load_config
  require_cmds restic docker findmnt python3 flock
  if [[ -n "${HEALTHCHECKS_URL:-}" ]]; then
    require_cmds curl
  fi
  require_password_file
  mkdir -p "$(dirname "$LOCK_FILE")"
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    die "another backup is already running"
  fi
  check_mount
  hc_ping start
  run_dumps
  freeze_containers
  init_repo_if_needed
  run_restic_backup
  unfreeze_containers
  hc_ping ""
  FAILED=0
  log "backup finished"
}

main "$@"
