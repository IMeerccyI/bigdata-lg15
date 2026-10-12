#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="${1:-}"
case "$LABEL" in
  1GB) SIZE=1000000000; BLOCKS=1000 ;;
  10GB) SIZE=10000000000; BLOCKS=10000 ;;
  *) echo "Uso: $0 1GB|10GB" >&2; exit 2 ;;
esac

mkdir -p "$ROOT_DIR/datasets"
FILE="$ROOT_DIR/datasets/dataset_${LABEL}.bin"
if [[ -f "$FILE" ]]; then
  ACTUAL="$(stat -c %s "$FILE")"
  if [[ "$ACTUAL" != "$SIZE" ]]; then
    echo "El archivo existente tiene $ACTUAL bytes; se esperaban $SIZE. Revíselo manualmente." >&2
    exit 1
  fi
  echo "Dataset existente: $FILE ($ACTUAL bytes)"
  exit 0
fi

echo "Generando $LABEL de datos binarios sintéticos fuera de Git..."
dd if=/dev/urandom of="$FILE" bs=1000000 count="$BLOCKS" status=progress
echo "Generado: $FILE ($(stat -c %s "$FILE") bytes)"
