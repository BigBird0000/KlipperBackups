#!/bin/bash
set -euo pipefail

########################################
# USER SETTINGS (safe defaults)
########################################
BACKUP_DIR="/root/backups"
KEEP_ARCHIVES=1

# Compression: auto | zstd | xz
COMPRESSION="auto"

# Optional features
ENABLE_CHECKSUM=true
ENABLE_RSYNC=false
RSYNC_TARGET="backup@nas:/volume1/klipper-backups"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

########################################
# Helpers
########################################
run() {
  if $DRY_RUN; then
    echo "[DRY-RUN] $*"
  else
    "$@"
  fi
}

########################################
# CPU detection & auto tuning
########################################
CPU_CORES=$(nproc)

if [[ "$COMPRESSION" == "auto" || "$COMPRESSION" == "zstd" ]]; then
  COMPRESSION="zstd"

  if (( CPU_CORES <= 1 )); then
    ZSTD_LEVEL=3
    ZSTD_THREADS=1
  elif (( CPU_CORES == 2 )); then
    ZSTD_LEVEL=5
    ZSTD_THREADS=2
  elif (( CPU_CORES <= 4 )); then
    ZSTD_LEVEL=6
    ZSTD_THREADS=4
  else
    ZSTD_LEVEL=8
    ZSTD_THREADS="$CPU_CORES"
  fi
fi

case "$COMPRESSION" in
  zstd)
    EXT="tar.zst"
    TAR_COMPRESS="zstd -$ZSTD_LEVEL -T$ZSTD_THREADS"
    ;;
  xz)
    EXT="tar.xz"
    TAR_COMPRESS="xz -6"
    ;;
  *)
    echo "ERROR: Unknown compression: $COMPRESSION"
    exit 1
    ;;
esac

########################################
#                  Paths
########################################
SOURCE="/"
TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
ARCHIVE_NAME="full_backup_$TIMESTAMP.$EXT"
ARCHIVE_PATH="$BACKUP_DIR/$ARCHIVE_NAME"
KLIPPER_ARCHIVE="/home/ajs/klipper-archive.sh"

########################################
# Excludes (shared)
########################################
EXCLUDES=(
  "$BACKUP_DIR"
  "*/.cache/*"
  "/dev"
  "/home/ajs/.cache"
  "/lost+found"
  "/media"
  "/mnt"
  "/proc"
  "/run"
  "/sys"
  "/timeshift"
  "/tmp"
  "/var/tmp"
  "/var/cache"
  "/var/lib/snapd"
  "/var/log"
  "full_backup*"
  "*.sock"
)

DU_EXCLUDES=()
TAR_EXCLUDES=()
for p in "${EXCLUDES[@]}"; do
  DU_EXCLUDES+=( "--exclude=$p" )
  TAR_EXCLUDES+=( "--exclude=$p" )
done

########################################
# Ensure backup dir
########################################
run mkdir -p "$BACKUP_DIR"

########################################
# Always restore Klipper
########################################
restore() {
  echo
  echo "Restoring Klipper services..."
  run "$KLIPPER_ARCHIVE" post || true
}
trap restore ERR INT

########################################
# Pre-clean
########################################
run sudo journalctl --vacuum-time=5d || true

snap list --all |
awk '/disabled/ { print $1, $3 }' |
while read -r snap rev; do
  run sudo snap remove --purge "$snap" --revision="$rev" || true
done

########################################
# Klipper pre-archive
########################################
if [ ! -f "$HOME/.klipper_archive_lock" ]; then
    run "$KLIPPER_ARCHIVE" pre
else
    echo "Lock file exists, skipping pre-archive (previous run incomplete?)"
fi

########################################
# Ensure tools
########################################
for cmd in tar du pv sha256sum; do
  command -v "$cmd" >/dev/null || run sudo apt install -y "$cmd"
done

########################################
# Estimate size
########################################
echo "Please allow a few minutes to estimate size"
TOTAL_SIZE=$(sudo du -sb "${DU_EXCLUDES[@]}" "$SOURCE" | awk '{print $1}')
echo "Estimated size: $((TOTAL_SIZE / 1024 / 1024)) MiB"
echo "Compression:   $COMPRESSION"
echo "CPU cores:     $CPU_CORES"
[[ "$COMPRESSION" == "zstd" ]] && echo "zstd level:    $ZSTD_LEVEL (threads: $ZSTD_THREADS)"

############################################################
#      Check if there is enough free space on the disk     #
############################################################
# get free space on disk in kb
BACKUP_FS=$(df -P "$BACKUP_DIR" | tail -1 | awk '{print $4}')
# convert to bytes for comparison
FREE_BYTES=$(( BACKUP_FS * 1024 ))

# do compare
echo "  Available: $((FREE_BYTES / 1024 / 1024)) MiB"
echo "     Needed: $((TOTAL_SIZE / 1024 / 1024)) MiB"
if (( FREE_BYTES < TOTAL_SIZE )); then
    echo "***  ERROR: Not enough free space in $BACKUP_DIR"
    exit 1
fi

#################################################################################
#                                Run backup
#################################################################################
echo "Starting backup..."
# older ## run bash -c "
# older ##   tar -c \
# older ##     --warning=no-file-changed \
# older ##     --ignore-failed-read \
# older ##     --use-compress-program='$TAR_COMPRESS' \
# older ##     ${TAR_EXCLUDES[*]} \
# older ##     '$SOURCE' \
# older ##   2>tar-errors.log \
# older ##   | tee tar-warnings.log \
# older ##   | pv -s $TOTAL_SIZE \
# older ##   > '$ARCHIVE_PATH'
# older ## "
# tar -cvf archive.tar /path/to/dir | grep -E '/$'
run bash -c "
  tar -cvf \
    --warning=no-file-changed \
    --ignore-failed-read \
    --use-compress-program='$TAR_COMPRESS' \
    ${TAR_EXCLUDES[*]} \
    '$SOURCE' \
  2>tar-errors.log \
  | grep '/$' \
  | tee tar-warnings.log \
  | pv -s $TOTAL_SIZE \
  > '$ARCHIVE_PATH'
"



echo "Check Files tar-warnings.log and tar-errors.log
# if .log file is too big, exit !
if [ $(wc -c < tar-errors.log) -gt 50 ]; then
    echo "File tar-errors.log is larger than 50 bytes, exiting."
    exit 0
fi

# if .log file is too big, exit !
if [ $(wc -c < tar-warnings.log) -gt 50 ]; then
    echo "File tar-warnings.log is larger than 50 bytes, exiting."
    exit 0
fi


########################################
# Optional checksum
########################################
if $ENABLE_CHECKSUM; then
  run sha256sum "$ARCHIVE_PATH" > "$ARCHIVE_PATH.sha256"
fi

########################################
# Auto-prune old archives
########################################
mapfile -t ARCHIVES < <(ls -1t "$BACKUP_DIR"/full_backup_*.$EXT 2>/dev/null || true)
if (( ${#ARCHIVES[@]} > KEEP_ARCHIVES )); then
  for old in "${ARCHIVES[@]:KEEP_ARCHIVES}"; do
    run rm -f "$old" "$old.sha256" || true
  done
fi

########################################
# Optional rsync
########################################
if $ENABLE_RSYNC; then
  run rsync -av --progress "$ARCHIVE_PATH"* "$RSYNC_TARGET/"
fi

#################################################################
#                  Restore
##################################################################
restore
trap - ERR INT

echo
echo "✅ Backup complete:"
echo "   $ARCHIVE_PATH"
$ENABLE_CHECKSUM && echo "   checksum: $ARCHIVE_PATH.sha256"
$ENABLE_RSYNC && echo "   synced to: $RSYNC_TARGET"
$DRY_RUN && echo "NOTE: Dry-run mode — no changes were made."
