#!/bin/bash
set -e

# Change to script's directory
if [ -n "$1" ]; then
    OUT_DIR="$1"
else
    OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Konfiguration
IMG_FILE="${OUT_DIR}/qemu_gpt.img"
IMG_SIZE="254M"
REF_FILES_SOURCE="$SCRIPT_DIR/../ci/nci-config/x86/scripts/target/muenblock-ref"

# Farben für Output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Cleanup Funktion
cleanup() {
    log_info "Cleanup..."
    rm -rf "$TEMP_DIR" "$TEMP_DIR2"
}

# Cleanup bei Fehler oder Exit
trap cleanup EXIT

log_info "=== Erstelle Partition 1: ext4 mit Referenzdateien ==="
# Erstelle temporäres Verzeichnis für Referenzdateien
TEMP_DIR=$(mktemp -d)
mkdir -p "$TEMP_DIR/files"
cd "$TEMP_DIR/files"

if [ -x "$REF_FILES_SOURCE" ]; then
    log_info "Erstelle Referenzdateien mit: $REF_FILES_SOURCE"
    $REF_FILES_SOURCE .
else
    log_error "muenblock-ref nicht gefunden. Abbruch"
    exit 1
fi

cd - > /dev/null

log_info "Erstelle ext4 partition (200MB)"
virt-make-fs --format=raw --type=ext4 --size=200M "$TEMP_DIR" partition1.img

log_info "Partition 1 (ext4) fertig - 200MB"

log_info "=== Erstelle Partition 2: ext2 ==="
# Erstelle leeres Verzeichnis für Partition 2
TEMP_DIR2=$(mktemp -d)
mkdir -p "$TEMP_DIR2/empty"

log_info "Erstelle ext2 partition (50MB)"
virt-make-fs --format=raw --type=ext2 --size=50M "$TEMP_DIR2/empty" partition2.img

log_info "Partition 2 (ext2) fertig - 50MB"

log_info "=== Kombiniere Partitionen zu GPT Image ==="
# Erstelle Image mit GPT
truncate -s $IMG_SIZE $IMG_FILE

# Verwende guestfish um GPT und Partitionen zu erstellen
guestfish -a $IMG_FILE <<EOF
run
part-init /dev/sda gpt
# 2048 .. 411647 = 200MiB (409600 sectors)
part-add /dev/sda primary 2048 411647
part-add /dev/sda primary 411648 514047
part-set-name /dev/sda 1 "Testing"
part-set-name /dev/sda 2 "ext"
EOF

# Kopiere die Filesystems in die Partitionen
log_info "Kopiere Filesystems in Partitionen"
dd if=partition1.img of=$IMG_FILE bs=512 seek=2048 conv=notrunc 2>/dev/null
dd if=partition2.img of=$IMG_FILE bs=512 seek=411648 conv=notrunc 2>/dev/null

# Cleanup temporäre Dateien
rm -f partition1.img partition2.img
rm -rf "$TEMP_DIR" "$TEMP_DIR2"

# Deaktiviere Cleanup trap (erfolgreich abgeschlossen)
trap - EXIT

log_info ""
log_info "=== Image erfolgreich erstellt (ohne root!) ==="
log_info "Image-Datei: $IMG_FILE"
log_info "✓ Partition 1 (ext4): 200M - mit Referenzdateien"
log_info "✓ Partition 2 (ext2): 50MB"
log_info ""
log_info "Zum Mounten des Images (mit guestfish, kein root nötig):"
log_info "  guestfish -a $IMG_FILE -m /dev/sda1"
log_info ""
log_info "Oder mit guestmount:"
log_info "  mkdir -p /tmp/mnt"
log_info "  guestmount -a $IMG_FILE -m /dev/sda1 /tmp/mnt"
log_info "  # Nach Gebrauch:"
log_info "  guestunmount /tmp/mnt"

# Zeige Partitionstabelle
log_info ""
log_info "Partitionstabelle:"
guestfish -a $IMG_FILE <<EOF
run
part-list /dev/sda
EOF