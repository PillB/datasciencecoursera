/* ════════════════════════════════════════════════════════════════════════════
   ARCHIVO 10 · CAPA 8 — REGLAS ESPECÍFICAS POR TABLA, SCORECARD Y PREPARACIÓN ML
   (lo más específico: conocimiento de negocio + uso final de la data)
   ────────────────────────────────────────────────────────────────────────────
   DOCSTRING (es-PE)
     1) Catálogo de reglas declarativas por tabla (estilo Great Expectations /
        Soda / dbt tests / Lakeflow-DLT expectations): cada regla es una
        expresión booleana SQL con dimensión DAMA, severidad y tolerancia.
        Se evalúan TODAS en una sola pasada sobre la tabla COMPLETA.
     2) Ejemplos de filas que fallan, y generación automática de CHECK
        constraints de Delta y de expectativas de Lakeflow Declarative
        Pipelines (DLT) a partir del catálogo ("reglas como código").
     3) Scorecard de calidad por dimensión (completitud, unicidad, validez,
        consistencia, oportunidad) en escala 0-100.
     4) Preparación para ML (Data-Centric AI de Andrew Ng / DeepLearning.AI,
        "ML Test Score" y "Data Validation for ML" de Google): perfil del
        target, Information Value / WoE por variable (con alerta de fuga),
        etiquetas en conflicto (mismas features, distinta etiqueta),
        solapamiento entre particiones (train/test) y una recomendación
        INCLUIR / TRANSFORMAR / EXCLUIR por variable.
     Requisitos: 00 y 02; el scorecard usa además 03 (L1) y 04 (L2).
   TOOLTIP ▸ Cómo usar / personalizar
     • Editen la vista dq_reglas (L8.00): ahí vive el conocimiento de negocio.
       Cada ronda nueva de información (diccionario, reglas del área usuaria,
       hallazgos de las capas 1-7) se traduce en filas nuevas de este catálogo.
     • Para ML configuren dq_expr_objetivo (y dq_valor_positivo si es binario)
       ANTES del archivo 02.
   ════════════════════════════════════════════════════════════════════════════ */


/* ────────────────────────────────────────────────────────────────────────────
   [L8.00] Catálogo de reglas de negocio (EDITABLE)
   DOCSTRING (es-PE)
     Vista con las reglas por tabla. Columnas:
       id_regla     : identificador único (se usa en nombres de constraints).
       tabla        : nombre de la tabla (sin catálogo/esquema) o '*' = todas.
       dimension    : COMPLETITUD | VALIDEZ | CONSISTENCIA | EXACTITUD |
                      OPORTUNIDAD | UNICIDAD.
       descripcion  : en lenguaje de negocio.
       expresion    : SQL booleano sobre la tabla CRUDA; TRUE = cumple.
                      Semántica de CHECK: NULL no es falla (se cuenta aparte
                      como indeterminado); para exigir presencia agreguen
                      "col IS NOT NULL".
       severidad    : CRITICA | ALTA | MEDIA | BAJA.
       tolerancia   : % máximo de filas que pueden fallar (0 = ninguna).
       activa       : false para desactivar sin borrar.
     Los ejemplos corresponden a una tabla "clientes" (la de las pruebas);
     reemplácenlos por los suyos.
   TOOLTIP ▸ Cómo interpretar / personalizar
     • Si una regla tiene un error de SQL (columna inexistente), L8.01 fallará
       e indicará la expresión: corríjanla o pongan activa = false.
     • Reglas que usan funciones dq_* (p.ej. dq_ruc_valido) sirven para
       evaluar aquí, pero NO se pueden convertir en CHECK/DLT (son temporales):
       L8.03 lo advierte. Para producción, conviertan la función en una
       función de Unity Catalog (CREATE FUNCTION cat.esq.ruc_valido ...).
     • La unicidad (clave) se valida en L1.07; la integridad referencial en
       L7.07. Aquí van reglas a nivel de FILA.
   ──────────────────────────────────────────────────────────────────────────── */
CREATE OR REPLACE TEMP VIEW dq_reglas AS
SELECT * FROM VALUES
  ('R01', 'clientes', 'COMPLETITUD',  'El cliente tiene identificador',              'id_cliente IS NOT NULL',                                   'CRITICA', 0.0,   true),
  ('R02', 'clientes', 'VALIDEZ',      'DNI de 8 dígitos (texto)',                    'dni RLIKE \'^[0-9]{8}$\'',                                 'ALTA',    0.01,  true),
  ('R03', 'clientes', 'VALIDEZ',      'RUC con dígito verificador válido (SUNAT)',   'dq_ruc_valido(ruc)',                                       'ALTA',    0.0,   true),
  ('R04', 'clientes', 'VALIDEZ',      'Edad entre 0 y 120 años',                     'edad BETWEEN 0 AND 120',                                   'ALTA',    0.0,   true),
  ('R05', 'clientes', 'CONSISTENCIA', 'Inicio no posterior al fin',                  'fecha_inicio <= fecha_fin',                                'ALTA',    0.0,   true),
  ('R06', 'clientes', 'OPORTUNIDAD',  'Fecha de alta no futura',                     'fecha_alta <= current_date()',                             'MEDIA',   0.0,   true),
  ('R07', 'clientes', 'VALIDEZ',      'Email con formato válido',                    'email RLIKE \'^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,}$\'', 'MEDIA', 0.01, true),
  ('R08', 'clientes', 'VALIDEZ',      'Flag activo en dominio S/N',                  'activo IN (\'S\', \'N\')',                                 'MEDIA',   0.0,   true),
  ('R09', 'clientes', 'EXACTITUD',    'Monto no negativo',                           'monto >= 0',                                               'ALTA',    0.005, true),
  ('R10', 'clientes', 'CONSISTENCIA', 'Distrito sin espacios en los bordes',         'distrito = trim(distrito)',                                'BAJA',    0.0,   true),
  ('R11', 'clientes', 'COMPLETITUD',  'Ingreso informado y numérico',                'ingreso IS NOT NULL AND NOT isnan(ingreso)',               'MEDIA',   0.10,  true),
  ('R12', 'clientes', 'VALIDEZ',      'Fecha de alta no centinela 1900-01-01',       'fecha_alta <> DATE\'1900-01-01\'',                         'MEDIA',   0.0,   true),
  ('R99', '*',        'COMPLETITUD',  'Ejemplo de regla global (desactivada)',       'true',                                                     'BAJA',    0.0,   false)
AS t(id_regla, tabla, dimension, descripcion, expresion, severidad, tolerancia, activa);


/* ────────────────────────────────────────────────────────────────────────────
   [L8.01] Evaluación de reglas sobre la tabla completa (una sola pasada)
   DOCSTRING (es-PE)
     Toma las reglas activas que aplican a dq_tabla (o '*'), genera UNA
     consulta con count_if(NOT (expresión)) y count_if((expresión) IS NULL)
     por regla, la guarda como vista dq_l8_resultados y muestra: filas,
     fallas, indeterminadas, % de fallas, tolerancia y estado.
   TOOLTIP ▸ Cómo leer e interpretar
     • FALLA: % fallas > tolerancia ⇒ incumplimiento; prioricen por severidad.
     • TOLERADO: hay fallas pero dentro de lo aceptado por negocio.
     • n_indeterminadas alto ⇒ la columna tiene muchos NULL: la regla "pasa"
       por vacío; complementen con una regla de COMPLETITUD.
     • Esta es la base para un "data contract": publiquen el resultado como
       tabla y conéctenlo a alertas (Databricks SQL Alerts).
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_sql = (
  WITH r AS (
    SELECT row_number() OVER (ORDER BY id_regla) AS k, *
    FROM dq_reglas
    WHERE activa AND (tabla = '*' OR lower(tabla) = lower(dq_tabla))
  )
  SELECT IF(count(*) = 0,
            concat('CREATE OR REPLACE TEMP VIEW dq_l8_resultados AS SELECT CAST(NULL AS STRING) AS id_regla, ',
                   '0L AS n_filas, 0L AS n_fallas, 0L AS n_indeterminadas WHERE false'),
            concat('CREATE OR REPLACE TEMP VIEW dq_l8_resultados AS ',
                   'SELECT id_regla, n_filas, n_fallas, n_indeterminadas FROM (SELECT n_filas, stack(',
                   CAST(count(*) AS STRING), ', ',
                   array_join(transform(array_sort(collect_list(struct(k, id_regla))),
                                        x -> concat(chr(39), x.id_regla, chr(39), ', f', CAST(x.k AS STRING),
                                                    ', i', CAST(x.k AS STRING))), ', '),
                   ') AS (id_regla, n_fallas, n_indeterminadas) FROM (SELECT count(*) AS n_filas, ',
                   array_join(transform(array_sort(collect_list(struct(k, expresion))),
                                        x -> concat('count_if(NOT (', x.expresion, ')) AS f', CAST(x.k AS STRING),
                                                    ', count_if((', x.expresion, ') IS NULL) AS i', CAST(x.k AS STRING))), ', '),
                   ' FROM ', dq_tabla_fq, ') a) b'))
  FROM r
);
EXECUTE IMMEDIATE dq_sql;

SELECT r.id_regla, r.dimension, r.severidad, r.descripcion, r.expresion,
       x.n_filas, x.n_fallas, x.n_indeterminadas,
       round(x.n_fallas / NULLIF(x.n_filas, 0), 6)                         AS pct_fallas,
       r.tolerancia,
       CASE WHEN x.n_fallas = 0 THEN 'CUMPLE'
            WHEN x.n_fallas / NULLIF(x.n_filas, 0) <= r.tolerancia THEN 'TOLERADO'
            ELSE 'FALLA' END                                                AS estado
FROM dq_l8_resultados x
JOIN dq_reglas r ON r.id_regla = x.id_regla
ORDER BY CASE estado WHEN 'FALLA' THEN 0 WHEN 'TOLERADO' THEN 1 ELSE 2 END,
         CASE r.severidad WHEN 'CRITICA' THEN 0 WHEN 'ALTA' THEN 1 WHEN 'MEDIA' THEN 2 ELSE 3 END,
         r.id_regla;


/* ────────────────────────────────────────────────────────────────────────────
   [L8.02] Ejemplos de filas que fallan una regla (dq_id_regla)
   DOCSTRING (es-PE)
     Muestra hasta dq_top_n filas (como JSON) que incumplen la regla indicada
     en dq_id_regla (por defecto, la primera regla en estado de falla).
   TOOLTIP ▸ Cómo leer e interpretar
     • Úsenlo para el "caso" que se lleva al dueño de la data: ejemplos
       concretos aceleran el diagnóstico de causa raíz.
     • Cambien de regla con: SET VAR dq_id_regla = 'R05';
   ──────────────────────────────────────────────────────────────────────────── */
DECLARE OR REPLACE VARIABLE dq_id_regla STRING DEFAULT '';
SET VAR dq_id_regla = coalesce(nullif(dq_id_regla, ''),
  (SELECT min(x.id_regla) FROM dq_l8_resultados x WHERE x.n_fallas > 0), '');

SET VAR dq_sql = coalesce(
  (SELECT concat('SELECT ', dq_lit(id_regla), ' AS id_regla, ', dq_lit(descripcion), ' AS descripcion, ',
                 'to_json(struct(*)) AS fila FROM ', dq_tabla_fq, ' WHERE NOT (', expresion, ') LIMIT ',
                 CAST(dq_top_n AS STRING))
     FROM dq_reglas WHERE id_regla = dq_id_regla),
  concat('SELECT ', dq_lit('Ninguna regla con fallas (o dq_id_regla no existe)'), ' AS info'));
EXECUTE IMMEDIATE dq_sql;


/* ────────────────────────────────────────────────────────────────────────────
   [L8.03] Reglas como código: CHECK constraints de Delta y expectativas DLT
   DOCSTRING (es-PE)
     A partir del catálogo genera, por regla activa de la tabla:
       ddl_check_delta   : ALTER TABLE ... ADD CONSTRAINT ... CHECK (...)
       expectativa_dlt   : CONSTRAINT ... EXPECT (...) [ON VIOLATION ...]
                           CRITICA → FAIL UPDATE; ALTA → DROP ROW;
                           MEDIA/BAJA → sólo registra (warn).
       advertencias      : si la regla no es portable (usa funciones dq_*
                           temporales) o no es determinística
                           (current_date/now/rand: no válida en CHECK).
   TOOLTIP ▸ Cómo leer e interpretar
     • Un CHECK en Delta RECHAZA toda escritura que lo viole: antes de
       agregarlo, la regla debe estar en CUMPLE (L8.01), si no el ALTER falla.
     • Las expectativas de Lakeflow/DLT registran métricas por regla en el
       event log del pipeline: es el monitoreo "en línea" de esta capa.
     • Copien la columna que corresponda y ejecútenla donde aplique.
   ──────────────────────────────────────────────────────────────────────────── */
SELECT id_regla, severidad, descripcion,
       concat('ALTER TABLE ', dq_tabla_fq, ' ADD CONSTRAINT dq_', lower(id_regla), ' CHECK (', expresion, ');') AS ddl_check_delta,
       concat('CONSTRAINT dq_', lower(id_regla), ' EXPECT (', expresion, ')',
              CASE severidad WHEN 'CRITICA' THEN ' ON VIOLATION FAIL UPDATE'
                             WHEN 'ALTA' THEN ' ON VIOLATION DROP ROW'
                             ELSE '' END) AS expectativa_dlt,
       filter(array(
         IF(expresion RLIKE '(?i)\\bdq_[a-z_]+\\s*\\(', 'NO_PORTABLE: usa función temporal dq_* (créenla en Unity Catalog)', NULL),
         IF(expresion RLIKE '(?i)\\b(current_date|current_timestamp|now|rand|randn|uuid)\\s*\\(',
            'NO_DETERMINISTICA: no válida en CHECK de Delta (sí en DLT)', NULL)
       ), a -> a IS NOT NULL) AS advertencias
FROM dq_reglas
WHERE activa AND (tabla = '*' OR lower(tabla) = lower(dq_tabla))
ORDER BY id_regla;


/* ────────────────────────────────────────────────────────────────────────────
   [L8.04] Scorecard de calidad por dimensión (0-100)
   DOCSTRING (es-PE)
     Consolida en una tabla de puntajes por dimensión DAMA/ISO 25012:
       COMPLETITUD  : 100 · (1 - promedio del % faltante efectivo por columna) [L1]
       UNICIDAD     : 100 · (1 - % de filas duplicadas exactas)               [dq_src]
       VALIDEZ_FORMATO : 100 · promedio del % del tipo sugerido en columnas
                      texto con tipo dominante                               [L2]
       Reglas por dimensión: 100 · (1 - fallas / filas) sumando las reglas
                      activas de esa dimensión                               [L8.01]
     y un puntaje GLOBAL = promedio simple de las dimensiones disponibles.
   TOOLTIP ▸ Cómo leer e interpretar
     • ≥ 98 excelente · 95-98 bueno · 90-95 regular · < 90 crítico (puntos de
       partida; acuerden los suyos con negocio como SLO de datos).
     • El puntaje es un RESUMEN para seguimiento ejecutivo; las decisiones se
       toman mirando el detalle (capas 1-8). Guárdenlo por corrida para ver
       la tendencia.
   ──────────────────────────────────────────────────────────────────────────── */
WITH completitud AS (
  SELECT 'COMPLETITUD' AS dimension,
         100 * (1 - avg((n_nulos + n_vacios + n_solo_espacios + n_placeholder) / NULLIF(n_filas, 0))) AS puntaje,
         'L1: promedio por columna' AS fuente
  FROM dq_l1_perfil
), unicidad AS (
  SELECT 'UNICIDAD' AS dimension,
         100 * (SELECT count(*) FROM (SELECT DISTINCT * FROM dq_src)) / NULLIF(count(*), 0) AS puntaje,
         'dq_src: filas distintas / filas' AS fuente
  FROM dq_src
), validez AS (
  SELECT 'VALIDEZ_FORMATO' AS dimension, 100 * avg(pct_sugerido) AS puntaje,
         'L2: % del tipo dominante en columnas texto' AS fuente
  FROM (SELECT columna, max_by(pct, especificidad) AS pct_sugerido
        FROM dq_l2_tipos WHERE pct >= dq_umbral_tipo_dominante GROUP BY columna)
), reglas AS (
  SELECT r.dimension, 100 * (1 - sum(x.n_fallas) / NULLIF(sum(x.n_filas), 0)) AS puntaje,
         concat('L8: ', count(*), ' reglas') AS fuente
  FROM dq_l8_resultados x JOIN dq_reglas r ON r.id_regla = x.id_regla
  GROUP BY r.dimension
), todo AS (
  SELECT * FROM completitud UNION ALL SELECT * FROM unicidad UNION ALL
  SELECT * FROM validez     UNION ALL SELECT * FROM reglas
)
SELECT dimension, round(puntaje, 2) AS puntaje, fuente,
       CASE WHEN puntaje >= 98 THEN 'EXCELENTE' WHEN puntaje >= 95 THEN 'BUENO'
            WHEN puntaje >= 90 THEN 'REGULAR' ELSE 'CRITICO' END AS nivel
FROM todo WHERE puntaje IS NOT NULL
UNION ALL
SELECT 'GLOBAL', round(avg(puntaje), 2), 'promedio simple de dimensiones',
       CASE WHEN avg(puntaje) >= 98 THEN 'EXCELENTE' WHEN avg(puntaje) >= 95 THEN 'BUENO'
            WHEN avg(puntaje) >= 90 THEN 'REGULAR' ELSE 'CRITICO' END
FROM todo WHERE puntaje IS NOT NULL;


/* ────────────────────────────────────────────────────────────────────────────
   [L8.05] ML · Perfil del target (_dq_objetivo)
   DOCSTRING (es-PE)
     Distribución de la variable objetivo definida en dq_expr_objetivo: por
     clase, n y %, nulos del target y razón de desbalance (mayoritaria /
     minoritaria). Si el target tiene > 20 valores se trata como continuo y
     se muestran estadísticos.
   TOOLTIP ▸ Cómo leer e interpretar
     • target_nulo > 0 ⇒ filas sin etiqueta: exclúyanlas del entrenamiento
       (o es un problema semi-supervisado).
     • razon_desbalance > 10 ⇒ desbalance fuerte: usen PR-AUC, recall por
       clase, ponderación o re-muestreo (sólo en train).
     • Si sale el aviso de "sin target", configuren dq_expr_objetivo y corran
       de nuevo el archivo 02.
   ──────────────────────────────────────────────────────────────────────────── */
WITH t AS (
  SELECT _dq_objetivo AS clase, count(*) AS n FROM dq_src GROUP BY _dq_objetivo
), s AS (
  SELECT count(*) AS k, sum(n) AS total,
         max(IF(clase IS NOT NULL, n, NULL)) AS n_mayor,
         min(IF(clase IS NOT NULL, n, NULL)) AS n_menor
  FROM t
)
SELECT CASE WHEN (SELECT count(*) FROM t WHERE clase IS NOT NULL) = 0 THEN '(sin target: configuren dq_expr_objetivo)'
            WHEN s.k > 21 THEN '(target continuo: ver estadísticos)'
            ELSE coalesce(t.clase, '<NULL>') END                                         AS clase,
       IF(s.k > 21, NULL, t.n)                                                           AS n,
       IF(s.k > 21, NULL, round(t.n / s.total, 4))                                       AS pct,
       IF(t.clase = dq_valor_positivo, 'POSITIVA', NULL)                                 AS marca,
       round(s.n_mayor / NULLIF(s.n_menor, 0), 2)                                        AS razon_desbalance,
       IF(s.k > 21, (SELECT concat('media=', round(avg(try_cast(_dq_objetivo AS DOUBLE)), 4),
                                   ' desv=', round(stddev(try_cast(_dq_objetivo AS DOUBLE)), 4),
                                   ' min=', min(try_cast(_dq_objetivo AS DOUBLE)),
                                   ' max=', max(try_cast(_dq_objetivo AS DOUBLE))) FROM dq_src), NULL) AS estadisticos
FROM t CROSS JOIN s
WHERE s.k <= 21 OR t.clase = (SELECT min(clase) FROM t)
ORDER BY n DESC NULLS LAST;


/* ────────────────────────────────────────────────────────────────────────────
   [L8.06] ML · Information Value (IV) y alerta de fuga por variable
   DOCSTRING (es-PE)
     Para target binario (clase positiva = dq_valor_positivo) calcula por
     variable el IV con cubetas: deciles para numéricas (> 10 valores), top-20
     categorías + OTROS para el resto, y NULL como cubeta propia.
       WoE_i = ln( (pos_i+0.5)/(P+0.5) / ((neg_i+0.5)/(N+0.5)) )
       IV    = Σ (pos_i/P - neg_i/N) · WoE_i
     También reporta la "pureza máxima": la mayor tasa de positivos (o de
     negativos) en una cubeta con ≥ dq_min_n_segmento filas.
     Deja el resultado en la vista dq_l8_iv.
   TOOLTIP ▸ Cómo leer e interpretar
     • IV < 0.02 inútil · 0.02-0.1 débil · 0.1-0.3 medio · 0.3-0.5 fuerte ·
       > dq_umbral_iv_sospechoso (0.5) SOSPECHOSO: demasiado bueno para ser
       verdad ⇒ probable FUGA DE INFORMACIÓN (variable posterior al evento,
       derivada del target, o ID que identifica casos).
     • pureza ≈ 1 en una cubeta grande ⇒ esa cubeta "decide" el target sola.
     • Práctica estándar en scoring crediticio (Siddiqi); también sirve para
       priorizar variables en cualquier clasificación binaria.
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_sql = concat(
  'CREATE OR REPLACE TEMP VIEW dq_l8_iv AS ',
  'WITH b AS (SELECT l.columna, l.valor, c.familia, ',
  '  CASE WHEN l._dq_objetivo = ', dq_lit(dq_valor_positivo), ' THEN 1 ELSE 0 END AS y, ',
  '  CASE WHEN c.familia = ', dq_lit('NUMERICO'), ' THEN nanvl(try_cast(l.valor AS DOUBLE), CAST(NULL AS DOUBLE)) ',
  '       WHEN c.familia = ', dq_lit('FECHA'), ' THEN CAST(datediff(try_cast(l.valor AS DATE), DATE', dq_lit('1970-01-01'), ') AS DOUBLE) ',
  '       WHEN c.familia = ', dq_lit('TEXTO'), ' AND dq_limpiar(l.valor) RLIKE ',
            dq_lit('^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$'), ' THEN try_cast(dq_limpiar(l.valor) AS DOUBLE) END AS x ',
  '  FROM dq_long l JOIN dq_columnas c ON c.columna = l.columna ',
  '  WHERE l._dq_objetivo IS NOT NULL AND lower(l.columna) <> lower(trim(', dq_lit(dq_expr_objetivo), '))), ',
  'tipo AS (SELECT columna, IF(count(x) >= 0.9 * count(valor) AND count(DISTINCT x) > 10, ', dq_lit('NUM'), ', ', dq_lit('CAT'), ') AS t, ',
  '  percentile_approx(x, array(0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9), 10000) AS cortes FROM b GROUP BY columna), ',
  'top AS (SELECT columna, valor FROM (SELECT columna, valor, row_number() OVER (PARTITION BY columna ORDER BY count(*) DESC, valor) AS rn ',
  '  FROM b WHERE valor IS NOT NULL GROUP BY columna, valor) WHERE rn <= 20), ',
  'bin AS (SELECT b.columna, b.y, CASE WHEN b.valor IS NULL THEN ', dq_lit('__NULO__'), ' ',
  '  WHEN t.t = ', dq_lit('NUM'), ' AND b.x IS NOT NULL THEN concat(', dq_lit('D'), ', lpad(CAST(size(filter(array_distinct(t.cortes), c -> b.x > c)) AS STRING), 2, ', dq_lit('0'), ')) ',
  '  WHEN t.t = ', dq_lit('NUM'), ' THEN ', dq_lit('__NO_NUMERICO__'), ' ',
  '  WHEN tp.valor IS NOT NULL THEN b.valor ELSE ', dq_lit('__OTROS__'), ' END AS cubeta ',
  '  FROM b JOIN tipo t ON t.columna = b.columna LEFT JOIN top tp ON tp.columna = b.columna AND tp.valor = b.valor), ',
  'g AS (SELECT columna, cubeta, sum(y) AS pos, sum(1 - y) AS neg FROM bin GROUP BY columna, cubeta), ',
  'tot AS (SELECT columna, sum(pos) AS P, sum(neg) AS N FROM g GROUP BY columna) ',
  'SELECT g.columna, max(t.t) AS tipo_cubeta, count(*) AS n_cubetas, max(tot.P) AS n_positivos, max(tot.N) AS n_negativos, ',
  '  sum((g.pos / NULLIF(tot.P, 0) - g.neg / NULLIF(tot.N, 0)) * ln(((g.pos + 0.5) / (tot.P + 0.5)) / ((g.neg + 0.5) / (tot.N + 0.5)))) AS iv, ',
  '  max(IF(g.pos + g.neg >= ', CAST(dq_min_n_segmento AS STRING), ', greatest(g.pos, g.neg) / (g.pos + g.neg), NULL)) AS pureza_maxima, ',
  '  max_by(g.cubeta, abs(g.pos / NULLIF(tot.P, 0) - g.neg / NULLIF(tot.N, 0))) AS cubeta_mas_discriminante ',
  'FROM g JOIN tot ON tot.columna = g.columna JOIN tipo t ON t.columna = g.columna ',
  'WHERE tot.P > 0 AND tot.N > 0 GROUP BY g.columna');
EXECUTE IMMEDIATE dq_sql;

SELECT columna, tipo_cubeta, n_cubetas, n_positivos, n_negativos,
       round(iv, 4)            AS iv,
       CASE WHEN iv > dq_umbral_iv_sospechoso THEN 'SOSPECHOSO (posible fuga)'
            WHEN iv >= 0.3 THEN 'FUERTE' WHEN iv >= 0.1 THEN 'MEDIO'
            WHEN iv >= 0.02 THEN 'DEBIL' ELSE 'INUTIL' END AS poder_predictivo,
       round(pureza_maxima, 4) AS pureza_maxima,
       cubeta_mas_discriminante
FROM dq_l8_iv
ORDER BY iv DESC;


/* ────────────────────────────────────────────────────────────────────────────
   [L8.07] ML · Etiquetas en conflicto (mismas features, distinto target)
   DOCSTRING (es-PE)
     Agrupa filas con EXACTAMENTE las mismas features (todas las columnas
     menos el target, el segmento y las columnas tipo ID —distintos ≥ 95%
     de las filas—) y cuenta los grupos donde el target toma más de un valor.
   TOOLTIP ▸ Cómo leer e interpretar
     • Grupos en conflicto = ruido de etiqueta o features insuficientes: el
       modelo no puede separar esos casos. En Data-Centric AI (Andrew Ng) se
       revisan y corrigen ANTES de tunear modelos; herramientas como
       cleanlab automatizan esta idea.
     • Si n_grupos_duplicados es alto pero sin conflicto, hay filas repetidas
       que inflan el entrenamiento (y pueden caer en train y test: ver L8.08).
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_sql = (
  WITH f AS (
    SELECT c.columna, c.ordinal, dq_id(c.columna) AS ident
    FROM dq_columnas c
    JOIN (SELECT columna, count_if(valor IS NOT NULL) AS n_dist, sum(n) AS n_filas FROM dq_freq GROUP BY columna) d
      ON d.columna = c.columna
    WHERE d.n_dist < 0.95 * d.n_filas
      AND lower(c.columna) <> lower(trim(dq_expr_objetivo))
  ), l AS (
    SELECT array_join(transform(array_sort(collect_list(struct(ordinal, columna))), x -> x.columna), ', ') AS nombres,
           array_join(transform(array_sort(collect_list(struct(ordinal, ident))), x -> x.ident), ', ')     AS idents
    FROM f
  )
  SELECT IF((SELECT count(_dq_objetivo) FROM dq_src) = 0 OR idents = '',
            concat('SELECT ', dq_lit('Sin target (configuren dq_expr_objetivo y corran el 02) o sin features elegibles'), ' AS info'),
            concat('SELECT count(*) AS n_grupos_duplicados, count_if(k > 1) AS n_grupos_en_conflicto, ',
                   'sum(IF(k > 1, n, 0)) AS n_filas_en_conflicto, ',
                   'round(sum(IF(k > 1, n, 0)) / (SELECT count(*) FROM dq_src), 6) AS pct_filas_en_conflicto, ',
                   dq_lit(nombres), ' AS features_usadas ',
                   'FROM (SELECT sha2(to_json(struct(', idents, ')), 256) AS h, count(*) AS n, count(DISTINCT _dq_objetivo) AS k ',
                   'FROM dq_src WHERE _dq_objetivo IS NOT NULL GROUP BY 1 HAVING count(*) > 1)'))
  FROM l
);
EXECUTE IMMEDIATE dq_sql;


/* ────────────────────────────────────────────────────────────────────────────
   [L8.08] ML · Solapamiento entre particiones (fuga train/test)
   DOCSTRING (es-PE)
     Si dq_expr_segmento define particiones (p.ej. TRAIN/TEST o meses),
     cuenta:
       • entidades (dq_columnas_clave) presentes en más de una partición;
       • filas idénticas (todas las columnas excepto segmento y target)
         presentes en más de una partición.
   TOOLTIP ▸ Cómo leer e interpretar
     • Entidades compartidas entre TRAIN y TEST ⇒ fuga por entidad: el
       modelo "memoriza" clientes y la métrica de test sale optimista. Usen
       partición agrupada por cliente (GroupKFold) o temporal.
     • Filas idénticas entre particiones ⇒ duplicados que inflan el test.
     • Si el segmento es temporal (meses), que un cliente aparezca en varios
       meses es normal; ahí lo grave son las filas idénticas.
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_sql = IF(
  (SELECT count(DISTINCT _dq_segmento) FROM dq_src) < 2,
  concat('SELECT ', dq_lit('Se requieren ≥ 2 segmentos en dq_expr_segmento'), ' AS info'),
  concat(
    'SELECT ', dq_lit('filas_identicas'), ' AS criterio, count(*) AS n_grupos_en_varias_particiones, sum(n) AS n_filas_involucradas ',
    'FROM (SELECT sha2(to_json(struct(', dq_lista_columnas, ')), 256) AS h, count(*) AS n, count(DISTINCT _dq_segmento) AS k ',
    'FROM dq_src GROUP BY 1) WHERE k > 1',
    IF(trim(dq_columnas_clave) = '', '',
       concat(' UNION ALL SELECT ', dq_lit(concat('entidad(', dq_columnas_clave, ')')), ', count(*), sum(n) ',
              'FROM (SELECT ',
              array_join(transform(split(dq_columnas_clave, ','), x -> concat('`', replace(trim(x), '`', '``'), '`')), ', '),
              ', count(*) AS n, count(DISTINCT _dq_segmento) AS k FROM dq_src GROUP BY ',
              array_join(transform(split(dq_columnas_clave, ','), x -> concat('`', replace(trim(x), '`', '``'), '`')), ', '),
              ') WHERE k > 1'))));
EXECUTE IMMEDIATE dq_sql;


/* ────────────────────────────────────────────────────────────────────────────
   [L8.09] ML · Recomendación por variable (INCLUIR / TRANSFORMAR / EXCLUIR)
   DOCSTRING (es-PE)
     Combina el perfil universal (L1) y el IV (L8.06) para recomendar qué
     hacer con cada columna como feature:
       EXCLUIR     : constante, ID (unicidad ≥ 95% en texto/entero, salvo
                     montos con decimales guardados como texto), > 95%
                     faltante, o IV sospechoso de fuga.
       TRANSFORMAR : faltantes relevantes (imputar + indicador), nulos
                     disfrazados, alta cardinalidad (encoding), espacios.
       INCLUIR     : el resto.
   TOOLTIP ▸ Cómo leer e interpretar
     • Es un punto de partida automático: la decisión final es de negocio
       (p.ej. una variable con fuga puede ser válida si se conoce en el
       momento de la predicción; verifiquen la "línea de tiempo" de cada
       variable).
     • Esta tabla es la base del documento de "feature selection" y del
       data card / datasheet del dataset (Gebru et al., 2018).
   ──────────────────────────────────────────────────────────────────────────── */
SELECT p.ordinal, p.columna, p.familia,
       round(p.n_nulos / p.n_filas, 4)                                                    AS pct_nulos,
       round((p.n_nulos + p.n_vacios + p.n_solo_espacios + p.n_placeholder) / p.n_filas, 4) AS pct_faltante_efectivo,
       p.n_distintos, round(p.n_distintos / NULLIF(p.n_validos, 0), 4)                    AS ratio_unicidad,
       round(iv.iv, 4) AS iv,
       CASE
         WHEN lower(p.columna) = lower(trim(dq_expr_objetivo))                              THEN 'TARGET'
         WHEN p.n_distintos <= 1                                                           THEN 'EXCLUIR'
         WHEN (p.n_nulos + p.n_vacios + p.n_solo_espacios + p.n_placeholder) / p.n_filas > 0.95 THEN 'EXCLUIR'
         WHEN p.n_distintos / NULLIF(p.n_validos, 0) >= 0.95 AND p.familia IN ('TEXTO', 'NUMERICO')
              AND NOT p.tipo_declarado RLIKE '^(FLOAT|DOUBLE|REAL|DECIMAL)'
              AND NOT coalesce(p.moda RLIKE '^-?[0-9]+[.][0-9]+$', false)                 THEN 'EXCLUIR'
         WHEN iv.iv > dq_umbral_iv_sospechoso                                              THEN 'EXCLUIR (revisar fuga)'
         WHEN (p.n_nulos + p.n_vacios + p.n_solo_espacios + p.n_placeholder) / p.n_filas > 0.05
              OR p.n_vacios + p.n_solo_espacios + p.n_placeholder > 0
              OR (p.familia = 'TEXTO' AND p.n_distintos > dq_max_cardinalidad_cat)
              OR p.n_espacios_bordes > 0                                                   THEN 'TRANSFORMAR'
         ELSE 'INCLUIR'
       END AS recomendacion,
       filter(array(
         IF(p.n_distintos <= 1, 'constante', NULL),
         IF(p.n_distintos / NULLIF(p.n_validos, 0) >= 0.95 AND p.familia IN ('TEXTO', 'NUMERICO')
            AND NOT p.tipo_declarado RLIKE '^(FLOAT|DOUBLE|REAL|DECIMAL)'
            AND NOT coalesce(p.moda RLIKE '^-?[0-9]+[.][0-9]+$', false), 'tipo ID / casi única', NULL),
         IF((p.n_nulos + p.n_vacios + p.n_solo_espacios + p.n_placeholder) / p.n_filas > 0.05, 'imputar + indicador de faltante', NULL),
         IF(p.n_vacios + p.n_solo_espacios + p.n_placeholder > 0, 'convertir nulos disfrazados a NULL', NULL),
         IF(p.familia = 'TEXTO' AND p.n_distintos > dq_max_cardinalidad_cat, 'alta cardinalidad: target/frequency encoding', NULL),
         IF(p.n_espacios_bordes > 0, 'trim/normalizar texto', NULL),
         IF(iv.iv > dq_umbral_iv_sospechoso, 'IV sospechoso: validar línea de tiempo (fuga)', NULL)
       ), x -> x IS NOT NULL) AS motivos
FROM dq_l1_perfil p
LEFT JOIN dq_l8_iv iv ON iv.columna = p.columna
ORDER BY CASE WHEN recomendacion LIKE 'EXCLUIR%' THEN 0 WHEN recomendacion = 'TRANSFORMAR' THEN 1 ELSE 2 END,
         p.ordinal;


/* ────────────────────────────────────────────────────────────────────────────
   [L8.10] Persistir resultados de reglas y scorecard (opcional)
   DOCSTRING (es-PE)
     Guarda en dq_metricas el % de fallas de cada regla (columna = id_regla)
     para el historial de cumplimiento.
   TOOLTIP ▸ Cómo interpretar
     • Con esta historia pueden construir un dashboard de cumplimiento por
       regla y por dimensión, y alertas cuando una regla pase a FALLA.
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_sql = IF(
  dq_esquema_trabajo = '',
  concat('SELECT ', dq_lit('persistencia desactivada (dq_esquema_trabajo vacío)'), ' AS info'),
  concat('INSERT INTO ', dq_esquema_trabajo, '.dq_metricas ',
         'SELECT ', dq_lit(dq_id_corrida), ', current_timestamp(), ', dq_lit(dq_tabla_fq), ', x.id_regla, ',
         dq_lit('L8'), ', ', dq_lit('pct_fallas_regla'), ', x.n_fallas / NULLIF(x.n_filas, 0), r.descripcion ',
         'FROM dq_l8_resultados x JOIN dq_reglas r ON r.id_regla = x.id_regla'));
EXECUTE IMMEDIATE dq_sql;
