/* ════════════════════════════════════════════════════════════════════════════
   ARCHIVO 08 · CAPA 6 — DERIVA Y ESTABILIDAD DE DISTRIBUCIONES (PSI, JS, KS)
   ────────────────────────────────────────────────────────────────────────────
   DOCSTRING (es-PE)
     Compara la distribución de cada columna entre un grupo BASE y un grupo
     ACTUAL, con métricas estándar de riesgo de modelos y MLOps:
       • PSI (Population Stability Index) / CSI por columna, con los NULL
         como su propia cubeta (detecta deriva de faltantes);
       • divergencia de Jensen-Shannon (simétrica y acotada 0-1);
       • estadístico KS (Kolmogorov-Smirnov) para numéricas;
       • deltas de % nulos, media estandarizada (SMD) y categorías nuevas.
     Los grupos se definen de dos formas (dq_modo_deriva):
       'SEGMENTO': dos valores de dq_expr_segmento (p.ej. meses, TRAIN/TEST).
       'FUENTES' : dos orígenes cualesquiera, p.ej. versiones Delta
                   ('cat.esq.tabla VERSION AS OF 120' vs 'cat.esq.tabla'),
                   o tabla de entrenamiento vs tabla de scoring.
     Base teórica: Siddiqi (2006), Yurdakul (2018), TFDV "drift/skew"
     (Breck et al. 2019), Lakehouse Monitoring (drift metrics).
     Requisitos: archivos 00 y 02 (en modo SEGMENTO, dq_expr_segmento
     configurado ANTES de correr el 02).
   TOOLTIP ▸ Cómo usar
     • Configuren dq_segmento_base y dq_segmento_actual (o las fuentes), corran
       L6.00 y luego L6.01 (resumen). Bajen al detalle con L6.02-L6.05.
     • Personalización futura: definan por columna el umbral de PSI aceptable
       (variables críticas del modelo más estrictas) y programen L6.06 como
       monitoreo mensual con persistencia (L6.07).
   ════════════════════════════════════════════════════════════════════════════ */


/* ────────────────────────────────────────────────────────────────────────────
   [L6.00] Construcción de dq_deriva_long (grupo BASE / ACTUAL, columna, valor)
   DOCSTRING (es-PE)
     Según dq_modo_deriva arma la vista dq_deriva_long:
       SEGMENTO: filtra dq_long a los dos valores de segmento y los rotula.
       FUENTES : aplica la misma proyección a texto y el mismo stack del
                 archivo 02 sobre dq_fuente_base y dq_fuente_actual.
     Valida que los parámetros estén completos (si no, error con mensaje).
   TOOLTIP ▸ Cómo interpretar
     • No devuelve filas. Revisen el conteo con:
       SELECT grupo, count(DISTINCT columna), count(*) FROM dq_deriva_long GROUP BY grupo;
     • En FUENTES, las dos fuentes deben tener las columnas de la tabla
       objetivo (mismo esquema). Para muestrear, pueden escribir la fuente como
       'cat.esq.tabla TABLESAMPLE (10 PERCENT)'.
   ──────────────────────────────────────────────────────────────────────────── */
SELECT CASE
         WHEN upper(dq_modo_deriva) = 'SEGMENTO' AND (dq_segmento_base = '' OR dq_segmento_actual = '')
           THEN raise_error('[DQ] Modo SEGMENTO: configuren dq_segmento_base y dq_segmento_actual (y dq_expr_segmento antes del archivo 02).')
         WHEN upper(dq_modo_deriva) = 'FUENTES' AND (dq_fuente_base = '' OR dq_fuente_actual = '')
           THEN raise_error('[DQ] Modo FUENTES: configuren dq_fuente_base y dq_fuente_actual.')
         WHEN upper(dq_modo_deriva) NOT IN ('SEGMENTO', 'FUENTES')
           THEN raise_error('[DQ] dq_modo_deriva debe ser SEGMENTO o FUENTES.')
         ELSE concat('OK: modo ', upper(dq_modo_deriva))
       END AS verificacion;

SET VAR dq_sql = IF(
  upper(dq_modo_deriva) = 'SEGMENTO',
  concat('CREATE OR REPLACE TEMP VIEW dq_deriva_long AS ',
         'SELECT IF(_dq_segmento = ', dq_lit(dq_segmento_base), ', ', dq_lit('BASE'), ', ', dq_lit('ACTUAL'), ') AS grupo, ',
         'columna, valor FROM dq_long WHERE _dq_segmento IN (', dq_lit(dq_segmento_base), ', ', dq_lit(dq_segmento_actual), ')'),
  concat('CREATE OR REPLACE TEMP VIEW dq_deriva_long AS ',
         'SELECT ', dq_lit('BASE'), ' AS grupo, ', dq_stack,
         ' FROM (SELECT ', dq_proyeccion, ' FROM (SELECT * FROM ', dq_fuente_base, ') s0) s1 ',
         'UNION ALL ',
         'SELECT ', dq_lit('ACTUAL'), ' AS grupo, ', dq_stack,
         ' FROM (SELECT ', dq_proyeccion, ' FROM (SELECT * FROM ', dq_fuente_actual, ') s0) s1'));
EXECUTE IMMEDIATE dq_sql;


/* ────────────────────────────────────────────────────────────────────────────
   [L6.00b] Vistas de cubetas: cortes (deciles BASE), top categorías y distribución
   DOCSTRING (es-PE)
     dq_deriva_num     : valor numérico x de cada celda (si aplica).
     dq_deriva_cols    : por columna, familia, % numérico y distintos en BASE.
     dq_deriva_cortes  : deciles de la BASE por columna (cortes únicos).
     dq_deriva_topcat  : 20 categorías más frecuentes de la BASE por columna.
     dq_deriva_dist    : por columna y tipo de cubeta (NUM = deciles de la
                         base; CAT = top-20 + '__OTROS__'), conteos BASE y
                         ACTUAL. NULL y no-numéricos van en cubetas propias.
   TOOLTIP ▸ Cómo interpretar / personalizar
     • No devuelven filas. Los deciles se fijan con la BASE (como manda la
       práctica de PSI): la ACTUAL se mide con los mismos cortes.
     • Para cambiar a 20 cubetas o top-50 categorías, editen los literales
       de esta sección (son estructurales, no umbrales).
   ──────────────────────────────────────────────────────────────────────────── */
CREATE OR REPLACE TEMP VIEW dq_deriva_num AS
SELECT d.grupo, d.columna, d.valor, c.familia,
       CASE WHEN c.familia = 'NUMERICO' THEN try_cast(d.valor AS DOUBLE)
            WHEN c.familia = 'FECHA'
              THEN CAST(datediff(try_cast(d.valor AS DATE), DATE'1970-01-01') AS DOUBLE)
            WHEN c.familia = 'TIMESTAMP'
              THEN CAST(unix_seconds(try_cast(d.valor AS TIMESTAMP)) AS DOUBLE) / 86400
            WHEN c.familia = 'TEXTO'
                 AND dq_limpiar(d.valor) RLIKE '^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$'
              THEN try_cast(dq_limpiar(d.valor) AS DOUBLE)
       END AS x
FROM dq_deriva_long d
JOIN dq_columnas c ON c.columna = d.columna;

CREATE OR REPLACE TEMP VIEW dq_deriva_cols AS
SELECT columna, max(familia) AS familia,
       count_if(x IS NOT NULL AND NOT isnan(x)) / NULLIF(count(valor), 0) AS pct_numerico_base,
       count(DISTINCT valor)                                             AS n_distintos_base
FROM dq_deriva_num
WHERE grupo = 'BASE'
GROUP BY columna;

CREATE OR REPLACE TEMP VIEW dq_deriva_cortes AS
SELECT columna,
       array_sort(array_distinct(percentile_approx(x, array(0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9), 10000))) AS cortes
FROM dq_deriva_num
WHERE grupo = 'BASE' AND x IS NOT NULL AND NOT isnan(x)
GROUP BY columna;

CREATE OR REPLACE TEMP VIEW dq_deriva_topcat AS
SELECT columna, valor
FROM (SELECT columna, valor, row_number() OVER (PARTITION BY columna ORDER BY count(*) DESC, valor) AS rn
      FROM dq_deriva_long
      WHERE grupo = 'BASE' AND valor IS NOT NULL
      GROUP BY columna, valor)
WHERE rn <= 20;

CREATE OR REPLACE TEMP VIEW dq_deriva_dist AS
WITH b AS (
  SELECT n.grupo, n.columna,
         CASE WHEN n.valor IS NULL THEN '__NULO__'
              WHEN n.x IS NULL OR isnan(n.x) THEN '__NO_NUMERICO__'
              ELSE concat('D', lpad(CAST(size(filter(k.cortes, c -> n.x > c)) AS STRING), 2, '0'))
         END AS bin_num,
         CASE WHEN n.valor IS NULL THEN '__NULO__'
              WHEN t.valor IS NOT NULL THEN n.valor
              ELSE '__OTROS__'
         END AS bin_cat
  FROM dq_deriva_num n
  LEFT JOIN dq_deriva_cortes k ON k.columna = n.columna
  LEFT JOIN dq_deriva_topcat t ON t.columna = n.columna AND t.valor = n.valor
)
SELECT columna, tipo_bin, bin,
       sum(IF(grupo = 'BASE', 1, 0))   AS n_base,
       sum(IF(grupo = 'ACTUAL', 1, 0)) AS n_actual
FROM b
LATERAL VIEW stack(2, 'NUM', bin_num, 'CAT', bin_cat) s AS tipo_bin, bin
GROUP BY columna, tipo_bin, bin;


/* ────────────────────────────────────────────────────────────────────────────
   [L6.01] PSI y Jensen-Shannon por columna (resumen de estabilidad)
   DOCSTRING (es-PE)
     Para cada columna elige cubetas NUM (deciles) si es numérica con > 10
     valores distintos, o CAT (top-20) en otro caso, y calcula:
       PSI = Σ (p_act - p_base) · ln(p_act / p_base)   (piso de 1e-4 por cubeta)
       JS  = ½ Σ p_b ln(p_b/m) + ½ Σ p_a ln(p_a/m), m = (p_a+p_b)/2, en bits (0-1).
     Incluye n de cada grupo, % nulos base vs actual, la cubeta que más
     contribuye y la clasificación.
   TOOLTIP ▸ Cómo leer e interpretar
     • PSI < 0.10 ESTABLE · 0.10-0.25 MODERADO (vigilar) · > 0.25
       SIGNIFICATIVO (la población cambió: re-evaluar/re-entrenar el modelo,
       o hay un problema de datos: nueva fuente, cambio de definición).
     • Si cubeta_mayor_contribucion = '__NULO__' la deriva es de COMPLETITUD
       (aumentaron los faltantes), típico de un campo que dejó de llenarse.
     • JS es más estable que PSI con cubetas casi vacías; úsenlo para
       comparar columnas entre sí.
     • Ojo: con muestras chicas (< 1000 por grupo) el PSI se infla por azar.
     • Si el segmento es temporal, las columnas de tiempo (fechas de evento)
       e IDs secuenciales SIEMPRE derivan por construcción, igual que la
       propia columna de segmento: ignórenlas o exclúyanlas.
     • Fechas y timestamps se comparan como número de días (cubetas NUM).
   ──────────────────────────────────────────────────────────────────────────── */
WITH elec AS (
  SELECT columna,
         IF((familia IN ('NUMERICO', 'FECHA', 'TIMESTAMP') OR (familia = 'TEXTO' AND pct_numerico_base >= dq_umbral_tipo_dominante))
            AND n_distintos_base > 10, 'NUM', 'CAT') AS tipo_bin
  FROM dq_deriva_cols
), d AS (
  SELECT x.columna, x.tipo_bin, x.bin, x.n_base, x.n_actual,
         sum(x.n_base) OVER (PARTITION BY x.columna)   AS tot_base,
         sum(x.n_actual) OVER (PARTITION BY x.columna) AS tot_actual
  FROM dq_deriva_dist x
  JOIN elec e ON e.columna = x.columna AND e.tipo_bin = x.tipo_bin
), p AS (
  SELECT *,
         greatest(n_base / NULLIF(tot_base, 0), 0.0001)     AS pb,
         greatest(n_actual / NULLIF(tot_actual, 0), 0.0001) AS pa
  FROM d
), c AS (
  SELECT *,
         (pa - pb) * ln(pa / pb)                                                    AS contrib_psi,
         0.5 * pb * log2(pb / ((pa + pb) / 2)) + 0.5 * pa * log2(pa / ((pa + pb) / 2)) AS contrib_js
  FROM p
)
SELECT columna, max(tipo_bin) AS tipo_cubeta,
       max(tot_base) AS n_base, max(tot_actual) AS n_actual, count(*) AS n_cubetas,
       round(sum(contrib_psi), 4)                                        AS psi,
       round(sum(contrib_js), 4)                                         AS jensen_shannon,
       round(max(IF(bin = '__NULO__', n_base, 0)) / max(tot_base), 4)    AS pct_nulos_base,
       round(max(IF(bin = '__NULO__', n_actual, 0)) / max(tot_actual), 4) AS pct_nulos_actual,
       max_by(bin, contrib_psi)                                          AS cubeta_mayor_contribucion,
       CASE WHEN max(tot_base) = 0 OR max(tot_actual) = 0 THEN 'SIN_DATOS_EN_UN_GRUPO'
            WHEN sum(contrib_psi) >= dq_umbral_psi_alto THEN 'SIGNIFICATIVO'
            WHEN sum(contrib_psi) >= dq_umbral_psi_moderado THEN 'MODERADO'
            ELSE 'ESTABLE' END                                           AS clasificacion
FROM c
GROUP BY columna
ORDER BY psi DESC;


/* ────────────────────────────────────────────────────────────────────────────
   [L6.02] Detalle por cubeta de las columnas con deriva (PSI ≥ moderado)
   DOCSTRING (es-PE)
     Para columnas con PSI ≥ dq_umbral_psi_moderado muestra cada cubeta con
     % base, % actual, diferencia y contribución al PSI, ordenadas por
     contribución. Para NUM incluye el rango de la cubeta.
   TOOLTIP ▸ Cómo leer e interpretar
     • Busquen el "cómo" de la deriva: ¿se movió la cola alta (D09)? ¿subieron
       los nulos? ¿apareció una categoría que absorbe a otra (renombrado)?
     • Grafiquen pct_base vs pct_actual por cubeta como barras agrupadas.
   ──────────────────────────────────────────────────────────────────────────── */
WITH elec AS (
  SELECT columna,
         IF((familia IN ('NUMERICO', 'FECHA', 'TIMESTAMP') OR (familia = 'TEXTO' AND pct_numerico_base >= dq_umbral_tipo_dominante))
            AND n_distintos_base > 10, 'NUM', 'CAT') AS tipo_bin
  FROM dq_deriva_cols
), d AS (
  SELECT x.*, sum(x.n_base) OVER (PARTITION BY x.columna) AS tot_base,
         sum(x.n_actual) OVER (PARTITION BY x.columna)    AS tot_actual
  FROM dq_deriva_dist x
  JOIN elec e ON e.columna = x.columna AND e.tipo_bin = x.tipo_bin
), c AS (
  SELECT *, greatest(n_base / NULLIF(tot_base, 0), 0.0001) AS pb,
         greatest(n_actual / NULLIF(tot_actual, 0), 0.0001) AS pa
  FROM d
), psi AS (
  SELECT columna, sum((pa - pb) * ln(pa / pb)) AS psi FROM c GROUP BY columna
)
SELECT c.columna, round(psi.psi, 4) AS psi_columna, c.tipo_bin, c.bin,
       CASE WHEN c.tipo_bin = 'NUM' AND c.bin RLIKE '^D[0-9]{2}$' THEN
              concat('(',
                     CASE WHEN CAST(substr(c.bin, 2) AS INT) = 0 THEN '-∞'
                          ELSE CAST(try_element_at(k.cortes, CAST(substr(c.bin, 2) AS INT)) AS STRING) END,
                     ', ',
                     coalesce(CAST(try_element_at(k.cortes, CAST(substr(c.bin, 2) AS INT) + 1) AS STRING), '+∞'), ']')
       END AS rango_cubeta,
       c.n_base, c.n_actual,
       round(c.n_base / NULLIF(c.tot_base, 0), 4)    AS pct_base,
       round(c.n_actual / NULLIF(c.tot_actual, 0), 4) AS pct_actual,
       round(c.n_actual / NULLIF(c.tot_actual, 0) - c.n_base / NULLIF(c.tot_base, 0), 4) AS diferencia,
       round((c.pa - c.pb) * ln(c.pa / c.pb), 5)     AS contribucion_psi
FROM c
JOIN psi ON psi.columna = c.columna
LEFT JOIN dq_deriva_cortes k ON k.columna = c.columna
WHERE psi.psi >= dq_umbral_psi_moderado
ORDER BY psi.psi DESC, c.columna, contribucion_psi DESC;


/* ────────────────────────────────────────────────────────────────────────────
   [L6.03] Kolmogorov-Smirnov (KS) para columnas numéricas
   DOCSTRING (es-PE)
     Calcula D = max |F_base(x) - F_actual(x)| sobre las distribuciones
     acumuladas empíricas exactas (de la muestra) y el valor crítico
     asintótico al 5%: 1.358 · sqrt((n+m)/(n·m)).
   TOOLTIP ▸ Cómo leer e interpretar
     • D es el TAMAÑO del cambio (0 = idénticas, 1 = disjuntas). Con muestras
       grandes casi todo sale "significativo": prioricen por D (p.ej. > 0.1).
     • x_en_max_diferencia indica en qué valor las distribuciones se separan
       más (dónde está el corrimiento).
   ──────────────────────────────────────────────────────────────────────────── */
WITH elec AS (
  SELECT columna FROM dq_deriva_cols
  WHERE (familia IN ('NUMERICO', 'FECHA', 'TIMESTAMP') OR (familia = 'TEXTO' AND pct_numerico_base >= dq_umbral_tipo_dominante))
    AND n_distintos_base > 10
), v AS (
  SELECT n.columna, n.x,
         sum(IF(n.grupo = 'BASE', 1, 0))   AS nb,
         sum(IF(n.grupo = 'ACTUAL', 1, 0)) AS na
  FROM dq_deriva_num n JOIN elec e ON e.columna = n.columna
  WHERE n.x IS NOT NULL AND NOT isnan(n.x)
  GROUP BY n.columna, n.x
), f AS (
  SELECT columna, x,
         sum(nb) OVER (PARTITION BY columna ORDER BY x ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
           / sum(nb) OVER (PARTITION BY columna) AS fb,
         sum(na) OVER (PARTITION BY columna ORDER BY x ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
           / sum(na) OVER (PARTITION BY columna) AS fa,
         sum(nb) OVER (PARTITION BY columna) AS n_base,
         sum(na) OVER (PARTITION BY columna) AS n_actual
  FROM v
)
SELECT columna, max(n_base) AS n_base, max(n_actual) AS n_actual,
       round(max(abs(fb - fa)), 4)                                                   AS ks_d,
       max_by(x, abs(fb - fa))                                                       AS x_en_max_diferencia,
       round(1.358 * sqrt((max(n_base) + max(n_actual)) / (max(n_base) * max(n_actual))), 4) AS critico_5pct,
       IF(max(abs(fb - fa)) > 1.358 * sqrt((max(n_base) + max(n_actual)) / (max(n_base) * max(n_actual))),
          'DISTINTAS (5%)', 'SIN_EVIDENCIA')                                         AS resultado
FROM f
WHERE n_base > 0 AND n_actual > 0
GROUP BY columna
ORDER BY ks_d DESC;


/* ────────────────────────────────────────────────────────────────────────────
   [L6.04] Deltas de métricas y categorías nuevas (resumen tipo "skew")
   DOCSTRING (es-PE)
     Por columna, compara BASE vs ACTUAL: % nulos, distintos, media y
     desviación (numéricas) con la diferencia de medias estandarizada
     SMD = (m_a - m_b) / sqrt((s_a² + s_b²)/2), y % de filas de ACTUAL con
     categorías que NO existen en BASE.
   TOOLTIP ▸ Cómo leer e interpretar
     • |SMD| > 0.1 diferencia relevante; > 0.25 importante (criterio usado
       en balance de covariables y monitoreo de modelos).
     • pct_actual_categorias_nuevas > 0 en una variable de un modelo ⇒ el
       encoder verá categorías desconocidas en producción ("training-serving
       skew" de TFDV): definan cómo se manejan.
     • delta_pct_nulos > 0.05 ⇒ degradación de completitud entre periodos.
   ──────────────────────────────────────────────────────────────────────────── */
WITH m AS (
  SELECT columna,
         count_if(grupo = 'BASE')                                         AS n_base,
         count_if(grupo = 'ACTUAL')                                       AS n_actual,
         count_if(grupo = 'BASE' AND valor IS NULL) / NULLIF(count_if(grupo = 'BASE'), 0)     AS pct_nulos_base,
         count_if(grupo = 'ACTUAL' AND valor IS NULL) / NULLIF(count_if(grupo = 'ACTUAL'), 0) AS pct_nulos_actual,
         count(DISTINCT IF(grupo = 'BASE', valor, NULL))                  AS distintos_base,
         count(DISTINCT IF(grupo = 'ACTUAL', valor, NULL))                AS distintos_actual,
         avg(IF(grupo = 'BASE' AND NOT isnan(x), x, NULL))                AS media_base,
         avg(IF(grupo = 'ACTUAL' AND NOT isnan(x), x, NULL))              AS media_actual,
         stddev_samp(IF(grupo = 'BASE' AND NOT isnan(x), x, NULL))        AS desv_base,
         stddev_samp(IF(grupo = 'ACTUAL' AND NOT isnan(x), x, NULL))      AS desv_actual
  FROM dq_deriva_num
  GROUP BY columna
), nuevas AS (
  SELECT a.columna,
         count(*)                                AS n_actual_validos,
         count_if(b.valor IS NULL)               AS n_actual_categoria_nueva,
         count(DISTINCT IF(b.valor IS NULL, a.valor, NULL)) AS n_categorias_nuevas
  FROM (SELECT columna, valor FROM dq_deriva_long WHERE grupo = 'ACTUAL' AND valor IS NOT NULL) a
  LEFT JOIN (SELECT DISTINCT columna, valor FROM dq_deriva_long WHERE grupo = 'BASE' AND valor IS NOT NULL) b
    ON b.columna = a.columna AND b.valor = a.valor
  GROUP BY a.columna
)
SELECT m.columna, c.familia, m.n_base, m.n_actual,
       round(m.pct_nulos_base, 4) AS pct_nulos_base, round(m.pct_nulos_actual, 4) AS pct_nulos_actual,
       round(m.pct_nulos_actual - m.pct_nulos_base, 4)                                          AS delta_pct_nulos,
       m.distintos_base, m.distintos_actual,
       round(m.media_base, 4) AS media_base, round(m.media_actual, 4) AS media_actual,
       round((m.media_actual - m.media_base) / NULLIF(sqrt((power(m.desv_base, 2) + power(m.desv_actual, 2)) / 2), 0), 4) AS smd,
       IF(es_cat, n.n_categorias_nuevas, NULL)                                                  AS n_categorias_nuevas,
       IF(es_cat, round(n.n_actual_categoria_nueva / NULLIF(n.n_actual_validos, 0), 4), NULL)   AS pct_actual_categorias_nuevas,
       filter(array(
         IF(abs(m.pct_nulos_actual - m.pct_nulos_base) > 0.05, 'CAMBIO_COMPLETITUD', NULL),
         IF(abs((m.media_actual - m.media_base) / NULLIF(sqrt((power(m.desv_base, 2) + power(m.desv_actual, 2)) / 2), 0)) > 0.1,
            'CAMBIO_DE_MEDIA (SMD>0.1)', NULL),
         IF(es_cat AND n.n_actual_categoria_nueva / NULLIF(n.n_actual_validos, 0) > 0.01, 'CATEGORIAS_NUEVAS', NULL)
       ), x -> x IS NOT NULL) AS alertas
FROM m
JOIN dq_columnas c   ON c.columna = m.columna
JOIN (SELECT columna,
             familia IN ('TEXTO', 'BOOLEANO') AND coalesce(pct_numerico_base, 0) < dq_umbral_tipo_dominante
             AND n_distintos_base <= dq_max_cardinalidad_cat * 20 AS es_cat
      FROM dq_deriva_cols) dc ON dc.columna = m.columna
LEFT JOIN nuevas n   ON n.columna = m.columna
ORDER BY size(alertas) DESC, m.columna;


/* ────────────────────────────────────────────────────────────────────────────
   [L6.05] PSI de cada segmento contra la BASE (serie de monitoreo)
   DOCSTRING (es-PE)
     Usa TODOS los valores de dq_expr_segmento presentes en la muestra (p.ej.
     cada mes) y calcula el PSI de cada columna de cada segmento contra la
     distribución BASE (mismas cubetas que L6.01). Ideal para graficar la
     estabilidad mes a mes.
   TOOLTIP ▸ Cómo leer e interpretar
     • Grafiquen como líneas: X = segmento, Y = psi, serie = columna, con
       líneas de referencia en 0.10 y 0.25.
     • Un salto en un segmento puntual ⇒ incidente de datos de ese periodo;
       una subida gradual ⇒ deriva real de la población.
     • Requiere dq_expr_segmento; en modo FUENTES sólo tiene sentido si la
       tabla objetivo también tiene segmentos.
   ──────────────────────────────────────────────────────────────────────────── */
WITH elec AS (
  SELECT columna,
         IF((familia IN ('NUMERICO', 'FECHA', 'TIMESTAMP') OR (familia = 'TEXTO' AND pct_numerico_base >= dq_umbral_tipo_dominante))
            AND n_distintos_base > 10, 'NUM', 'CAT') AS tipo_bin
  FROM dq_deriva_cols
), seg0 AS (
  SELECT l._dq_segmento AS segmento, l.columna, l.valor,
         CASE WHEN co.familia = 'NUMERICO' THEN try_cast(l.valor AS DOUBLE)
              WHEN co.familia = 'FECHA'
                THEN CAST(datediff(try_cast(l.valor AS DATE), DATE'1970-01-01') AS DOUBLE)
              WHEN co.familia = 'TIMESTAMP'
                THEN CAST(unix_seconds(try_cast(l.valor AS TIMESTAMP)) AS DOUBLE) / 86400
              WHEN co.familia = 'TEXTO'
                   AND dq_limpiar(l.valor) RLIKE '^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$'
                THEN try_cast(dq_limpiar(l.valor) AS DOUBLE)
         END AS x
  FROM dq_long l
  JOIN dq_columnas co ON co.columna = l.columna
  WHERE l._dq_segmento IS NOT NULL
), seg AS (
  SELECT s.segmento, s.columna,
         CASE WHEN s.valor IS NULL THEN '__NULO__'
              WHEN e.tipo_bin = 'NUM' THEN
                CASE WHEN s.x IS NULL OR isnan(s.x) THEN '__NO_NUMERICO__'
                     ELSE concat('D', lpad(CAST(size(filter(k.cortes, c -> s.x > c)) AS STRING), 2, '0')) END
              WHEN t.valor IS NOT NULL THEN s.valor
              ELSE '__OTROS__' END AS bin
  FROM seg0 s
  JOIN elec e ON e.columna = s.columna
  LEFT JOIN dq_deriva_cortes k ON k.columna = s.columna
  LEFT JOIN dq_deriva_topcat t ON t.columna = s.columna AND t.valor = s.valor
), dist AS (
  SELECT segmento, columna, bin, count(*) AS n FROM seg GROUP BY segmento, columna, bin
), base AS (
  SELECT d.columna, d.bin, d.n_base
  FROM dq_deriva_dist d JOIN elec e ON e.columna = d.columna AND e.tipo_bin = d.tipo_bin
), bs AS (
  SELECT s.segmento, b.columna, b.bin, b.n_base
  FROM (SELECT DISTINCT segmento, columna FROM dist) s
  JOIN base b ON b.columna = s.columna
), j AS (
  SELECT coalesce(bs.segmento, d.segmento) AS segmento,
         coalesce(bs.columna, d.columna)   AS columna,
         coalesce(bs.bin, d.bin)           AS bin,
         coalesce(bs.n_base, 0)            AS nb,
         coalesce(d.n, 0)                  AS na
  FROM bs FULL OUTER JOIN dist d
    ON d.segmento = bs.segmento AND d.columna = bs.columna AND d.bin = bs.bin
), p AS (
  SELECT *,
         greatest(nb / NULLIF(sum(nb) OVER (PARTITION BY segmento, columna), 0), 0.0001) AS pb,
         greatest(na / NULLIF(sum(na) OVER (PARTITION BY segmento, columna), 0), 0.0001) AS pa
  FROM j
)
SELECT segmento, columna,
       round(sum((pa - pb) * ln(pa / pb)), 4) AS psi_vs_base,
       sum(na)                                AS n_segmento,
       CASE WHEN sum((pa - pb) * ln(pa / pb)) >= dq_umbral_psi_alto THEN 'SIGNIFICATIVO'
            WHEN sum((pa - pb) * ln(pa / pb)) >= dq_umbral_psi_moderado THEN 'MODERADO'
            ELSE 'ESTABLE' END                AS clasificacion
FROM p
GROUP BY segmento, columna
ORDER BY columna, segmento;


/* ────────────────────────────────────────────────────────────────────────────
   [L6.06] Persistir PSI por columna (opcional)
   DOCSTRING (es-PE)
     Guarda el PSI de cada columna (BASE vs ACTUAL) en dq_metricas, con el
     detalle del par comparado en valor_texto.
   TOOLTIP ▸ Cómo interpretar
     • Con corridas mensuales obtienen la historia de estabilidad de cada
       variable: insumo directo para el monitoreo de modelos (SBS/Basilea
       exigen seguimiento de estabilidad de poblaciones en modelos de riesgo).
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_sql = IF(
  dq_esquema_trabajo = '',
  concat('SELECT ', dq_lit('persistencia desactivada (dq_esquema_trabajo vacío)'), ' AS info'),
  concat('INSERT INTO ', dq_esquema_trabajo, '.dq_metricas ',
         'WITH elec AS (SELECT columna, IF((familia = ', dq_lit('NUMERICO'), ' OR (familia = ', dq_lit('TEXTO'),
         ' AND pct_numerico_base >= ', CAST(dq_umbral_tipo_dominante AS STRING), ') OR familia IN (', dq_lit('FECHA'), ', ', dq_lit('TIMESTAMP'), ')) AND n_distintos_base > 10, ',
         dq_lit('NUM'), ', ', dq_lit('CAT'), ') AS tipo_bin FROM dq_deriva_cols), ',
         'd AS (SELECT x.*, sum(x.n_base) OVER (PARTITION BY x.columna) AS tb, sum(x.n_actual) OVER (PARTITION BY x.columna) AS ta ',
         'FROM dq_deriva_dist x JOIN elec e ON e.columna = x.columna AND e.tipo_bin = x.tipo_bin) ',
         'SELECT ', dq_lit(dq_id_corrida), ', current_timestamp(), ', dq_lit(dq_tabla_fq), ', columna, ',
         dq_lit('L6'), ', ', dq_lit('psi'), ', ',
         'sum((greatest(n_actual / NULLIF(ta, 0), 0.0001) - greatest(n_base / NULLIF(tb, 0), 0.0001)) * ',
         'ln(greatest(n_actual / NULLIF(ta, 0), 0.0001) / greatest(n_base / NULLIF(tb, 0), 0.0001))), ',
         dq_lit(concat(dq_modo_deriva, ': ', dq_segmento_base, dq_fuente_base, ' vs ', dq_segmento_actual, dq_fuente_actual)),
         ' FROM d GROUP BY columna'));
EXECUTE IMMEDIATE dq_sql;
