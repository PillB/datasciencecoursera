/* ════════════════════════════════════════════════════════════════════════════
   ARCHIVO 05 · CAPA 3 — ESTADÍSTICA DESCRIPTIVA Y ANOMALÍAS NUMÉRICAS
   ────────────────────────────────────────────────────────────────────────────
   DOCSTRING (es-PE)
     EDA cuantitativo de cada columna numérica (declarada numérica, o texto
     que en ≥ dq_umbral_tipo_dominante de los casos es un número de
     magnitud — se excluyen códigos como DNI/RUC/teléfono):
       • tendencia central y dispersión: media, mediana, desviación estándar,
         VARIANZA muestral y poblacional, coeficiente de variación, IQR;
       • forma: asimetría (skewness), curtosis en exceso, percentiles 1-99;
       • atípicos: cercas de Tukey (1.5 y 3 IQR) y z-score robusto con MAD
         (Iglewicz y Hoaglin, umbral 3.5);
       • valores especiales: NaN, ±Infinito, ceros, negativos, centinelas
         (-1, -999, 9999...), "heaping" (amontonamiento en múltiplos de 5/10)
         y conformidad con la ley de Benford (Nigrini) para montos;
       • rangos de dominio esperados según el nombre (edad, mes, nota 0-20...).
     Requisitos: archivos 00 y 02.
   TOOLTIP ▸ Cómo usar
     • L3.01 es el resumen; L3.02-L3.06 profundizan. L3.05 se grafica como
       histograma (barras) en el editor de Databricks.
     • Personalización futura: cuando conozcan el dominio de cada columna,
       llévenlo a reglas explícitas en la capa 8 (rango, precisión, signo) y
       usen esta capa para monitorear deriva de la distribución.
   ════════════════════════════════════════════════════════════════════════════ */


/* ────────────────────────────────────────────────────────────────────────────
   [L3.00] Vistas base dq_num (valores numéricos) y dq_l3_cols (candidatas)
   DOCSTRING (es-PE)
     dq_num: una fila por celda de columnas NUMERICO o TEXTO con el valor
       convertido a DOUBLE (x), y banderas es_nan / es_inf. En texto sólo se
       convierten valores con forma de número estándar (regex) para no
       aceptar '1d' o '0x1A' que Java/Spark sí castean.
     dq_l3_cols: por columna, % de valores numéricos, % con decimales, si
       hay ceros a la izquierda y si el nombre sugiere magnitud. Con esto las
       consultas deciden qué columnas texto se tratan como numéricas.
   TOOLTIP ▸ Cómo interpretar
     • No devuelven filas. x es NULL para NaN/Infinito (se cuentan aparte),
       así no contaminan medias ni varianzas.
   ──────────────────────────────────────────────────────────────────────────── */
CREATE OR REPLACE TEMP VIEW dq_num AS
WITH b AS (
  SELECT l.columna, c.familia, c.tipo_declarado, l.valor, l._dq_segmento, l._dq_objetivo,
         CASE
           WHEN c.familia = 'NUMERICO' THEN try_cast(l.valor AS DOUBLE)
           WHEN c.familia = 'TEXTO'
                AND dq_limpiar(l.valor) RLIKE '^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$'
             THEN try_cast(dq_limpiar(l.valor) AS DOUBLE)
         END AS x_crudo
  FROM dq_long l
  JOIN dq_columnas c ON c.columna = l.columna
  WHERE c.familia IN ('NUMERICO', 'TEXTO')
)
SELECT columna, familia, tipo_declarado, valor, _dq_segmento, _dq_objetivo,
       coalesce(isnan(x_crudo), false)                                         AS es_nan,
       coalesce(abs(x_crudo) = CAST('Infinity' AS DOUBLE), false)              AS es_inf,
       CASE WHEN isnan(x_crudo) OR abs(x_crudo) = CAST('Infinity' AS DOUBLE) THEN NULL
            ELSE x_crudo END                                                   AS x
FROM b;

CREATE OR REPLACE TEMP VIEW dq_l3_cols AS
SELECT columna, familia, tipo_declarado,
       count(valor)                                                            AS n_no_nulos,
       count(x)                                                                AS n_numericos,
       count(DISTINCT x)                                                       AS n_distintos,
       count(x) / NULLIF(count_if(valor IS NOT NULL AND NOT dq_es_placeholder(valor)
                                  AND dq_limpiar(valor) <> ''), 0)             AS pct_numerico,
       count_if(x IS NOT NULL AND valor RLIKE '[.]') / NULLIF(count(x), 0)     AS pct_con_decimales,
       count_if(x IS NOT NULL AND dq_limpiar(valor) RLIKE '^0[0-9]')           AS n_ceros_izq,
       max(lower(columna) RLIKE '(^|_)(monto|importe|precio|saldo|total|amount|amt|costo|ingreso|sueldo|salario|pago|deuda|tasa|rate|cantidad|cant|qty|edad|peso|talla|stock|unidades|score|puntaje|nota|dias|meses|anios|plazo|cuota)(_|$)') AS nombre_magnitud,
       max(lower(columna) RLIKE '(^|_)(id|cod|codigo|code|dni|ruc|ubigeo|telefono|celular|cuenta|cci|nro|numero|num|doc|documento|postal|zip)(_|$)') AS nombre_codigo
FROM dq_num
GROUP BY columna, familia, tipo_declarado;


/* ────────────────────────────────────────────────────────────────────────────
   [L3.01] Estadística descriptiva por columna numérica (con alertas)
   DOCSTRING (es-PE)
     Por columna numérica: conteos (válidos, NaN, Inf, ceros, negativos),
     mínimo, percentiles 1/5/25/50/75/95/99, máximo, media, desviación
     estándar, varianza muestral y poblacional, coeficiente de variación,
     asimetría, curtosis (en exceso), IQR, % enteros y suma.
   TOOLTIP ▸ Cómo leer e interpretar
     • media vs mediana: si difieren mucho (|media-mediana| > 0.5·desv) la
       distribución está sesgada o hay atípicos; reporten mediana y P95.
     • asimetria > 2 (o < -2) ⇒ ASIMETRIA_ALTA: típico de montos/ingresos
       (log-normal). Para modelos lineales consideren log1p.
     • curtosis_exceso > 7 ⇒ COLAS_PESADAS: muchos extremos; la media y la
       varianza son inestables.
     • cv = desv / |media| > 1 ⇒ dispersión muy alta (o media cerca de 0).
     • INFLADA_EN_CEROS (≥ 50% ceros): ¿cero real o "no informado"?
     • NAN_O_INFINITO: viene de divisiones 0/0 o x/0 aguas arriba.
     • POSIBLE_CODIGO: es "número" pero el nombre dice código/ID: no
       interpreten medias ni varianzas (no tienen sentido).
     • Ojo: los percentiles son aproximados (percentile_approx, error relativo
       ~1/10000 del rango de rangos); suficiente para EDA.
   ──────────────────────────────────────────────────────────────────────────── */
WITH sel AS (
  SELECT * FROM dq_l3_cols
  WHERE familia = 'NUMERICO'
     OR (familia = 'TEXTO' AND pct_numerico >= dq_umbral_tipo_dominante AND n_ceros_izq = 0
         AND NOT nombre_codigo AND (pct_con_decimales > 0 OR nombre_magnitud))
), e AS (
  SELECT n.columna,
         count(n.valor)                                         AS n_no_nulos,
         count(n.x)                                             AS n_validos,
         count_if(n.es_nan)                                     AS n_nan,
         count_if(n.es_inf)                                     AS n_inf,
         min(n.x)                                               AS minimo,
         max(n.x)                                               AS maximo,
         avg(n.x)                                               AS media,
         stddev_samp(n.x)                                       AS desv_est,
         var_samp(n.x)                                          AS varianza_muestral,
         var_pop(n.x)                                           AS varianza_poblacional,
         skewness(n.x)                                          AS asimetria,
         kurtosis(n.x)                                          AS curtosis_exceso,
         percentile_approx(n.x, array(0.01, 0.05, 0.25, 0.5, 0.75, 0.95, 0.99), 10000) AS p,
         count_if(n.x = 0)                                      AS n_ceros,
         count_if(n.x < 0)                                      AS n_negativos,
         count_if(n.x % 1 = 0)                                  AS n_enteros,
         sum(n.x)                                               AS suma
  FROM dq_num n
  JOIN sel s ON s.columna = n.columna
  GROUP BY n.columna
)
SELECT c.ordinal, e.columna, s.familia, s.tipo_declarado,
       e.n_no_nulos, e.n_validos, e.n_nan, e.n_inf,
       round(s.pct_numerico, 4)                                AS pct_numerico,
       e.minimo, e.p[0] AS p01, e.p[1] AS p05, e.p[2] AS p25, e.p[3] AS mediana,
       e.p[4] AS p75, e.p[5] AS p95, e.p[6] AS p99, e.maximo,
       round(e.media, 6)                                       AS media,
       round(e.desv_est, 6)                                    AS desv_est,
       round(e.varianza_muestral, 6)                           AS varianza_muestral,
       round(e.varianza_poblacional, 6)                        AS varianza_poblacional,
       round(e.desv_est / NULLIF(abs(e.media), 0), 4)          AS coef_variacion,
       round(IF(e.desv_est > 0, e.asimetria, NULL), 4)         AS asimetria,
       round(IF(e.desv_est > 0, e.curtosis_exceso, NULL), 4)   AS curtosis_exceso,
       e.p[4] - e.p[2]                                         AS iqr,
       round(e.n_ceros / NULLIF(e.n_validos, 0), 4)            AS pct_ceros,
       round(e.n_negativos / NULLIF(e.n_validos, 0), 4)        AS pct_negativos,
       round(e.n_enteros / NULLIF(e.n_validos, 0), 4)          AS pct_enteros,
       e.suma,
       filter(array(
         IF(e.n_validos = 0, 'SIN_VALORES_NUMERICOS', NULL),
         IF(e.n_nan + e.n_inf > 0, 'NAN_O_INFINITO', NULL),
         IF(e.desv_est = 0, 'VARIANZA_CERO', NULL),
         IF(abs(e.asimetria) > 2 AND e.desv_est > 0, 'ASIMETRIA_ALTA', NULL),
         IF(e.curtosis_exceso > 7 AND e.desv_est > 0, 'COLAS_PESADAS', NULL),
         IF(e.desv_est / NULLIF(abs(e.media), 0) > 1, 'CV_ALTO', NULL),
         IF(abs(e.media - e.p[3]) > 0.5 * e.desv_est, 'MEDIA_LEJOS_DE_MEDIANA', NULL),
         IF(e.n_ceros / NULLIF(e.n_validos, 0) >= 0.5, 'INFLADA_EN_CEROS', NULL),
         IF(e.n_negativos > 0 AND s.nombre_magnitud
            AND NOT lower(e.columna) RLIKE '(saldo|tasa|rate|variacion|delta|diferencia|ajuste)',
            'NEGATIVOS_EN_MAGNITUD', NULL),
         IF(s.nombre_codigo, 'POSIBLE_CODIGO (no interpretar estadísticos)', NULL)
       ), x -> x IS NOT NULL)                                 AS alertas
FROM e
JOIN dq_l3_cols s  ON s.columna = e.columna
JOIN dq_columnas c ON c.columna = e.columna
ORDER BY size(alertas) DESC, c.ordinal;


/* ────────────────────────────────────────────────────────────────────────────
   [L3.02] Valores atípicos: Tukey (IQR) y z-score robusto (MAD)
   DOCSTRING (es-PE)
     Por columna numérica calcula las cercas de Tukey (Q1 - k·IQR, Q3 + k·IQR
     con k = 1.5 "leve" y k = 3 "extremo") y el z-score robusto modificado
     z = 0.6745·(x - mediana)/MAD (si MAD = 0 usa 1.2533·desvío medio
     absoluto). Cuenta atípicos por cada método y muestra los 5 valores más
     bajos y más altos.
   TOOLTIP ▸ Cómo leer e interpretar
     • Tukey y MAD son robustos (no se dejan "jalar" por los mismos atípicos,
       a diferencia del z-score clásico con media y desviación).
     • pct_atipicos_extremos > 1% en montos ⇒ revisen unidades (soles vs
       céntimos, miles), cargas duplicadas o centinelas (9999999.99).
     • En distribuciones muy asimétricas (montos), apliquen el análisis sobre
       log10(x) o usen sólo el criterio extremo (k = 3).
     • Un atípico NO es automáticamente un error: valídenlo con negocio
       (un cliente corporativo puede tener un ingreso 100 veces mayor).
     • Se excluyen columnas binarias/constantes (≤ 2 valores distintos) y
       las que por nombre son códigos (id, dni...): ahí "atípico" no aplica.
   ──────────────────────────────────────────────────────────────────────────── */
WITH sel AS (
  SELECT * FROM dq_l3_cols
  WHERE (familia = 'NUMERICO'
         OR (familia = 'TEXTO' AND pct_numerico >= dq_umbral_tipo_dominante AND n_ceros_izq = 0
             AND (pct_con_decimales > 0 OR nombre_magnitud)))
    AND NOT nombre_codigo AND n_distintos > 2
), q AS (
  SELECT n.columna,
         percentile_approx(n.x, array(0.25, 0.5, 0.75), 10000) AS p,
         avg(n.x) AS media
  FROM dq_num n JOIN sel s ON s.columna = n.columna
  WHERE n.x IS NOT NULL
  GROUP BY n.columna
), d AS (
  SELECT n.columna, n.x, q.p[0] AS q1, q.p[1] AS mediana, q.p[2] AS q3,
         abs(n.x - q.p[1]) AS desv_abs
  FROM dq_num n JOIN q ON q.columna = n.columna
  WHERE n.x IS NOT NULL
), mad AS (
  SELECT columna,
         percentile_approx(desv_abs, 0.5, 10000) AS mad,
         avg(desv_abs)                           AS desv_media_abs
  FROM d GROUP BY columna
), z AS (
  SELECT d.*, m.mad, m.desv_media_abs,
         d.q3 - d.q1 AS iqr,
         CASE WHEN m.mad > 0 THEN 0.6745 * (d.x - d.mediana) / m.mad
              WHEN m.desv_media_abs > 0 THEN (d.x - d.mediana) / (1.253314 * m.desv_media_abs)
         END AS z_robusto
  FROM d JOIN mad m ON m.columna = d.columna
)
SELECT columna,
       count(*)                                                                  AS n_validos,
       max(q1) AS q1, max(mediana) AS mediana, max(q3) AS q3, max(iqr) AS iqr, max(mad) AS mad,
       max(q1) - 1.5 * max(iqr)                                                  AS cerca_inferior_1_5,
       max(q3) + 1.5 * max(iqr)                                                  AS cerca_superior_1_5,
       count_if(x < q1 - 1.5 * iqr OR x > q3 + 1.5 * iqr)                        AS n_atipicos_leves,
       count_if(x < q1 - 3 * iqr OR x > q3 + 3 * iqr)                            AS n_atipicos_extremos,
       round(count_if(x < q1 - 3 * iqr OR x > q3 + 3 * iqr) / count(*), 5)       AS pct_atipicos_extremos,
       count_if(abs(z_robusto) > dq_umbral_z_robusto)                            AS n_atipicos_mad,
       round(count_if(abs(z_robusto) > dq_umbral_z_robusto) / count(*), 5)       AS pct_atipicos_mad,
       slice(array_sort(collect_set(x)), 1, 5)                                   AS cinco_mas_bajos,
       slice(sort_array(collect_set(x), false), 1, 5)                            AS cinco_mas_altos
FROM z
GROUP BY columna
ORDER BY pct_atipicos_mad DESC;


/* ────────────────────────────────────────────────────────────────────────────
   [L3.03] Centinelas, amontonamiento (heaping) y preferencia de dígitos
   DOCSTRING (es-PE)
     Por columna numérica: cuántos valores son centinelas típicos (-1, -9,
     -99, -999, -9999, 99, 999, 9999, 99999, 999999, 9999999, 9999999.99,
     1e9...), el centinela más frecuente, % de múltiplos de 5, 10 y 100 entre
     los enteros, y el estadístico chi-cuadrado del último dígito (para
     columnas enteras con ≥ 100 valores y rango ≥ 100).
   TOOLTIP ▸ Cómo leer e interpretar
     • Centinelas = "nulos mágicos" de sistemas legados: si se promedian
       destruyen la media (un -999 en edades). Conviértanlos a NULL.
     • Heaping: si pct_multiplos_5 ≫ 20% (lo esperado al azar) hay redondeo
       humano (edades "50", montos "1000"): dato auto-reportado o estimado.
     • chi2_ultimo_digito > 16.92 (gl = 9, α = 5%) ⇒ los últimos dígitos NO
       son uniformes: redondeo, imputación o (en auditoría) manipulación.
   ──────────────────────────────────────────────────────────────────────────── */
WITH sel AS (
  SELECT * FROM dq_l3_cols
  WHERE (familia = 'NUMERICO'
         OR (familia = 'TEXTO' AND pct_numerico >= dq_umbral_tipo_dominante AND n_ceros_izq = 0
             AND (pct_con_decimales > 0 OR nombre_magnitud)))
    AND NOT nombre_codigo AND n_distintos > 2
), b AS (
  SELECT n.columna, n.x,
         n.x IN (-1, -9, -99, -999, -9999, -99999, 99, 999, 9999, 99999, 999999, 9999999,
                 99999999, 999999999, 9999999.99, 999999.99, 1000000000, -1000000000) AS es_centinela,
         n.x % 1 = 0 AND abs(n.x) < 1e15                                            AS es_entero
  FROM dq_num n JOIN sel s ON s.columna = n.columna
  WHERE n.x IS NOT NULL
), dig AS (
  SELECT columna, CAST(abs(x) % 10 AS INT) AS digito, count(*) AS n
  FROM b WHERE es_entero
  GROUP BY columna, CAST(abs(x) % 10 AS INT)
), chi AS (
  SELECT columna,
         sum(power(n - tot / 10.0, 2) / (tot / 10.0)) AS chi2_ultimo_digito
  FROM (SELECT d.*, sum(n) OVER (PARTITION BY columna) AS tot FROM dig d)
  GROUP BY columna
), cen AS (
  SELECT columna, max_by(x, n) AS centinela_top
  FROM (SELECT columna, x, count(*) AS n FROM b WHERE es_centinela GROUP BY columna, x)
  GROUP BY columna
)
SELECT b.columna,
       count(*)                                                                  AS n_validos,
       count_if(es_centinela)                                                    AS n_centinelas,
       round(count_if(es_centinela) / count(*), 5)                               AS pct_centinelas,
       max(cen.centinela_top)                                                    AS centinela_mas_frecuente,
       round(count_if(es_entero AND x % 5 = 0) / NULLIF(count_if(es_entero), 0), 4)   AS pct_multiplos_5,
       round(count_if(es_entero AND x % 10 = 0) / NULLIF(count_if(es_entero), 0), 4)  AS pct_multiplos_10,
       round(count_if(es_entero AND x % 100 = 0) / NULLIF(count_if(es_entero), 0), 4) AS pct_multiplos_100,
       IF(count_if(es_entero) / count(*) >= 0.99 AND count(*) >= 100 AND max(x) - min(x) >= 100,
          round(max(chi.chi2_ultimo_digito), 2), NULL)                           AS chi2_ultimo_digito,
       filter(array(
         IF(count_if(es_centinela) > 0, 'CENTINELAS', NULL),
         IF(count_if(es_entero AND x % 5 = 0) / NULLIF(count_if(es_entero), 0) > 0.35
            AND count_if(es_entero) / count(*) >= 0.99, 'HEAPING_MULTIPLOS_5', NULL),
         IF(count_if(es_entero) / count(*) >= 0.99 AND count(*) >= 100 AND max(x) - min(x) >= 100
            AND max(chi.chi2_ultimo_digito) > 16.92, 'ULTIMO_DIGITO_NO_UNIFORME', NULL)
       ), a -> a IS NOT NULL)                                                    AS alertas
FROM b
LEFT JOIN chi ON chi.columna = b.columna
LEFT JOIN cen ON cen.columna = b.columna
GROUP BY b.columna
ORDER BY size(alertas) DESC, b.columna;


/* ────────────────────────────────────────────────────────────────────────────
   [L3.04] Rango de dominio esperado según el nombre de la columna
   DOCSTRING (es-PE)
     Cruza el nombre de cada columna numérica con un catálogo de dominios
     típicos (edad 0-120, mes 1-12, día 1-31, hora 0-23, nota vigesimal 0-20,
     porcentaje 0-100, latitud/longitud del Perú, año 1900-año actual+1,
     montos ≥ 0...) y cuenta valores por debajo y por encima.
   TOOLTIP ▸ Cómo leer e interpretar
     • fuera_de_rango > 0 casi siempre es error (edad 999, mes 13) o
       centinela (-1). Excepción: notas en escala 0-100 o porcentajes como
       fracción 0-1: ajusten el catálogo.
     • Personalización: este VALUES es el lugar para codificar el
       conocimiento del dominio cuando lo tengan (rangos por columna exacta
       en vez de por patrón de nombre).
   ──────────────────────────────────────────────────────────────────────────── */
WITH dominio AS (
  SELECT * FROM VALUES
    ('(^|_)edad(_|$)',                         0D,     120D,   'edad en años'),
    ('(^|_)(mes|month)(_|$)',                  1D,     12D,    'mes del año'),
    ('(^|_)(dia|day)(_|$)',                    1D,     31D,    'día del mes'),
    ('(^|_)(hora|hour)(_|$)',                  0D,     23D,    'hora del día'),
    ('(^|_)nota(_|$)',                         0D,     20D,    'nota vigesimal (Perú)'),
    ('(^|_)(porcentaje|pct|porc)(_|$)',        0D,     100D,   'porcentaje'),
    ('(^|_)(lat|latitud)(_|$)',                -18.4D, -0.03D, 'latitud Perú'),
    ('(^|_)(lon|lng|longitud)(_|$)',           -81.4D, -68.6D, 'longitud Perú'),
    ('(^|_)(anio|ano|año|year|ejercicio)(_|$)', 1900D, CAST(year(current_date()) + 1 AS DOUBLE), 'año'),
    ('(^|_)(monto|importe|precio|costo|sueldo|salario|ingreso|cantidad|cant|qty|stock|unidades|plazo|cuota)(_|$)',
                                               0D,     CAST('Infinity' AS DOUBLE), 'magnitud no negativa')
  AS t(patron, minimo_esperado, maximo_esperado, descripcion)
), sel AS (
  SELECT * FROM dq_l3_cols
  WHERE familia = 'NUMERICO'
     OR (familia = 'TEXTO' AND pct_numerico >= dq_umbral_tipo_dominante AND n_ceros_izq = 0
         AND NOT nombre_codigo AND (pct_con_decimales > 0 OR nombre_magnitud))
)
SELECT n.columna, d.descripcion, d.minimo_esperado, d.maximo_esperado,
       count(n.x)                                         AS n_validos,
       min(n.x)                                           AS minimo_observado,
       max(n.x)                                           AS maximo_observado,
       count_if(n.x < d.minimo_esperado)                  AS n_bajo_rango,
       count_if(n.x > d.maximo_esperado)                  AS n_sobre_rango,
       round((count_if(n.x < d.minimo_esperado) + count_if(n.x > d.maximo_esperado)) / NULLIF(count(n.x), 0), 5)
                                                          AS pct_fuera_de_rango,
       slice(array_sort(collect_set(IF(n.x < d.minimo_esperado OR n.x > d.maximo_esperado, n.x, NULL))), 1, 10)
                                                          AS ejemplos_fuera_de_rango
FROM dq_num n
JOIN sel s     ON s.columna = n.columna
JOIN dominio d ON lower(n.columna) RLIKE d.patron
WHERE n.x IS NOT NULL
GROUP BY n.columna, d.descripcion, d.minimo_esperado, d.maximo_esperado
ORDER BY pct_fuera_de_rango DESC;


/* ────────────────────────────────────────────────────────────────────────────
   [L3.05] Histograma por columna (20 cubetas entre P1 y P99 + colas)
   DOCSTRING (es-PE)
     Para cada columna numérica arma 20 cubetas de igual ancho entre P1 y
     P99, más una cubeta "< P1" (0) y otra "> P99" (21), con conteo y %.
     Así los atípicos no aplastan el histograma.
   TOOLTIP ▸ Cómo leer e interpretar
     • Visualícenlo en Databricks: tipo Bar, X = cubeta, Y = n, agrupado
       por columna (o filtren una columna).
     • Bimodalidad (dos jorobas) ⇒ mezcla de poblaciones (dos productos,
       dos monedas, dos unidades): segmenten antes de modelar.
     • Picos aislados ⇒ valores por defecto, centinelas o heaping.
     • Si P1 = P99 la columna es casi constante (no se histogramiza).
   ──────────────────────────────────────────────────────────────────────────── */
WITH sel AS (
  SELECT * FROM dq_l3_cols
  WHERE familia = 'NUMERICO'
     OR (familia = 'TEXTO' AND pct_numerico >= dq_umbral_tipo_dominante AND n_ceros_izq = 0
         AND NOT nombre_codigo AND (pct_con_decimales > 0 OR nombre_magnitud))
), r AS (
  SELECT n.columna, percentile_approx(n.x, array(0.01, 0.99), 10000) AS p
  FROM dq_num n JOIN sel s ON s.columna = n.columna
  WHERE n.x IS NOT NULL
  GROUP BY n.columna
), h AS (
  SELECT n.columna, r.p[0] AS p01, r.p[1] AS p99,
         CASE WHEN n.x < r.p[0] THEN 0
              WHEN n.x > r.p[1] THEN 21
              ELSE least(20, width_bucket(n.x, r.p[0], r.p[1], 20)) END AS cubeta
  FROM dq_num n JOIN r ON r.columna = n.columna
  WHERE n.x IS NOT NULL AND r.p[1] > r.p[0]
)
SELECT columna, cubeta,
       CASE cubeta WHEN 0 THEN concat('< ', CAST(max(p01) AS STRING))
                   WHEN 21 THEN concat('> ', CAST(max(p99) AS STRING))
                   ELSE concat('[', CAST(round(max(p01) + (cubeta - 1) * (max(p99) - max(p01)) / 20, 4) AS STRING), ', ',
                               CAST(round(max(p01) + cubeta * (max(p99) - max(p01)) / 20, 4) AS STRING), ')') END AS rango,
       count(*) AS n,
       round(count(*) / sum(count(*)) OVER (PARTITION BY columna), 5) AS pct
FROM h
GROUP BY columna, cubeta
ORDER BY columna, cubeta;


/* ────────────────────────────────────────────────────────────────────────────
   [L3.06] Ley de Benford (primer dígito) para columnas de montos
   DOCSTRING (es-PE)
     Para columnas numéricas con ≥ 300 valores positivos que abarcan ≥ 2
     órdenes de magnitud, compara la distribución del primer dígito
     significativo contra Benford: P(d) = log10(1 + 1/d). Reporta el MAD de
     Nigrini y su clasificación de conformidad.
   TOOLTIP ▸ Cómo leer e interpretar
     • MAD (Nigrini, primer dígito): < 0.006 conformidad cercana;
       0.006-0.012 aceptable; 0.012-0.015 marginal; > 0.015 NO conforme.
     • Aplica a magnitudes "naturales" (montos de transacciones, ingresos,
       poblaciones). NO aplica a precios fijados, edades, códigos, montos con
       tope o mínimos.
     • No conformidad ⇒ montos inventados, redondeados, umbrales de
       aprobación (fraccionamiento) o mezcla de procesos. Es señal para
       auditar, no prueba de fraude.
   ──────────────────────────────────────────────────────────────────────────── */
WITH sel AS (
  SELECT * FROM dq_l3_cols
  WHERE (familia = 'NUMERICO'
         OR (familia = 'TEXTO' AND pct_numerico >= dq_umbral_tipo_dominante AND n_ceros_izq = 0
             AND (pct_con_decimales > 0 OR nombre_magnitud)))
    AND NOT nombre_codigo AND n_distintos > 2
), pos AS (
  SELECT n.columna, n.x,
         CAST(regexp_extract(CAST(abs(n.x) AS STRING), '([1-9])', 1) AS INT) AS d
  FROM dq_num n JOIN sel s ON s.columna = n.columna
  WHERE n.x > 0
), elig AS (
  SELECT columna FROM pos GROUP BY columna
  HAVING count(*) >= 300 AND log10(max(x) / min(x)) >= 2
), comp AS (
  SELECT e.columna, dd.d, coalesce(o.n, 0) AS n, t.total, log10(1 + 1.0 / dd.d) AS esperado
  FROM elig e
  CROSS JOIN (SELECT explode(sequence(1, 9)) AS d) dd
  JOIN (SELECT columna, count(*) AS total FROM pos GROUP BY columna) t ON t.columna = e.columna
  LEFT JOIN (SELECT columna, d, count(*) AS n FROM pos GROUP BY columna, d) o
    ON o.columna = e.columna AND o.d = dd.d
)
SELECT columna,
       max(total)                                                  AS n_valores,
       round(avg(abs(n / total - esperado)), 5)                    AS mad_nigrini,
       CASE WHEN avg(abs(n / total - esperado)) < 0.006 THEN 'CONFORMIDAD_CERCANA'
            WHEN avg(abs(n / total - esperado)) < 0.012 THEN 'ACEPTABLE'
            WHEN avg(abs(n / total - esperado)) < 0.015 THEN 'MARGINAL'
            ELSE 'NO_CONFORME' END                                 AS conformidad,
       transform(array_sort(collect_list(struct(d, round(n / total, 4) AS obs, round(esperado, 4) AS esp))),
                 s -> concat(CAST(s.d AS STRING), ': ', CAST(s.obs AS STRING), ' vs ', CAST(s.esp AS STRING))) AS detalle_digitos
FROM comp
GROUP BY columna
ORDER BY mad_nigrini DESC;


/* ────────────────────────────────────────────────────────────────────────────
   [L3.07] Persistir métricas numéricas (opcional)
   DOCSTRING (es-PE)
     Guarda media, desviación, varianza, mediana, P05, P95, % ceros y % nulos
     por columna numérica en dq_metricas, para monitoreo de deriva simple
     (cambio de media/varianza entre corridas).
   TOOLTIP ▸ Cómo interpretar
     • Comparen corrida a corrida la diferencia de medias estandarizada
       (SMD = Δmedia / desv); |SMD| > 0.1 ya merece mirarse (ver capa 6).
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_sql = IF(
  dq_esquema_trabajo = '',
  concat('SELECT ', dq_lit('persistencia desactivada (dq_esquema_trabajo vacío)'), ' AS info'),
  concat('INSERT INTO ', dq_esquema_trabajo, '.dq_metricas ',
         'SELECT ', dq_lit(dq_id_corrida), ', current_timestamp(), ', dq_lit(dq_tabla_fq), ', columna, ',
         dq_lit('L3'), ', metrica, valor, NULL FROM (',
         'SELECT columna, avg(x) AS media, stddev_samp(x) AS desv, var_samp(x) AS varianza, ',
         'percentile_approx(x, 0.5, 10000) AS mediana, percentile_approx(x, 0.05, 10000) AS p05, ',
         'percentile_approx(x, 0.95, 10000) AS p95, count_if(x = 0) / NULLIF(count(x), 0) AS pct_ceros ',
         'FROM dq_num WHERE familia = ', dq_lit('NUMERICO'), ' GROUP BY columna) ',
         'LATERAL VIEW stack(7, ', dq_lit('media'), ', media, ', dq_lit('desv_est'), ', desv, ',
         dq_lit('varianza'), ', varianza, ', dq_lit('mediana'), ', CAST(mediana AS DOUBLE), ',
         dq_lit('p05'), ', CAST(p05 AS DOUBLE), ', dq_lit('p95'), ', CAST(p95 AS DOUBLE), ',
         dq_lit('pct_ceros'), ', pct_ceros) s AS metrica, valor'));
EXECUTE IMMEDIATE dq_sql;
