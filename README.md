# LG15 Tolerancia a fallos en HDFS

Continuación de la práctica de HDFS de LG14, ahora en un repositorio independiente. El entorno usa un NameNode y tres DataNodes con factor de replicación 2. Se prueba la caída de un DataNode con archivos sintéticos de 1 GB y 10 GB.

## Iniciar

```bash
docker compose up -d
docker compose ps
docker compose exec -T namenode hdfs dfsadmin -report
```

Interfaz del NameNode: <http://localhost:9871>. Cada DataNode usa un volumen propio. Los puertos 9871, 9865, 9866 y 9867 permiten abrir sus interfaces sin interferir con la práctica anterior.

## Ejecutar las dos pruebas

```bash
./scripts/prueba-fallo.sh 1GB
./scripts/prueba-fallo.sh 10GB
```

Cada prueba genera el archivo local, lo sube a HDFS, registra los bloques y sus ubicaciones, provoca la caída de `datanode2` y espera que HDFS restaure la segunda réplica en los dos nodos restantes. Con `datanode2` aún detenido, lee el archivo completo y compara su SHA256 con el original. Finalmente vuelve a iniciarlo.

Para repetir una prueba sin volver a subir el archivo, añade `--reuse`, por ejemplo `./scripts/prueba-fallo.sh 10GB --reuse`.

Los datasets son binarios sintéticos de exactamente 1.000.000.000 y 10.000.000.000 bytes. Quedan en `datasets/`, que está ignorada por Git. HDFS sí almacena sus bloques y réplicas en los volúmenes de Docker.

Los registros pequeños de cada experimento están en `evidencias/resultados/1GB/` y `evidencias/resultados/10GB/`. Antes, durante y después se guardan las salidas de `hdfs dfsadmin -report` y `hdfs fsck -files -blocks -locations`.

## Resultados observados

| Característica | Dataset 1 GB | Dataset 10 GB |
| --- | ---: | ---: |
| Tamaño exacto | 1.000.000.000 bytes | 10.000.000.000 bytes |
| Bloques de 128 MiB | 8 | 75 |
| Réplicas configuradas por bloque | 2 | 2 |
| DataNode detenido | `datanode2` | `datanode2` |
| Bloques que tenía ese nodo | 5 | 54 |
| Bloques disponibles durante la falla | 8 de 8 | 75 de 75 |
| Bloques subreplicados observados | 5 | 54 |
| Archivo legible con el nodo caído | Sí; SHA256 igual | Sí; SHA256 igual |
| Tiempo hasta detectar la caída | 31 s | 31 s |
| Tiempo para restaurar las réplicas | 29 s | 147 s |
| Nuevas réplicas | 5 en los nodos restantes | 54 en los nodos restantes |

La recuperación se mide desde que el NameNode informa dos DataNodes activos hasta que `fsck` muestra cero bloques subreplicados **y ya no ubica bloques en el nodo caído**. Los bloques afectados conservaron una copia legible mientras HDFS creó la segunda en `datanode1` o `datanode3`. La recuperación de 10 GB tomó más tiempo porque había más bloques y datos que copiar. Estos tiempos son mediciones de esta máquina, no garantías de rendimiento.

La primera captura automática de `durante-fsck.txt` se hizo justo después de detectar la caída y aún marcaba cero bloques subreplicados; HDFS actualizó ese contador instantes después. El estado transitorio de 1 GB quedó en `durante-subrep-fsck.txt` y el de 10 GB en la captura `03-10gb-falla.png`.

El NameNode guarda metadatos y decide las ubicaciones y nuevas réplicas; los DataNodes almacenan los bloques. El número de bloques es el tamaño del archivo dividido entre 128 MiB, redondeado hacia arriba. Replicación 2 significa dos copias **de cada bloque**, distribuidas entre nodos, no dos copias completas del archivo en dos nodos fijos. Si el factor fuera 1, los bloques del nodo caído podrían dejar de estar disponibles; con dos DataNodes caídos también podrían faltar bloques. Un archivo puede seguir legible con una sola copia mientras HDFS aún no cumple el factor configurado. Este entorno tiene un solo NameNode, por lo que **no prueba alta disponibilidad del NameNode**. El [diagrama editable](diagrama/arquitectura-hdfs.drawio) muestra la topología.

Las capturas de `evidencias/` se tomaron en el workspace 2 con una terminal flotante. Para 10 GB muestran el estado antes del fallo (`02`), la caída (`03`), la recuperación con el nodo aún detenido (`04`) y el resultado (`05`). Para 1 GB muestran el resultado (`06`), los registros antes (`07`) y después (`08`) y los cinco bloques subreplicados durante el fallo (`09`).

## Comandos para mostrar en clase

```bash
docker compose ps
docker compose exec -T namenode hdfs dfsadmin -report
docker compose exec -T namenode hdfs dfs -ls -h /lg15/dataset_1GB
docker compose exec -T namenode hdfs fsck /lg15/dataset_1GB/dataset_1GB.bin -files -blocks -locations
docker compose exec -T namenode hdfs dfs -ls -h /lg15/dataset_10GB
docker compose exec -T namenode hdfs fsck /lg15/dataset_10GB/dataset_10GB.bin -files -blocks -locations
```

Para repetir manualmente la caída, detén solo un DataNode con `docker compose stop datanode2`, comprueba la lectura del archivo y restáuralo con `docker compose start datanode2`. Durante el fallo, el archivo debe seguir disponible gracias a la otra réplica. El número de réplicas puede quedar temporalmente por debajo de 2 y luego recuperarse en los nodos activos.

Para detener el entorno sin borrar los datos:

```bash
docker compose down
```

No uses `docker compose down -v` si quieres conservar los archivos almacenados en HDFS.
