/* ════════════════════════════════════════════════════════════════════════════
   ARCHIVO 06 · CAPA 4 — VALIDACIÓN Y EDA TEMPORAL
   ────────────────────────────────────────────────────────────────────────────
   DOCSTRING (es-PE)
     Analiza columnas DATE/TIMESTAMP y columnas texto que en su mayoría son
     fechas (convertidas con dq_fecha_texto según dq_orden_fecha_texto):
       • rango, fechas futuras, demasiado antiguas y centinelas (1900-01-01,
         1899-12-30 de Excel, 1970-01-01 epoch, 9999-12-31...);
       • horas "redondas": timestamps que siempre son 00:00:00 (eran fechas)
         o 05:00:00 (medianoche de Lima guardada en UTC: desfase de zona);
       • frescura (días desde el último dato) vs SLA;
       • volumen mensual y diario con detección robusta de anomalías,
         ajustada por día de semana; huecos en el calendario;
       • patrón hora × día de semana.
     Cubre las dimensiones "oportunidad/actualidad" (timeliness/currency) de
     ISO 25012 y los pilares "frescura" y "volumen" de la observabilidad.
     Requisitos: archivos 00 y 02.
   TOOLTIP ▸ Cómo usar
     • L4.01 primero; L4.02-L4.05 para la(s) columna(s) de evento principal.
     • Personalización futura: definan cuál es la columna de evento de cada
       tabla, su SLA de frescura y su calendario esperado (¿hay data sábados,
       domingos, feriados?) y llévenlo a reglas en la capa 8.
   ════════════════════════════════════════════════════════════════════════════ */


/* ────────────────────────────────────────────────────────────────────────────
   [L4.00] Vistas dq_tiempo (valores temporales) y dq_l4_cols (candidatas)
   DOCSTRING (es-PE)
     dq_tiempo: una fila por celda de columnas FECHA, TIMESTAMP o TEXTO con
       ts = valor convertido a TIMESTAMP, solo_fecha = true si el dato no
       trae hora y es_centinela = true para fechas "mágicas" (1900-01-01,
       1899-12-30, 1970-01-01, 9999-12-31...; editen la lista si usan otras). Se genera con EXECUTE IMMEDIATE para "congelar" el valor
       de dq_orden_fecha_texto (DMY/MDY) dentro de la vista.
     dq_l4_cols: por columna, cuántos valores se pudieron convertir y su %.
   TOOLTIP ▸ Cómo interpretar
     • No devuelven filas. Si cambian dq_orden_fecha_texto, vuelvan a
       correr L4.00.
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_sql = concat(
  'CREATE OR REPLACE TEMP VIEW dq_tiempo AS ',
  'SELECT b.*, coalesce(to_date(b.ts) IN (',
     array_join(transform(array('1900-01-01', '1899-12-30', '1899-12-31', '1901-01-01', '1970-01-01',
                                '1753-01-01', '0001-01-01', '2000-01-01', '9999-12-31', '9999-01-01',
                                '2999-12-31', '3000-01-01', '2099-12-31', '2100-01-01'),
                          x -> concat('DATE', chr(39), x, chr(39))), ', '),
  '), false) AS es_centinela ',
  'FROM (',
  'SELECT l.columna, c.familia, l.valor, l._dq_segmento, l._dq_objetivo, ',
  '  CASE WHEN c.familia = ', dq_lit('FECHA'), ' THEN CAST(try_cast(l.valor AS DATE) AS TIMESTAMP) ',
  '       WHEN c.familia = ', dq_lit('TIMESTAMP'), ' THEN try_cast(l.valor AS TIMESTAMP) ',
  '       WHEN c.familia = ', dq_lit('TEXTO'), ' THEN coalesce(',
  '            IF(dq_limpiar(l.valor) RLIKE ', dq_lit('^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{1,2}:[0-9]{2}'), ', ',
  '               try_cast(dq_limpiar(l.valor) AS TIMESTAMP), NULL), ',
  '            CAST(dq_fecha_texto(l.valor, ', dq_lit(dq_orden_fecha_texto), ') AS TIMESTAMP)) ',
  '  END AS ts, ',
  '  (c.familia = ', dq_lit('FECHA'), ' OR (c.familia = ', dq_lit('TEXTO'), ' AND NOT coalesce(dq_limpiar(l.valor) RLIKE ',
       dq_lit('[T ][0-9]{1,2}:[0-9]{2}'), ', false))) AS solo_fecha ',
  'FROM dq_long l JOIN dq_columnas c ON c.columna = l.columna ',
  'WHERE c.familia IN (', dq_lit('FECHA'), ', ', dq_lit('TIMESTAMP'), ', ', dq_lit('TEXTO'), ')) b');
EXECUTE IMMEDIATE dq_sql;

CREATE OR REPLACE TEMP VIEW dq_l4_cols AS
SELECT columna, familia,
       count_if(valor IS NOT NULL AND dq_limpiar(valor) <> '' AND NOT dq_es_placeholder(valor)) AS n_no_vacios,
       count(ts)                                                                               AS n_fechas,
       count(ts) / NULLIF(count_if(valor IS NOT NULL AND dq_limpiar(valor) <> ''
                                   AND NOT dq_es_placeholder(valor)), 0)                       AS pct_fecha
FROM dq_tiempo
GROUP BY columna, familia;


/* ────────────────────────────────────────────────────────────────────────────
   [L4.01] Perfil temporal por columna (rango, futuro, centinelas, horas, frescura)
   DOCSTRING (es-PE)
     Por columna temporal: n válidos, no convertibles (texto), mínimo,
     máximo, rango en días, días distintos, fechas futuras (más allá de
     hoy + dq_tolerancia_futuro_dias), anteriores a dq_fecha_min_valida,
     centinelas, % fin de semana, % a medianoche exacta, % a las 05:00:00
     exactas, días desde el máximo y alertas.
   TOOLTIP ▸ Cómo leer e interpretar
     • FECHAS_FUTURAS: en fechas de evento/registro es error (reloj del
       servidor, dd/MM vs MM/dd, año mal digitado 2204). En vencimientos o
       programaciones es normal: interprétenlo según la columna.
     • CENTINELAS: 1900-01-01 / 1899-12-30 (cero de Excel) / 1970-01-01 /
       9999-12-31 = "sin fecha" disfrazado. Distorsionan antigüedades y edades.
     • SOLO_MEDIANOCHE (≥ 95% a las 00:00:00 en un TIMESTAMP): en realidad es
       una fecha; no hagan análisis por hora.
     • DESFASE_ZONA_HORARIA (≥ 20% exactamente a las 05:00:00): fechas de Lima
       (UTC-5) convertidas a UTC; al truncar a fecha en UTC se cae al día
       correcto, pero si alguien convierte de nuevo se corre un día.
       Usen from_utc_timestamp(ts, 'America/Lima') de forma consistente.
     • dias_desde_maximo > dq_sla_frescura_dias en la columna de EVENTO ⇒
       la tabla no se está actualizando (incidente de frescura).
   ──────────────────────────────────────────────────────────────────────────── */
WITH sel AS (
  SELECT * FROM dq_l4_cols
  WHERE familia IN ('FECHA', 'TIMESTAMP')
     OR (familia = 'TEXTO' AND pct_fecha >= dq_umbral_tipo_dominante)
), t AS (
  SELECT d.*, to_date(d.ts) AS f
  FROM dq_tiempo d JOIN sel s ON s.columna = d.columna
)
SELECT c.ordinal, t.columna, max(t.familia)                                          AS familia,
       count(t.ts)                                                                   AS n_validos,
       max(s.n_no_vacios) - count(t.ts)                                              AS n_no_convertibles,
       min(t.ts)                                                                     AS minimo,
       max(t.ts)                                                                     AS maximo,
       datediff(max(t.f), min(t.f))                                                  AS rango_dias,
       count(DISTINCT t.f)                                                           AS n_dias_distintos,
       count_if(t.ts > current_timestamp() + make_interval(0, 0, 0, dq_tolerancia_futuro_dias)) AS n_futuras,
       count_if(t.f < dq_fecha_min_valida)                                           AS n_muy_antiguas,
       count_if(t.es_centinela)                                                      AS n_centinelas,
       sort_array(collect_set(IF(t.es_centinela, CAST(t.f AS STRING), NULL)))        AS centinelas_vistos,
       round(count_if(dayofweek(t.f) IN (1, 7)) / NULLIF(count(t.ts), 0), 4)        AS pct_fin_de_semana,
       round(count_if(NOT t.solo_fecha AND hour(t.ts) = 0 AND minute(t.ts) = 0 AND second(t.ts) = 0)
             / NULLIF(count_if(NOT t.solo_fecha AND t.ts IS NOT NULL), 0), 4)        AS pct_medianoche,
       round(count_if(NOT t.solo_fecha AND hour(t.ts) = 5 AND minute(t.ts) = 0 AND second(t.ts) = 0)
             / NULLIF(count_if(NOT t.solo_fecha AND t.ts IS NOT NULL), 0), 4)        AS pct_05h_exactas,
       datediff(current_date(), max(IF(t.es_centinela OR t.f > current_date(), NULL, t.f))) AS dias_desde_maximo,
       filter(array(
         IF(count_if(t.ts > current_timestamp() + make_interval(0, 0, 0, dq_tolerancia_futuro_dias)) > 0, 'FECHAS_FUTURAS', NULL),
         IF(count_if(t.f < dq_fecha_min_valida AND NOT t.es_centinela) > 0, 'FECHAS_MUY_ANTIGUAS', NULL),
         IF(count_if(t.es_centinela) > 0, 'CENTINELAS', NULL),
         IF(max(s.n_no_vacios) - count(t.ts) > 0, 'VALORES_NO_CONVERTIBLES', NULL),
         IF(count_if(NOT t.solo_fecha AND hour(t.ts) = 0 AND minute(t.ts) = 0 AND second(t.ts) = 0)
            / NULLIF(count_if(NOT t.solo_fecha AND t.ts IS NOT NULL), 0) >= 0.95, 'SOLO_MEDIANOCHE', NULL),
         IF(count_if(NOT t.solo_fecha AND hour(t.ts) = 5 AND minute(t.ts) = 0 AND second(t.ts) = 0)
            / NULLIF(count_if(NOT t.solo_fecha AND t.ts IS NOT NULL), 0) >= 0.20, 'DESFASE_ZONA_HORARIA', NULL),
         IF(datediff(current_date(), max(IF(t.es_centinela OR t.f > current_date(), NULL, t.f))) > dq_sla_frescura_dias,
            'SIN_DATOS_RECIENTES (si es columna de evento)', NULL)
       ), x -> x IS NOT NULL)                                                        AS alertas
FROM t
JOIN sel s         ON s.columna = t.columna
JOIN dq_columnas c ON c.columna = t.columna
GROUP BY c.ordinal, t.columna
ORDER BY size(alertas) DESC, c.ordinal;


/* ────────────────────────────────────────────────────────────────────────────
   [L4.02] Volumen mensual por columna temporal con anomalías robustas
   DOCSTRING (es-PE)
     Cuenta registros por mes (incluye los meses SIN registros dentro del
     rango, hasta 600 meses), calcula variación vs mes anterior y un
     z-score robusto del conteo (mediana y MAD de los meses de la columna).
     Excluye centinelas y fechas futuras.
   TOOLTIP ▸ Cómo leer e interpretar
     • MES_VACIO dentro del rango ⇒ hueco de carga (o negocio estacional).
     • |z_robusto| > dq_umbral_z_robusto ⇒ mes anómalo (pico por re-carga
       duplicada, caída por carga incompleta).
     • El primer y último mes suelen ser parciales: no los lean como caída.
     • En Databricks grafíquenlo como líneas: X = mes, Y = n, serie = columna.
   ──────────────────────────────────────────────────────────────────────────── */
WITH sel AS (
  SELECT * FROM dq_l4_cols
  WHERE familia IN ('FECHA', 'TIMESTAMP')
     OR (familia = 'TEXTO' AND pct_fecha >= dq_umbral_tipo_dominante)
), m AS (
  SELECT d.columna, CAST(date_trunc('MONTH', d.ts) AS DATE) AS mes, count(*) AS n
  FROM dq_tiempo d JOIN sel s ON s.columna = d.columna
  WHERE d.ts IS NOT NULL AND to_date(d.ts) BETWEEN dq_fecha_min_valida AND current_date()
    AND NOT d.es_centinela
  GROUP BY d.columna, CAST(date_trunc('MONTH', d.ts) AS DATE)
), r AS (
  SELECT columna, min(mes) AS mes_ini, max(mes) AS mes_fin FROM m GROUP BY columna
  HAVING months_between(max(mes), min(mes)) <= 600
), cal AS (
  SELECT r.columna, explode(sequence(r.mes_ini, r.mes_fin, INTERVAL 1 MONTH)) AS mes FROM r
), serie AS (
  SELECT cal.columna, cal.mes, coalesce(m.n, 0) AS n
  FROM cal LEFT JOIN m ON m.columna = cal.columna AND m.mes = cal.mes
), est AS (
  SELECT columna, percentile_approx(n, 0.5, 10000) AS mediana FROM serie GROUP BY columna
), mad AS (
  SELECT s.columna, percentile_approx(abs(s.n - e.mediana), 0.5, 10000) AS mad
  FROM serie s JOIN est e ON e.columna = s.columna GROUP BY s.columna
)
SELECT s.columna, s.mes, s.n,
       lag(s.n) OVER (PARTITION BY s.columna ORDER BY s.mes)                               AS n_mes_anterior,
       round(s.n / NULLIF(lag(s.n) OVER (PARTITION BY s.columna ORDER BY s.mes), 0) - 1, 4) AS var_vs_mes_anterior,
       round(CAST(0.6745 * (s.n - e.mediana) / NULLIF(md.mad, 0) AS DOUBLE), 2)            AS z_robusto,
       CASE WHEN s.mes IN (r.mes_ini, r.mes_fin) THEN 'MES_PARCIAL (borde del rango)'
            WHEN s.n = 0 THEN 'MES_VACIO'
            WHEN abs(0.6745 * (s.n - e.mediana) / NULLIF(md.mad, 0)) > dq_umbral_z_robusto THEN 'MES_ANOMALO'
       END                                                                                  AS marca
FROM serie s
JOIN r      ON r.columna = s.columna
JOIN est e  ON e.columna = s.columna
JOIN mad md ON md.columna = s.columna
ORDER BY s.columna, s.mes;


/* ────────────────────────────────────────────────────────────────────────────
   [L4.03] Huecos en el calendario diario (días sin registros)
   DOCSTRING (es-PE)
     Por columna temporal con rango ≤ dq_max_dias_calendario: días del rango,
     días con datos, días faltantes, el hueco más largo (días consecutivos
     sin datos) con su inicio y fin, y cuántos huecos de ≥ 3 días hay.
   TOOLTIP ▸ Cómo leer e interpretar
     • Procesos diarios (ventas, transacciones) no deberían tener huecos
       salvo feriados: un hueco de varios días seguidos = carga perdida.
     • Huecos regulares de 2 días ⇒ fines de semana (proceso de días hábiles).
     • En fechas de nacimiento o de alta, los huecos son normales: esta
       consulta aplica a columnas de EVENTO.
   ──────────────────────────────────────────────────────────────────────────── */
WITH sel AS (
  SELECT * FROM dq_l4_cols
  WHERE familia IN ('FECHA', 'TIMESTAMP')
     OR (familia = 'TEXTO' AND pct_fecha >= dq_umbral_tipo_dominante)
), d AS (
  SELECT DISTINCT t.columna, to_date(t.ts) AS dia
  FROM dq_tiempo t JOIN sel s ON s.columna = t.columna
  WHERE t.ts IS NOT NULL AND to_date(t.ts) BETWEEN dq_fecha_min_valida AND current_date()
    AND NOT t.es_centinela
), g AS (
  SELECT columna, dia,
         lead(dia) OVER (PARTITION BY columna ORDER BY dia) AS siguiente,
         datediff(lead(dia) OVER (PARTITION BY columna ORDER BY dia), dia) - 1 AS hueco
  FROM d
)
SELECT columna,
       min(dia)                                          AS primer_dia,
       max(dia)                                          AS ultimo_dia,
       datediff(max(dia), min(dia)) + 1                  AS dias_en_rango,
       count(*)                                          AS dias_con_datos,
       datediff(max(dia), min(dia)) + 1 - count(*)       AS dias_faltantes,
       round(1 - count(*) / (datediff(max(dia), min(dia)) + 1), 4) AS pct_dias_faltantes,
       max(hueco)                                        AS hueco_mas_largo_dias,
       date_add(max_by(dia, hueco), 1)                   AS inicio_hueco_mas_largo,
       date_add(max_by(siguiente, hueco), -1)            AS fin_hueco_mas_largo,
       count_if(hueco >= 3)                              AS n_huecos_3_o_mas_dias
FROM g
GROUP BY columna
HAVING datediff(max(dia), min(dia)) + 1 <= dq_max_dias_calendario
ORDER BY hueco_mas_largo_dias DESC;


/* ────────────────────────────────────────────────────────────────────────────
   [L4.04] Volumen diario con anomalías ajustadas por día de semana
   DOCSTRING (es-PE)
     Para cada columna temporal, conteo por día y z-score robusto
     calculado CONTRA LOS MISMOS días de semana (los lunes contra lunes...),
     para no confundir la estacionalidad semanal con anomalías. Devuelve sólo
     los días marcados como anómalos.
   TOOLTIP ▸ Cómo leer e interpretar
     • z_robusto muy negativo ⇒ carga incompleta / caída de un sistema fuente.
     • z_robusto muy positivo ⇒ duplicación de carga, campaña o cierre de mes.
     • Crucen las fechas con DESCRIBE HISTORY (L0.08) y con el calendario de
       feriados del Perú (28-29 jul, 25 dic, 1 ene, Semana Santa...).
     • Sólo se evalúan días de semana con mediana ≥ 10 registros: con
       conteos chicos el ruido de Poisson genera falsas alarmas.
   ──────────────────────────────────────────────────────────────────────────── */
WITH sel AS (
  SELECT * FROM dq_l4_cols
  WHERE familia IN ('FECHA', 'TIMESTAMP')
     OR (familia = 'TEXTO' AND pct_fecha >= dq_umbral_tipo_dominante)
), dia AS (
  SELECT t.columna, to_date(t.ts) AS dia, dayofweek(to_date(t.ts)) AS dow, count(*) AS n
  FROM dq_tiempo t JOIN sel s ON s.columna = t.columna
  WHERE t.ts IS NOT NULL AND to_date(t.ts) BETWEEN dq_fecha_min_valida AND current_date()
    AND NOT t.es_centinela
  GROUP BY t.columna, to_date(t.ts), dayofweek(to_date(t.ts))
), est AS (
  SELECT columna, dow, percentile_approx(n, 0.5, 10000) AS mediana, count(*) AS n_dias
  FROM dia GROUP BY columna, dow
), mad AS (
  SELECT d.columna, d.dow, percentile_approx(abs(d.n - e.mediana), 0.5, 10000) AS mad
  FROM dia d JOIN est e ON e.columna = d.columna AND e.dow = d.dow
  GROUP BY d.columna, d.dow
), z AS (
  SELECT d.columna, d.dia,
         CASE d.dow WHEN 1 THEN 'domingo' WHEN 2 THEN 'lunes' WHEN 3 THEN 'martes' WHEN 4 THEN 'miércoles'
                    WHEN 5 THEN 'jueves' WHEN 6 THEN 'viernes' ELSE 'sábado' END AS dia_semana,
         d.n, e.mediana AS mediana_mismo_dia_semana, e.n_dias,
         CAST(0.6745 * (d.n - e.mediana) / NULLIF(m.mad, 0) AS DOUBLE) AS z_robusto
  FROM dia d
  JOIN est e ON e.columna = d.columna AND e.dow = d.dow
  JOIN mad m ON m.columna = d.columna AND m.dow = d.dow
)
SELECT columna, dia, dia_semana, n, mediana_mismo_dia_semana, round(z_robusto, 2) AS z_robusto,
       IF(z_robusto < 0, 'CAIDA', 'PICO') AS tipo_anomalia
FROM z
WHERE abs(z_robusto) > dq_umbral_z_robusto AND n_dias >= 8 AND mediana_mismo_dia_semana >= 10
ORDER BY columna, abs(z_robusto) DESC
LIMIT 500;


/* ────────────────────────────────────────────────────────────────────────────
   [L4.05] Patrón hora × día de semana (columnas TIMESTAMP)
   DOCSTRING (es-PE)
     Matriz de conteos por día de semana y hora (0-23) para columnas con
     hora real (no sólo fecha). Útil como mapa de calor.
   TOOLTIP ▸ Cómo leer e interpretar
     • Visualícenlo como Heatmap: X = hora, Y = dia_semana, color = n.
     • Actividad "humana" de madrugada (02-05 h) en un canal presencial ⇒
       desfase de zona horaria o procesos batch registrando su propia hora.
     • Una sola hora con casi todo el volumen ⇒ la hora es del batch de
       carga, no del evento de negocio.
   ──────────────────────────────────────────────────────────────────────────── */
SELECT t.columna,
       dayofweek(t.ts)                                                                   AS num_dia,
       CASE dayofweek(t.ts) WHEN 1 THEN '7-domingo' WHEN 2 THEN '1-lunes' WHEN 3 THEN '2-martes'
                            WHEN 4 THEN '3-miércoles' WHEN 5 THEN '4-jueves' WHEN 6 THEN '5-viernes'
                            ELSE '6-sábado' END                                          AS dia_semana,
       hour(t.ts)                                                                        AS hora,
       count(*)                                                                          AS n
FROM dq_tiempo t
JOIN dq_l4_cols s ON s.columna = t.columna
WHERE t.ts IS NOT NULL AND NOT t.solo_fecha
  AND (s.familia = 'TIMESTAMP' OR (s.familia = 'TEXTO' AND s.pct_fecha >= dq_umbral_tipo_dominante))
GROUP BY t.columna, dayofweek(t.ts), hour(t.ts)
ORDER BY t.columna, dia_semana, hora;


/* ────────────────────────────────────────────────────────────────────────────
   [L4.06] Persistir métricas temporales (opcional)
   DOCSTRING (es-PE)
     Guarda por columna temporal: días desde el máximo (frescura), n de
     fechas futuras y n de centinelas, para monitorear frescura en el tiempo.
   TOOLTIP ▸ Cómo interpretar
     • Grafiquen dias_desde_maximo por corrida: debe mantenerse ≤ SLA.
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_sql = IF(
  dq_esquema_trabajo = '',
  concat('SELECT ', dq_lit('persistencia desactivada (dq_esquema_trabajo vacío)'), ' AS info'),
  concat('INSERT INTO ', dq_esquema_trabajo, '.dq_metricas ',
         'SELECT ', dq_lit(dq_id_corrida), ', current_timestamp(), ', dq_lit(dq_tabla_fq), ', columna, ',
         dq_lit('L4'), ', metrica, valor, NULL FROM (',
         'SELECT columna, CAST(datediff(current_date(), max(IF(to_date(ts) > current_date(), NULL, to_date(ts)))) AS DOUBLE) AS dias_desde_maximo, ',
         'CAST(count_if(ts > current_timestamp()) AS DOUBLE) AS n_futuras ',
         'FROM dq_tiempo WHERE familia IN (', dq_lit('FECHA'), ', ', dq_lit('TIMESTAMP'), ') GROUP BY columna) ',
         'LATERAL VIEW stack(2, ', dq_lit('dias_desde_maximo'), ', dias_desde_maximo, ',
         dq_lit('n_futuras'), ', n_futuras) s AS metrica, valor'));
EXECUTE IMMEDIATE dq_sql;
