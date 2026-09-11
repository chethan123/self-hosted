#!/bin/sh
# Dump service's whole program (docs/specs/dump/01-the-dump-sidecar.md, ADR-0009): prune, check
# room, dump, verify, publish. POSIX sh only (busybox ash) — arithmetic is epoch seconds, no `date -d yesterday`/`find -newermt`.
#   dump-loop.sh [loop]            the service's command
#   dump-loop.sh verify <file>     decode an archive whole (smoke test)
#   dump-loop.sh prune <dir>       apply retention (smoke test)
#   dump-loop.sh healthcheck       the container's healthcheck
set -eu

# 0640 files in a 0750 directory: the dumps are every balance, every statement
# and every original uploaded CSV in plaintext, and they are readable to the
# account that owns the directory because that is what collects them.
umask 027

DUMP_DIR="${DUMP_DIR:-/dumps}"
# `-`, not `:-`: an unset knob takes the default; an explicitly empty one stays empty and is
# refused by name — the colon form would quietly turn `DUMP_ENABLED=` into `true`.
DUMP_ENABLED="${DUMP_ENABLED-true}"
DUMP_AT="${DUMP_AT-02}"
DUMP_KEEP_DAYS="${DUMP_KEEP_DAYS-7}"
DUMP_COMPRESS="${DUMP_COMPRESS-0}"
APP_VERSION="${APP_VERSION:-unknown}"

log() { printf 'dump: %s\n' "$*"; }
die() { printf 'dump: %s\n' "$*" >&2; exit 1; }

# One gibibyte, and then some: the floor below which a dump is refused however
# small the database claims it will be.
FLOOR_BYTES=1073741824
# Retry offsets in seconds FROM THE FIRST FAILURE — +15, +30, +60 minutes, not
# three waits of that length, which would put the last attempt at +105. A free-
# space refusal never enters this ladder.
RETRY_OFFSETS="900 1800 3600"

now() { date -u +%s; }
stamp() { date -u +%Y%m%dT%H%M%SZ; }

# "08" is not 8 in POSIX arithmetic — it is an invalid octal — and `10#08` is a
# bashism this shell does not have. Strip the zero instead.
strip0() { v=${1#0}; printf '%s\n' "${v:-0}"; }

# Fails closed and names the variable (.env.example's promise). No DUMP_UID/DUMP_GID here —
# Compose applies them before this script runs. Checked alone, first: disabling dumps must work even if other inputs are bad.
validate_enabled() {
  case "$DUMP_ENABLED" in
    true|false) ;;
    *) die "DUMP_ENABLED must be true or false, not '$DUMP_ENABLED'" ;;
  esac
}

validate() {
  case "$DUMP_AT" in
    [0-1][0-9]|2[0-3]) ;;
    *) die "DUMP_AT must be a two-digit UTC hour 00-23, not '$DUMP_AT'" ;;
  esac
  case "$DUMP_KEEP_DAYS" in
    ''|*[!0-9]*) die "DUMP_KEEP_DAYS must be a whole number of days, not '$DUMP_KEEP_DAYS'" ;;
  esac
  # After stripping, so `00` and `08` are caught here, not as a zero-day window
  # or an invalid-octal arithmetic error later.
  [ "$(strip0 "$DUMP_KEEP_DAYS")" -ge 1 ] ||
    die "DUMP_KEEP_DAYS must be at least 1 — 0 would delete the dump just written"
  case "$DUMP_COMPRESS" in
    [0-9]|none) ;;
    *) die "DUMP_COMPRESS must be 0-9 or none, not '$DUMP_COMPRESS'" ;;
  esac
  [ "$(id -u)" != "0" ] ||
    die "refusing to run as root; set DUMP_UID and DUMP_GID to the account that owns $DUMP_DIR"
  [ -n "${DATABASE_URL:-}" ] || die "DATABASE_URL is required"
  # Only dumps the bundled `db` service — an operator on their own Postgres
  # deletes `db` and this service with it (docs/operating.md).
  host=$(printf '%s' "$DATABASE_URL" | sed -n 's|^[a-z+]*://[^@]*@\([^:/?]*\).*|\1|p')
  [ "$host" = "db" ] ||
    die "DATABASE_URL names '$host'; this service only dumps the bundled db service"
  # hostaddr is what libpq actually dials — an authority of `db` with
  # `?hostaddr=203.0.113.1` would send the bundled credential to a stranger.
  case "$DATABASE_URL" in
    *hostaddr=*|*"?host="*|*"&host="*)
      die "DATABASE_URL carries a host or hostaddr parameter, which decides the connection independently of the URL's own host" ;;
  esac
  [ -d "$DUMP_DIR" ] || die "$DUMP_DIR does not exist"
  [ -w "$DUMP_DIR" ] || die "$DUMP_DIR is not writable as $(id -u):$(id -g)"
}

marker() { printf '%s/%s' "$DUMP_DIR" "$1"; }

marker_field() {
  [ -f "$1" ] || return 0
  sed -n 's/.*"'"$2"'"[ ]*:[ ]*"\{0,1\}\([^",}]*\)"\{0,1\}.*/\1/p' "$1" | head -1
}

write_attempt() {
  printf '{"started_at":"%s","outcome":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" \
    > "$(marker last-attempt.json)"
}

write_success() {
  printf '{"finished_at":"%s","file":"%s","bytes":%s,"sha256":"%s","compress":"%s","server_version":"%s","app_version":"%s","seconds":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "$DUMP_COMPRESS" "$4" "$APP_VERSION" "$5" \
    > "$(marker last-success.json)"
}

write_error() {
  printf '{"failed_at":"%s","stage":"%s","message":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" > "$(marker last-error.json)"
}

is_ours() {
  case "$1" in
    portfolio-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z.dump) return 0 ;;
    *) return 1 ;;
  esac
}

name_epoch() {
  s=${1#portfolio-}
  s=${s%.dump}
  d=${s%T*}
  t=${s#*T}
  t=${t%Z}
  date -u -d "$(printf '%s' "$d" | cut -c1-4)-$(printf '%s' "$d" | cut -c5-6)-$(printf '%s' "$d" | cut -c7-8) $(printf '%s' "$t" | cut -c1-2):$(printf '%s' "$t" | cut -c3-4):$(printf '%s' "$t" | cut -c5-6)" +%s 2>/dev/null
}

prune() {
  dir="$1"
  cutoff=$(( $(now) - $(strip0 "$DUMP_KEEP_DAYS") * 86400 ))
  newest=""
  for f in "$dir"/portfolio-*.dump; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    is_ours "$b" || continue
    # Spelled as an `if`, not `a || b && c`: that form's false result would exit the loop under `set -e`.
    if [ -z "$newest" ] || [ "$b" \> "$newest" ]; then newest="$b"; fi
  done
  for f in "$dir"/portfolio-*.dump; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    is_ours "$b" || continue
    # The newest dump is never deleted, whatever its age: a stale copy beats an
    # empty directory on the day the collector has been broken for a fortnight.
    [ "$b" != "$newest" ] || continue
    e=$(name_epoch "$b")
    [ -n "$e" ] || continue
    [ "$e" -lt "$cutoff" ] || continue
    rm -f "$f" "$f.json"
    log "pruned $b"
  done
}

# `pg_restore --list` reads only the table of contents at the front of a
# custom archive — a dump truncated at 5% still lists everything and exits 0.
# Decoding to /dev/null reads every data block instead.
verify() {
  pg_restore -f /dev/null "$1" >/dev/null 2>&1
}

db_query() { psql -d "$DATABASE_URL" -At -q -c "$1"; }

free_bytes() { df -P "$DUMP_DIR" | awk 'NR==2 {print $4 * 1024}'; }

# Bounded from the database, not the last archive (a first run has no predecessor). Twice the
# size: an uncompressed dump exceeds its source pages since TOAST-compressed jsonb expands.
room_for_dump() {
  size=$(db_query "select pg_database_size(current_database())") || size=""
  # Distinct from a space refusal, or a stale `stage=space` marker would skip
  # every retry for a database merely unreachable for a minute.
  if [ -z "$size" ]; then
    fail_run "database" "could not read the database size"
    return 1
  fi
  # Distinct exit code from the space refusal below (2), so the caller can
  # tell them apart without re-reading a marker file.
  need=$(( size * 2 + FLOOR_BYTES ))
  have=$(free_bytes)
  [ "$have" -ge "$need" ] && return 0
  fail_run "space" "refusing: $DUMP_DIR has $have bytes free, this run needs $need"
  return 2
}

# A dump far smaller than the last is a truncation the decode missed — but only when both were
# written at the same compression, since changing that legitimately changes size by an order of magnitude.
too_small() {
  last=$(marker last-success.json)
  prev_bytes=$(marker_field "$last" bytes)
  prev_compress=$(marker_field "$last" compress)
  [ -n "$prev_bytes" ] || return 1
  [ "$prev_compress" = "$DUMP_COMPRESS" ] || return 1
  [ "$(( $1 * 2 ))" -lt "$prev_bytes" ]
}

# `set -e` doesn't apply inside a function called as `||`'s left operand
# (exactly how the loop calls run_once) — so every step below is checked by hand.
fail_run() {
  log "$2"
  write_error "$1" "$2"
  write_attempt failure
}

run_once() {
  write_attempt started || { log "cannot write to $DUMP_DIR"; return 1; }
  prune "$DUMP_DIR" || log "retention pass failed; continuing to the dump"
  room_for_dump || return $?

  s=$(stamp)
  part="$DUMP_DIR/.portfolio-$s.dump.part"
  final="$DUMP_DIR/portfolio-$s.dump"
  started=$(now)

  if ! pg_dump -d "$DATABASE_URL" --format=custom --compress="$DUMP_COMPRESS" -f "$part" 2>/tmp/dump.err; then
    fail_run "pg_dump" "pg_dump failed: $(tr -d '\n\"' < /tmp/dump.err | tail -c 200)"
    rm -f "$part"; return 1
  fi

  if ! verify "$part"; then
    fail_run "verify" "verification failed: the archive does not decode whole"
    rm -f "$part"; return 1
  fi

  bytes=$(wc -c < "$part" 2>/dev/null | tr -d ' ') || bytes=""
  [ -n "$bytes" ] || { fail_run "size" "could not measure the archive"; return 1; }
  if too_small "$bytes"; then
    fail_run "shrink" "refusing: $bytes bytes is less than half the last dump at the same compression"
    rm -f "$part"; return 1
  fi

  # Staging file lives here, not on a tmpfs, so this mv stays within one
  # filesystem — a cross-device mv is a copy, exposing a half-written archive.
  mv "$part" "$final" || { fail_run "publish" "could not rename the archive into place"; rm -f "$part"; return 1; }

  sha=$(sha256sum "$final" | cut -d' ' -f1) || sha=""
  [ -n "$sha" ] || { fail_run "publish" "could not hash $(basename "$final")"; return 1; }
  server=$(db_query 'show server_version') || server="unknown"
  finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  elapsed=$(( $(now) - started ))

  # Outlives last-success.json, which tomorrow's run overwrites — so a dump
  # collected weeks later still carries its own finish time.
  printf '{"finished_at":"%s","sha256":"%s","bytes":%s,"compress":"%s","server_version":"%s","app_version":"%s","seconds":%s}\n' \
    "$finished" "$sha" "$bytes" "$DUMP_COMPRESS" "$server" "$APP_VERSION" "$elapsed" > "$final.json" ||
    { fail_run "publish" "could not write the sidecar json"; return 1; }

  write_success "$(basename "$final")" "$bytes" "$sha" "$server" "$elapsed" ||
    { fail_run "publish" "could not write the success marker"; return 1; }
  write_attempt success || { log "wrote the dump but could not update the attempt marker"; return 1; }
  log "wrote $(basename "$final") ($bytes bytes)"
}

seconds_until_window() {
  target=$(( $(strip0 "$DUMP_AT") * 3600 ))
  current=$(( $(strip0 "$(date -u +%H)") * 3600 + $(strip0 "$(date -u +%M)") * 60 + $(strip0 "$(date -u +%S)") ))
  d=$(( target - current ))
  [ "$d" -gt 0 ] || d=$(( d + 86400 ))
  printf '%s\n' "$d"
}

# Sleep in chunks so SIGTERM lands promptly. Guard against `left` going bad —
# a silent no-op here once turned this loop into dump-as-fast-as-possible.
nap() {
  left="$1"
  case "$left" in
    ''|*[!0-9]*)
      log "internal: refusing to sleep '$left' seconds; waiting an hour instead"
      left=3600
      ;;
  esac
  while [ "$left" -gt 0 ]; do
    [ "$left" -lt 60 ] && { sleep "$left"; return 0; }
    sleep 60
    left=$(( left - 60 ))
  done
}

# Not "dump on every boot" (a crash loop would dump each time). Only a *successful* attempt within
# the last hour holds the boot dump back, so a crash mid-retry doesn't abandon the ladder until tomorrow.
needs_catch_up() {
  a=$(marker last-attempt.json)
  [ -f "$a" ] || return 0
  [ "$(marker_field "$a" outcome)" = "success" ] || return 0
  started=$(marker_field "$a" started_at)
  epoch=$(date -u -d "$(printf '%s' "$started" | tr 'TZ' ' ')" +%s 2>/dev/null || echo 0)
  [ "$(( $(now) - epoch ))" -gt 3600 ]
}

loop() {
  rm -f "$DUMP_DIR"/.portfolio-*.dump.part
  if needs_catch_up; then
    log "no recent successful attempt; dumping now"
    run_once || retry_ladder $?
  fi
  while true; do
    nap "$(seconds_until_window)"
    run_once || retry_ladder $?
  done
}

# Takes the failed run's own exit code rather than re-reading a marker: a stale
# `stage=space` from last week must not silence today's retries.
retry_ladder() {
  # A space refusal is the one failure retrying cannot help and can worsen.
  [ "${1:-1}" != "2" ] || { log "no retries for a space refusal; waiting for the next window"; return 0; }
  first_failure=$(now)
  for offset in $RETRY_OFFSETS; do
    delay=$(( first_failure + offset - $(now) ))
    [ "$delay" -gt 0 ] || delay=1
    log "retrying at +$(( offset / 60 )) minutes"
    nap "$delay"
    run_once && return 0
  done
  log "three attempts failed; waiting for the next window"
}

# Age of the newest dump, not the last exit status — for a human at `docker compose ps`; restart policies don't act on this.
healthcheck() {
  newest=""
  for f in "$DUMP_DIR"/portfolio-*.dump; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    is_ours "$b" || continue
    if [ -z "$newest" ] || [ "$b" \> "$newest" ]; then newest="$b"; fi
  done
  [ -n "$newest" ] || { echo "no dump yet"; exit 1; }
  age=$(( $(now) - $(name_epoch "$newest") ))
  # A day, plus six hours of grace for a slow run or a retry ladder.
  [ "$age" -lt 108000 ] || { echo "newest dump is $age seconds old"; exit 1; }
  echo "$newest"
}

case "${1:-loop}" in
  loop)
    validate_enabled
    if [ "$DUMP_ENABLED" = "false" ]; then
      log "dumps are disabled by DUMP_ENABLED=false; exiting"
      exit 0
    fi
    validate
    log "every day at ${DUMP_AT}:00 UTC, keeping ${DUMP_KEEP_DAYS} days in $DUMP_DIR"
    loop
    ;;
  verify)  [ $# -eq 2 ] || die "usage: dump-loop.sh verify <file>"; verify "$2" ;;
  prune)   [ $# -eq 2 ] || die "usage: dump-loop.sh prune <dir>"; prune "$2" ;;
  healthcheck) healthcheck ;;
  *) die "unknown command '$1'" ;;
esac
