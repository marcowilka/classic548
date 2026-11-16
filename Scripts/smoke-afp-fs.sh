#!/bin/zsh
# Smoke-test ClassicAFP / FSKit volume I/O on a live mount.
# Assumes the volume is already mounted (no ClassicAFP IPC / mount logic).
#
# Usage:
#   ./Scripts/smoke-afp-fs.sh
#   ./Scripts/smoke-afp-fs.sh /Volumes/OtherVol/some/path
set -euo pipefail

ROOT="${1:-/Volumes/SPM/deinsportplatz/Technik}"
PASSED=0
FAILED=0
WARNED=0
WORK=""

cleanup() {
  if [[ -n "${WORK:-}" && -e "$WORK" ]]; then
    rm -rf "$WORK" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

ok() {
  echo "OK  $1"
  PASSED=$((PASSED + 1))
}

fail() {
  echo "FAIL $1${2:+ — $2}"
  FAILED=$((FAILED + 1))
}

warn() {
  echo "WARN $1${2:+ — $2}"
  WARNED=$((WARNED + 1))
}

echo "== ClassicAFP FS smoke: $ROOT"

if [[ ! -d "$ROOT" ]]; then
  echo "error: mount path missing: $ROOT" >&2
  echo "  Mount the share in ClassicAFP first, then re-run." >&2
  exit 1
fi

WORK="$ROOT/classic548-smoke-$$-$(date +%Y%m%d%H%M%S)"
if ! mkdir -p "$WORK" 2>/tmp/classic548-smoke-mkdir.err; then
  echo "error: cannot create work dir under $ROOT" >&2
  echo "  mkdir failed: $(tr '\n' ' ' </tmp/classic548-smoke-mkdir.err)" >&2
  echo "  Path mode bits may look writable while FSKit create returns EINVAL." >&2
  rm -f /tmp/classic548-smoke-mkdir.err
  exit 1
fi
rm -f /tmp/classic548-smoke-mkdir.err
echo "Work dir: $WORK"

# --- 1. mkdir nested dirs ---
if mkdir -p "$WORK/a/b/c"; then
  ok "mkdir nested"
else
  fail "mkdir nested"
fi

# --- 2. create + write small file ---
SMALL="$WORK/a/small.txt"
EXPECTED_SMALL=$'hello classic548\nline2'
if printf '%s' "$EXPECTED_SMALL" >"$SMALL"; then
  ok "create write"
else
  fail "create write"
fi

# --- 3. read / content compare ---
if [[ -f "$SMALL" ]] && cmp -s <(printf '%s' "$EXPECTED_SMALL") "$SMALL"; then
  ok "read compare"
else
  fail "read compare"
fi

# --- 4. overwrite ---
EXPECTED_OVER=$'overwritten content\nv2'
if printf '%s' "$EXPECTED_OVER" >"$SMALL" && cmp -s <(printf '%s' "$EXPECTED_OVER") "$SMALL"; then
  ok "overwrite"
else
  fail "overwrite"
fi

# --- 5. append ---
if printf '\nappended' >>"$SMALL"; then
  EXPECTED_APPEND=$'overwritten content\nv2\nappended'
  if cmp -s <(printf '%s' "$EXPECTED_APPEND") "$SMALL"; then
    ok "append"
  else
    fail "append" "content mismatch after append"
  fi
else
  fail "append" "write failed"
fi

# --- 6. copy file + directory tree ---
COPY_FILE="$WORK/a/small-copy.txt"
if cp "$SMALL" "$COPY_FILE" && cmp -s "$SMALL" "$COPY_FILE"; then
  ok "copy file"
else
  fail "copy file"
fi

if cp -R "$WORK/a" "$WORK/a-copy" \
  && [[ -f "$WORK/a-copy/small.txt" ]] \
  && [[ -d "$WORK/a-copy/b/c" ]] \
  && cmp -s "$SMALL" "$WORK/a-copy/small.txt"; then
  ok "copy tree"
else
  fail "copy tree"
fi

# --- 7. rename / move ---
MOVED="$WORK/a/renamed.txt"
if mv "$COPY_FILE" "$MOVED" && [[ -f "$MOVED" ]] && [[ ! -e "$COPY_FILE" ]]; then
  ok "rename move"
else
  fail "rename move"
fi

# --- 8. delete file / empty dir / non-empty dir ---
if rm -f "$MOVED" && [[ ! -e "$MOVED" ]]; then
  ok "delete file"
else
  fail "delete file"
fi

EMPTY_DIR="$WORK/empty-dir"
if mkdir -p "$EMPTY_DIR" && rmdir "$EMPTY_DIR" && [[ ! -e "$EMPTY_DIR" ]]; then
  ok "rmdir empty"
else
  fail "rmdir empty"
fi

if rm -rf "$WORK/a-copy" && [[ ! -e "$WORK/a-copy" ]]; then
  ok "rm tree"
else
  fail "rm tree"
fi

# --- 9. larger write (~1.5 MiB) + checksum ---
LARGE="$WORK/a/large.bin"
LARGE_SRC="$WORK/.large-src.bin"
# 1536 KiB of patterned data (local staging, then copy onto volume).
if dd if=/dev/zero bs=1024 count=1536 2>/dev/null | \
   LC_ALL=C tr '\0' 'A' >"$LARGE_SRC"; then
  if cp "$LARGE_SRC" "$LARGE"; then
    SUM_SRC=$(shasum -a 256 "$LARGE_SRC" | awk '{print $1}')
    SUM_DST=$(shasum -a 256 "$LARGE" | awk '{print $1}')
    if [[ "$SUM_SRC" == "$SUM_DST" && -n "$SUM_DST" ]]; then
      ok "large write checksum"
    else
      fail "large write checksum" "src=$SUM_SRC dst=$SUM_DST"
    fi
  else
    fail "large write checksum" "cp to volume failed"
  fi
else
  fail "large write checksum" "local pattern generate failed"
fi
rm -f "$LARGE_SRC" 2>/dev/null || true

# Overwrite large file with different pattern and verify.
if dd if=/dev/zero bs=1024 count=512 2>/dev/null | \
   LC_ALL=C tr '\0' 'B' >"$LARGE_SRC"; then
  if cp "$LARGE_SRC" "$LARGE"; then
    SUM_SRC=$(shasum -a 256 "$LARGE_SRC" | awk '{print $1}')
    SUM_DST=$(shasum -a 256 "$LARGE" | awk '{print $1}')
    SIZE=$(stat -f '%z' "$LARGE" 2>/dev/null || echo 0)
    if [[ "$SUM_SRC" == "$SUM_DST" && "$SIZE" -eq 524288 ]]; then
      ok "large overwrite truncate"
    else
      fail "large overwrite truncate" "src=$SUM_SRC dst=$SUM_DST size=$SIZE"
    fi
  else
    fail "large overwrite truncate" "cp failed"
  fi
else
  fail "large overwrite truncate" "pattern generate failed"
fi
rm -f "$LARGE_SRC" 2>/dev/null || true

# --- 10. stat / list ---
if ls -la "$WORK/a" >/dev/null 2>&1; then
  ok "ls"
else
  fail "ls"
fi

if stat "$SMALL" >/dev/null 2>&1 && stat "$WORK/a" >/dev/null 2>&1; then
  ok "stat"
else
  fail "stat"
fi

# Soft check: xattr list (WARN only)
if command -v xattr >/dev/null 2>&1; then
  if xattr -l "$SMALL" >/dev/null 2>&1; then
    warn "xattr list" "ok (informational)"
  else
    warn "xattr list" "failed (non-fatal)"
  fi
else
  warn "xattr list" "xattr not available"
fi

echo "== Result: $PASSED passed, $FAILED failed, $WARNED warned"
if [[ "$FAILED" -gt 0 ]]; then
  exit 1
fi
exit 0
