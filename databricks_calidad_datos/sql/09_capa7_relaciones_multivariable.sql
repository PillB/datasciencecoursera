/* ════════════════════════════════════════════════════════════════════════════
   ARCHIVO 09 · CAPA 7 — RELACIONES ENTRE COLUMNAS Y ENTRE TABLAS
   ────────────────────────────────────────────────────────────────────────────
   DOCSTRING (es-PE)
     Valida y explora lo que ninguna métrica univariada ve:
       • correlación de Pearson entre numéricas (redundancia, fórmulas, fuga);
       • asociación entre categóricas con V de Cramér (incluye segmento y
         target si están configurados);
       • patrones de faltantes: combinaciones de columnas vacías juntas,
         co-ocurrencia (Jaccard) y faltantes CONDICIONALES a otra variable
         (MCAR vs MAR, Little 1988 / Rubin 1976);
       • reglas de orden descubiertas automáticamente (fecha_inicio ≤ fecha_fin)
         y sus violaciones;
       • dependencias funcionales código ↔ descripción;
       • integridad referencial (huérfanos) a partir de las FK declaradas en
         Unity Catalog o de una pareja indicada a mano.
     Dimensión DAMA/ISO: consistencia (intra e inter tabla) e integridad.
     Requisitos: archivos 00 y 02. Las consultas generan SQL dinámico y lo
     ejecutan con EXECUTE IMMEDIATE (se limita a dq_max_columnas_pares).
   TOOLTIP ▸ Cómo usar
     • L7.01-L7.05 son automáticas. L7.06 y L7.07 son PLANTILLAS: configuren
       las variables dq_fd_* / dq_ri_* de esta sección.
     • Personalización futura: las reglas descubiertas aquí (orden de fechas,
       código→descripción, FK) se "promueven" a reglas formales en la capa 8.
   ════════════════════════════════════════════════════════════════════════════ */


/* ────────────────────────────────────────────────────────────────────────────
   [L7.00] Variables de plantillas y vistas auxiliares de columnas
   DOCSTRING (es-PE)
     Declara variables para las plantillas (dependencia funcional e
     integridad referencial manual) y crea:
       dq_l7_cols_faltantes : columnas con % faltante efectivo entre 0 y 100%.
       dq_l7_cols_cat       : columnas categóricas con 2 a 20 valores (máx. 12),
                              + _dq_segmento y _dq_objetivo si tienen datos.
       dq_l7_cols_num       : columnas numéricas no-código con > 2 valores.
   TOOLTIP ▸ Cómo interpretar
     • No devuelve filas. Revisen qué columnas entraron con
       SELECT * FROM dq_l7_cols_cat; (etc.).
   ──────────────────────────────────────────────────────────────────────────── */
DECLARE OR REPLACE VARIABLE dq_fd_determinante   STRING DEFAULT '';
DECLARE OR REPLACE VARIABLE dq_fd_dependiente    STRING DEFAULT '';
DECLARE OR REPLACE VARIABLE dq_ri_columna_hija   STRING DEFAULT '';
DECLARE OR REPLACE VARIABLE dq_ri_tabla_padre    STRING DEFAULT '';
DECLARE OR REPLACE VARIABLE dq_ri_columna_padre  STRING DEFAULT '';

CREATE OR REPLACE TEMP VIEW dq_l7_perfil_cols AS
SELECT f.columna, c.ordinal, c.familia, c.tipo_declarado,
       sum(f.n)                                                                         AS n_filas,
       sum(IF(f.valor IS NULL OR dq_limpiar(f.valor) = '' OR dq_es_placeholder(f.valor), f.n, 0)) AS n_faltantes,
       count_if(f.valor IS NOT NULL AND dq_limpiar(f.valor) <> '' AND NOT dq_es_placeholder(f.valor)) AS n_distintos
FROM dq_freq f
JOIN dq_columnas c ON c.columna = f.columna
GROUP BY f.columna, c.ordinal, c.familia, c.tipo_declarado;

CREATE OR REPLACE TEMP VIEW dq_l7_cols_faltantes AS
SELECT columna, ordinal FROM dq_l7_perfil_cols
WHERE n_faltantes > 0 AND n_faltantes < n_filas;

CREATE OR REPLACE TEMP VIEW dq_l7_cols_cat AS
SELECT columna, ordinal FROM (
  SELECT columna, ordinal, row_number() OVER (ORDER BY n_distintos, ordinal) AS rn
  FROM dq_l7_perfil_cols
  WHERE n_distintos BETWEEN 2 AND 20
    AND familia IN ('TEXTO', 'BOOLEANO', 'NUMERICO')
    AND NOT tipo_declarado RLIKE '^(FLOAT|DOUBLE|REAL|DECIMAL)'
) WHERE rn <= 12
UNION ALL
SELECT '_dq_segmento', 100000 FROM dq_src HAVING count(_dq_segmento) > 0 AND count(DISTINCT _dq_segmento) BETWEEN 2 AND 50
UNION ALL
SELECT '_dq_objetivo', 100001 FROM dq_src HAVING count(_dq_objetivo) > 0 AND count(DISTINCT _dq_objetivo) BETWEEN 2 AND 50;

CREATE OR REPLACE TEMP VIEW dq_l7_cols_num AS
SELECT columna, ordinal FROM dq_l7_perfil_cols
WHERE familia = 'NUMERICO' AND n_distintos > 2
  AND NOT lower(columna) RLIKE '(^|_)(id|cod|codigo|code|dni|ruc|ubigeo|telefono|celular|cuenta|cci|nro|numero|num|doc|documento|postal|zip)(_|$)';


/* ────────────────────────────────────────────────────────────────────────────
   [L7.01] Matriz de correlación de Pearson entre columnas numéricas
   DOCSTRING (es-PE)
     Genera una sola consulta que calcula corr(a, b) y el n de pares válidos
     para todas las parejas de columnas numéricas no-código (máximo
     dq_max_columnas_pares columnas), y la ejecuta.
   TOOLTIP ▸ Cómo leer e interpretar
     • |r| ≥ dq_umbral_correlacion ⇒ REDUNDANTES: una sobra para ML
       (multicolinealidad) o una se calcula de la otra.
     • |r| = 1 exacto ⇒ DERIVADA: relación lineal perfecta (columna en otra
       unidad, total = suma...). Verifiquen que no sea una fuga del target.
     • Pearson sólo ve relaciones LINEALES y es sensible a atípicos: si sale
       bajo pero sospechan relación, prueben con log o rangos.
     • Visualícenlo como heatmap: X = col_a, Y = col_b, color = pearson.
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_sql = (
  WITH c AS (
    SELECT columna, ordinal FROM (SELECT *, row_number() OVER (ORDER BY ordinal) AS rn FROM dq_l7_cols_num)
    WHERE rn <= dq_max_columnas_pares
  ), p AS (
    SELECT a.columna AS ca, b.columna AS cb, a.ordinal AS oa, b.ordinal AS ob
    FROM c a JOIN c b ON a.ordinal < b.ordinal
  ), e AS (
    SELECT oa, ob,
           concat(dq_lit(ca), ', ', dq_lit(cb), ', ',
                  'corr(', dq_id(ca), ', ', dq_id(cb), '), ',
                  'count_if(', dq_id(ca), ' IS NOT NULL AND ', dq_id(cb), ' IS NOT NULL)') AS par
    FROM p
  )
  SELECT IF(count(*) = 0,
            concat('SELECT ', dq_lit('Menos de 2 columnas numéricas: no hay correlaciones que calcular'), ' AS info'),
            concat('SELECT col_a, col_b, round(pearson, 4) AS pearson, n_pares, ',
                   'CASE WHEN abs(pearson) >= 0.999999 THEN ', dq_lit('DERIVADA (|r| = 1)'),
                   ' WHEN abs(pearson) >= ', CAST(dq_umbral_correlacion AS STRING), ' THEN ', dq_lit('REDUNDANTES'),
                   ' WHEN abs(pearson) >= 0.7 THEN ', dq_lit('FUERTE'), ' END AS marca ',
                   'FROM (SELECT stack(', CAST(count(*) AS STRING), ', ',
                   array_join(transform(array_sort(collect_list(struct(oa, ob, par))), x -> x.par), ', '),
                   ') AS (col_a, col_b, pearson, n_pares) FROM (SELECT ',
                   (SELECT array_join(transform(array_sort(collect_list(struct(ordinal, ex))), x -> x.ex), ', ')
                      FROM (SELECT ordinal,
                                   concat('nanvl(try_cast(', dq_id(columna), ' AS DOUBLE), CAST(NULL AS DOUBLE)) AS ', dq_id(columna)) AS ex
                            FROM c)),
                   ' FROM dq_src) t) ORDER BY abs(pearson) DESC NULLS LAST'))
  FROM e
);
EXECUTE IMMEDIATE dq_sql;


/* ────────────────────────────────────────────────────────────────────────────
   [L7.02] Asociación entre categóricas: V de Cramér (incluye segmento y target)
   DOCSTRING (es-PE)
     Para las columnas de dq_l7_cols_cat (2-20 categorías), arma todas las
     parejas, cuenta la tabla de contingencia en UNA pasada (explode de
     parejas) y calcula chi² = N·(Σ O²/(fila·col)) − N y la
     V de Cramér = sqrt(chi² / (N·(min(r,c) − 1))).
   TOOLTIP ▸ Cómo leer e interpretar
     • V ≈ 0 independencia; 0.1-0.3 débil; 0.3-0.5 moderada; > 0.5 fuerte.
     • V ≥ 0.9 entre dos columnas ⇒ codifican lo mismo (redundantes).
     • V alta entre una variable y _dq_objetivo ⇒ ¡POSIBLE FUGA DE
       INFORMACIÓN! (la variable "conoce" el resultado: p.ej. un flag que se
       llena después del evento). Validen el momento en que se registra.
     • V alta con _dq_segmento ⇒ la variable cambió de composición entre
       segmentos (deriva; ver capa 6).
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_sql = (
  WITH c AS (SELECT * FROM dq_l7_cols_cat),
  p AS (SELECT a.columna AS ca, b.columna AS cb, a.ordinal AS oa, b.ordinal AS ob
        FROM c a JOIN c b ON a.ordinal < b.ordinal)
  SELECT IF(count(*) = 0,
            concat('SELECT ', dq_lit('Menos de 2 columnas categóricas elegibles'), ' AS info'),
            concat(
              'WITH x AS (SELECT p.a, p.b, p.va, p.vb FROM dq_src LATERAL VIEW explode(array(',
              array_join(transform(array_sort(collect_list(struct(oa, ob,
                concat('named_struct(', dq_lit('a'), ', ', dq_lit(ca), ', ', dq_lit('b'), ', ', dq_lit(cb), ', ',
                       dq_lit('va'), ', ', dq_id(ca), ', ', dq_lit('vb'), ', ', dq_id(cb), ')') AS e))), x -> x.e), ', '),
              ')) t AS p WHERE p.va IS NOT NULL AND p.vb IS NOT NULL), ',
              'o AS (SELECT a, b, va, vb, count(*) AS n FROM x GROUP BY a, b, va, vb), ',
              'm AS (SELECT o.*, sum(n) OVER (PARTITION BY a, b) AS tot, ',
              '      sum(n) OVER (PARTITION BY a, b, va) AS fa, sum(n) OVER (PARTITION BY a, b, vb) AS fb FROM o) ',
              'SELECT a AS col_a, b AS col_b, max(tot) AS n, count(DISTINCT va) AS k_a, count(DISTINCT vb) AS k_b, ',
              'round(max(tot) * sum(n * n / (fa * fb)) - max(tot), 2) AS chi2, ',
              'round(sqrt(greatest(max(tot) * sum(n * n / (fa * fb)) - max(tot), 0) / ',
              '      (max(tot) * NULLIF(least(count(DISTINCT va), count(DISTINCT vb)) - 1, 0))), 4) AS v_cramer ',
              'FROM m GROUP BY a, b ORDER BY v_cramer DESC NULLS LAST'))
  FROM p
);
EXECUTE IMMEDIATE dq_sql;


/* ────────────────────────────────────────────────────────────────────────────
   [L7.03] Patrones de faltantes por fila (qué columnas faltan juntas)
   DOCSTRING (es-PE)
     Para las columnas con faltantes (NULL, vacío o placeholder; máx.
     dq_max_columnas_pares), arma por fila la lista de columnas faltantes y
     cuenta los patrones más frecuentes (como el md.pattern de R/mice o la
     matriz de missingno en Python).
   TOOLTIP ▸ Cómo leer e interpretar
     • Patrón '(ninguna)' = filas completas: su % es la "completitud de fila".
     • Un patrón con varias columnas que faltan SIEMPRE juntas ⇒ vienen de la
       misma fuente/JOIN que falló (p.ej. un LEFT JOIN sin match): causa raíz
       única, se corrige en un solo lugar.
     • Muchos patrones distintos y raros ⇒ faltantes dispersos (más
       compatibles con azar, MCAR).
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_sql = (
  WITH c AS (
    SELECT columna, ordinal FROM (SELECT *, row_number() OVER (ORDER BY ordinal) AS rn FROM dq_l7_cols_faltantes)
    WHERE rn <= dq_max_columnas_pares
  )
  SELECT IF(count(*) = 0,
            concat('SELECT ', dq_lit('Ninguna columna tiene faltantes: no hay patrones'), ' AS info'),
            concat('SELECT coalesce(nullif(patron, ', dq_lit(''), '), ', dq_lit('(ninguna)'), ') AS columnas_faltantes, ',
                   'size(split(nullif(patron, ', dq_lit(''), '), ', dq_lit(', '), ')) AS n_columnas_faltantes, ',
                   'count(*) AS n_filas, round(count(*) / sum(count(*)) OVER (), 5) AS pct_filas ',
                   'FROM (SELECT concat_ws(', dq_lit(', '), ', ',
                   array_join(transform(array_sort(collect_list(struct(ordinal,
                     concat('IF(', dq_id(columna), ' IS NULL OR dq_limpiar(', dq_id(columna), ') = ', dq_lit(''),
                            ' OR dq_es_placeholder(', dq_id(columna), '), ', dq_lit(columna), ', NULL)') AS e))), x -> x.e), ', '),
                   ') AS patron FROM dq_src) GROUP BY patron ORDER BY n_filas DESC LIMIT 50'))
  FROM c
);
EXECUTE IMMEDIATE dq_sql;


/* ────────────────────────────────────────────────────────────────────────────
   [L7.04] Faltantes CONDICIONALES: % faltante de A según el valor de B
   DOCSTRING (es-PE)
     Para cada columna A con faltantes y cada columna categórica B (incluye
     _dq_segmento y _dq_objetivo), compara el % de faltantes de A dentro de
     cada valor de B contra el % global de A, en una sola pasada.
     Reporta los grupos con |diferencia| ≥ 10 puntos, n ≥ dq_min_n_segmento
     y significancia |z| ≥ 3 (prueba de proporciones contra el % global).
   TOOLTIP ▸ Cómo leer e interpretar
     • Si la falta de A depende de B ⇒ los faltantes NO son al azar (MAR):
       imputar con la media global sesga; imputen por grupo o modelen.
     • Si depende de _dq_objetivo ⇒ faltante INFORMATIVO (MNAR respecto al
       target): el hecho de faltar predice el resultado; agreguen un
       indicador "A_es_nulo" o investiguen el proceso (¿se llena después?).
     • Si depende de _dq_segmento (p.ej. mes) ⇒ un periodo/fuente dejó de
       enviar la columna: incidente de completitud.
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_sql = (
  WITH a AS (
    SELECT columna, ordinal FROM (SELECT *, row_number() OVER (ORDER BY ordinal) AS rn FROM dq_l7_cols_faltantes)
    WHERE rn <= dq_max_columnas_pares
  ), b AS (SELECT * FROM dq_l7_cols_cat)
  SELECT IF((SELECT count(*) FROM a) = 0 OR (SELECT count(*) FROM b) = 0,
            concat('SELECT ', dq_lit('Sin columnas con faltantes o sin columnas categóricas'), ' AS info'),
            concat(
              'WITH x AS (SELECT col_b, val_b, ',
              (SELECT array_join(transform(array_sort(collect_list(struct(ordinal,
                        concat('IF(', dq_id(columna), ' IS NULL OR dq_limpiar(', dq_id(columna), ') = ', dq_lit(''),
                               ' OR dq_es_placeholder(', dq_id(columna), '), 1, 0) AS m', CAST(ordinal AS STRING)) AS e))),
                                 y -> y.e), ', ') FROM a),
              ' FROM dq_src LATERAL VIEW stack(', CAST((SELECT count(*) FROM b) AS STRING), ', ',
              (SELECT array_join(transform(array_sort(collect_list(struct(ordinal,
                        concat(dq_lit(columna), ', CAST(', dq_id(columna), ' AS STRING)') AS e))), y -> y.e), ', ') FROM b),
              ') s AS col_b, val_b), ',
              'g AS (SELECT col_b, val_b, count(*) AS n, ',
              (SELECT array_join(transform(array_sort(collect_list(struct(ordinal,
                        concat('sum(m', CAST(ordinal AS STRING), ') AS s', CAST(ordinal AS STRING)) AS e))), y -> y.e), ', ') FROM a),
              ' FROM x GROUP BY col_b, val_b), ',
              'l AS (SELECT col_b, val_b, n, stack(', CAST((SELECT count(*) FROM a) AS STRING), ', ',
              (SELECT array_join(transform(array_sort(collect_list(struct(ordinal,
                        concat(dq_lit(columna), ', s', CAST(ordinal AS STRING)) AS e))), y -> y.e), ', ') FROM a),
              ') AS (col_a, n_faltantes) FROM g), ',
              'r AS (SELECT l.*, sum(n_faltantes) OVER (PARTITION BY col_a, col_b) / sum(n) OVER (PARTITION BY col_a, col_b) AS pct_global FROM l) ',
              'SELECT col_a AS columna_con_faltantes, col_b AS columna_condicion, coalesce(val_b, ', dq_lit('<NULL>'), ') AS valor_condicion, n, ',
              'round(n_faltantes / n, 4) AS pct_faltante_en_grupo, round(pct_global, 4) AS pct_faltante_global, ',
              'round(n_faltantes / n - pct_global, 4) AS diferencia, ',
              'round((n_faltantes / n - pct_global) / sqrt(pct_global * (1 - pct_global) / n), 2) AS z ',
              'FROM r WHERE col_a <> col_b AND n >= ', CAST(dq_min_n_segmento AS STRING),
              ' AND abs(n_faltantes / n - pct_global) >= 0.10 ',
              ' AND abs(n_faltantes / n - pct_global) / sqrt(pct_global * (1 - pct_global) / n) >= 3 ',
              'ORDER BY abs(n_faltantes / n - pct_global) DESC LIMIT 500'))
);
EXECUTE IMMEDIATE dq_sql;


/* ────────────────────────────────────────────────────────────────────────────
   [L7.05] Reglas de orden descubiertas entre fechas (y entre montos) y violaciones
   DOCSTRING (es-PE)
     Para cada pareja de columnas FECHA/TIMESTAMP (y de numéricas no-código
     de escala parecida: medias a menos de 10x), cuenta en cuántas filas
     a < b, a = b y a > b. Para numéricas sólo muestra reglas violadas. Si en ≥ 95% de las filas
     se cumple a ≤ b (o a ≥ b) pero no en el 100%, la regla "probable" está
     siendo violada por el resto.
   TOOLTIP ▸ Cómo leer e interpretar
     • fecha_inicio ≤ fecha_fin en 97% ⇒ el 3% restante son errores
       (fechas invertidas, digitación) o casos de negocio no documentados.
     • fecha_nacimiento ≤ fecha_registro, fecha_emision ≤ fecha_vencimiento,
       monto_pagado ≤ monto_total: típicas reglas que aparecen solas aquí.
     • Las reglas confirmadas se vuelven CHECK constraints / expectations en
       la capa 8.
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_sql = (
  WITH c AS (
    SELECT columna, ordinal,
           CASE WHEN familia = 'FECHA' THEN concat('try_cast(', dq_id(columna), ' AS DATE)')
                WHEN familia = 'TIMESTAMP' THEN concat('try_cast(', dq_id(columna), ' AS TIMESTAMP)')
                ELSE concat('nanvl(try_cast(', dq_id(columna), ' AS DOUBLE), CAST(NULL AS DOUBLE))') END AS ex,
           IF(familia IN ('FECHA', 'TIMESTAMP'), 'T', 'N') AS clase
    FROM dq_l7_perfil_cols
    WHERE familia IN ('FECHA', 'TIMESTAMP')
       OR columna IN (SELECT columna FROM dq_l7_cols_num)
  ), c2 AS (
    SELECT * FROM (SELECT *, row_number() OVER (ORDER BY clase DESC, ordinal) AS rn FROM c) WHERE rn <= dq_max_columnas_pares
  ), p AS (
    SELECT a.columna AS ca, b.columna AS cb, a.ordinal AS oa, b.ordinal AS ob,
           IF(a.clase = 'T' AND b.clase = 'T', 'FECHAS', 'NUMERICAS') AS tipo,
           concat(dq_lit(a.columna), ', ', dq_lit(b.columna), ', ', dq_lit(IF(a.clase = 'T', 'FECHAS', 'NUMERICAS')), ', ',
                  'count_if((', a.ex, ') < (', b.ex, ')), ',
                  'count_if((', a.ex, ') = (', b.ex, ')), ',
                  'count_if((', a.ex, ') > (', b.ex, ')), ',
                  IF(a.clase = 'T', 'CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE)',
                     concat('avg(abs(', a.ex, ')), avg(abs(', b.ex, '))'))) AS e
    FROM c2 a JOIN c2 b ON a.ordinal < b.ordinal AND a.clase = b.clase
  )
  SELECT IF(count(*) = 0,
            concat('SELECT ', dq_lit('No hay parejas comparables'), ' AS info'),
            concat('SELECT col_a, col_b, tipo, n_menor + n_igual + n_mayor AS n_pares, n_menor, n_igual, n_mayor, ',
                   'round((n_menor + n_igual) / (n_menor + n_igual + n_mayor), 4) AS pct_a_menor_igual_b, ',
                   'CASE WHEN (n_menor + n_igual) / (n_menor + n_igual + n_mayor) >= 0.95 AND n_mayor > 0 ',
                   '       THEN concat(col_a, ', dq_lit(' <= '), ', col_b, ', dq_lit(' (violada en '), ', n_mayor, ', dq_lit(' filas)'), ') ',
                   '     WHEN (n_mayor + n_igual) / (n_menor + n_igual + n_mayor) >= 0.95 AND n_menor > 0 ',
                   '       THEN concat(col_a, ', dq_lit(' >= '), ', col_b, ', dq_lit(' (violada en '), ', n_menor, ', dq_lit(' filas)'), ') ',
                   '     WHEN n_mayor = 0 AND n_menor + n_igual > 0 THEN concat(col_a, ', dq_lit(' <= '), ', col_b, ', dq_lit(' (se cumple siempre)'), ') ',
                   '     WHEN n_menor = 0 AND n_mayor + n_igual > 0 THEN concat(col_a, ', dq_lit(' >= '), ', col_b, ', dq_lit(' (se cumple siempre)'), ') ',
                   'END AS regla_probable ',
                   'FROM (SELECT stack(', CAST(count(*) AS STRING), ', ',
                   array_join(transform(array_sort(collect_list(struct(oa, ob, e))), x -> x.e), ', '),
                   ') AS (col_a, col_b, tipo, n_menor, n_igual, n_mayor, media_abs_a, media_abs_b) FROM dq_src) ',
                   'WHERE n_menor + n_igual + n_mayor >= 30 ',
                   '  AND (tipo = ', dq_lit('FECHAS'), ' OR (greatest(media_abs_a, media_abs_b) <= 10 * least(media_abs_a, media_abs_b) ',
                   '       AND least(n_menor, n_mayor) > 0 AND greatest(n_menor, n_mayor) + n_igual >= 0.95 * (n_menor + n_igual + n_mayor))) ',
                   'ORDER BY CASE WHEN regla_probable LIKE ', dq_lit('%violada%'), ' THEN 0 ',
                   '              WHEN regla_probable IS NOT NULL THEN 1 ELSE 2 END, tipo, col_a, col_b'))
  FROM p
);
EXECUTE IMMEDIATE dq_sql;


/* ────────────────────────────────────────────────────────────────────────────
   [L7.06] Dependencia funcional A → B (código → descripción): automática + manual
   DOCSTRING (es-PE)
     Busca parejas por NOMBRE del tipo cod_X / id_X ↔ X / nombre_X / desc_X
     (y la pareja manual dq_fd_determinante → dq_fd_dependiente si se
     configuró) y verifica si cada valor de A tiene UN SOLO valor de B:
     cuenta valores de A con varias B, filas afectadas y ejemplos.
   TOOLTIP ▸ Cómo leer e interpretar
     • cod_producto con 2 descripciones distintas ⇒ catálogo inconsistente o
       descripción que cambió en el tiempo sin historizar (SCD).
     • Si la dependencia inversa (B → A) tampoco se cumple, puede haber
       descripciones duplicadas con códigos distintos (duplicados maestros).
     • Para usar la plantilla manual:
       SET VAR dq_fd_determinante = 'ubigeo'; SET VAR dq_fd_dependiente = 'distrito';
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_sql = (
  WITH n AS (
    SELECT columna,
           regexp_replace(lower(columna), '^(cod|codigo|code|cd|id|cve|clave|nom|nombre|desc|descripcion|des|dsc|txt|glosa)_', '') AS raiz,
           lower(columna) RLIKE '^(cod|codigo|code|cd|id|cve|clave)_' AS es_codigo
    FROM dq_columnas WHERE familia IN ('TEXTO', 'NUMERICO')
  ), pares AS (
    SELECT DISTINCT a.columna AS det, b.columna AS dep
    FROM n a JOIN n b ON a.raiz = b.raiz AND a.columna <> b.columna AND a.es_codigo AND NOT b.es_codigo
    UNION
    SELECT trim(dq_fd_determinante), trim(dq_fd_dependiente)
    WHERE trim(dq_fd_determinante) <> '' AND trim(dq_fd_dependiente) <> ''
  )
  SELECT IF(count(*) = 0,
            concat('SELECT ', dq_lit('No se hallaron parejas código↔descripción; configuren dq_fd_determinante/dq_fd_dependiente'), ' AS info'),
            array_join(collect_list(concat(
              'SELECT ', dq_lit(det), ' AS determinante, ', dq_lit(dep), ' AS dependiente, ',
              'count(*) AS n_valores_determinante, count_if(k > 1) AS n_con_varias_dependientes, ',
              'sum(IF(k > 1, n, 0)) AS n_filas_afectadas, ',
              'slice(collect_list(IF(k > 1, concat(CAST(a AS STRING), ', dq_lit(' → '), ', array_join(bs, ', dq_lit(' | '), ')), NULL)), 1, 5) AS ejemplos ',
              'FROM (SELECT ', dq_id(det), ' AS a, count(*) AS n, count(DISTINCT ', dq_id(dep), ') AS k, ',
              'slice(collect_set(', dq_id(dep), '), 1, 5) AS bs FROM dq_src WHERE ', dq_id(det), ' IS NOT NULL GROUP BY ', dq_id(det), ')')),
              ' UNION ALL '))
  FROM pares
);
EXECUTE IMMEDIATE dq_sql;


/* ────────────────────────────────────────────────────────────────────────────
   [L7.07] Integridad referencial desde las FK declaradas (tablas completas)
   DOCSTRING (es-PE)
     Lee las FOREIGN KEY declaradas en information_schema para las tablas del
     alcance (o la pareja manual dq_ri_columna_hija → dq_ri_tabla_padre.
     dq_ri_columna_padre, aplicada a la tabla objetivo), genera un chequeo
     de huérfanos por cada una (soporta FK compuestas) y lo ejecuta sobre las
     tablas COMPLETAS (no la muestra).
   TOOLTIP ▸ Cómo leer e interpretar
     • n_huerfanos > 0 ⇒ registros hijos cuya llave no existe en el padre:
       un INNER JOIN los pierde en silencio (reportes que no cuadran), y un
       LEFT JOIN trae atributos nulos.
     • Causas típicas: el maestro se carga después que la transacción
       (problema de orden/latencia), borrados físicos en el maestro, tipos
       distintos ('001' vs 1, ver L0.04) o espacios en las llaves.
     • Ojo: en Databricks las FK son informativas; esta consulta es la que
       realmente las verifica.
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_sql = (
  WITH fk AS (
    SELECT tc.constraint_name, tc.table_schema AS esq_hija, tc.table_name AS tab_hija,
           rc.unique_constraint_schema AS esq_ref, rc.unique_constraint_name AS restr_ref
    FROM IDENTIFIER(dq_info_schema || '.table_constraints') tc
    JOIN IDENTIFIER(dq_info_schema || '.referential_constraints') rc
      ON rc.constraint_schema = tc.constraint_schema AND rc.constraint_name = tc.constraint_name
    WHERE tc.constraint_type = 'FOREIGN KEY'
      AND ((dq_regex_esquemas = '' AND lower(tc.table_schema) = lower(dq_esquema))
           OR (dq_regex_esquemas <> '' AND tc.table_schema RLIKE dq_regex_esquemas))
      AND tc.table_name RLIKE dq_regex_tablas
  ), cols AS (
    SELECT fk.constraint_name, fk.esq_hija, fk.tab_hija,
           kp.table_schema AS esq_padre, kp.table_name AS tab_padre,
           kh.column_name AS col_hija, kp.column_name AS col_padre, kh.ordinal_position AS pos,
           dq_lit(kh.column_name) AS lit_h, dq_id(kh.column_name) AS id_h, dq_id(kp.column_name) AS id_p
    FROM fk
    JOIN IDENTIFIER(dq_info_schema || '.key_column_usage') kh
      ON kh.constraint_schema = fk.esq_hija AND kh.constraint_name = fk.constraint_name
    JOIN IDENTIFIER(dq_info_schema || '.key_column_usage') kp
      ON kp.constraint_schema = fk.esq_ref AND kp.constraint_name = fk.restr_ref
     AND kp.ordinal_position = kh.ordinal_position
  ), q0 AS (
    SELECT constraint_name, esq_hija, tab_hija,
           max(esq_padre) AS esq_padre, max(tab_padre) AS tab_padre,
           concat(esq_hija, '.', tab_hija, '(',
                  array_join(transform(array_sort(collect_list(struct(pos, col_hija))), x -> x.col_hija), ', '), ')') AS desc_hija,
           concat(max(esq_padre), '.', max(tab_padre), '(',
                  array_join(transform(array_sort(collect_list(struct(pos, col_padre))), x -> x.col_padre), ', '), ')') AS desc_padre,
           array_join(transform(array_sort(collect_list(struct(pos, lit_h, id_h))),
                                x -> concat(x.lit_h, ', h.', x.id_h)), ', ')                         AS json_ejemplo,
           array_join(transform(array_sort(collect_list(struct(pos, id_p))),
                                x -> concat(x.id_p, ' AS k', CAST(x.pos AS STRING))), ', ')          AS select_padre,
           array_join(transform(array_sort(collect_list(struct(pos, id_h))),
                                x -> concat('h.', x.id_h, ' = p.k', CAST(x.pos AS STRING))), ' AND ') AS condicion_join,
           array_join(transform(array_sort(collect_list(struct(pos, id_h))),
                                x -> concat('h.', x.id_h, ' IS NOT NULL')), ' AND ')                 AS condicion_no_nula
    FROM cols
    GROUP BY constraint_name, esq_hija, tab_hija
  ), q AS (
    SELECT constraint_name,
           concat(
             'SELECT ', dq_lit(constraint_name), ' AS restriccion, ',
             dq_lit(desc_hija), ' AS hija, ', dq_lit(desc_padre), ' AS padre, ',
             'count(*) AS n_filas_hijas_con_llave, count_if(p._dq_existe IS NULL) AS n_huerfanos, ',
             'round(count_if(p._dq_existe IS NULL) / NULLIF(count(*), 0), 6) AS pct_huerfanos, ',
             'slice(collect_set(IF(p._dq_existe IS NULL, to_json(named_struct(', json_ejemplo, ')), NULL)), 1, 10) AS ejemplos_huerfanos ',
             'FROM ', dq_id(dq_catalogo), '.', dq_id(esq_hija), '.', dq_id(tab_hija), ' h ',
             'LEFT JOIN (SELECT DISTINCT ', select_padre, ', true AS _dq_existe FROM ',
             dq_id(dq_catalogo), '.', dq_id(esq_padre), '.', dq_id(tab_padre), ') p ON ', condicion_join,
             ' WHERE ', condicion_no_nula) AS sql_fk
    FROM q0
  ), manual AS (
    SELECT concat(
             'SELECT ', dq_lit('manual'), ' AS restriccion, ', dq_lit(concat(dq_tabla_fq, '(', dq_ri_columna_hija, ')')), ' AS hija, ',
             dq_lit(concat(dq_ri_tabla_padre, '(', dq_ri_columna_padre, ')')), ' AS padre, ',
             'count(*) AS n_filas_hijas_con_llave, count_if(p._dq_existe IS NULL) AS n_huerfanos, ',
             'round(count_if(p._dq_existe IS NULL) / NULLIF(count(*), 0), 6) AS pct_huerfanos, ',
             'slice(collect_set(IF(p._dq_existe IS NULL, CAST(h.', dq_id(dq_ri_columna_hija), ' AS STRING), NULL)), 1, 10) AS ejemplos_huerfanos ',
             'FROM ', dq_tabla_fq, ' h LEFT JOIN (SELECT DISTINCT ', dq_id(dq_ri_columna_padre), ' AS k1, true AS _dq_existe FROM ',
             dq_ri_tabla_padre, ') p ON h.', dq_id(dq_ri_columna_hija), ' = p.k1 WHERE h.', dq_id(dq_ri_columna_hija), ' IS NOT NULL') AS sql_fk
    WHERE dq_ri_columna_hija <> '' AND dq_ri_tabla_padre <> '' AND dq_ri_columna_padre <> ''
  ), todo AS (
    SELECT sql_fk FROM q UNION ALL SELECT sql_fk FROM manual
  )
  SELECT IF(count(*) = 0,
            concat('SELECT ', dq_lit('No hay FK declaradas en el alcance ni pareja manual (dq_ri_*)'), ' AS info'),
            concat(array_join(collect_list(sql_fk), ' UNION ALL '), ' ORDER BY pct_huerfanos DESC'))
  FROM todo
);
EXECUTE IMMEDIATE dq_sql;
