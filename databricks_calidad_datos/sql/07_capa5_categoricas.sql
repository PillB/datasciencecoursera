/* ════════════════════════════════════════════════════════════════════════════
   ARCHIVO 07 · CAPA 5 — VARIABLES CATEGÓRICAS Y CONSISTENCIA DE DOMINIOS
   ────────────────────────────────────────────────────────────────────────────
   DOCSTRING (es-PE)
     Caracteriza columnas categóricas (texto, booleanas y numéricas de baja
     cardinalidad): cardinalidad, concentración, entropía de Shannon,
     impureza de Gini, categorías raras, y sobre todo CONSISTENCIA de
     escritura del dominio:
       • variantes de un mismo valor ('LIMA', 'Lima ', 'lima', 'Líma') vía
         "huella" (fingerprint/key-collision de OpenRefine);
       • casi-duplicados por distancia de edición (Levenshtein): 'Miraflroes'
         vs 'Miraflores';
       • estilo de mayúsculas mezclado.
     Dimensión DAMA/ISO: consistencia y validez de dominio.
     Requisitos: archivos 00 y 02.
   TOOLTIP ▸ Cómo usar
     • L5.01 da la foto general; L5.02/L5.03 generan la "tabla de
       homologación" (valor_crudo → valor_canonico) que luego se aplica en
       silver con un JOIN o un CASE.
     • Personalización futura: cuando tengan catálogos maestros (ubigeos
       INEI, códigos SBS, tablas de productos), validen dominio cerrado con
       la capa 8 (regla IN (SELECT ...)) en lugar de heurísticas.
   ════════════════════════════════════════════════════════════════════════════ */


/* ────────────────────────────────────────────────────────────────────────────
   [L5.00] Vista dq_cat: frecuencias de valores válidos de columnas categóricas
   DOCSTRING (es-PE)
     Toma dq_freq sin nulos, vacíos ni placeholders, para columnas TEXTO y
     BOOLEANO y numéricas enteras, y agrega la cardinalidad de cada columna.
   TOOLTIP ▸ Cómo interpretar
     • No devuelve filas. Las consultas filtran por cardinalidad según
       dq_max_cardinalidad_cat cuando corresponde.
   ──────────────────────────────────────────────────────────────────────────── */
CREATE OR REPLACE TEMP VIEW dq_cat AS
SELECT f.columna, c.familia, f.valor, f.n,
       count(*) OVER (PARTITION BY f.columna) AS cardinalidad,
       sum(f.n) OVER (PARTITION BY f.columna) AS n_validos
FROM dq_freq f
JOIN dq_columnas c ON c.columna = f.columna
WHERE f.valor IS NOT NULL
  AND dq_limpiar(f.valor) <> ''
  AND NOT dq_es_placeholder(f.valor)
  AND (c.familia IN ('TEXTO', 'BOOLEANO')
       OR (c.familia = 'NUMERICO' AND NOT c.tipo_declarado RLIKE '^(FLOAT|DOUBLE|REAL|DECIMAL)'));


/* ────────────────────────────────────────────────────────────────────────────
   [L5.01] Perfil categórico: cardinalidad, concentración, entropía y rareza
   DOCSTRING (es-PE)
     Por columna: cardinalidad, clase de cardinalidad, categoría top y su %,
     entropía de Shannon (bits), entropía normalizada (0 = un solo valor,
     1 = uniforme), impureza de Gini, número de categorías raras
     (p < dq_umbral_raro), % de filas en raras y singletons.
     Las numéricas sólo entran si tienen ≤ dq_max_cardinalidad_cat valores.
   TOOLTIP ▸ Cómo leer e interpretar
     • DESBALANCE_EXTREMO (top ≥ 95%): poca información; en un target es
       desbalance de clases (usar métricas PR-AUC, no accuracy).
     • entropia_normalizada baja con muchas categorías ⇒ "cola larga": pocas
       categorías concentran todo; agrupen la cola en 'OTROS' para modelar.
     • MUCHAS_RARAS (> 5% de filas en categorías raras): errores de
       escritura o dominio sin controlar (texto libre en un campo de lista).
     • ALTA_CARDINALIDAD: no usen one-hot; usen target/frequency encoding o
       embeddings, y verifiquen que no sea un ID camuflado (fuga en ML).
   ──────────────────────────────────────────────────────────────────────────── */
WITH b AS (
  SELECT *, n / n_validos AS p FROM dq_cat
  WHERE familia <> 'NUMERICO' OR cardinalidad <= dq_max_cardinalidad_cat
), a AS (
  SELECT columna,
         max(familia)                                         AS familia,
         max(cardinalidad)                                    AS cardinalidad,
         max(n_validos)                                       AS n_validos,
         max_by(valor, n)                                     AS categoria_top,
         max(p)                                               AS pct_top,
         -sum(p * log2(p))                                    AS entropia_bits,
         1 - sum(p * p)                                       AS gini_impureza,
         count_if(p < dq_umbral_raro)                         AS n_categorias_raras,
         sum(IF(p < dq_umbral_raro, n, 0)) / max(n_validos)   AS pct_filas_raras,
         count_if(n = 1)                                      AS n_singletons
  FROM b
  GROUP BY columna
)
SELECT c.ordinal, a.columna, a.familia, a.n_validos, a.cardinalidad,
       CASE WHEN a.cardinalidad = 1 THEN 'CONSTANTE'
            WHEN a.cardinalidad = 2 THEN 'BINARIA'
            WHEN a.cardinalidad <= 10 THEN 'BAJA'
            WHEN a.cardinalidad <= dq_max_cardinalidad_cat THEN 'MEDIA'
            WHEN a.cardinalidad <= 0.5 * a.n_validos THEN 'ALTA'
            ELSE 'CASI_UNICA (tipo ID)' END                                   AS clase_cardinalidad,
       a.categoria_top, round(a.pct_top, 4)                                   AS pct_top,
       round(a.entropia_bits, 4)                                              AS entropia_bits,
       round(a.entropia_bits / NULLIF(log2(a.cardinalidad), 0), 4)            AS entropia_normalizada,
       round(a.gini_impureza, 4)                                              AS gini_impureza,
       a.n_categorias_raras, round(a.pct_filas_raras, 4)                      AS pct_filas_raras,
       a.n_singletons,
       filter(array(
         IF(a.cardinalidad > 1 AND a.pct_top >= 0.95, 'DESBALANCE_EXTREMO', NULL),
         IF(a.pct_filas_raras > 0.05 AND a.cardinalidad <= 0.5 * a.n_validos, 'MUCHAS_RARAS', NULL),
         IF(a.cardinalidad > dq_max_cardinalidad_cat AND a.cardinalidad <= 0.5 * a.n_validos, 'ALTA_CARDINALIDAD', NULL),
         IF(a.familia = 'TEXTO' AND a.cardinalidad = 2, 'BINARIA_EN_TEXTO (¿booleano?)', NULL)
       ), x -> x IS NOT NULL)                                                 AS alertas
FROM a
JOIN dq_columnas c ON c.columna = a.columna
ORDER BY size(alertas) DESC, c.ordinal;


/* ────────────────────────────────────────────────────────────────────────────
   [L5.02] Variantes de escritura de un mismo valor (huella / fingerprint)
   DOCSTRING (es-PE)
     Agrupa los valores de cada columna texto (cardinalidad ≤ 5000) por su
     huella con letras (minúsculas, sin tildes, sin signos, tokens ordenados). Lista los
     grupos con más de una forma escrita, la forma dominante (sugerida como
     canónica) y cuántas filas usan formas NO dominantes.
   TOOLTIP ▸ Cómo leer e interpretar
     • Ejemplo: huella 'lima' → ['Lima' (1200), 'LIMA' (80), ' lima' (40),
       'Líma' (20)]: 140 filas se agruparían mal en cualquier reporte.
     • Úsenlo como tabla de homologación: valor_crudo → forma_dominante.
     • Ojo: la huella también junta 'Juan Pérez' y 'Pérez Juan' (orden de
       tokens) —casi siempre es deseable— y 'Peña'/'Pena' (por la ñ):
       revisen antes de aplicar automáticamente.
   ──────────────────────────────────────────────────────────────────────────── */
WITH h AS (
  SELECT columna, valor, n, dq_huella(valor) AS huella
  FROM dq_cat
  WHERE familia = 'TEXTO' AND cardinalidad <= 5000
), g AS (
  SELECT columna, huella,
         count(*)                                              AS n_formas,
         sum(n)                                                AS n_filas,
         max_by(valor, n)                                      AS forma_dominante,
         sum(n) - max(n)                                       AS n_filas_formas_no_dominantes,
         slice(sort_array(collect_list(named_struct('n', n, 'forma', valor)), false), 1, 10) AS formas
  FROM h
  WHERE huella RLIKE '[a-z]'
  GROUP BY columna, huella
  HAVING count(*) > 1
)
SELECT columna, huella, n_formas, n_filas, forma_dominante, n_filas_formas_no_dominantes,
       transform(formas, f -> concat('[', f.forma, '] × ', CAST(f.n AS STRING))) AS formas_y_frecuencias
FROM g
ORDER BY n_filas_formas_no_dominantes DESC, columna
LIMIT 1000;


/* ────────────────────────────────────────────────────────────────────────────
   [L5.03] Casi-duplicados por distancia de edición (posibles errores de tipeo)
   DOCSTRING (es-PE)
     En columnas texto con 3 a 500 huellas distintas, compara todas las
     parejas de huellas con letras (los códigos numéricos se excluyen) y reporta las que difieren en ≤ 2 ediciones
     (Levenshtein) con similitud ≥ 80% y longitud ≥ 4, indicando cuál es la
     forma frecuente y cuál la rara.
   TOOLTIP ▸ Cómo leer e interpretar
     • ratio_frecuencia = n_rara / n_frecuente. Si es < 0.1 la rara es casi
       seguro un error de tipeo de la frecuente ('miraflroes' → 'miraflores').
     • Si ambas son frecuentes (ratio > 0.5) probablemente son valores
       distintos y válidos ('san juan' vs 'san luis'): no homologar.
   ──────────────────────────────────────────────────────────────────────────── */
WITH h AS (
  SELECT columna, dq_huella(valor) AS huella, sum(n) AS n
  FROM dq_cat
  WHERE familia = 'TEXTO' AND cardinalidad <= 5000
  GROUP BY columna, dq_huella(valor)
), elig AS (
  SELECT columna FROM h GROUP BY columna HAVING count(*) BETWEEN 3 AND 500
), p AS (
  SELECT a.columna, a.huella AS h1, a.n AS n1, b.huella AS h2, b.n AS n2,
         levenshtein(a.huella, b.huella) AS distancia,
         greatest(char_length(a.huella), char_length(b.huella)) AS largo
  FROM h a
  JOIN h b ON a.columna = b.columna AND a.huella < b.huella
  JOIN elig e ON e.columna = a.columna
  WHERE least(char_length(a.huella), char_length(b.huella)) >= 4
    AND a.huella RLIKE '[a-z]' AND b.huella RLIKE '[a-z]'
    AND abs(char_length(a.huella) - char_length(b.huella)) <= 2
)
SELECT columna,
       IF(n1 >= n2, h1, h2)                         AS forma_frecuente,
       IF(n1 >= n2, n1, n2)                         AS n_frecuente,
       IF(n1 >= n2, h2, h1)                         AS forma_rara,
       IF(n1 >= n2, n2, n1)                         AS n_rara,
       distancia,
       round(1 - distancia / largo, 3)              AS similitud,
       round(least(n1, n2) / greatest(n1, n2), 4)   AS ratio_frecuencia,
       IF(least(n1, n2) / greatest(n1, n2) < 0.1, 'PROBABLE_TYPO', 'REVISAR') AS marca
FROM p
WHERE distancia BETWEEN 1 AND 2 AND 1 - distancia / largo >= 0.8
ORDER BY columna, ratio_frecuencia;


/* ────────────────────────────────────────────────────────────────────────────
   [L5.04] Estilo de mayúsculas por columna texto
   DOCSTRING (es-PE)
     Para columnas texto con cardinalidad ≤ 5000 donde ≥ 50% de las filas
     tienen letras (excluye números/fechas en texto), clasifica cada
     valor en MAYÚSCULAS, minúsculas, Tipo Título o Mixto y reporta el % de
     filas de cada estilo y si no hay un estilo dominante (≥ 90%).
   TOOLTIP ▸ Cómo leer e interpretar
     • ESTILO_MEZCLADO ⇒ los valores vienen de varias fuentes o de digitación
       libre: normalicen (upper/initcap) antes de agrupar o cruzar.
     • En códigos (AB-1234) lo esperado es 100% MAYUSCULAS.
   ──────────────────────────────────────────────────────────────────────────── */
WITH b AS (
  SELECT columna, n, n_validos, dq_limpiar(valor) AS t
  FROM dq_cat
  WHERE familia = 'TEXTO' AND cardinalidad <= 5000 AND valor RLIKE '[A-Za-zÁÉÍÓÚÑáéíóúñ]'
), e AS (
  SELECT columna, n, n_validos,
         CASE WHEN t = upper(t) THEN 'MAYUSCULAS'
              WHEN t = lower(t) THEN 'minusculas'
              WHEN t = initcap(t) THEN 'Titulo'
              ELSE 'Mixto' END AS estilo
  FROM b
)
SELECT columna,
       round(sum(IF(estilo = 'MAYUSCULAS', n, 0)) / sum(n), 4) AS pct_mayusculas,
       round(sum(IF(estilo = 'minusculas', n, 0)) / sum(n), 4) AS pct_minusculas,
       round(sum(IF(estilo = 'Titulo', n, 0)) / sum(n), 4)     AS pct_titulo,
       round(sum(IF(estilo = 'Mixto', n, 0)) / sum(n), 4)      AS pct_mixto,
       IF(greatest(sum(IF(estilo = 'MAYUSCULAS', n, 0)), sum(IF(estilo = 'minusculas', n, 0)),
                   sum(IF(estilo = 'Titulo', n, 0)), sum(IF(estilo = 'Mixto', n, 0))) / sum(n) < 0.9,
          'ESTILO_MEZCLADO', NULL)                              AS alerta
FROM e
GROUP BY columna
HAVING sum(n) >= 0.5 * max(n_validos)
ORDER BY alerta NULLS LAST, columna;


/* ────────────────────────────────────────────────────────────────────────────
   [L5.05] Categorías raras (detalle) en columnas de baja cardinalidad
   DOCSTRING (es-PE)
     Para columnas con cardinalidad ≤ dq_max_cardinalidad_cat lista las
     categorías con proporción < max(dq_umbral_raro, 0.5%) o con n < 5.
   TOOLTIP ▸ Cómo leer e interpretar
     • En un campo de lista cerrada (estado, canal, tipo de documento) una
       categoría rara suele ser un valor inválido ('X' en un flag S/N).
     • Para ML: categorías con n < 30 dan estimaciones inestables (agrúpenlas)
       y pueden no aparecer en producción (error de categoría desconocida).
   ──────────────────────────────────────────────────────────────────────────── */
SELECT columna, cardinalidad, valor, n, round(n / n_validos, 5) AS pct
FROM dq_cat
WHERE cardinalidad BETWEEN 2 AND dq_max_cardinalidad_cat
  AND (n / n_validos < greatest(dq_umbral_raro, 0.005) OR n < 5)
ORDER BY columna, n;


/* ────────────────────────────────────────────────────────────────────────────
   [L5.06] Persistir métricas categóricas (opcional)
   DOCSTRING (es-PE)
     Guarda por columna categórica: cardinalidad, % top y entropía
     normalizada, para detectar cambios de dominio entre corridas.
   TOOLTIP ▸ Cómo interpretar
     • Un salto en la cardinalidad entre corridas = categorías nuevas
       (nuevo producto/canal o valores basura): verifiquen el dominio.
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_sql = IF(
  dq_esquema_trabajo = '',
  concat('SELECT ', dq_lit('persistencia desactivada (dq_esquema_trabajo vacío)'), ' AS info'),
  concat('INSERT INTO ', dq_esquema_trabajo, '.dq_metricas ',
         'SELECT ', dq_lit(dq_id_corrida), ', current_timestamp(), ', dq_lit(dq_tabla_fq), ', columna, ',
         dq_lit('L5'), ', metrica, valor, NULL FROM (',
         'SELECT columna, CAST(max(cardinalidad) AS DOUBLE) AS cardinalidad, max(n / n_validos) AS pct_top, ',
         '-sum((n / n_validos) * log2(n / n_validos)) / NULLIF(log2(max(cardinalidad)), 0) AS entropia_norm ',
         'FROM dq_cat GROUP BY columna) ',
         'LATERAL VIEW stack(3, ', dq_lit('cardinalidad'), ', cardinalidad, ', dq_lit('pct_top'), ', pct_top, ',
         dq_lit('entropia_normalizada'), ', entropia_norm) s AS metrica, valor'));
EXECUTE IMMEDIATE dq_sql;
