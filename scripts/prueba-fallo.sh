#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="${1:-}"
MODE="${2:-}"
case "$LABEL" in
  1GB) SIZE=1000000000 ;;
  10GB) SIZE=10000000000 ;;
  *) echo "Uso: $0 1GB|10GB [--reuse]" >&2; exit 2 ;;
esac
if [[ -n "$MODE" && "$MODE" != "--reuse" ]]; then
  echo "Uso: $0 1GB|10GB [--reuse]" >&2
  exit 2
fi

cd "$ROOT_DIR"
SOURCE="datasets/dataset_${LABEL}.bin"
HDFS_PATH="/lg15/dataset_${LABEL}/dataset_${LABEL}.bin"
RESULT_DIR="evidencias/resultados/${LABEL}"
mkdir -p "$RESULT_DIR"

./scripts/generar-dataset.sh "$LABEL"
docker compose up -d

live_nodes() {
  docker compose exec -T namenode hdfs dfsadmin -report 2>/dev/null \
    | sed -n 's/^Live datanodes (\([0-9]*\)):/\1/p' | head -1
}

wait_for_nodes() {
  local wanted="$1" actual
  for _ in $(seq 1 120); do
    actual="$(live_nodes || true)"
    if [[ "$actual" == "$wanted" ]]; then return 0; fi
    sleep 2
  done
  echo "HDFS no reportó $wanted DataNodes activos. Último valor: ${actual:-ninguno}" >&2
  return 1
}

wait_for_nodes 3
if [[ "$MODE" == "--reuse" ]]; then
  echo "Reutilizando $LABEL ya cargado en HDFS..."
else
  echo "Subiendo $LABEL a HDFS con factor de replicación 2..."
  docker compose exec -T namenode hdfs dfs -mkdir -p "/lg15/dataset_${LABEL}"
  docker compose exec -T namenode hdfs dfs -put -f "/datasets/dataset_${LABEL}.bin" "$HDFS_PATH"
fi
docker compose exec -T namenode hdfs dfs -setrep -w 2 "$HDFS_PATH" >/dev/null

ACTUAL="$(docker compose exec -T namenode hdfs dfs -stat '%b' "$HDFS_PATH")"
if [[ "$ACTUAL" != "$SIZE" ]]; then
  echo "Tamaño en HDFS incorrecto: $ACTUAL bytes; se esperaban $SIZE." >&2
  exit 1
fi

docker compose ps > "$RESULT_DIR/contenedores-antes.txt"
docker compose exec -T namenode hdfs dfsadmin -report > "$RESULT_DIR/antes-reporte.txt"
docker compose exec -T namenode hdfs fsck "$HDFS_PATH" -files -blocks -locations > "$RESULT_DIR/antes-fsck.txt"
docker compose exec -T namenode hdfs dfs -ls "$HDFS_PATH" > "$RESULT_DIR/antes-archivo.txt"

NODE_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' lg15-datanode-2)"
if [[ -z "$NODE_IP" ]] || ! grep -qF "$NODE_IP:9866" "$RESULT_DIR/antes-fsck.txt"; then
  echo "El DataNode 2 no contiene bloques de este archivo; no se puede usar para esta prueba." >&2
  exit 1
fi
AFFECTED_BLOCKS="$(grep -cF "$NODE_IP:9866" "$RESULT_DIR/antes-fsck.txt")"

EXPECTED_SHA="$(sha256sum "$SOURCE" | cut -d' ' -f1)"
printf '%s  %s\n' "$EXPECTED_SHA" "$SOURCE" > "$RESULT_DIR/sha256-local.txt"

echo "Simulando la caída de datanode2..."
FAILURE_STARTED="$(date +%s)"
docker compose kill datanode2
restore_node() { docker compose start datanode2 >/dev/null; }
trap restore_node EXIT
for _ in $(seq 1 180); do
  docker compose exec -T namenode hdfs dfsadmin -report > "$RESULT_DIR/durante-reporte.txt"
  if grep -q '^Live datanodes (2):' "$RESULT_DIR/durante-reporte.txt"; then break; fi
  sleep 1
done
if ! grep -q '^Live datanodes (2):' "$RESULT_DIR/durante-reporte.txt"; then
  echo "HDFS no detectó la caída de datanode2." >&2
  exit 1
fi
FAILURE_DETECTED="$(date +%s)"

docker compose ps -a > "$RESULT_DIR/durante-contenedores.txt"
docker compose exec -T namenode hdfs fsck "$HDFS_PATH" -files -blocks -locations > "$RESULT_DIR/durante-fsck.txt"

echo "Esperando la recuperación automática de las réplicas..."
RECOVERED=0
SEEN_SUBREP=0
for _ in $(seq 1 180); do
  docker compose exec -T namenode hdfs fsck "$HDFS_PATH" -files -blocks -locations > "$RESULT_DIR/recuperacion-fsck.txt"
  if [[ "$SEEN_SUBREP" == 0 ]] && grep -Eq 'Under-replicated blocks:[[:space:]]*[1-9][0-9]*' "$RESULT_DIR/recuperacion-fsck.txt"; then
    cp "$RESULT_DIR/recuperacion-fsck.txt" "$RESULT_DIR/durante-subrep-fsck.txt"
    SEEN_SUBREP=1
  fi
  if grep -Eq 'Under-replicated blocks:[[:space:]]*0([[:space:]]|$)' "$RESULT_DIR/recuperacion-fsck.txt" \
    && grep -q 'Status: HEALTHY' "$RESULT_DIR/recuperacion-fsck.txt" \
    && ! grep -qF "$NODE_IP:9866" "$RESULT_DIR/recuperacion-fsck.txt"; then
    RECOVERED=1
    break
  fi
  sleep 2
done
RECOVERY_FINISHED="$(date +%s)"
if [[ "$RECOVERED" != 1 ]]; then
  echo "No se comprobó la recuperación de todas las réplicas en seis minutos." >&2
  exit 1
fi

docker compose exec -T namenode hdfs dfsadmin -report > "$RESULT_DIR/recuperacion-reporte.txt"
echo "Leyendo el archivo completo mientras datanode2 sigue caído..."
ACTUAL_SHA="$(docker compose exec -T namenode bash -o pipefail -c "hdfs dfs -cat '$HDFS_PATH' | sha256sum" | cut -d' ' -f1)"
printf '%s  %s\n' "$ACTUAL_SHA" "$HDFS_PATH" > "$RESULT_DIR/sha256-durante.txt"
if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
  echo "La lectura difiere del archivo original." >&2
  exit 1
fi
{
  echo "Dataset: $LABEL"
  echo "Tamaño exacto: $SIZE bytes"
  echo "Archivo HDFS: $HDFS_PATH"
  echo "DataNode detenido: datanode2"
  echo "Bloques inicialmente ubicados en el nodo detenido: $AFFECTED_BLOCKS"
  echo "Tiempo hasta detectar la caída: $((FAILURE_DETECTED - FAILURE_STARTED)) segundos"
  echo "Tiempo desde detección hasta recuperar la replicación: $((RECOVERY_FINISHED - FAILURE_DETECTED)) segundos"
  echo "SHA256 original: $EXPECTED_SHA"
  echo "SHA256 leído durante la falla: $ACTUAL_SHA"
  echo "Lectura durante la falla: correcta"
} | tee "$RESULT_DIR/resumen.txt"

echo "Restaurando datanode2..."
restore_node
trap - EXIT
wait_for_nodes 3
docker compose exec -T namenode hdfs dfsadmin -report > "$RESULT_DIR/despues-reporte.txt"
docker compose exec -T namenode hdfs fsck "$HDFS_PATH" -files -blocks -locations > "$RESULT_DIR/despues-fsck.txt"
echo "Prueba $LABEL completada. Resultados: $RESULT_DIR"
