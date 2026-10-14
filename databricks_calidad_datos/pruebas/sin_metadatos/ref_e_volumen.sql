/* ════════════════════════════════════════════════════════════════════════════
   REFERENCIA E · CAPA V: VOLUMEN POR PERIODO, FECHA DE CARGA Y ARCHIVO
   ────────────────────────────────────────────────────────────────────────────
   DOCSTRING (es-PE)
     Analiza CUÁNTAS filas llegan por día, por mes y por archivo/lote, para
     detectar cargas fallidas, parciales, duplicadas o tardías. Distingue
     tres "relojes":
       CARGA   : cuándo se cargó la fila (fecactualizacion, fecha_carga,
                 fec_proceso, timestamp de ingesta…).
       NEGOCIO : cuándo ocurrió el hecho (fecha de operación).
       LOTE    : el archivo o lote de origen (y la fecha en su nombre).
     A diferencia de L4.02-L4.04 (que trabajan sobre la MUESTRA dq_long),
     esta capa lee la tabla COMPLETA (dq_objetivo): un día con pocas filas
     no desaparece por muestreo. Cada consulta re-lee la tabla; si es muy
     grande y no necesitan esta capa, pongan dq_lv_activo = false.
     Requiere: P2.01v2-P2.03v2 (dq_objetivo, dq_columnas) y dq_mapa.
   TOOLTIP ▸ Cómo leer la capa (orden sugerido)
     • LV.00 qué columnas eligió (o por qué no hay) → LV.01 resumen y
       frescura → LV.02 días anómalos → LV.03 huecos → LV.04 meses →
       LV.05/LV.06 latencia y recargas → LV.07 archivos → LV.08 columnas que
       se vacían en una carga.
     • Ningún hallazgo de volumen es por sí solo un error de datos: cada
       fila trae la columna hipotesis con las causas en orden de
       probabilidad y la consulta que permite distinguirlas.
   ════════════════════════════════════════════════════════════════════════════ */


/* ────────────────────────────────────────────────────────────────────────────
   [LV.00] Columnas de tiempo y lote: candidatas, estadísticas y selección
   DOCSTRING (es-PE)
     Busca columnas candidatas en dq_objetivo: tipo DATE/TIMESTAMP, campo
     FECHA del diccionario, o nombre que sugiere fecha, carga o archivo
     (dq_lv_regex_carga, dq_lv_regex_lote). Asigna un rol (CARGA, NEGOCIO,
     LOTE), mide en UNA lectura de la tabla cuántos valores se convierten a
     fecha válida (1950 a hoy + 1 año) y elige una columna por rol:
       • si el equipo fijó dq_lv_col_* y la columna existe, se usa ésa;
       • si no, la de ≥ 90% de fechas válidas con más días distintos
         (CARGA prefiere TIMESTAMP; NEGOCIO prefiere campos del diccionario).
     En la columna LOTE la fecha se extrae del nombre (AAAAMMDD en el texto).
     Crea dq_lv_base (dq_objetivo + _dq_lv_f_carga, _dq_lv_f_negocio,
     _dq_lv_lote, _dq_lv_f_lote, _dq_lv_hash, _dq_lv_f_serie) y las vistas
     dq_lv_eventos, dq_lv_diario y dq_lv_serie que usa el resto de la capa.
   TOOLTIP ▸ Cómo leer e interpretar (hipótesis alternativas)
     • seleccion = ELEGIDA_<rol> indica la columna usada. Si eligió mal (p.ej.
       tomó fec_proceso como CARGA cuando es fecha de negocio), fijen
       dq_lv_col_carga / dq_lv_col_negocio / dq_lv_col_lote y vuelvan a
       correr desde LV.00.
     • pct_fecha_valida bajo en una candidata: 1) no es una fecha (código,
       periodo AAAAMM), 2) formato distinto al esperado (revisen el formato
       en el diccionario o dq_orden_fecha_texto), 3) centinelas o basura.
     • Sin ninguna candidata CARGA ni LOTE: la tabla no trae trazabilidad de
       carga; la capa se limita a la fecha de negocio. Pidan a ingeniería de
       datos la columna de auditoría (fecha de carga o nombre de archivo).
   ──────────────────────────────────────────────────────────────────────────── */
DECLARE OR REPLACE VARIABLE dq_lv_cands ARRAY<STRUCT<columna STRING, q STRING, lit STRING, familia STRING, rol STRING,
  en_diccionario BOOLEAN, expr STRING, expr_ts STRING>>
  DEFAULT CAST(array() AS ARRAY<STRUCT<columna STRING, q STRING, lit STRING, familia STRING, rol STRING,
  en_diccionario BOOLEAN, expr STRING, expr_ts STRING>>);
DECLARE OR REPLACE VARIABLE dq_lv_stats ARRAY<STRUCT<columna STRING, n_no_nulos BIGINT, n_fecha BIGINT,
  n_fecha_valida BIGINT, f_min DATE, f_max DATE, n_dias BIGINT, n_distintos BIGINT>>
  DEFAULT CAST(array() AS ARRAY<STRUCT<columna STRING, n_no_nulos BIGINT, n_fecha BIGINT,
  n_fecha_valida BIGINT, f_min DATE, f_max DATE, n_dias BIGINT, n_distintos BIGINT>>);
DECLARE OR REPLACE VARIABLE dq_lv_rol_serie STRING DEFAULT '';
DECLARE OR REPLACE VARIABLE dq_lv_manual_invalidas STRING DEFAULT '';
DECLARE OR REPLACE VARIABLE dq_lv_rango_dias INT DEFAULT 0;

SET VAR dq_lv_cands = (
  SELECT collect_list(named_struct('columna', columna, 'q', q, 'lit', lit, 'familia', familia, 'rol', rol,
                                   'en_diccionario', en_diccionario, 'expr', expr, 'expr_ts', expr_ts))
  FROM (
    SELECT columna, q, lit, familia, rol, en_diccionario,
           CASE WHEN rol = 'LOTE' AND familia NOT IN ('FECHA', 'TIMESTAMP')
                  THEN concat('dq_fecha_formato(regexp_extract(CAST(', q, ' AS STRING), ',
                              dq_lit('(20[0-9]{2}[01][0-9][0-3][0-9])'), ', 1), ', dq_lit('AAAAMMDD'), ')')
                WHEN familia IN ('FECHA', 'TIMESTAMP') THEN concat('CAST(', q, ' AS DATE)')
                WHEN coalesce(formato, '') <> ''
                  THEN concat('dq_fecha_formato(CAST(', q, ' AS STRING), ', dq_lit(formato), ')')
                ELSE concat('coalesce(dq_fecha_formato(CAST(', q, ' AS STRING), ', dq_lit('AAAAMMDD'), '), ',
                            'dq_fecha_texto(CAST(', q, ' AS STRING), ', dq_lit(dq_orden_fecha_texto), '))') END AS expr,
           IF(familia = 'TIMESTAMP', concat('CAST(', q, ' AS TIMESTAMP)'), 'CAST(NULL AS TIMESTAMP)') AS expr_ts
    FROM (
      SELECT c.columna, dq_id(c.columna) AS q, dq_lit(c.columna) AS lit, c.familia, c.ordinal,
             m.campo IS NOT NULL AS en_diccionario, m.formato,
             CASE WHEN c.columna = dq_lv_col_lote THEN 'LOTE'
                  WHEN c.columna = dq_lv_col_carga THEN 'CARGA'
                  WHEN c.columna = dq_lv_col_negocio THEN 'NEGOCIO'
                  WHEN c.familia = 'TEXTO' AND c.columna RLIKE dq_lv_regex_lote
                       AND NOT c.columna RLIKE '(?i)(fec|fch|fecha|date)' THEN 'LOTE'
                  WHEN c.columna RLIKE dq_lv_regex_carga THEN 'CARGA'
                  ELSE 'NEGOCIO' END AS rol
      FROM dq_columnas c
      LEFT JOIN (SELECT columna, max(campo) AS campo, max(formato) AS formato, max(familia_declarada) AS familia_declarada
                 FROM dq_mapa WHERE estado = 'MAPEADO' GROUP BY columna) m ON m.columna = c.columna
      WHERE c.columna IS NOT NULL
        AND coalesce(c.familia, 'OTRO') NOT IN ('BOOLEANO', 'BINARIO', 'COMPLEJO', 'INTERVALO')
        AND (c.familia IN ('FECHA', 'TIMESTAMP') OR m.familia_declarada = 'FECHA'
             OR c.columna RLIKE dq_lv_regex_carga OR c.columna RLIKE dq_lv_regex_lote
             OR c.columna RLIKE '(?i)(fec|fch|fecha|date|_dt$|^dt_|periodo)'
             OR c.columna IN (dq_lv_col_carga, dq_lv_col_negocio, dq_lv_col_lote))
      ORDER BY CASE WHEN c.columna IN (dq_lv_col_carga, dq_lv_col_negocio, dq_lv_col_lote) THEN 0 ELSE 1 END, c.ordinal
      LIMIT 40) a));

SET VAR dq_lv_manual_invalidas = concat_ws(', ',
  IF(dq_lv_col_carga <> '' AND NOT exists(dq_lv_cands, x -> x.columna = dq_lv_col_carga), dq_lv_col_carga, NULL),
  IF(dq_lv_col_negocio <> '' AND NOT exists(dq_lv_cands, x -> x.columna = dq_lv_col_negocio), dq_lv_col_negocio, NULL),
  IF(dq_lv_col_lote <> '' AND NOT exists(dq_lv_cands, x -> x.columna = dq_lv_col_lote), dq_lv_col_lote, NULL));

SET VAR dq_sql = IF(size(dq_lv_cands) = 0 OR NOT dq_lv_activo,
  'SELECT CAST(array() AS ARRAY<STRUCT<columna STRING, n_no_nulos BIGINT, n_fecha BIGINT, n_fecha_valida BIGINT, f_min DATE, f_max DATE, n_dias BIGINT, n_distintos BIGINT>>)',
  concat(
    'SELECT collect_list(named_struct(\'columna\', columna, \'n_no_nulos\', n_no_nulos, \'n_fecha\', n_fecha, ',
    '\'n_fecha_valida\', n_fecha_valida, \'f_min\', f_min, \'f_max\', f_max, \'n_dias\', n_dias, \'n_distintos\', n_distintos)) ',
    'FROM (SELECT stack(', CAST(size(dq_lv_cands) AS STRING), ', ',
    array_join(transform(dq_lv_cands, (x, i) -> concat(x.lit,
      ', n', CAST(i AS STRING), ', f', CAST(i AS STRING), ', v', CAST(i AS STRING), ', mn', CAST(i AS STRING),
      ', mx', CAST(i AS STRING), ', d', CAST(i AS STRING), ', r', CAST(i AS STRING))), ', '),
    ') AS (columna, n_no_nulos, n_fecha, n_fecha_valida, f_min, f_max, n_dias, n_distintos) FROM (SELECT ',
    array_join(transform(dq_lv_cands, (x, i) -> concat(
      'count(_c', CAST(i AS STRING), ') AS n', CAST(i AS STRING),
      ', count(_e', CAST(i AS STRING), ') AS f', CAST(i AS STRING),
      ', count_if(_e', CAST(i AS STRING), ' BETWEEN DATE\'1950-01-01\' AND date_add(current_date(), 366)) AS v', CAST(i AS STRING),
      ', min(_e', CAST(i AS STRING), ') AS mn', CAST(i AS STRING),
      ', max(_e', CAST(i AS STRING), ') AS mx', CAST(i AS STRING),
      ', approx_count_distinct(_e', CAST(i AS STRING), ') AS d', CAST(i AS STRING),
      ', approx_count_distinct(_c', CAST(i AS STRING), ') AS r', CAST(i AS STRING))), ', '),
    ' FROM (SELECT ',
    array_join(transform(dq_lv_cands, (x, i) -> concat(x.expr, ' AS _e', CAST(i AS STRING), ', ', x.q, ' AS _c', CAST(i AS STRING))), ', '),
    ' FROM dq_objetivo) a) b) c'));
EXECUTE IMMEDIATE dq_sql INTO dq_lv_stats;

-- Selección: manual si existe; si no, automática.
SET VAR dq_lv_col_carga = coalesce(
  IF(exists(dq_lv_cands, x -> x.columna = dq_lv_col_carga), dq_lv_col_carga, NULL),
  (SELECT max_by(c.columna, named_struct('ts', c.familia = 'TIMESTAMP', 'dias', s.n_dias, 'n', s.n_fecha_valida))
   FROM (SELECT inline(dq_lv_cands)) c JOIN (SELECT inline(dq_lv_stats)) s ON s.columna = c.columna
   WHERE c.rol = 'CARGA' AND s.n_no_nulos > 0 AND s.n_fecha_valida >= 0.9 * s.n_no_nulos),
  '');
SET VAR dq_lv_col_negocio = coalesce(
  IF(exists(dq_lv_cands, x -> x.columna = dq_lv_col_negocio), dq_lv_col_negocio, NULL),
  (SELECT max_by(c.columna, named_struct('dic', c.en_diccionario, 'dias', s.n_dias, 'n', s.n_fecha_valida))
   FROM (SELECT inline(dq_lv_cands)) c JOIN (SELECT inline(dq_lv_stats)) s ON s.columna = c.columna
   WHERE c.rol = 'NEGOCIO' AND c.columna <> dq_lv_col_carga
     AND s.n_no_nulos > 0 AND s.n_fecha_valida >= 0.9 * s.n_no_nulos AND s.n_dias >= 2),
  '');
SET VAR dq_lv_col_lote = coalesce(
  IF(exists(dq_lv_cands, x -> x.columna = dq_lv_col_lote), dq_lv_col_lote, NULL),
  (SELECT max_by(c.columna, named_struct('n', s.n_no_nulos, 'd', s.n_distintos))
   FROM (SELECT inline(dq_lv_cands)) c JOIN (SELECT inline(dq_lv_stats)) s ON s.columna = c.columna
   WHERE c.rol = 'LOTE' AND c.columna NOT IN (dq_lv_col_carga, dq_lv_col_negocio)
     AND s.n_no_nulos > 0 AND s.n_distintos <= 100000),
  '');
SET VAR dq_lv_rol_serie = CASE WHEN dq_lv_col_carga <> '' THEN 'CARGA' WHEN dq_lv_col_negocio <> '' THEN 'NEGOCIO'
                               WHEN dq_lv_col_lote <> '' THEN 'LOTE' ELSE '' END;

SET VAR dq_sql = concat(
  'CREATE OR REPLACE TEMP VIEW dq_lv_base AS SELECT *, ',
  CASE dq_lv_rol_serie WHEN 'CARGA' THEN '_dq_lv_f_carga' WHEN 'NEGOCIO' THEN '_dq_lv_f_negocio'
                       WHEN 'LOTE' THEN '_dq_lv_f_lote' ELSE 'CAST(NULL AS DATE)' END, ' AS _dq_lv_f_serie ',
  'FROM (SELECT *, ',
  coalesce((SELECT max(expr) FROM (SELECT inline(dq_lv_cands)) WHERE columna = dq_lv_col_carga), 'CAST(NULL AS DATE)'), ' AS _dq_lv_f_carga, ',
  coalesce((SELECT max(expr_ts) FROM (SELECT inline(dq_lv_cands)) WHERE columna = dq_lv_col_carga), 'CAST(NULL AS TIMESTAMP)'), ' AS _dq_lv_ts_carga, ',
  coalesce((SELECT max(expr) FROM (SELECT inline(dq_lv_cands)) WHERE columna = dq_lv_col_negocio), 'CAST(NULL AS DATE)'), ' AS _dq_lv_f_negocio, ',
  coalesce((SELECT max(concat('CAST(', q, ' AS STRING)')) FROM (SELECT inline(dq_lv_cands)) WHERE columna = dq_lv_col_lote), 'CAST(NULL AS STRING)'), ' AS _dq_lv_lote, ',
  coalesce((SELECT max(expr) FROM (SELECT inline(dq_lv_cands)) WHERE columna = dq_lv_col_lote), 'CAST(NULL AS DATE)'), ' AS _dq_lv_f_lote, ',
  IF(dq_lv_col_lote = '', 'CAST(NULL AS BIGINT)',
     coalesce((SELECT concat('xxhash64(to_json(named_struct(',
                             array_join(transform(array_sort(collect_list(struct(ordinal, e))), x -> x.e), ', '), ')))')
               FROM (SELECT ordinal, concat(dq_lit(columna), ', ', dq_id(columna)) AS e FROM dq_columnas
                     WHERE columna IS NOT NULL AND columna NOT IN (dq_lv_col_carga, dq_lv_col_lote))
               HAVING count(*) > 0), 'CAST(NULL AS BIGINT)')), ' AS _dq_lv_hash ',
  'FROM dq_objetivo', IF(dq_lv_activo, '', ' WHERE false'), ') z');
EXECUTE IMMEDIATE dq_sql;

CREATE OR REPLACE TEMP VIEW dq_lv_eventos AS
SELECT rol, fecha
FROM (SELECT stack(3, 'CARGA', _dq_lv_f_carga, 'NEGOCIO', _dq_lv_f_negocio, 'LOTE', _dq_lv_f_lote) AS (rol, fecha)
      FROM dq_lv_base) e
WHERE fecha BETWEEN DATE'1950-01-01' AND date_add(current_date(), 366);

CREATE OR REPLACE TEMP VIEW dq_lv_diario AS
SELECT rol, fecha, count(*) AS n FROM dq_lv_eventos GROUP BY rol, fecha;

-- Serie diaria completa (días sin filas = 0) con línea base robusta: mediana
-- del MISMO día de semana en las 8 semanas previas (editen "8 PRECEDING").
CREATE OR REPLACE TEMP VIEW dq_lv_serie AS
WITH r AS (
  SELECT rol, min(fecha) AS mn, max(fecha) AS mx FROM dq_lv_diario GROUP BY rol
), cal AS (
  SELECT rol, mx, explode(sequence(greatest(mn, date_add(mx, -3660)), mx, INTERVAL 1 DAY)) AS fecha FROM r
), s AS (
  SELECT c.rol, c.fecha, c.mx, coalesce(d.n, 0) AS n
  FROM cal c LEFT JOIN dq_lv_diario d ON d.rol = c.rol AND d.fecha = c.fecha
)
SELECT rol, fecha, n, dayofweek(fecha) AS dow,
       CASE dayofweek(fecha) WHEN 1 THEN 'dom' WHEN 2 THEN 'lun' WHEN 3 THEN 'mar' WHEN 4 THEN 'mié'
                             WHEN 5 THEN 'jue' WHEN 6 THEN 'vie' ELSE 'sáb' END AS dia_semana,
       datediff(mx, fecha) AS dias_al_final,
       date_format(fecha, 'MM-dd') IN ('01-01', '05-01', '06-07', '06-29', '07-23', '07-28', '07-29',
                                       '08-06', '08-30', '10-08', '11-01', '12-08', '12-09', '12-25') AS feriado_fijo,
       date_format(date_add(fecha, -1), 'MM-dd') IN ('01-01', '05-01', '06-07', '06-29', '07-23', '07-28', '07-29',
                                       '08-06', '08-30', '10-08', '11-01', '12-08', '12-09', '12-25') AS feriado_fijo_previo,
       percentile_approx(n, 0.5) OVER w8 AS base_mediana,
       count(n) OVER w8 AS n_base,
       lag(n) OVER (PARTITION BY rol ORDER BY fecha) AS n_anterior
FROM s
WINDOW w8 AS (PARTITION BY rol, dayofweek(fecha) ORDER BY fecha ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING);

SET VAR dq_log = array_append(dq_log, named_struct(
  'paso', 'LV.00',
  'escenario', CASE WHEN NOT dq_lv_activo THEN 'VOLUMEN_DESACTIVADO'
                    WHEN dq_lv_rol_serie = '' THEN 'VOLUMEN_SIN_COLUMNA_DE_TIEMPO'
                    WHEN dq_lv_col_carga = '' AND dq_lv_col_lote = '' THEN 'VOLUMEN_SOLO_FECHA_NEGOCIO'
                    ELSE 'VOLUMEN_CON_TRAZABILIDAD_DE_CARGA' END,
  'detalle', concat('carga=', IF(dq_lv_col_carga = '', '(ninguna)', dq_lv_col_carga),
                    '; negocio=', IF(dq_lv_col_negocio = '', '(ninguna)', dq_lv_col_negocio),
                    '; lote=', IF(dq_lv_col_lote = '', '(ninguna)', dq_lv_col_lote),
                    '; serie principal=', IF(dq_lv_rol_serie = '', '(ninguna)', dq_lv_rol_serie),
                    IF(dq_lv_manual_invalidas = '', '', concat('; columnas indicadas que NO existen: ', dq_lv_manual_invalidas))),
  'interpretacion', CASE
    WHEN NOT dq_lv_activo THEN 'Capa V desactivada (dq_lv_activo = false): no hay análisis de volumen ni de cargas.'
    WHEN dq_lv_rol_serie = '' THEN 'No se halló columna de fecha ni de archivo: no se puede analizar volumen por periodo. Fijen dq_lv_col_carga / dq_lv_col_negocio si existen con otro nombre.'
    WHEN dq_lv_col_carga = '' AND dq_lv_col_lote = '' THEN 'Sólo hay fecha de negocio: un día bajo puede ser carga fallida O baja actividad real; sin fecha de carga ni archivo no se pueden separar.'
    ELSE 'Hay trazabilidad de carga: los huecos y caídas por fecha de carga apuntan a problemas de ingesta; compárenlos con la fecha de negocio (LV.05-LV.06).' END));

SELECT c.columna, c.familia, c.rol, c.en_diccionario, s.n_no_nulos, s.n_fecha_valida,
       round(s.n_fecha_valida / NULLIF(s.n_no_nulos, 0), 4) AS pct_fecha_valida,
       s.n_fecha - s.n_fecha_valida AS n_fuera_de_rango, s.f_min, s.f_max, s.n_dias, s.n_distintos,
       CASE WHEN c.columna = dq_lv_col_carga THEN 'ELEGIDA_CARGA' WHEN c.columna = dq_lv_col_negocio THEN 'ELEGIDA_NEGOCIO'
            WHEN c.columna = dq_lv_col_lote THEN 'ELEGIDA_LOTE' ELSE '' END AS seleccion
FROM (SELECT inline(dq_lv_cands)) c
LEFT JOIN (SELECT inline(dq_lv_stats)) s ON s.columna = c.columna
ORDER BY CASE WHEN c.columna IN (dq_lv_col_carga, dq_lv_col_negocio, dq_lv_col_lote) THEN 0 ELSE 1 END, c.rol, c.columna;


/* ────────────────────────────────────────────────────────────────────────────
   [LV.01] Resumen por reloj: cobertura del calendario, cadencia y frescura
   DOCSTRING (es-PE)
     Una fila por rol (CARGA, NEGOCIO, LOTE): columna usada, filas con fecha
     válida, rango, días calendario vs. días con datos, cadencia típica
     (mediana de días entre fechas con datos), brecha máxima, días desde la
     última fecha hasta hoy y concentración de filas en los últimos 30 días
     del rango.
   TOOLTIP ▸ Cómo leer e interpretar (hipótesis alternativas)
     • CARGA_UNICA (un solo día de carga): la tabla es una foto (snapshot o
       full refresh); el volumen por fecha de carga no informa nada; usen el
       reloj NEGOCIO.
     • CONCENTRADO_RECIENTE: muchas más filas en los últimos 30 días de lo
       esperable. Hipótesis: 1) la "fecha de actualización" se sobrescribe
       en cada actualización (SCD1), así las filas viejas "se mudan" a fechas
       recientes y el pasado se ve vacío → no interpreten huecos antiguos
       como cargas fallidas; 2) crecimiento real; 3) recarga masiva reciente.
       Lo distinguen con LV.05 (latencia negocio→carga muy larga en filas
       recientes = sobrescritura o recarga).
     • DESACTUALIZADO (días_desde_ultima > 2 × cadencia): la carga dejó de
       llegar, o la tabla que leen es una copia/histórico. Confirmen con el
       dueño del proceso antes de reportarlo como incidente.
     • NO_DISPONIBLE: no hay columna para ese rol (ver LV.00).
   ──────────────────────────────────────────────────────────────────────────── */
WITH roles AS (
  SELECT * FROM VALUES ('CARGA', 1), ('NEGOCIO', 2), ('LOTE', 3) AS t(rol, o)
), fechas AS (
  SELECT rol, count(fecha) AS n_con_fecha
  FROM (SELECT stack(3, 'CARGA', _dq_lv_f_carga, 'NEGOCIO', _dq_lv_f_negocio, 'LOTE', _dq_lv_f_lote) AS (rol, fecha)
        FROM dq_lv_base) e
  GROUP BY rol
), activos AS (
  SELECT rol, fecha, n, datediff(fecha, lag(fecha) OVER (PARTITION BY rol ORDER BY fecha)) AS salto
  FROM dq_lv_diario
), agg AS (
  SELECT rol, sum(n) AS n_validas, min(fecha) AS fecha_min, max(fecha) AS fecha_max, count(*) AS dias_con_datos,
         percentile_approx(salto, 0.5) AS cadencia_dias, max(salto) AS max_brecha_dias
  FROM activos GROUP BY rol
), rec AS (
  SELECT a.rol, sum(IF(d.fecha > date_add(a.fecha_max, -30), d.n, 0)) / NULLIF(sum(d.n), 0) AS pct_ult_30d
  FROM agg a JOIN dq_lv_diario d ON d.rol = a.rol GROUP BY a.rol
), t AS (
  SELECT r.rol, r.o,
         CASE r.rol WHEN 'CARGA' THEN dq_lv_col_carga WHEN 'NEGOCIO' THEN dq_lv_col_negocio ELSE dq_lv_col_lote END AS columna,
         f.n_con_fecha, a.n_validas, a.fecha_min, a.fecha_max, a.dias_con_datos,
         datediff(a.fecha_max, a.fecha_min) + 1 AS dias_calendario,
         a.cadencia_dias, a.max_brecha_dias, datediff(current_date(), a.fecha_max) AS dias_desde_ultima,
         rec.pct_ult_30d
  FROM roles r LEFT JOIN fechas f ON f.rol = r.rol LEFT JOIN agg a ON a.rol = r.rol LEFT JOIN rec ON rec.rol = r.rol
)
SELECT rol, nullif(columna, '') AS columna, dq_n_filas_total AS n_filas_tabla, n_validas AS n_con_fecha_valida,
       round(n_validas / NULLIF(dq_n_filas_total, 0), 4) AS pct_con_fecha_valida,
       coalesce(n_con_fecha, 0) - coalesce(n_validas, 0) AS n_fuera_de_rango,
       fecha_min, fecha_max, dias_calendario, dias_con_datos,
       round(dias_con_datos / NULLIF(dias_calendario, 0), 4) AS pct_dias_con_datos,
       cadencia_dias, max_brecha_dias, dias_desde_ultima, round(pct_ult_30d, 4) AS pct_filas_ultimos_30d,
       filter(array(
         IF(columna = '' OR n_validas IS NULL, 'NO_DISPONIBLE', NULL),
         IF(dias_con_datos = 1, 'CARGA_UNICA', NULL),
         IF(dias_calendario > 90 AND pct_ult_30d > least(0.9, 3 * 30 / dias_calendario), 'CONCENTRADO_RECIENTE', NULL),
         IF(dias_desde_ultima > greatest(2 * coalesce(cadencia_dias, 1), 2), 'DESACTUALIZADO', NULL),
         IF(max_brecha_dias > greatest(3 * coalesce(cadencia_dias, 1), 3), 'BRECHAS_LARGAS', NULL),
         IF(coalesce(n_con_fecha, 0) - coalesce(n_validas, 0) > 0, 'FECHAS_FUERA_DE_RANGO', NULL)), x -> x IS NOT NULL) AS diagnostico,
       CASE
         WHEN columna = '' OR n_validas IS NULL THEN 'Sin columna para este reloj (ver LV.00).'
         WHEN dias_con_datos = 1 THEN '1) foto completa (snapshot/full refresh) 2) una sola carga histórica: el volumen por este reloj no sirve; usen otro reloj.'
         WHEN dias_calendario > 90 AND pct_ult_30d > least(0.9, 3 * 30 / dias_calendario)
           THEN '1) fecha que se sobrescribe al actualizar (SCD1) 2) recarga masiva reciente 3) crecimiento real. Ver LV.05.'
         WHEN dias_desde_ultima > greatest(2 * coalesce(cadencia_dias, 1), 2)
           THEN '1) la carga dejó de llegar 2) la tabla es una copia o histórico 3) la columna elegida no es la de carga.'
         ELSE 'Cobertura y cadencia sin alertas generales; revisen el detalle en LV.02-LV.04.' END AS hipotesis
FROM t
ORDER BY o;


/* ────────────────────────────────────────────────────────────────────────────
   [LV.02] Días anómalos: huecos, caídas y picos vs. el mismo día de semana
   DOCSTRING (es-PE)
     Sobre la serie diaria completa de cada reloj compara el conteo del día
     con la mediana del mismo día de semana en las 8 semanas previas
     (base_mediana). Estados: HUECO (0 filas donde normalmente hay),
     BAJO (razón < dq_lv_umbral_bajo), ALTO (razón > dq_lv_umbral_alto),
     ACTIVIDAD_INUSUAL (filas en un día que normalmente no tiene),
     RECIENTE_POSIBLE_INCOMPLETO (caída en los últimos dq_lv_dias_recientes
     días: puede ser latencia, no falla). Etiquetas: FERIADO (fijos de Perú +
     dq_lv_feriados), DIA_POST_FERIADO, FIN_DE_SEMANA, FIN_DE_MES,
     PREVIO_HUECO (pico justo después de un hueco), SIGUIENTE_ALTO (hueco o
     caída seguido de un pico). Sólo lista días no normales.
   TOOLTIP ▸ Cómo leer e interpretar (hipótesis alternativas)
     • HUECO/BAJO + SIGUIENTE_ALTO (y ALTO + PREVIO_HUECO al día siguiente):
       carga diferida, el archivo se cargó un día después. No se perdió data;
       el problema es de oportunidad (SLA). Confírmenlo en LV.07 (archivo
       cargado en otra fecha) y LV.06.
     • HUECO/BAJO sin recuperación: 1) carga fallida o parcial (archivo
       truncado: crucen con LD.08 y LV.07); 2) el origen no envió; 3) baja
       actividad real; 4) filtro de filas. En reloj CARGA pesa más 1); en
       reloj NEGOCIO pesa más 3).
     • Con etiqueta FERIADO o DIA_POST_FERIADO: primero sospechen
       estacionalidad real (comparen con el mismo feriado de otro año).
       Semana Santa y feriados puntuales NO están en la lista fija:
       agréguenlos en dq_lv_feriados.
     • ALTO sin PREVIO_HUECO: 1) carga duplicada o reenvío (LV.07
       DUPLICADO_EXACTO, L1.05); 2) backfill o recarga histórica (LV.06);
       3) evento real (fin de mes, quincena, campaña).
     • Días con TIMESTAMP de carga cerca de medianoche pueden "cambiar de
       día" según la zona horaria de la sesión (UTC vs. America/Lima).
   ──────────────────────────────────────────────────────────────────────────── */
WITH s AS (
  SELECT *, n / NULLIF(base_mediana, 0) AS razon,
         feriado_fijo OR array_contains(split(regexp_replace(dq_lv_feriados, ' ', ''), ','), CAST(fecha AS STRING)) AS feriado,
         feriado_fijo_previo OR array_contains(split(regexp_replace(dq_lv_feriados, ' ', ''), ','), CAST(date_add(fecha, -1) AS STRING)) AS post_feriado
  FROM dq_lv_serie
), e AS (
  SELECT *,
         CASE WHEN base_mediana > 0 AND dias_al_final < dq_lv_dias_recientes AND (n = 0 OR razon < dq_lv_umbral_bajo)
                THEN 'RECIENTE_POSIBLE_INCOMPLETO'
              WHEN n_base < 3 THEN 'SIN_BASE'
              WHEN n = 0 AND base_mediana > 0 THEN 'HUECO'
              WHEN n = 0 THEN 'SIN_ACTIVIDAD_HABITUAL'
              WHEN coalesce(base_mediana, 0) = 0 THEN 'ACTIVIDAD_INUSUAL'
              WHEN razon < dq_lv_umbral_bajo THEN 'BAJO'
              WHEN razon > dq_lv_umbral_alto THEN 'ALTO'
              ELSE 'NORMAL' END AS estado
  FROM s
), f AS (
  SELECT *, lead(razon) OVER (PARTITION BY rol ORDER BY fecha) AS razon_siguiente FROM e
)
SELECT rol,
       CASE rol WHEN 'CARGA' THEN dq_lv_col_carga WHEN 'NEGOCIO' THEN dq_lv_col_negocio ELSE dq_lv_col_lote END AS columna,
       fecha, dia_semana, n, base_mediana, round(razon, 3) AS razon, estado,
       filter(array(
         IF(feriado, 'FERIADO', NULL), IF(post_feriado, 'DIA_POST_FERIADO', NULL),
         IF(dow IN (1, 7), 'FIN_DE_SEMANA', NULL), IF(fecha = last_day(fecha), 'FIN_DE_MES', NULL),
         IF(estado = 'ALTO' AND n_anterior = 0, 'PREVIO_HUECO', NULL),
         IF(estado IN ('HUECO', 'BAJO') AND razon_siguiente > dq_lv_umbral_alto, 'SIGUIENTE_ALTO', NULL)), x -> x IS NOT NULL) AS etiquetas,
       CASE
         WHEN estado = 'RECIENTE_POSIBLE_INCOMPLETO' THEN '1) data aún en camino (latencia, ver LV.05) 2) carga del día fallida. Revaluar en unos días.'
         WHEN estado IN ('HUECO', 'BAJO') AND razon_siguiente > dq_lv_umbral_alto
           THEN '1) carga diferida: se cargó al día siguiente (ver ALTO siguiente y LV.07) 2) proceso fallido y reprocesado.'
         WHEN estado IN ('HUECO', 'BAJO') AND (feriado OR post_feriado)
           THEN '1) efecto feriado (actividad real menor) 2) carga parcial o no ejecutada.'
         WHEN estado = 'HUECO' AND rol = 'NEGOCIO'
           THEN '1) sin actividad ese día 2) carga de ese día perdida (ver reloj CARGA) 3) filtro de filas.'
         WHEN estado = 'HUECO'
           THEN '1) carga no ejecutada o fallida 2) el origen no envió archivo 3) datos borrados o filtrados 4) si la fecha se sobrescribe (SCD1), filas re-actualizadas después.'
         WHEN estado = 'BAJO'
           THEN '1) carga parcial (archivo truncado: ver LD.08 y LV.07) 2) caída de la fuente o baja actividad real 3) datos tardíos aún no cargados (LV.05).'
         WHEN estado = 'ALTO' AND n_anterior = 0
           THEN '1) recuperación del hueco del día anterior (no es duplicado) 2) carga duplicada.'
         WHEN estado = 'ALTO'
           THEN '1) carga duplicada o reenvío (LV.07, L1.05) 2) backfill / recarga histórica (LV.06) 3) evento real (fin de mes, campaña).'
         WHEN estado = 'ACTIVIDAD_INUSUAL'
           THEN '1) carga extraordinaria o reproceso en día sin actividad habitual 2) cambio de calendario operativo.'
       END AS hipotesis
FROM f
WHERE estado NOT IN ('NORMAL', 'SIN_BASE', 'SIN_ACTIVIDAD_HABITUAL')
ORDER BY rol, fecha
LIMIT 1000;


/* ────────────────────────────────────────────────────────────────────────────
   [LV.03] Huecos como rachas: días seguidos sin filas
   DOCSTRING (es-PE)
     Agrupa días consecutivos con 0 filas en rachas (desde, hasta, días,
     días hábiles = sin fin de semana ni feriado) y mira el día siguiente
     a la racha. Clasifica: HUECO_CON_RECUPERACION (el día siguiente trae un
     pico), HUECO_RECIENTE (toca el final de la serie), SOLO_FIN_DE_SEMANA_O_
     FERIADO, HUECO_HABIL. Ignora rachas en días que nunca tienen actividad
     (base 0).
   TOOLTIP ▸ Cómo leer e interpretar (hipótesis alternativas)
     • HUECO_HABIL largo en reloj CARGA = periodo sin cargas: incidente de
       ingesta o datos aún no recuperados. Si el reloj NEGOCIO NO tiene el
       mismo hueco, la data llegó por otra carga (backfill) → oportunidad,
       no pérdida.
     • HUECO_CON_RECUPERACION: la data se recuperó al día siguiente
       (compárenlo con el pico de LV.02).
     • SOLO_FIN_DE_SEMANA_O_FERIADO: probablemente esperado; confírmenlo con
       el calendario operativo del origen.
     • Si el hueco coincide con el cambio de layout (change log del
       diccionario) sospechen registros rechazados por el parser de ingesta.
   ──────────────────────────────────────────────────────────────────────────── */
WITH s AS (
  SELECT *, (dow IN (1, 7) OR feriado_fijo
             OR array_contains(split(regexp_replace(dq_lv_feriados, ' ', ''), ','), CAST(fecha AS STRING))) AS no_habil
  FROM dq_lv_serie
), z AS (
  SELECT *, date_add(fecha, -CAST(row_number() OVER (PARTITION BY rol ORDER BY fecha) AS INT)) AS grupo
  FROM s WHERE n = 0
), rachas AS (
  SELECT rol, grupo, min(fecha) AS desde, max(fecha) AS hasta, count(*) AS dias,
         count_if(NOT no_habil) AS dias_habiles, max(coalesce(base_mediana, 0)) AS base_max, min(dias_al_final) AS dias_al_final
  FROM z GROUP BY rol, grupo
)
SELECT r.rol,
       CASE r.rol WHEN 'CARGA' THEN dq_lv_col_carga WHEN 'NEGOCIO' THEN dq_lv_col_negocio ELSE dq_lv_col_lote END AS columna,
       r.desde, r.hasta, r.dias, r.dias_habiles, a.n AS n_dia_anterior, d.n AS n_dia_siguiente, d.base_mediana AS base_dia_siguiente,
       CASE WHEN d.n / NULLIF(d.base_mediana, 0) > dq_lv_umbral_alto THEN 'HUECO_CON_RECUPERACION'
            WHEN r.dias_al_final < dq_lv_dias_recientes OR d.fecha IS NULL THEN 'HUECO_RECIENTE'
            WHEN r.dias_habiles = 0 THEN 'SOLO_FIN_DE_SEMANA_O_FERIADO'
            ELSE 'HUECO_HABIL' END AS clasificacion,
       CASE WHEN d.n / NULLIF(d.base_mediana, 0) > dq_lv_umbral_alto
              THEN '1) carga diferida y recuperada al día siguiente 2) reproceso tras falla. Riesgo: SLA, no pérdida.'
            WHEN r.dias_al_final < dq_lv_dias_recientes OR d.fecha IS NULL
              THEN '1) data aún en camino 2) carga detenida. Revaluar después.'
            WHEN r.dias_habiles = 0 THEN '1) sin operación en fin de semana/feriado (esperado) 2) carga no ejecutada.'
            ELSE '1) cargas fallidas o no ejecutadas 2) el origen no envió 3) filas borradas/filtradas. Comparen con el otro reloj.' END AS hipotesis
FROM rachas r
LEFT JOIN dq_lv_serie a ON a.rol = r.rol AND a.fecha = date_add(r.desde, -1)
LEFT JOIN dq_lv_serie d ON d.rol = r.rol AND d.fecha = date_add(r.hasta, 1)
WHERE r.base_max > 0
ORDER BY r.rol, r.desde
LIMIT 1000;


/* ────────────────────────────────────────────────────────────────────────────
   [LV.04] Volumen mensual por reloj con comparación robusta
   DOCSTRING (es-PE)
     Por rol y mes: filas, días con datos, días del mes dentro del rango
     observado, promedio por día activo, filas normalizadas al mes completo
     (meses de borde), base = mediana de los 6 meses previos, razón,
     variación vs. mes anterior y vs. el mismo mes del año anterior.
     Estados: MES_SIN_DATOS, MES_PARCIAL_BORDE, MES_BAJO (< (1+umbral_bajo)/2
     de la base, p.ej. 0,75), MES_ALTO (> (1+umbral_alto)/2, p.ej. 1,4),
     DIAS_FALTANTES (menos días con datos que lo habitual) o NORMAL.
     Muestra todos los meses.
   TOOLTIP ▸ Cómo leer e interpretar (hipótesis alternativas)
     • MES_BAJO con DIAS_FALTANTES: faltan cargas puntuales → vean qué días
       en LV.02/LV.03.
     • MES_BAJO sin días faltantes: todas las cargas vinieron "flacas" →
       1) cambio de filtro o de alcance en el origen, 2) estacionalidad real
       (comparen var_anual), 3) cambio de layout que descarta registros.
     • MES_ALTO: 1) duplicados (L1.05, LV.07), 2) recarga histórica que cae
       en este mes por fecha de carga, 3) crecimiento o campaña.
     • MES_PARCIAL_BORDE: primer o último mes cortado; no lo comparen tal
       cual (usen n_normalizado).
   ──────────────────────────────────────────────────────────────────────────── */
WITH r AS (
  SELECT rol, min(fecha) AS mn, max(fecha) AS mx FROM dq_lv_diario GROUP BY rol
), meses AS (
  SELECT rol, mn, mx, explode(sequence(trunc(mn, 'MM'), trunc(mx, 'MM'), INTERVAL 1 MONTH)) AS mes FROM r
), m AS (
  SELECT x.rol, x.mes, x.mn, x.mx, coalesce(sum(d.n), 0) AS n, count(d.fecha) AS dias_con_datos,
         day(last_day(x.mes)) AS dias_mes,
         datediff(least(last_day(x.mes), x.mx), greatest(x.mes, x.mn)) + 1 AS dias_en_rango
  FROM meses x LEFT JOIN dq_lv_diario d ON d.rol = x.rol AND trunc(d.fecha, 'MM') = x.mes
  GROUP BY x.rol, x.mes, x.mn, x.mx
), b AS (
  SELECT *, n * dias_mes / NULLIF(dias_en_rango, 0) AS n_normalizado,
         percentile_approx(n * dias_mes / NULLIF(dias_en_rango, 0), 0.5)
           OVER (PARTITION BY rol ORDER BY mes ROWS BETWEEN 6 PRECEDING AND 1 PRECEDING) AS base_6m,
         percentile_approx(dias_con_datos * dias_mes / NULLIF(dias_en_rango, 0), 0.5)
           OVER (PARTITION BY rol ORDER BY mes ROWS BETWEEN 6 PRECEDING AND 1 PRECEDING) AS dias_base_6m,
         lag(n) OVER (PARTITION BY rol ORDER BY mes) AS n_mes_anterior,
         lag(n, 12) OVER (PARTITION BY rol ORDER BY mes) AS n_anio_anterior
  FROM m
)
SELECT rol,
       CASE rol WHEN 'CARGA' THEN dq_lv_col_carga WHEN 'NEGOCIO' THEN dq_lv_col_negocio ELSE dq_lv_col_lote END AS columna,
       date_format(mes, 'yyyy-MM') AS mes, n, dias_con_datos, dias_en_rango,
       round(n / NULLIF(dias_con_datos, 0), 1) AS prom_por_dia_activo,
       round(n_normalizado, 0) AS n_normalizado, round(base_6m, 0) AS base_6m,
       round(n_normalizado / NULLIF(base_6m, 0), 3) AS razon,
       round(n / NULLIF(n_mes_anterior, 0) - 1, 3) AS var_mes_anterior,
       round(n / NULLIF(n_anio_anterior, 0) - 1, 3) AS var_anual,
       CASE WHEN n = 0 THEN 'MES_SIN_DATOS'
            WHEN dias_en_rango < dias_mes THEN 'MES_PARCIAL_BORDE'
            WHEN n_normalizado / NULLIF(base_6m, 0) < (1 + dq_lv_umbral_bajo) / 2 THEN 'MES_BAJO'
            WHEN n_normalizado / NULLIF(base_6m, 0) > (1 + dq_lv_umbral_alto) / 2 THEN 'MES_ALTO'
            WHEN dias_con_datos < dias_base_6m - 2 THEN 'DIAS_FALTANTES'
            ELSE 'NORMAL' END AS estado,
       CASE WHEN n = 0 THEN '1) mes sin cargas (incidente o fuera de alcance) 2) filtro de filas 3) la fecha se sobrescribe (SCD1, ver LV.01).'
            WHEN dias_en_rango < dias_mes THEN 'Mes cortado por el inicio o fin del rango: comparen n_normalizado.'
            WHEN n_normalizado / NULLIF(base_6m, 0) < (1 + dq_lv_umbral_bajo) / 2
              THEN IF(dias_con_datos < dias_base_6m - 2,
                      '1) faltan cargas puntuales (ver LV.02/LV.03) 2) baja actividad real.',
                      '1) cargas incompletas todo el mes (filtro/alcance/layout) 2) estacionalidad real (ver var_anual).')
            WHEN n_normalizado / NULLIF(base_6m, 0) > (1 + dq_lv_umbral_alto) / 2
              THEN '1) duplicados o reenvíos (L1.05, LV.07) 2) recarga histórica 3) crecimiento o campaña.'
            WHEN dias_con_datos < dias_base_6m - 2 THEN '1) días sin carga compensados por otros días 2) cambio de calendario.'
            ELSE NULL END AS hipotesis
FROM b
ORDER BY rol, mes;


/* ────────────────────────────────────────────────────────────────────────────
   [LV.05] Latencia fecha de negocio → fecha de carga
   DOCSTRING (es-PE)
     Si hay reloj CARGA y NEGOCIO: días entre la fecha del hecho y su carga
     (p50, p90, p99, máximo), % cargado el mismo día, % con carga ANTES del
     hecho (latencia negativa) y % con más de 30 días de atraso.
   TOOLTIP ▸ Cómo leer e interpretar (hipótesis alternativas)
     • p50/p90 dan el SLA real: los últimos p90 días de la serie NEGOCIO
       siempre se verán incompletos (aún llegan) → no los reporten como
       caída.
     • pct_negativa > 0: 1) fechas de negocio futuras (operaciones
       programadas), 2) zona horaria (carga en UTC, negocio en hora Lima),
       3) columnas mal elegidas o invertidas (revisen LV.00).
     • pct_mas_30_dias alto: 1) recargas o backfills, 2) fecha de
       actualización que se sobrescribe (SCD1), 3) correcciones tardías.
     • OMITIDO: falta uno de los dos relojes.
   ──────────────────────────────────────────────────────────────────────────── */
WITH l AS (
  SELECT datediff(_dq_lv_f_carga, _dq_lv_f_negocio) AS lag
  FROM dq_lv_base
  WHERE _dq_lv_f_carga BETWEEN DATE'1950-01-01' AND date_add(current_date(), 366)
    AND _dq_lv_f_negocio BETWEEN DATE'1950-01-01' AND date_add(current_date(), 366)
)
SELECT IF(dq_lv_col_carga = '' OR dq_lv_col_negocio = '', 'OMITIDO', 'CALCULADO') AS estado,
       nullif(dq_lv_col_negocio, '') AS columna_negocio, nullif(dq_lv_col_carga, '') AS columna_carga,
       count(lag) AS n_pares,
       percentile_approx(lag, 0.5) AS lag_p50, percentile_approx(lag, 0.9) AS lag_p90,
       percentile_approx(lag, 0.99) AS lag_p99, max(lag) AS lag_max,
       round(count_if(lag = 0) / NULLIF(count(lag), 0), 4) AS pct_mismo_dia,
       round(count_if(lag < 0) / NULLIF(count(lag), 0), 4) AS pct_negativa,
       round(count_if(lag > 30) / NULLIF(count(lag), 0), 4) AS pct_mas_30_dias,
       CASE WHEN dq_lv_col_carga = '' OR dq_lv_col_negocio = '' THEN 'Falta reloj de carga o de negocio (ver LV.00): no se puede medir latencia.'
            WHEN count_if(lag < 0) / NULLIF(count(lag), 0) > 0.01 THEN '1) fechas de negocio futuras 2) zona horaria 3) columnas mal elegidas o invertidas.'
            WHEN count_if(lag > 30) / NULLIF(count(lag), 0) > 0.05 THEN '1) recargas/backfills 2) fecha de actualización sobrescrita (SCD1) 3) correcciones tardías.'
            ELSE 'Latencia estable: usen lag_p90 como ventana de "datos aún en camino".' END AS hipotesis
FROM l;


/* ────────────────────────────────────────────────────────────────────────────
   [LV.06] Recargas y cargas repetidas (cruce carga × negocio)
   DOCSTRING (es-PE)
     Dos vistas en una salida (columna tipo):
       POR_FECHA_CARGA : días de carga que traen fechas de negocio mucho más
         antiguas que lo normal (más allá de p99 de latencia + 7 días) o
         muchas más fechas de negocio distintas que lo habitual →
         RECARGA_O_BACKFILL.
       POR_FECHA_NEGOCIO : fechas de negocio cuya data llegó repartida en
         varias cargas y la parte que NO vino en la carga principal es
         ≥ 30% → CARGA_REPETIDA_O_TARDIA_MASIVA.
     Sólo lista excepciones.
   TOOLTIP ▸ Cómo leer e interpretar (hipótesis alternativas)
     • CARGA_REPETIDA_O_TARDIA_MASIVA con n_filas ≈ 2 × lo normal en LV.02
       (reloj NEGOCIO): DUPLICADO por reenvío del mismo archivo → validen con
       LV.07 (DUPLICADO_EXACTO) y L1.05. Si el total por fecha de negocio es
       normal, fue una carga tardía de la parte faltante (no duplicado).
     • RECARGA_O_BACKFILL: reproceso de histórico. Es legítimo si fue
       planificado; si no, puede duplicar o pisar datos ya cargados.
   ──────────────────────────────────────────────────────────────────────────── */
WITH b AS (
  SELECT _dq_lv_f_carga AS fc, _dq_lv_f_negocio AS fn
  FROM dq_lv_base
  WHERE _dq_lv_f_carga BETWEEN DATE'1950-01-01' AND date_add(current_date(), 366)
    AND _dq_lv_f_negocio BETWEEN DATE'1950-01-01' AND date_add(current_date(), 366)
), p AS (
  SELECT percentile_approx(datediff(fc, fn), 0.99) AS p99 FROM b
), pc AS (
  SELECT fc, count(*) AS n, count(DISTINCT fn) AS n_fn, min(fn) AS fn_min, max(fn) AS fn_max FROM b GROUP BY fc
), pc2 AS (
  SELECT pc.*, percentile_approx(n_fn, 0.5) OVER () AS n_fn_mediana FROM pc
), pn AS (
  SELECT fn, fc, count(*) AS n FROM b GROUP BY fn, fc
), pn2 AS (
  SELECT fn, sum(n) AS n, count(*) AS n_cargas, max(n) AS n_principal, max_by(fc, n) AS carga_principal,
         array_join(slice(array_sort(collect_list(CAST(fc AS STRING))), 1, 5), ', ') AS cargas
  FROM pn GROUP BY fn
)
SELECT 'POR_FECHA_CARGA' AS tipo, pc2.fc AS fecha, pc2.n AS n_filas,
       concat('fechas de negocio: ', pc2.n_fn, ' distintas (mediana ', pc2.n_fn_mediana, '), de ', pc2.fn_min, ' a ', pc2.fn_max) AS detalle,
       'RECARGA_O_BACKFILL' AS diagnostico,
       '1) reproceso o backfill planificado 2) recarga no planificada que puede duplicar data 3) archivo acumulado tras días sin carga.' AS hipotesis
FROM pc2 CROSS JOIN p
WHERE dq_lv_col_carga <> '' AND dq_lv_col_negocio <> ''
  AND (pc2.fn_min < date_add(pc2.fc, -CAST(coalesce(p.p99, 0) + 7 AS INT))
       OR (pc2.n_fn > 3 * pc2.n_fn_mediana AND pc2.n_fn > 3))
UNION ALL
SELECT 'POR_FECHA_NEGOCIO', pn2.fn, pn2.n,
       concat('llegó en ', pn2.n_cargas, ' cargas (', pn2.cargas, '); principal ', pn2.carga_principal,
              ' con ', pn2.n_principal, ' filas; resto ', pn2.n - pn2.n_principal),
       'CARGA_REPETIDA_O_TARDIA_MASIVA',
       '1) reenvío/duplicado del archivo (ver LV.07 y L1.05) 2) carga tardía de la parte faltante (total normal) 3) corrección masiva.'
FROM pn2
WHERE dq_lv_col_carga <> '' AND dq_lv_col_negocio <> ''
  AND pn2.n >= 20 AND (pn2.n - pn2.n_principal) >= 0.3 * pn2.n
ORDER BY tipo, fecha
LIMIT 1000;


/* ────────────────────────────────────────────────────────────────────────────
   [LV.07] Archivos o lotes: tamaño, duplicados y fecha de carga
   DOCSTRING (es-PE)
     Por valor de la columna LOTE (archivo): filas, fecha en el nombre,
     fechas de carga y de negocio que contiene, y una huella del contenido
     (suma de hash de cada fila sin las columnas de carga y lote). Marca:
       DUPLICADO_EXACTO : otro lote con el mismo número de filas y la misma
         huella (mismo contenido con otro nombre).
       TAMANO_BAJO / TAMANO_ALTO : filas vs. la mediana de lotes del mismo
         día de semana (razón < umbral_bajo o > umbral_alto).
       VARIAS_FECHAS_CARGA : el mismo lote cargado en más de un día.
       CARGADO_EN_OTRA_FECHA : la fecha del nombre ≠ primera fecha de carga.
     Sólo lista lotes con alguna marca.
   TOOLTIP ▸ Cómo leer e interpretar (hipótesis alternativas)
     • DUPLICADO_EXACTO: reenvío con otro nombre; si ambos están cargados la
       data está duplicada → confirmen con L1.05 y LV.06.
     • TAMANO_BAJO: 1) archivo truncado (crucen con el trailer en LD.08),
       2) carga parcial, 3) día de baja actividad (feriado).
     • VARIAS_FECHAS_CARGA: el mismo archivo se procesó dos veces → riesgo
       de duplicados.
     • CARGADO_EN_OTRA_FECHA: llegada tardía (SLA) o convención de nombre
       distinta (fecha del archivo = fecha de negocio, no de carga). Si TODOS
       los lotes tienen la misma diferencia, es la convención, no un
       problema.
     • OMITIDO: no hay columna de archivo/lote (ver LV.00).
   ──────────────────────────────────────────────────────────────────────────── */
WITH l AS (
  SELECT _dq_lv_lote AS lote, count(*) AS n, min(_dq_lv_f_lote) AS fecha_nombre,
         min(_dq_lv_f_carga) AS carga_min, max(_dq_lv_f_carga) AS carga_max,
         count(DISTINCT _dq_lv_f_carga) AS n_fechas_carga,
         min(_dq_lv_f_negocio) AS negocio_min, max(_dq_lv_f_negocio) AS negocio_max,
         sum(CAST(_dq_lv_hash AS DECIMAL(38, 0))) AS huella
  FROM dq_lv_base WHERE _dq_lv_lote IS NOT NULL GROUP BY _dq_lv_lote
), m AS (
  SELECT *, count(*) OVER (PARTITION BY n, huella) AS n_misma_huella,
         percentile_approx(n, 0.5) OVER (PARTITION BY dayofweek(coalesce(fecha_nombre, carga_min, negocio_max))) AS mediana_dia,
         count(*) OVER (PARTITION BY dayofweek(coalesce(fecha_nombre, carga_min, negocio_max))) AS n_lotes_dia
  FROM l
), f AS (
  SELECT *, filter(array(
           IF(n_misma_huella > 1 AND huella IS NOT NULL, 'DUPLICADO_EXACTO', NULL),
           IF(n_lotes_dia >= 4 AND n / NULLIF(mediana_dia, 0) < dq_lv_umbral_bajo, 'TAMANO_BAJO', NULL),
           IF(n_lotes_dia >= 4 AND n / NULLIF(mediana_dia, 0) > dq_lv_umbral_alto, 'TAMANO_ALTO', NULL),
           IF(n_fechas_carga > 1, 'VARIAS_FECHAS_CARGA', NULL),
           IF(fecha_nombre IS NOT NULL AND carga_min IS NOT NULL AND carga_min <> fecha_nombre,
              concat('CARGADO_EN_OTRA_FECHA(', datediff(carga_min, fecha_nombre), 'd)'), NULL)), x -> x IS NOT NULL) AS marcas
  FROM m
)
SELECT lote, n, mediana_dia AS mediana_mismo_dia_semana, round(n / NULLIF(mediana_dia, 0), 3) AS razon,
       fecha_nombre, carga_min, carga_max, negocio_min, negocio_max, marcas,
       CASE WHEN array_contains(marcas, 'DUPLICADO_EXACTO') THEN '1) reenvío del mismo contenido con otro nombre 2) dos lotes legítimamente idénticos (raro). Ver L1.05.'
            WHEN array_contains(marcas, 'VARIAS_FECHAS_CARGA') THEN '1) mismo archivo procesado dos veces (duplicados) 2) carga incremental del mismo archivo.'
            WHEN array_contains(marcas, 'TAMANO_BAJO') THEN '1) archivo truncado o carga parcial (LD.08) 2) baja actividad real (feriado).'
            WHEN array_contains(marcas, 'TAMANO_ALTO') THEN '1) archivo acumulado tras días sin envío 2) duplicado dentro del archivo 3) evento real.'
            ELSE '1) llegada tardía (SLA) 2) convención: la fecha del nombre es la de negocio, no la de carga.' END AS hipotesis
FROM f
WHERE size(marcas) > 0
UNION ALL
SELECT '(OMITIDO)', CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), CAST(NULL AS DOUBLE), CAST(NULL AS DATE), CAST(NULL AS DATE),
       CAST(NULL AS DATE), CAST(NULL AS DATE), CAST(NULL AS DATE), array('SIN_COLUMNA_LOTE'),
       'No hay columna de archivo o lote: fijen dq_lv_col_lote si existe con otro nombre (ver LV.00).'
WHERE dq_lv_col_lote = ''
ORDER BY lote
LIMIT 1000;


/* ────────────────────────────────────────────────────────────────────────────
   [LV.08] Columnas que se vacían (o se llenan) en un periodo de carga
   DOCSTRING (es-PE)
     Por periodo del reloj principal (CARGA si existe; si no NEGOCIO o LOTE;
     DIA si el rango ≤ 400 días, si no MES, o lo que indique
     dq_lv_granularidad) calcula el % de vacíos (NULL o en blanco) de cada
     columna (hasta dq_max_columnas_pares columnas) y lo compara con la
     mediana de esa columna en todos los periodos. Marca VACIO_ANOMALO
     (sube ≥ 20 puntos y al menos al doble + 5 puntos) y LLENO_INUSUAL
     (columna casi siempre vacía que ese periodo viene llena). Requiere ≥ 5
     periodos y ≥ 20 filas en el periodo.
   TOOLTIP ▸ Cómo leer e interpretar (hipótesis alternativas)
     • VACIO_ANOMALO en UNA columna un día: 1) campo no enviado o mal
       mapeado en esa carga, 2) cambio de layout ese día (vean LD.09 y el
       change log), 3) origen sin dato ese día.
     • VACIO_ANOMALO en MUCHAS columnas el mismo periodo: registro cortado o
       parser desalineado → vean LD.07 (largos de línea) para ese periodo.
     • LLENO_INUSUAL: campo nuevo que empezó a llenarse (versión de layout)
       o carga de prueba.
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_lv_rango_dias = coalesce((SELECT datediff(max(fecha), min(fecha)) FROM dq_lv_diario WHERE rol = dq_lv_rol_serie), 0);

SET VAR dq_sql = coalesce((
  SELECT IF(count(*) = 0 OR dq_lv_rol_serie = '', NULL, concat(
    'WITH p AS (SELECT periodo, _n, stack(', CAST(count(*) AS STRING), ', ',
    array_join(transform(array_sort(collect_list(struct(ordinal, s))), x -> x.s), ', '),
    ') AS (columna, n_vacios) FROM (SELECT ',
    IF(upper(dq_lv_granularidad) = 'MES' OR (upper(dq_lv_granularidad) = 'AUTO' AND dq_lv_rango_dias > 400),
       'trunc(_dq_lv_f_serie, ', 'CAST(_dq_lv_f_serie AS DATE)'),
    IF(upper(dq_lv_granularidad) = 'MES' OR (upper(dq_lv_granularidad) = 'AUTO' AND dq_lv_rango_dias > 400),
       concat(dq_lit('MM'), ')'), ''),
    ' AS periodo, count(*) AS _n, ',
    array_join(transform(array_sort(collect_list(struct(ordinal, a))), x -> x.a), ', '),
    ' FROM dq_lv_base WHERE _dq_lv_f_serie BETWEEN DATE', chr(39), '1950-01-01', chr(39),
    ' AND date_add(current_date(), 366) GROUP BY 1) z), ',
    'q AS (SELECT *, n_vacios / _n AS pct, percentile_approx(n_vacios / _n, 0.5) OVER (PARTITION BY columna) AS mediana, ',
    'count(*) OVER (PARTITION BY columna) AS n_periodos FROM p) ',
    'SELECT periodo, columna, _n AS n_filas_periodo, n_vacios, round(pct, 4) AS pct_vacios, round(mediana, 4) AS mediana_pct_vacios, ',
    'CASE WHEN pct - mediana >= 0.2 AND pct >= 2 * mediana + 0.05 THEN ', dq_lit('VACIO_ANOMALO'), ' ELSE ', dq_lit('LLENO_INUSUAL'), ' END AS diagnostico, ',
    'CASE WHEN pct - mediana >= 0.2 AND pct >= 2 * mediana + 0.05 THEN ',
    dq_lit('1) campo no enviado o mal mapeado en esa carga 2) cambio de layout (LD.09, change log) 3) origen sin dato ese periodo. Si muchas columnas caen el mismo periodo: registro cortado o parser desalineado (LD.07).'),
    ' ELSE ', dq_lit('1) campo nuevo que empezó a llenarse (versión de layout) 2) carga de prueba o corrección puntual.'), ' END AS hipotesis ',
    'FROM q WHERE n_periodos >= 5 AND _n >= 20 AND ((pct - mediana >= 0.2 AND pct >= 2 * mediana + 0.05) OR (mediana >= 0.8 AND pct <= mediana - 0.5)) ',
    'ORDER BY periodo, columna LIMIT 1000'))
  FROM (SELECT ordinal,
               concat(dq_lit(columna), ', _v', CAST(ordinal AS STRING)) AS s,
               concat('count_if(', dq_id(columna), ' IS NULL OR trim(CAST(', dq_id(columna), ' AS STRING)) = ', dq_lit(''),
                      ') AS _v', CAST(ordinal AS STRING)) AS a
        FROM dq_columnas
        WHERE columna IS NOT NULL AND columna NOT IN (dq_lv_col_carga, dq_lv_col_negocio, dq_lv_col_lote)
          AND coalesce(familia, 'OTRO') NOT IN ('COMPLEJO', 'BINARIO')
        ORDER BY ordinal
        LIMIT 60)),
  concat('SELECT ', dq_lit('OMITIDO'), ' AS diagnostico, ',
         dq_lit('Sin reloj principal (LV.00) o sin columnas perfilables: no se puede medir vacíos por periodo.'), ' AS hipotesis'));
EXECUTE IMMEDIATE dq_sql;

SET VAR dq_log = array_append(dq_log, named_struct(
  'paso', 'LV.02-LV.07',
  'escenario', IF(dq_lv_rol_serie = '', 'VOLUMEN_OMITIDO', 'VOLUMEN_EVALUADO'),
  'detalle', coalesce((
    SELECT concat('reloj ', dq_lv_rol_serie, ': ', count_if(n = 0 AND base_mediana > 0 AND n_base >= 3 AND dias_al_final >= dq_lv_dias_recientes), ' días HUECO, ',
                  count_if(n > 0 AND n_base >= 3 AND dias_al_final >= dq_lv_dias_recientes AND n / NULLIF(base_mediana, 0) < dq_lv_umbral_bajo), ' días BAJO, ',
                  count_if(n_base >= 3 AND n / NULLIF(base_mediana, 0) > dq_lv_umbral_alto), ' días ALTO, de ', count(*), ' días')
    FROM dq_lv_serie WHERE rol = dq_lv_rol_serie), 'sin serie'),
  'interpretacion', 'Detalle y hipótesis en LV.02 (días), LV.03 (rachas), LV.04 (meses), LV.06 (recargas) y LV.07 (archivos). Un día anómalo no es por sí solo un error: revisen la columna hipotesis.'));
