/* ════════════════════════════════════════════════════════════════════════════
   ARCHIVO 03 · CAPA 1 — PERFIL UNIVERSAL (todas las columnas, cualquier tipo)
   ────────────────────────────────────────────────────────────────────────────
   DOCSTRING (es-PE)
     Métricas que aplican a TODA columna sin importar su tipo: completitud
     (nulos reales y "disfrazados"), cardinalidad, unicidad, moda, longitudes,
     higiene de texto (espacios, saltos de línea, caracteres invisibles,
     mojibake) y, a nivel tabla, duplicados exactos, casi-duplicados y
     unicidad de la clave de negocio.
     Dimensiones DAMA / ISO 25012 cubiertas: completitud, unicidad, validez
     sintáctica básica. Equivale a los "column profiles" de Deequ, TFDV,
     ydata-profiling y Great Expectations, pero en SQL puro y escalable.
     Requisitos: archivos 00 y 02 ejecutados en la sesión.
   TOOLTIP ▸ Cómo usar
     • L1.00 crea la vista base; L1.01 es el "tablero" principal: ordénenlo
       por número de alertas y vayan de arriba hacia abajo.
     • Personalización futura: cuando se conozca el diccionario de datos,
       definan por columna su % de nulos tolerado y su longitud esperada en
       la capa 8 (reglas), y dejen esta capa como red de seguridad genérica.
   ════════════════════════════════════════════════════════════════════════════ */


/* ────────────────────────────────────────────────────────────────────────────
   [L1.00] Vista base dq_l1_perfil (métricas crudas por columna)
   DOCSTRING (es-PE)
     Clasifica cada valor distinto de dq_freq en NULO, VACIO ('' o '[]'/'{}'
     en complejos), SOLO_ESPACIOS, PLACEHOLDER (nulo disfrazado) o VALOR, y
     agrega por columna conteos, cardinalidad, moda, top-5, longitudes y
     contadores de higiene de texto. Todo ponderado por frecuencia (n).
   TOOLTIP ▸ Cómo interpretar
     • No devuelve filas (crea la vista). Si la tabla es grande y van a
       consultar la vista varias veces, materialicen dq_freq (archivo 02).
     • Ojo: para columnas numéricas 'NaN' cae como PLACEHOLDER (es un faltante
       numérico); en texto, 'NA' también (si 'NA' es un valor válido en su
       dominio —p.ej. código de país Namibia— quítenlo de dq_es_placeholder).
   ──────────────────────────────────────────────────────────────────────────── */
CREATE OR REPLACE TEMP VIEW dq_l1_perfil AS
WITH clasif AS (
  SELECT f.columna, f.valor, f.n, c.familia,
         CASE
           WHEN f.valor IS NULL                                        THEN 'NULO'
           WHEN f.valor = ''                                           THEN 'VACIO'
           WHEN c.familia = 'COMPLEJO' AND f.valor IN ('[]', '{}')     THEN 'VACIO'
           WHEN dq_limpiar(f.valor) = ''                               THEN 'SOLO_ESPACIOS'
           WHEN dq_es_placeholder(f.valor)                             THEN 'PLACEHOLDER'
           ELSE 'VALOR'
         END AS clase
  FROM dq_freq f
  JOIN dq_columnas c ON c.columna = f.columna
), rk AS (
  SELECT *,
         row_number() OVER (PARTITION BY columna
                            ORDER BY IF(clase = 'VALOR', 0, 1), n DESC, valor) AS rn
  FROM clasif
), longitudes AS (
  SELECT columna, char_length(valor) AS largo, sum(n) AS n
  FROM clasif
  WHERE clase = 'VALOR'
  GROUP BY columna, char_length(valor)
), long_moda AS (
  SELECT columna,
         max_by(largo, n)            AS largo_moda,
         max(n) / sum(n)             AS pct_largo_moda,
         count(*)                    AS n_largos_distintos
  FROM longitudes
  GROUP BY columna
), agg AS (
  SELECT columna,
    sum(n)                                                     AS n_filas,
    sum(IF(clase = 'NULO', n, 0))                              AS n_nulos,
    sum(IF(clase = 'VACIO', n, 0))                             AS n_vacios,
    sum(IF(clase = 'SOLO_ESPACIOS', n, 0))                     AS n_solo_espacios,
    sum(IF(clase = 'PLACEHOLDER', n, 0))                       AS n_placeholder,
    sum(IF(clase = 'VALOR', n, 0))                             AS n_validos,
    count_if(clase = 'VALOR')                                  AS n_distintos,
    count_if(clase = 'VALOR' AND n = 1)                        AS n_singletons,
    max(IF(rn = 1 AND clase = 'VALOR', valor, NULL))           AS moda,
    max(IF(rn = 1 AND clase = 'VALOR', n, NULL))               AS n_moda,
    slice(sort_array(collect_list(
      IF(rn <= 5 AND clase = 'VALOR', named_struct('n', n, 'valor', valor), NULL)), false), 1, 5) AS top5,
    sort_array(collect_list(IF(clase = 'PLACEHOLDER', dq_limpiar(valor), NULL)))   AS placeholders_vistos,
    min(IF(clase = 'VALOR', char_length(valor), NULL))         AS largo_min,
    max(IF(clase = 'VALOR', char_length(valor), NULL))         AS largo_max,
    sum(IF(clase = 'VALOR', char_length(valor) * n, 0))
      / NULLIF(sum(IF(clase = 'VALOR', n, 0)), 0)              AS largo_prom,
    sum(IF(clase = 'VALOR' AND valor <> dq_limpiar(valor), n, 0))            AS n_espacios_bordes,
    sum(IF(clase = 'VALOR' AND valor RLIKE '\\S\\s{2,}\\S', n, 0))           AS n_espacios_dobles,
    sum(IF(valor RLIKE '[\\r\\n]', n, 0))                                    AS n_saltos_linea,
    sum(IF(valor RLIKE '\\t', n, 0))                                         AS n_tabs,
    sum(IF(valor RLIKE '[\\x{0000}-\\x{0008}\\x{000B}\\x{000C}\\x{000E}-\\x{001F}\\x{007F}]', n, 0)) AS n_ctrl_otros,
    sum(IF(valor RLIKE '[\\x{00A0}\\x{200B}\\x{200C}\\x{200D}\\x{2060}\\x{FEFF}]', n, 0))          AS n_invisibles,
    sum(IF(valor RLIKE '[ÃÂ][\\x{0080}-\\x{00BF}\\x{0152}\\x{0153}\\x{0160}\\x{0161}\\x{0178}\\x{017D}\\x{017E}\\x{02C6}\\x{02DC}\\x{2013}\\x{2014}\\x{2018}-\\x{201E}\\x{2020}-\\x{2022}\\x{2026}\\x{2030}\\x{2039}\\x{203A}\\x{20AC}\\x{2122}]|\\x{FFFD}', n, 0))
                                                                             AS n_mojibake,
    sum(IF(clase = 'VALOR' AND valor RLIKE '[^\\x{0000}-\\x{007F}]', n, 0))  AS n_no_ascii
  FROM rk
  GROUP BY columna
)
SELECT c.ordinal, c.tipo_declarado, c.familia,
       a.*,
       lm.largo_moda, lm.pct_largo_moda, lm.n_largos_distintos
FROM agg a
JOIN dq_columnas c       ON c.columna = a.columna
LEFT JOIN long_moda lm   ON lm.columna = a.columna;


/* ────────────────────────────────────────────────────────────────────────────
   [L1.01] Tablero de perfil universal por columna (con alertas)
   DOCSTRING (es-PE)
     Una fila por columna con: % nulos, % faltante efectivo (nulos + vacíos +
     sólo espacios + placeholders), distintos, ratio de unicidad, moda y su
     peso, longitudes, contadores de higiene y un arreglo de alertas.
   TOOLTIP ▸ Cómo leer e interpretar
     • pct_faltante_efectivo > pct_nulos ⇒ hay NULOS DISFRAZADOS ('', 'N/A',
       '-', '#N/A'...). Un IS NULL no los ve y los modelos los tratan como
       una categoría más (sesgo silencioso). Normalícenlos a NULL en silver.
     • ratio_unicidad = distintos / válidos. 1.0 sin nulos ⇒ POSIBLE_CLAVE.
       Entre 0.95 y 1 en un ID ⇒ CASI_UNICA: hay duplicados que no deberían.
     • CONSTANTE / CASI_CONSTANTE (moda ≥ 99%): sin poder informativo; en ML
       se eliminan (varianza ~0) y en BI suelen ser columnas "por defecto".
     • LONGITUD_IRREGULAR: ≥ 90% de valores comparte una longitud (código de
       largo fijo: DNI=8, RUC=11, ubigeo=6) pero el resto no ⇒ ceros perdidos
       o truncamientos. Revisen L1.03.
     • ESPACIOS_BORDES, SALTOS_LINEA, TABS, CTRL, INVISIBLES (NBSP, BOM,
       zero-width): rompen JOINs ('Lima ' ≠ 'Lima'), GROUP BYs y exportes CSV.
     • MOJIBAKE ('Ã±' en vez de 'ñ', '�'): error de encoding (UTF-8 leído
       como Latin-1/Windows-1252) en la ingesta. Arreglen en la fuente.
   ──────────────────────────────────────────────────────────────────────────── */
SELECT ordinal, columna, tipo_declarado, familia, n_filas,
       round(n_nulos / NULLIF(n_filas, 0), 4)                                              AS pct_nulos,
       round((n_nulos + n_vacios + n_solo_espacios + n_placeholder) / NULLIF(n_filas, 0), 4) AS pct_faltante_efectivo,
       n_vacios, n_solo_espacios, n_placeholder, placeholders_vistos,
       n_distintos,
       round(n_distintos / NULLIF(n_validos, 0), 4)                                        AS ratio_unicidad,
       moda,
       round(n_moda / NULLIF(n_validos, 0), 4)                                             AS pct_moda,
       largo_min, largo_max, round(largo_prom, 2) AS largo_prom, largo_moda,
       round(pct_largo_moda, 4) AS pct_largo_moda,
       n_espacios_bordes, n_saltos_linea, n_tabs, n_ctrl_otros, n_invisibles, n_mojibake, n_no_ascii,
       filter(array(
         IF(n_validos = 0, 'COLUMNA_SIN_VALORES', NULL),
         IF(n_nulos / NULLIF(n_filas, 0) >= dq_umbral_nulos_critico AND n_validos > 0, 'NULOS_CRITICO',
            IF(n_nulos / NULLIF(n_filas, 0) >= dq_umbral_nulos_alerta, 'NULOS_ALERTA', NULL)),
         IF(n_vacios + n_solo_espacios + n_placeholder > 0, 'NULOS_DISFRAZADOS', NULL),
         IF(n_distintos = 1, 'CONSTANTE', NULL),
         IF(n_distintos > 1 AND n_moda / NULLIF(n_validos, 0) >= 0.99, 'CASI_CONSTANTE', NULL),
         IF(n_distintos = n_validos AND n_validos = n_filas AND n_filas > 1, 'POSIBLE_CLAVE', NULL),
         IF(n_distintos / NULLIF(n_validos, 0) BETWEEN 0.95 AND 0.99999 AND familia IN ('TEXTO', 'NUMERICO')
            AND NOT (familia = 'NUMERICO' AND tipo_declarado RLIKE '^(FLOAT|DOUBLE|REAL|DECIMAL)'),
            'CASI_UNICA', NULL),
         IF(familia IN ('TEXTO', 'NUMERICO') AND pct_largo_moda >= 0.90 AND pct_largo_moda < 1
            AND largo_max <= 30 AND n_largos_distintos > 1
            AND NOT (familia = 'NUMERICO' AND tipo_declarado RLIKE '^(FLOAT|DOUBLE|REAL|DECIMAL)'),
            'LONGITUD_IRREGULAR', NULL),
         IF(familia = 'TEXTO' AND n_espacios_bordes > 0, 'ESPACIOS_BORDES', NULL),
         IF(n_saltos_linea > 0, 'SALTOS_LINEA', NULL),
         IF(n_tabs > 0, 'TABS', NULL),
         IF(n_ctrl_otros > 0, 'CARACTERES_CONTROL', NULL),
         IF(n_invisibles > 0, 'CARACTERES_INVISIBLES', NULL),
         IF(n_mojibake > 0, 'MOJIBAKE', NULL)
       ), x -> x IS NOT NULL)                                                              AS alertas
FROM dq_l1_perfil
ORDER BY size(alertas) DESC, ordinal;


/* ────────────────────────────────────────────────────────────────────────────
   [L1.02] Top-N valores por columna (con % y % acumulado)
   DOCSTRING (es-PE)
     Para cada columna, los dq_top_n valores más frecuentes (incluye NULL,
     vacíos y placeholders, marcados en la columna clase) con su % sobre el
     total de filas y el % acumulado.
   TOOLTIP ▸ Cómo leer e interpretar
     • Si el top-1 es un placeholder ('0', '-', 'SIN DATO', '1900-01-01'...)
       la columna está más vacía de lo que dice IS NULL.
     • % acumulado del top-N cerca de 100% ⇒ variable categórica de baja
       cardinalidad (candidata a dominio cerrado en la capa 8).
     • Valores "por defecto" sospechosos: 0, 1, 'X', 'OTROS', '99999'.
     • En Databricks pueden visualizarlo como gráfico de barras por columna.
   ──────────────────────────────────────────────────────────────────────────── */
WITH t AS (
  SELECT f.columna, f.valor, f.n,
         sum(f.n) OVER (PARTITION BY f.columna) AS total,
         row_number() OVER (PARTITION BY f.columna ORDER BY f.n DESC, f.valor) AS rn
  FROM dq_freq f
)
SELECT c.ordinal, t.columna, t.rn AS ranking,
       t.valor,
       CASE WHEN t.valor IS NULL THEN 'NULO'
            WHEN dq_limpiar(t.valor) = '' THEN 'VACIO/ESPACIOS'
            WHEN dq_es_placeholder(t.valor) THEN 'PLACEHOLDER'
            ELSE 'VALOR' END                                    AS clase,
       t.n,
       round(t.n / t.total, 4)                                  AS pct,
       round(sum(t.n) OVER (PARTITION BY t.columna ORDER BY t.rn) / t.total, 4) AS pct_acumulado
FROM t
JOIN dq_columnas c ON c.columna = t.columna
WHERE t.rn <= dq_top_n
ORDER BY c.ordinal, t.rn;


/* ────────────────────────────────────────────────────────────────────────────
   [L1.03] Distribución de longitudes (columnas texto y códigos)
   DOCSTRING (es-PE)
     Para columnas TEXTO y NUMERICO enteras con pocas longitudes distintas
     (≤ 15) y una longitud dominante (≥ 80% de los valores, típico de
     códigos de largo fijo), muestra cada longitud con su frecuencia, % y
     3 ejemplos.
   TOOLTIP ▸ Cómo leer e interpretar
     • Un DNI debe tener 8 caracteres, un RUC 11, un ubigeo 6, un celular 9:
       las longitudes minoritarias son los errores (ceros a la izquierda
       perdidos, dígitos de más, concatenaciones).
     • Columna NUMERICO (p.ej. dni_num) con longitud 7 ⇒ el cero inicial se
       perdió al tipar como número: corrijan en la ingesta (lpad(...,8,'0')).
     • Textos libres tendrán muchas longitudes: no salen aquí (se filtran).
   ──────────────────────────────────────────────────────────────────────────── */
WITH l AS (
  SELECT f.columna, char_length(f.valor) AS largo, sum(f.n) AS n,
         slice(collect_list(f.valor), 1, 3) AS ejemplos
  FROM dq_freq f
  JOIN dq_columnas c ON c.columna = f.columna
  WHERE f.valor IS NOT NULL AND NOT dq_es_placeholder(f.valor) AND dq_limpiar(f.valor) <> ''
    AND (c.familia = 'TEXTO'
         OR (c.familia = 'NUMERICO' AND NOT c.tipo_declarado RLIKE '^(FLOAT|DOUBLE|REAL|DECIMAL)'))
  GROUP BY f.columna, char_length(f.valor)
), m AS (
  SELECT columna, count(*) AS n_largos, sum(n) AS total, max(n) / sum(n) AS pct_largo_top
  FROM l GROUP BY columna
)
SELECT c.ordinal, l.columna, l.largo, l.n,
       round(l.n / m.total, 4) AS pct,
       l.ejemplos,
       IF(l.n / m.total < 0.10 AND m.n_largos > 1, 'LONGITUD_MINORITARIA', NULL) AS marca
FROM l
JOIN m ON m.columna = l.columna
JOIN dq_columnas c ON c.columna = l.columna
WHERE m.n_largos BETWEEN 2 AND 15
  AND m.pct_largo_top >= 0.80
ORDER BY c.ordinal, l.n DESC;


/* ────────────────────────────────────────────────────────────────────────────
   [L1.04] Ejemplos de problemas de higiene de texto (con caracteres visibles)
   DOCSTRING (es-PE)
     Lista ejemplos concretos de valores con espacios en bordes, saltos de
     línea, tabs, caracteres de control, invisibles (NBSP/BOM/zero-width) o
     mojibake. Para que se VEAN, reemplaza: salto→⏎, tab→⇥, NBSP→⍽,
     zero-width/BOM→¤, espacio de borde→·.
   TOOLTIP ▸ Cómo leer e interpretar
     • valor_visible muestra exactamente qué hay "escondido" en el dato.
     • Con estos ejemplos se arma el caso para el dueño de la fuente (p.ej.
       "el sistema X exporta con NBSP desde Excel") y la regla de limpieza
       en silver (regexp_replace + trim).
   ──────────────────────────────────────────────────────────────────────────── */
WITH p AS (
  SELECT f.columna, f.valor, f.n,
         CASE
           WHEN f.valor RLIKE '[ÃÂ][\\x{0080}-\\x{00BF}\\x{2018}-\\x{201E}\\x{2030}\\x{0160}\\x{0161}]|\\x{FFFD}' THEN 'MOJIBAKE'
           WHEN f.valor RLIKE '[\\x{00A0}\\x{200B}\\x{200C}\\x{200D}\\x{2060}\\x{FEFF}]'       THEN 'INVISIBLES'
           WHEN f.valor RLIKE '[\\r\\n]'                                                      THEN 'SALTO_LINEA'
           WHEN f.valor RLIKE '\\t'                                                           THEN 'TAB'
           WHEN f.valor RLIKE '[\\x{0000}-\\x{0008}\\x{000B}\\x{000C}\\x{000E}-\\x{001F}\\x{007F}]' THEN 'CONTROL'
           WHEN f.valor <> dq_limpiar(f.valor) AND dq_limpiar(f.valor) <> ''                  THEN 'ESPACIOS_BORDES'
         END AS problema
  FROM dq_freq f
  JOIN dq_columnas c ON c.columna = f.columna
  WHERE f.valor IS NOT NULL AND c.familia IN ('TEXTO', 'COMPLEJO')
), r AS (
  SELECT *, row_number() OVER (PARTITION BY columna, problema ORDER BY n DESC, valor) AS rn
  FROM p WHERE problema IS NOT NULL
)
SELECT columna, problema, n,
       regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
         valor, '\\r?\\n', '⏎'), '\\t', '⇥'), '\\x{00A0}', '⍽'),
         '[\\x{200B}\\x{200C}\\x{200D}\\x{2060}\\x{FEFF}]', '¤'), '^ +', '·'), ' +$', '·') AS valor_visible,
       char_length(valor) AS largo
FROM r
WHERE rn <= 5
ORDER BY columna, problema, n DESC;


/* ────────────────────────────────────────────────────────────────────────────
   [L1.05] Duplicados a nivel tabla: exactos y casi-duplicados
   DOCSTRING (es-PE)
     Sobre dq_src (muestra): filas, filas distintas, filas duplicadas exactas
     (todas las columnas iguales) y "casi duplicadas" (iguales luego de
     normalizar mayúsculas y espacios en TODA la fila).
   TOOLTIP ▸ Cómo leer e interpretar
     • pct_duplicados_exactos > 0 en una tabla que debería tener grano único
       ⇒ cargas repetidas (re-ejecuciones no idempotentes, MERGE mal hecho,
       append en lugar de overwrite). Revisen DESCRIBE HISTORY (L0.08).
     • casi_duplicados > exactos ⇒ el mismo registro llega con diferencias
       cosméticas ('LIMA' vs 'Lima ') desde fuentes distintas.
     • Ojo con la muestra: si dq_columnas_clave está vacío la muestra es por
       hash de fila, y las copias exactas caen juntas (el conteo es fiable).
   ──────────────────────────────────────────────────────────────────────────── */
SELECT n_filas,
       n_filas_distintas,
       n_filas - n_filas_distintas                                   AS n_duplicados_exactos,
       round((n_filas - n_filas_distintas) / NULLIF(n_filas, 0), 6)  AS pct_duplicados_exactos,
       n_filas - n_filas_normalizadas_distintas                      AS n_casi_duplicados,
       round((n_filas - n_filas_normalizadas_distintas) / NULLIF(n_filas, 0), 6) AS pct_casi_duplicados
FROM (
  SELECT count(*)                                                            AS n_filas,
         count(DISTINCT sha2(to_json(struct(*)), 256))                       AS n_filas_distintas,
         count(DISTINCT sha2(lower(regexp_replace(to_json(struct(*)), '\\s+', '')), 256)) AS n_filas_normalizadas_distintas
  FROM dq_src
);


/* ────────────────────────────────────────────────────────────────────────────
   [L1.06] Ejemplos de filas duplicadas exactas
   DOCSTRING (es-PE)
     Muestra hasta dq_top_n grupos de filas idénticas con cuántas veces se
     repiten (la fila se muestra como JSON para verla completa).
   TOOLTIP ▸ Cómo leer e interpretar
     • Si las repeticiones son exactamente 2, 3... y coinciden con días de
       re-proceso, es un problema de idempotencia del pipeline.
     • Si sólo difieren columnas técnicas (fecha_carga, _ingest_ts) excluyan
       esas columnas con dq_regex_excluir_columnas y vuelvan a correr: así
       aparecen los duplicados "de negocio".
   ──────────────────────────────────────────────────────────────────────────── */
SELECT fila_json, count(*) AS repeticiones
FROM (SELECT to_json(struct(*)) AS fila_json FROM dq_src)
GROUP BY fila_json
HAVING count(*) > 1
ORDER BY repeticiones DESC, fila_json
LIMIT dq_top_n;


/* ────────────────────────────────────────────────────────────────────────────
   [L1.07] Unicidad de la clave de negocio (dq_columnas_clave)
   DOCSTRING (es-PE)
     Si se configuró dq_columnas_clave, mide: filas, claves distintas, filas
     con alguna parte de la clave nula, claves duplicadas, filas involucradas
     y claves duplicadas CON CONFLICTO (misma clave, distinto contenido).
     Si no hay clave configurada, devuelve un mensaje informativo.
   TOOLTIP ▸ Cómo leer e interpretar
     • claves_duplicadas_identicas: la misma fila cargada varias veces
       (deduplicar con DISTINCT/QUALIFY es seguro).
     • claves_duplicadas_con_conflicto: varias VERSIONES del mismo registro
       (p.ej. cliente con 2 direcciones). Deduplicar a ciegas pierde
       información: definan la regla de supervivencia (la más reciente, la
       de fuente maestra...) o modelen como SCD tipo 2.
     • filas_clave_nula > 0 en una PK ⇒ error grave (la entidad no es
       identificable; los JOIN la descartan en silencio).
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_sql = IF(
  trim(dq_columnas_clave) = '',
  concat('SELECT ', dq_lit('Sin clave configurada: hagan SET VAR dq_columnas_clave = ...'), ' AS info'),
  (SELECT concat(
     'SELECT ', dq_lit(dq_columnas_clave), ' AS clave, ',
     'sum(n) AS n_filas, count(*) AS n_claves_distintas, ',
     'sum(IF(clave_nula, n, 0)) AS n_filas_clave_nula, ',
     'count_if(n > 1) AS n_claves_duplicadas, ',
     'sum(IF(n > 1, n, 0)) AS n_filas_en_claves_duplicadas, ',
     'count_if(n > 1 AND n_versiones = 1) AS n_claves_duplicadas_identicas, ',
     'count_if(n > 1 AND n_versiones > 1) AS n_claves_duplicadas_con_conflicto, ',
     'round(sum(IF(n > 1, n, 0)) / sum(n), 6) AS pct_filas_afectadas ',
     'FROM (SELECT ', k, ', count(*) AS n, ',
     'count(DISTINCT sha2(to_json(struct(*)), 256)) AS n_versiones, ',
     'max(', nulos, ') AS clave_nula ',
     'FROM dq_src GROUP BY ', k, ')')
   FROM (SELECT array_join(transform(split(dq_columnas_clave, ','),
                                     x -> concat('`', replace(trim(x), '`', '``'), '`')), ', ') AS k,
                array_join(transform(split(dq_columnas_clave, ','),
                                     x -> concat('`', replace(trim(x), '`', '``'), '` IS NULL')), ' OR ') AS nulos))
);
EXECUTE IMMEDIATE dq_sql;


/* ────────────────────────────────────────────────────────────────────────────
   [L1.08] Ejemplos de claves duplicadas y sus versiones en conflicto
   DOCSTRING (es-PE)
     Muestra hasta dq_top_n claves duplicadas, con cuántas filas y cuántas
     versiones distintas tiene cada una, y las columnas que DIFIEREN entre
     versiones (para entender el origen del conflicto).
   TOOLTIP ▸ Cómo leer e interpretar
     • columnas_que_difieren vacío ⇒ copias idénticas.
     • Si siempre difiere una columna técnica (fecha_carga) ⇒ duplicado por
       re-carga. Si difieren atributos de negocio ⇒ conflicto real de fuentes.
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_sql = IF(
  trim(dq_columnas_clave) = '',
  concat('SELECT ', dq_lit('Sin clave configurada'), ' AS info'),
  (SELECT concat(
     'WITH dup AS (SELECT ', k, ', count(*) AS _dq_n FROM dq_src GROUP BY ', k,
     '             HAVING count(*) > 1 ORDER BY _dq_n DESC LIMIT ', CAST(dq_top_n AS STRING), '), ',
     'l AS (SELECT ', k, ', _dq_n, ', dq_stack,
     '      FROM (SELECT s.*, dup._dq_n FROM dq_src s JOIN dup ON ', j, ') x), ',
     'v AS (SELECT ', k, ', _dq_n, columna, count(DISTINCT coalesce(valor, ', dq_lit('<NULL>'), ')) AS n_valores ',
     '      FROM l GROUP BY ', k, ', _dq_n, columna) ',
     'SELECT ', k, ', max(_dq_n) AS n_filas, ',
     'sort_array(collect_set(IF(n_valores > 1, columna, NULL))) AS columnas_que_difieren ',
     'FROM v GROUP BY ', k, ' ORDER BY n_filas DESC')
   FROM (SELECT array_join(transform(split(dq_columnas_clave, ','),
                                     x -> concat('`', replace(trim(x), '`', '``'), '`')), ', ') AS k,
                array_join(transform(split(dq_columnas_clave, ','),
                                     x -> concat('s.`', replace(trim(x), '`', '``'), '` <=> dup.`',
                                                 replace(trim(x), '`', '``'), '`')), ' AND ') AS j))
);
EXECUTE IMMEDIATE dq_sql;


/* ────────────────────────────────────────────────────────────────────────────
   [L1.09] Persistir métricas de la capa 1 (opcional)
   DOCSTRING (es-PE)
     Si dq_esquema_trabajo está configurado, guarda en dq_metricas por
     columna: pct_nulos, pct_faltante_efectivo, n_distintos, ratio_unicidad,
     pct_moda y largo_prom, con la marca de la corrida.
   TOOLTIP ▸ Cómo interpretar
     • Con la historia pueden aplicar detección de anomalías sobre métricas
       (p.ej. pct_nulos de hoy > media + 3σ de los últimos 30 días), que es
       como trabajan Deequ y Lakehouse Monitoring.
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_sql = IF(
  dq_esquema_trabajo = '',
  concat('SELECT ', dq_lit('persistencia desactivada (dq_esquema_trabajo vacío)'), ' AS info'),
  concat('INSERT INTO ', dq_esquema_trabajo, '.dq_metricas ',
         'SELECT ', dq_lit(dq_id_corrida), ', current_timestamp(), ', dq_lit(dq_tabla_fq), ', columna, ',
         dq_lit('L1'), ', metrica, valor, NULL FROM dq_l1_perfil ',
         'LATERAL VIEW stack(6, ',
           dq_lit('pct_nulos'), ', n_nulos / NULLIF(n_filas, 0), ',
           dq_lit('pct_faltante_efectivo'), ', (n_nulos + n_vacios + n_solo_espacios + n_placeholder) / NULLIF(n_filas, 0), ',
           dq_lit('n_distintos'), ', CAST(n_distintos AS DOUBLE), ',
           dq_lit('ratio_unicidad'), ', n_distintos / NULLIF(n_validos, 0), ',
           dq_lit('pct_moda'), ', n_moda / NULLIF(n_validos, 0), ',
           dq_lit('largo_prom'), ', CAST(largo_prom AS DOUBLE)) s AS metrica, valor'));
EXECUTE IMMEDIATE dq_sql;
