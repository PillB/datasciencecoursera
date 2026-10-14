/* ════════════════════════════════════════════════════════════════════════════
   ARCHIVO 04 · CAPA 2 — INFERENCIA SEMÁNTICA DE TIPOS EN COLUMNAS TEXTO
   ────────────────────────────────────────────────────────────────────────────
   DOCSTRING (es-PE)
     Para cada columna STRING/VARCHAR "prueba" ~35 tipos semánticos sobre cada
     valor distinto (fecha en 8 formatos, timestamp, número en 8 formatos y
     locales, moneda, %, booleano, email, URL, UUID, JSON, IP, epoch, y
     documentos peruanos: DNI, RUC con dígito verificador, ubigeo, celular y
     fijo). Con eso:
       1) sugiere el tipo dominante (si ≥ dq_umbral_tipo_dominante),
       2) lista los valores que NO calzan (los sospechosos de error: la
          columna "casi toda fecha" con algunos valores que no lo son),
       3) detecta formatos mezclados (dd/MM con MM/dd, coma vs punto
          decimal, moneda embebida, ceros a la izquierda),
       4) perfila "máscaras" de forma (AA-9999) para hallar valores raros.
     Es la versión SQL de la inferencia de tipos de TFDV / pandas
     infer_dtype / Great Expectations "expect_column_values_to_match_regex"
     y del "pattern profiling" de herramientas comerciales.
     Método: regex de forma + try_cast (seguro con ANSI) + validación de
     calendario real (31/02 se rechaza) + dígito verificador.
   TOOLTIP ▸ Cómo usar
     • L2.01 es el resumen: una fila por columna con el diagnóstico.
       L2.02 baja al detalle de los valores sospechosos.
     • Personalización futura: agreguen tipos propios (código de producto,
       placa vehicular 'ABC-123', CCI, CUSPP) como (1) un flag en la vista
       dq_l2_flags, (2) una entrada en el stack de dq_l2_valor_tipo y (3) una
       fila en dq_l2_catalogo_tipos con su especificidad. Ver README.
   ════════════════════════════════════════════════════════════════════════════ */


/* ────────────────────────────────────────────────────────────────────────────
   [L2.00a] Catálogo de tipos semánticos (editable)
   DOCSTRING (es-PE)
     Vista con cada tipo semántico, su especificidad (a mayor número, más
     específico: gana al desempatar), el tipo Databricks recomendado y la
     expresión de conversión sugerida ({c} = nombre de la columna).
   TOOLTIP ▸ Cómo interpretar / personalizar
     • Si un valor calza en varios tipos (p.ej. '20131312955' es entero y
       RUC), se sugiere el MÁS específico que supere el umbral.
     • Cambien especificidades si en su dominio un tipo debe ganar a otro.
   ──────────────────────────────────────────────────────────────────────────── */
CREATE OR REPLACE TEMP VIEW dq_l2_catalogo_tipos AS
SELECT * FROM VALUES
  ('ruc_pe',              100, 'STRING(11)',      'mantener STRING; validar dígito verificador (dq_ruc_valido)'),
  ('uuid',                 98, 'STRING',          'lower(trim({c}))'),
  ('email',                97, 'STRING',          'lower(trim({c})) y validar dominio'),
  ('ipv4',                 96, 'STRING',          'trim({c})'),
  ('url',                  95, 'STRING',          'trim({c})'),
  ('json',                 94, 'VARIANT/STRUCT',  'parse_json({c}) o from_json({c}, esquema)'),
  ('timestamp_iso',        92, 'TIMESTAMP',       'try_cast({c} AS TIMESTAMP)'),
  ('timestamp_dmy',        91, 'TIMESTAMP',       'try_to_timestamp({c}, \'d/M/yyyy H:mm[:ss]\')'),
  ('fecha_iso',            90, 'DATE',            'try_cast({c} AS DATE)'),
  ('fecha_ymd_barra',      89, 'DATE',            'try_cast(replace({c}, \'/\', \'-\') AS DATE)'),
  ('fecha_dmy',            88, 'DATE',            'CAST(try_to_timestamp({c}, \'d/M/yyyy\') AS DATE)'),
  ('fecha_mdy',            87, 'DATE',            'CAST(try_to_timestamp({c}, \'M/d/yyyy\') AS DATE)'),
  ('fecha_texto_mes',      86, 'DATE',            'traducir mes (ENE→01, SET→09) y luego to_date'),
  ('fecha_compacta',       85, 'DATE',            'CAST(try_to_timestamp({c}, \'yyyyMMdd\') AS DATE)'),
  ('fecha_anio_2dig',      84, 'DATE',            'evitar: definir pivote de siglo explícito'),
  ('fecha_cualquiera',     83, 'DATE',            'MULTIFORMATO: normalizar cada formato por separado (coalesce)'),
  ('hora',                 82, 'STRING/INT',      'convertir a segundos del día si se opera'),
  ('epoch_ms',             81, 'TIMESTAMP',       'timestamp_millis(CAST({c} AS BIGINT))'),
  ('epoch_s',              80, 'TIMESTAMP',       'timestamp_seconds(CAST({c} AS BIGINT))'),
  ('telefono_movil_pe',    79, 'STRING(9)',       'right(regexp_replace({c}, \'[^0-9]\', \'\'), 9)'),
  ('telefono_fijo_pe',     78, 'STRING',          'regexp_replace({c}, \'[^0-9]\', \'\')'),
  ('ubigeo_pe',            77, 'STRING(6)',       'lpad(trim({c}), 6, \'0\')'),
  ('dni_pe',               76, 'STRING(8)',       'lpad(trim({c}), 8, \'0\')'),
  ('porcentaje',           75, 'DECIMAL(9,4)',    'try_cast(replace(replace({c}, \'%\', \'\'), \',\', \'.\') AS DECIMAL(9,4)) / 100'),
  ('moneda',               74, 'DECIMAL(18,2)',   'quitar símbolo (S/, $, USD) y separador de miles; luego try_cast'),
  ('booleano',             72, 'BOOLEAN',         'lower(trim({c})) IN (\'s\', \'si\', \'sí\', \'y\', \'yes\', \'t\', \'true\', \'v\', \'verdadero\')'),
  ('entero_ceros_izq',     70, 'STRING',          'mantener STRING: es un código (castear pierde ceros)'),
  ('entero',               65, 'BIGINT',          'try_cast({c} AS BIGINT)'),
  ('decimal_punto',        60, 'DECIMAL(p,s)',    'try_cast({c} AS DECIMAL(p,s))  -- p,s en L2.05'),
  ('cientifico',           58, 'DOUBLE',          'try_cast({c} AS DOUBLE)'),
  ('miles_coma',           56, 'DECIMAL(p,s)',    'try_cast(replace({c}, \',\', \'\') AS DECIMAL(p,s))'),
  ('miles_punto',          55, 'DECIMAL(p,s)',    'try_cast(replace(replace({c}, \'.\', \'\'), \',\', \'.\') AS DECIMAL(p,s))'),
  ('decimal_coma',         54, 'DECIMAL(p,s)',    'try_cast(replace({c}, \',\', \'.\') AS DECIMAL(p,s))'),
  ('numero_estandar',      50, 'DECIMAL(p,s)',    'try_cast({c} AS DECIMAL(p,s))  -- p,s en L2.05'),
  ('numero_cualquiera',    45, 'DECIMAL(p,s)',    'MULTIFORMATO: normalizar locale/moneda/% antes de castear'),
  ('codigo_alfanumerico',  40, 'STRING',          'upper(trim({c}))'),
  ('texto',                10, 'STRING',          'texto libre')
AS t(tipo, especificidad, tipo_destino, conversion_sugerida);


/* ────────────────────────────────────────────────────────────────────────────
   [L2.00b] Vista dq_l2_flags: un flag booleano por tipo y por valor distinto
   DOCSTRING (es-PE)
     Para cada valor distinto de cada columna TEXTO (excluye nulos, vacíos y
     placeholders, que ya se midieron en la capa 1) calcula t = valor limpio
     y ~40 indicadores: forma (regex) + validez (try_cast, calendario real,
     dígito verificador). También partes de fechas dd/MM para resolver
     ambigüedades.
   TOOLTIP ▸ Cómo interpretar
     • No devuelve filas. Es la base de L2.01-L2.07.
     • Ojo: se evalúa sobre valores DISTINTOS (n = frecuencia): es barato aun
       con millones de filas, salvo columnas tipo ID (todo distinto).
   ──────────────────────────────────────────────────────────────────────────── */
CREATE OR REPLACE TEMP VIEW dq_l2_flags AS
WITH v AS (
  SELECT f.columna, f.valor, f.n, dq_limpiar(f.valor) AS t
  FROM dq_freq f
  JOIN dq_columnas c ON c.columna = f.columna
  WHERE c.familia = 'TEXTO'
    AND f.valor IS NOT NULL
    AND dq_limpiar(f.valor) <> ''
    AND NOT dq_es_placeholder(f.valor)
), b AS (
  SELECT columna, valor, n, t,
    -- números
    t RLIKE '^[+-]?[0-9]+$'                                                    AS es_entero,
    t RLIKE '^0[0-9]+$'                                                        AS es_entero_ceros_izq,
    t RLIKE '^[+-]?([0-9]+[.][0-9]+|[.][0-9]+)$'                               AS es_decimal_punto,
    t RLIKE '^[+-]?[0-9]+,[0-9]+$'                                             AS es_decimal_coma,
    t RLIKE '^[+-]?[0-9]{1,3}(,[0-9]{3})+([.][0-9]+)?$'                        AS es_miles_coma,
    t RLIKE '^[+-]?[0-9]{1,3}([.][0-9]{3})+(,[0-9]+)?$'                        AS es_miles_punto,
    t RLIKE '^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)[eE][+-]?[0-9]+$'             AS es_cientifico,
    t RLIKE '^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$'          AS es_numero_estandar,
    t RLIKE '(?i)^(S/[.]?|PEN|USD|US[$]|[$]|€|EUR)\\s?[+-]?[0-9][0-9.,]*$'     AS es_moneda,
    t RLIKE '^[+-]?[0-9]+([.,][0-9]+)?\\s?%$'                                  AS es_porcentaje,
    -- fechas y tiempos
    t RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' AND try_cast(t AS DATE) IS NOT NULL AS es_fecha_iso,
    t RLIKE '^[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}$'
      AND try_cast(replace(t, '/', '-') AS DATE) IS NOT NULL                   AS es_fecha_ymd_barra,
    t RLIKE '^[0-9]{1,2}([/.-])[0-9]{1,2}\\1[0-9]{4}$'                         AS es_forma_dmy_mdy,
    t RLIKE '^[0-9]{1,2}([/.-])[0-9]{1,2}\\1[0-9]{4}$'
      AND dq_fecha_texto(t, 'DMY') IS NOT NULL                                 AS es_fecha_dmy,
    t RLIKE '^[0-9]{1,2}([/.-])[0-9]{1,2}\\1[0-9]{4}$'
      AND dq_fecha_texto(t, 'MDY') IS NOT NULL                                 AS es_fecha_mdy,
    CASE WHEN t RLIKE '^[0-9]{1,2}([/.-])[0-9]{1,2}\\1[0-9]{4}$'
         THEN CAST(regexp_extract(t, '^([0-9]{1,2})', 1) AS INT) END           AS parte1,
    CASE WHEN t RLIKE '^[0-9]{1,2}([/.-])[0-9]{1,2}\\1[0-9]{4}$'
         THEN CAST(regexp_extract(t, '^[0-9]{1,2}[/.-]([0-9]{1,2})', 1) AS INT) END AS parte2,
    t RLIKE '^(19|20)[0-9]{6}$' AND dq_fecha_texto(t, 'DMY') IS NOT NULL       AS es_fecha_compacta,
    t RLIKE '^[0-9]{1,2}([/.-])[0-9]{1,2}\\1[0-9]{2}$'                         AS es_fecha_anio_2dig,
    t RLIKE '(?i)^[0-9]{1,2}[-/ .]?(ene|feb|mar|abr|may|jun|jul|ago|set|sep|oct|nov|dic|jan|apr|aug|dec)[a-z]*[.]?[-/ .]?([0-9]{2}|[0-9]{4})$'
                                                                               AS es_fecha_texto_mes,
    t RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{1,2}:[0-9]{2}(:[0-9]{2}([.][0-9]{1,9})?)?\\s?(Z|[+-][0-9]{2}(:?[0-9]{2})?)?$'
      AND try_cast(t AS TIMESTAMP) IS NOT NULL                                 AS es_timestamp_iso,
    t RLIKE '(?i)^[0-9]{1,2}([/.-])[0-9]{1,2}\\1[0-9]{4}[ T][0-9]{1,2}:[0-9]{2}(:[0-9]{2})?\\s?([ap][.]?\\s?m[.]?)?$'
      AND (dq_fecha_texto(regexp_extract(t, '^(\\S+)', 1), 'DMY') IS NOT NULL
           OR dq_fecha_texto(regexp_extract(t, '^(\\S+)', 1), 'MDY') IS NOT NULL) AS es_timestamp_dmy,
    t RLIKE '^([01]?[0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?$'                   AS es_hora,
    t RLIKE '^1[0-9]{9}$'                                                      AS es_epoch_s,
    t RLIKE '^1[0-9]{12}$'                                                     AS es_epoch_ms,
    -- identificadores y formatos estructurados
    t RLIKE '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,}$'                AS es_email,
    t RLIKE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' AS es_uuid,
    (t LIKE '{%' AND json_object_keys(t) IS NOT NULL)
      OR (t LIKE '[%' AND json_array_length(t) IS NOT NULL)                    AS es_json,
    t RLIKE '(?i)^(https?|ftp)://[^\\s/$.?#][^\\s]*$'                          AS es_url,
    t RLIKE '^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])[.]){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])$' AS es_ipv4,
    -- Perú
    regexp_replace(t, '[\\s().-]', '') RLIKE '^([+]?51)?9[0-9]{8}$'            AS es_telefono_movil_pe,
    regexp_replace(t, '[\\s().-]', '') RLIKE '^([+]?51)?(01[0-9]{7}|0[4-8][0-9]{7})$' AS es_telefono_fijo_pe,
    t RLIKE '^[0-9]{8}$'                                                       AS es_dni_pe,
    t RLIKE '^(10|15|16|17|20)[0-9]{9}$'                                       AS es_ruc_forma,
    dq_ruc_valido(t)                                                           AS es_ruc_pe,
    t RLIKE '^(0[1-9]|1[0-9]|2[0-5])[0-9]{4}$'                                 AS es_ubigeo_pe,
    -- otros
    lower(t) IN ('true', 'false', 't', 'f', 'y', 'n', 'yes', 'no', 'si', 'sí', 's',
                 'verdadero', 'falso', 'v')                                    AS es_booleano,
    t RLIKE '^[A-Za-z0-9]+([-_/.][A-Za-z0-9]+)*$' AND t RLIKE '[0-9]' AND t RLIKE '[A-Za-z]' AS es_codigo_alfanumerico,
    t RLIKE '[A-Za-zÁÉÍÓÚÜÑáéíóúüñ]'                                           AS es_texto
  FROM v
)
SELECT *,
       (es_fecha_iso OR es_fecha_ymd_barra OR es_fecha_dmy OR es_fecha_mdy OR es_fecha_compacta
        OR es_fecha_texto_mes OR es_timestamp_iso OR es_timestamp_dmy)        AS es_fecha_cualquiera,
       (es_numero_estandar OR es_miles_coma OR es_miles_punto OR es_decimal_coma
        OR es_moneda OR es_porcentaje)                                         AS es_numero_cualquiera
FROM b;


/* ────────────────────────────────────────────────────────────────────────────
   [L2.00c] Vistas dq_l2_valor_tipo (largo) y dq_l2_tipos (agregado)
   DOCSTRING (es-PE)
     dq_l2_valor_tipo despivotea los flags a (columna, valor, n, tipo,
     coincide). dq_l2_tipos agrega por columna y tipo: n evaluados, n que
     coinciden y % de coincidencia, junto con la especificidad del catálogo.
   TOOLTIP ▸ Cómo interpretar
     • No devuelven filas. Para ver la matriz completa:
       SELECT * FROM dq_l2_tipos WHERE pct > 0 ORDER BY columna, pct DESC;
   ──────────────────────────────────────────────────────────────────────────── */
CREATE OR REPLACE TEMP VIEW dq_l2_valor_tipo AS
SELECT columna, valor, n, tipo, coincide
FROM dq_l2_flags
LATERAL VIEW stack(37,
  'ruc_pe', es_ruc_pe,                 'uuid', es_uuid,
  'email', es_email,                   'ipv4', es_ipv4,
  'url', es_url,                       'json', es_json,
  'timestamp_iso', es_timestamp_iso,   'timestamp_dmy', es_timestamp_dmy,
  'fecha_iso', es_fecha_iso,           'fecha_ymd_barra', es_fecha_ymd_barra,
  'fecha_dmy', es_fecha_dmy,           'fecha_mdy', es_fecha_mdy,
  'fecha_texto_mes', es_fecha_texto_mes, 'fecha_compacta', es_fecha_compacta,
  'fecha_anio_2dig', es_fecha_anio_2dig, 'fecha_cualquiera', es_fecha_cualquiera,
  'hora', es_hora,                     'epoch_ms', es_epoch_ms,
  'epoch_s', es_epoch_s,               'telefono_movil_pe', es_telefono_movil_pe,
  'telefono_fijo_pe', es_telefono_fijo_pe, 'ubigeo_pe', es_ubigeo_pe,
  'dni_pe', es_dni_pe,                 'porcentaje', es_porcentaje,
  'moneda', es_moneda,                 'booleano', es_booleano,
  'entero_ceros_izq', es_entero_ceros_izq, 'entero', es_entero,
  'decimal_punto', es_decimal_punto,   'cientifico', es_cientifico,
  'miles_coma', es_miles_coma,         'miles_punto', es_miles_punto,
  'decimal_coma', es_decimal_coma,     'numero_estandar', es_numero_estandar,
  'numero_cualquiera', es_numero_cualquiera, 'codigo_alfanumerico', es_codigo_alfanumerico,
  'texto', es_texto
) s AS tipo, coincide;

CREATE OR REPLACE TEMP VIEW dq_l2_tipos AS
SELECT vt.columna, vt.tipo, k.especificidad, k.tipo_destino, k.conversion_sugerida,
       sum(vt.n)                                   AS n_evaluados,
       sum(IF(vt.coincide, vt.n, 0))               AS n_coinciden,
       sum(IF(vt.coincide, vt.n, 0)) / sum(vt.n)   AS pct
FROM dq_l2_valor_tipo vt
JOIN dq_l2_catalogo_tipos k ON k.tipo = vt.tipo
GROUP BY vt.columna, vt.tipo, k.especificidad, k.tipo_destino, k.conversion_sugerida;


/* ────────────────────────────────────────────────────────────────────────────
   [L2.01] Resumen de inferencia por columna texto (tipo sugerido + diagnóstico)
   DOCSTRING (es-PE)
     Una fila por columna TEXTO con: tipo sugerido (el más específico con
     % ≥ dq_umbral_tipo_dominante), su %, cuántos valores no calzan, el tipo
     Databricks recomendado, la conversión sugerida, los 5 tipos con mayor %
     y un diagnóstico.
   TOOLTIP ▸ Cómo leer e interpretar
     • CONFORME: 100% de los valores calzan → se puede tipar sin pérdida.
     • DOMINANTE_CON_VIOLACIONES: p.ej. 96% fechas y 4% "otra cosa" → ese 4%
       son errores de captura/carga. Véanlos en L2.02 ANTES de castear (un
       try_cast los volvería NULL en silencio: pérdida de datos invisible).
     • FECHA_MULTIFORMATO / NUMERO_MULTIFORMATO: los valores sí son fechas o
       números, pero en formatos mezclados (ver L2.04 / L2.05).
     • CODIGO_CON_CEROS: números con ceros a la izquierda → NO castear a INT.
     • MIXTO: ningún tipo llega al umbral → texto libre o columna "comodín"
       (varios significados en un mismo campo): pregunten al dueño.
     • El tipo texto/codigo_alfanumerico como sugerido es normal en nombres,
       descripciones y códigos de negocio.
   ──────────────────────────────────────────────────────────────────────────── */
WITH t AS (
  SELECT * FROM dq_l2_tipos
), sug AS (
  SELECT columna,
         max(n_evaluados)                                                     AS n_evaluados,
         max_by(tipo, IF(pct >= dq_umbral_tipo_dominante, especificidad, -1)) AS tipo_candidato,
         max(IF(pct >= dq_umbral_tipo_dominante, 1, 0))                       AS hay_dominante,
         max_by(tipo, pct * 1000 + especificidad / 1000)                      AS tipo_mayoritario,
         slice(sort_array(collect_list(IF(pct > 0, named_struct('pct', round(pct, 4), 'tipo', tipo), NULL)), false), 1, 5) AS top5_tipos,
         max(IF(tipo = 'entero_ceros_izq', pct, 0))                           AS pct_ceros_izq
  FROM t
  GROUP BY columna
), res AS (
  SELECT s.*,
         IF(s.hay_dominante = 1, s.tipo_candidato, s.tipo_mayoritario) AS tipo_sugerido
  FROM sug s
)
SELECT c.ordinal, r.columna, r.n_evaluados,
       r.tipo_sugerido,
       round(t.pct, 4)                         AS pct_tipo_sugerido,
       t.n_evaluados - t.n_coinciden           AS n_no_calzan,
       t.tipo_destino, t.conversion_sugerida,
       r.top5_tipos,
       CASE
         WHEN r.hay_dominante = 0                                   THEN 'MIXTO'
         WHEN r.tipo_sugerido = 'fecha_cualquiera'                  THEN 'FECHA_MULTIFORMATO'
         WHEN r.tipo_sugerido = 'numero_cualquiera'                 THEN 'NUMERO_MULTIFORMATO'
         WHEN r.tipo_sugerido IN ('entero', 'numero_estandar', 'dni_pe', 'ubigeo_pe') AND r.pct_ceros_izq > 0
                                                                    THEN 'CODIGO_CON_CEROS'
         WHEN t.pct = 1                                             THEN 'CONFORME'
         ELSE 'DOMINANTE_CON_VIOLACIONES'
       END AS diagnostico
FROM res r
JOIN t ON t.columna = r.columna AND t.tipo = r.tipo_sugerido
JOIN dq_columnas c ON c.columna = r.columna
ORDER BY CASE diagnostico WHEN 'DOMINANTE_CON_VIOLACIONES' THEN 1 WHEN 'FECHA_MULTIFORMATO' THEN 2
                          WHEN 'NUMERO_MULTIFORMATO' THEN 3 WHEN 'CODIGO_CON_CEROS' THEN 4
                          WHEN 'MIXTO' THEN 5 ELSE 6 END,
         c.ordinal;


/* ────────────────────────────────────────────────────────────────────────────
   [L2.02] Valores que NO calzan con el tipo dominante (sospechosos de error)
   DOCSTRING (es-PE)
     Para columnas cuyo tipo dominante supera el umbral pero no llega al
     100%, lista los dq_top_n valores que no calzan (más frecuentes primero)
     y en qué OTROS tipos sí calzan (pista de la causa raíz).
   TOOLTIP ▸ Cómo leer e interpretar
     • Ejemplo clásico: columna fecha_iso con '31/12/2024' (calza en fecha_dmy:
       otro formato), '2024-02-30' (no calza en nada de fecha: fecha
       imposible), 'PENDIENTE' (texto: estado metido en un campo fecha).
     • tipos_donde_si_calza vacío ⇒ basura o error de digitación.
     • Ojo: si un "violador" es muy frecuente, quizá sea un placeholder del
       sistema fuente: agréguenlo a dq_es_placeholder.
   ──────────────────────────────────────────────────────────────────────────── */
WITH t AS (SELECT * FROM dq_l2_tipos),
sug AS (
  SELECT columna,
         max_by(tipo, IF(pct >= dq_umbral_tipo_dominante, especificidad, -1)) AS tipo_sugerido,
         max(IF(pct >= dq_umbral_tipo_dominante, 1, 0)) AS hay_dominante
  FROM t GROUP BY columna
), obj AS (
  SELECT s.columna, s.tipo_sugerido, t.pct
  FROM sug s JOIN t ON t.columna = s.columna AND t.tipo = s.tipo_sugerido
  WHERE s.hay_dominante = 1 AND t.pct < 1 AND s.tipo_sugerido NOT IN ('texto')
), viol AS (
  SELECT vt.columna, vt.valor, vt.n, o.tipo_sugerido, o.pct,
         row_number() OVER (PARTITION BY vt.columna ORDER BY vt.n DESC, vt.valor) AS rn
  FROM dq_l2_valor_tipo vt
  JOIN obj o ON o.columna = vt.columna AND o.tipo_sugerido = vt.tipo
  WHERE NOT vt.coincide
)
SELECT v.columna, v.tipo_sugerido, round(v.pct, 4) AS pct_tipo_sugerido,
       v.rn AS ranking, v.valor AS valor_sospechoso, v.n,
       (SELECT sort_array(collect_list(x.tipo))
          FROM dq_l2_valor_tipo x
         WHERE x.columna = v.columna AND x.valor = v.valor AND x.coincide) AS tipos_donde_si_calza
FROM viol v
WHERE v.rn <= dq_top_n
ORDER BY v.columna, v.rn;


/* ────────────────────────────────────────────────────────────────────────────
   [L2.03] Perfil de máscaras (forma) por columna texto
   DOCSTRING (es-PE)
     Convierte cada valor a su máscara (dígito→9, mayúscula→A, minúscula→a)
     y muestra, para columnas estructuradas (≤ 50 máscaras distintas), las
     máscaras con su %, ejemplos y una marca si es RARA (< 1% o < dq_umbral_raro).
   TOOLTIP ▸ Cómo leer e interpretar
     • Un código de producto 'AB-1234' tiene máscara 'AA-9999'. Si aparece
       'aa_99' (0.2%) es un valor mal formado aunque "parezca" código.
     • Placas peruanas 'ABC-123' → 'AAA-999'; celulares '999999999'.
     • Columnas con > 50 máscaras son texto libre y no se listan aquí.
   ──────────────────────────────────────────────────────────────────────────── */
WITH m AS (
  SELECT f.columna, dq_mascara(dq_limpiar(f.valor)) AS mascara, sum(f.n) AS n,
         slice(collect_list(f.valor), 1, 3) AS ejemplos
  FROM dq_freq f
  JOIN dq_columnas c ON c.columna = f.columna
  WHERE c.familia = 'TEXTO' AND f.valor IS NOT NULL
    AND dq_limpiar(f.valor) <> '' AND NOT dq_es_placeholder(f.valor)
  GROUP BY f.columna, dq_mascara(dq_limpiar(f.valor))
), tot AS (
  SELECT columna, sum(n) AS total, count(*) AS n_mascaras FROM m GROUP BY columna
), r AS (
  SELECT m.*, tot.total, tot.n_mascaras, m.n / tot.total AS pct,
         row_number() OVER (PARTITION BY m.columna ORDER BY m.n DESC, m.mascara) AS rn
  FROM m JOIN tot ON tot.columna = m.columna
  WHERE tot.n_mascaras BETWEEN 2 AND 50
)
SELECT columna, n_mascaras, rn AS ranking, mascara, n, round(pct, 5) AS pct, ejemplos,
       IF(pct < greatest(dq_umbral_raro, 0.01), 'MASCARA_RARA', NULL) AS marca
FROM r
WHERE rn <= dq_top_n OR pct < greatest(dq_umbral_raro, 0.01)
ORDER BY columna, rn;


/* ────────────────────────────────────────────────────────────────────────────
   [L2.04] Fechas guardadas como texto: formatos, ambigüedad dd/MM vs MM/dd
   DOCSTRING (es-PE)
     Para columnas texto donde ≥ 50% de los valores son alguna fecha, cuenta
     cuántos valores hay en cada formato y, para dd/MM/yyyy vs MM/dd/yyyy:
       solo_dmy  : primera parte > 12 (sólo puede ser día) → convención DMY.
       solo_mdy  : segunda parte > 12 (sólo puede ser día) → convención MDY.
       ambiguas  : ambas partes ≤ 12 y distintas (03/04 = ¿3 abr o 4 mar?).
       forma_invalida : tiene forma de fecha pero no existe en el calendario
                        bajo NINGUNA convención (31/02, 2024-13-01).
   TOOLTIP ▸ Cómo leer e interpretar
     • CONVIVEN_DMY_Y_MDY (solo_dmy > 0 y solo_mdy > 0): la columna mezcla
       convenciones (p.ej. una fuente peruana y otra en formato EE.UU.). Las
       "ambiguas" quedan indeterminables sin otra fuente: ¡ojo con castear!
     • FECHAS_IMPOSIBLES: errores de digitación o de validación en origen.
     • MULTIFORMATO: conviven ISO, dd/MM, yyyyMMdd... normalicen con un
       coalesce de conversiones por formato.
     • convencion_inferida usa la evidencia no ambigua (solo_dmy vs solo_mdy);
       si no hay evidencia, usa dq_orden_fecha_texto.
   ──────────────────────────────────────────────────────────────────────────── */
WITH a AS (
  SELECT columna,
         sum(n)                                                                AS n_evaluados,
         sum(IF(es_fecha_cualquiera, n, 0))                                    AS n_fecha_alguna,
         sum(IF(es_fecha_iso, n, 0))                                           AS n_iso,
         sum(IF(es_fecha_ymd_barra, n, 0))                                     AS n_ymd_barra,
         sum(IF(es_forma_dmy_mdy AND es_fecha_dmy AND NOT es_fecha_mdy, n, 0))  AS n_solo_dmy,
         sum(IF(es_forma_dmy_mdy AND es_fecha_mdy AND NOT es_fecha_dmy, n, 0))  AS n_solo_mdy,
         sum(IF(es_fecha_dmy AND es_fecha_mdy AND parte1 <> parte2, n, 0))      AS n_ambiguas,
         sum(IF(es_fecha_dmy AND es_fecha_mdy AND parte1 = parte2, n, 0))       AS n_dia_igual_mes,
         sum(IF(es_fecha_compacta, n, 0))                                      AS n_compacta,
         sum(IF(es_timestamp_iso, n, 0))                                       AS n_timestamp_iso,
         sum(IF(es_timestamp_dmy, n, 0))                                       AS n_timestamp_dmy,
         sum(IF(es_fecha_texto_mes, n, 0))                                     AS n_texto_mes,
         sum(IF(es_fecha_anio_2dig, n, 0))                                     AS n_anio_2dig,
         sum(IF((es_forma_dmy_mdy AND NOT es_fecha_dmy AND NOT es_fecha_mdy)
                OR (t RLIKE '^[0-9]{4}[-/][0-9]{1,2}[-/][0-9]{1,2}$'
                    AND NOT es_fecha_iso AND NOT es_fecha_ymd_barra
                    AND dq_fecha_texto(t, 'DMY') IS NULL), n, 0))              AS n_forma_invalida,
         sum(IF(NOT es_fecha_cualquiera AND NOT es_fecha_anio_2dig, n, 0))     AS n_no_fecha
  FROM dq_l2_flags
  GROUP BY columna
)
SELECT columna, n_evaluados,
       round(n_fecha_alguna / n_evaluados, 4) AS pct_fecha,
       n_iso, n_ymd_barra, n_solo_dmy, n_solo_mdy, n_ambiguas, n_dia_igual_mes,
       n_compacta, n_timestamp_iso, n_timestamp_dmy, n_texto_mes, n_anio_2dig,
       n_forma_invalida, n_no_fecha,
       CASE WHEN n_solo_dmy > n_solo_mdy THEN 'DMY'
            WHEN n_solo_mdy > n_solo_dmy THEN 'MDY'
            ELSE concat(upper(dq_orden_fecha_texto), ' (por defecto, sin evidencia)') END AS convencion_inferida,
       filter(array(
         IF(n_solo_dmy > 0 AND n_solo_mdy > 0, 'CONVIVEN_DMY_Y_MDY', NULL),
         IF(n_forma_invalida > 0, 'FECHAS_IMPOSIBLES', NULL),
         IF((IF(n_iso > 0, 1, 0) + IF(n_ymd_barra > 0, 1, 0) + IF(n_solo_dmy + n_solo_mdy + n_ambiguas + n_dia_igual_mes > 0, 1, 0)
             + IF(n_compacta > 0, 1, 0) + IF(n_timestamp_iso + n_timestamp_dmy > 0, 1, 0) + IF(n_texto_mes > 0, 1, 0)) > 1,
            'MULTIFORMATO', NULL),
         IF(n_anio_2dig > 0, 'ANIO_DE_2_DIGITOS', NULL),
         IF(n_ambiguas > 0 AND n_solo_dmy = 0 AND n_solo_mdy = 0, 'CONVENCION_INDETERMINADA', NULL),
         IF(n_no_fecha > 0, 'VALORES_NO_FECHA', NULL)
       ), x -> x IS NOT NULL) AS alertas
FROM a
WHERE n_fecha_alguna / n_evaluados >= 0.5
ORDER BY size(alertas) DESC, columna;


/* ────────────────────────────────────────────────────────────────────────────
   [L2.05] Números guardados como texto: locale, moneda, ceros y DECIMAL(p,s)
   DOCSTRING (es-PE)
     Para columnas texto donde ≥ 50% de los valores son algún número, cuenta
     formatos (estándar, coma decimal, separador de miles con coma o punto,
     moneda, %, científico, ceros a la izquierda), los casos AMBIGUOS
     ('1,234' = ¿mil doscientos o uno coma dos?) y sugiere DECIMAL(p,s) a
     partir de los dígitos enteros y decimales máximos observados.
   TOOLTIP ▸ Cómo leer e interpretar
     • LOCALE_MIXTO: conviven '1,234.50' y '1.234,50' (o '12,5' y '12.5'):
       un replace ciego corrompe la mitad de los montos. Normalicen por fuente.
     • MONEDA_EMBEBIDA ('S/ 100', 'USD 50'): además de limpiar el símbolo,
       ¡verifiquen que no se estén mezclando soles y dólares en un mismo campo!
     • CEROS_A_LA_IZQUIERDA: si hay '00123', probablemente es un código y no
       una cantidad.
     • decimal_sugerido es un mínimo: agreguen holgura (p+2) para crecimiento.
   ──────────────────────────────────────────────────────────────────────────── */
WITH a AS (
  SELECT columna,
         sum(n)                                                         AS n_evaluados,
         sum(IF(es_numero_cualquiera, n, 0))                            AS n_numero_alguno,
         sum(IF(es_numero_estandar, n, 0))                              AS n_estandar,
         sum(IF(es_entero, n, 0))                                       AS n_enteros,
         sum(IF(es_entero_ceros_izq, n, 0))                             AS n_ceros_izq,
         sum(IF(es_decimal_coma AND NOT es_miles_coma, n, 0))           AS n_decimal_coma,
         sum(IF(es_miles_coma AND NOT es_decimal_coma, n, 0))           AS n_miles_coma,
         sum(IF(es_miles_punto AND NOT es_decimal_punto, n, 0))         AS n_miles_punto,
         sum(IF((es_decimal_coma AND es_miles_coma) OR (es_decimal_punto AND es_miles_punto), n, 0)) AS n_ambiguos,
         sum(IF(es_moneda, n, 0))                                       AS n_moneda,
         sum(IF(es_porcentaje, n, 0))                                   AS n_porcentaje,
         sum(IF(es_cientifico, n, 0))                                   AS n_cientifico,
         sum(IF(NOT es_numero_cualquiera, n, 0))                        AS n_no_numero,
         max(IF(es_numero_estandar AND NOT es_cientifico,
                char_length(regexp_extract(t, '^[+-]?0*([0-9]*)', 1)), NULL))  AS max_digitos_enteros,
         max(IF(es_numero_estandar AND NOT es_cientifico,
                char_length(regexp_extract(t, '[.]([0-9]*)$', 1)), NULL))      AS max_digitos_decimales,
         min(IF(es_numero_estandar, try_cast(t AS DOUBLE), NULL))       AS min_valor,
         max(IF(es_numero_estandar, try_cast(t AS DOUBLE), NULL))       AS max_valor
  FROM dq_l2_flags
  GROUP BY columna
)
SELECT columna, n_evaluados,
       round(n_numero_alguno / n_evaluados, 4) AS pct_numero,
       n_estandar, n_enteros, n_ceros_izq, n_decimal_coma, n_miles_coma, n_miles_punto,
       n_ambiguos, n_moneda, n_porcentaje, n_cientifico, n_no_numero,
       min_valor, max_valor,
       concat('DECIMAL(', least(38, greatest(1, coalesce(max_digitos_enteros, 0) + coalesce(max_digitos_decimales, 0))),
              ',', least(37, coalesce(max_digitos_decimales, 0)), ')') AS decimal_sugerido,
       filter(array(
         IF((n_decimal_coma + n_miles_punto) > 0
            AND (n_miles_coma > 0 OR n_estandar - n_enteros > 0), 'LOCALE_MIXTO', NULL),
         IF(n_moneda > 0, 'MONEDA_EMBEBIDA', NULL),
         IF(n_porcentaje > 0, 'PORCENTAJE_EMBEBIDO', NULL),
         IF(n_ceros_izq > 0, 'CEROS_A_LA_IZQUIERDA', NULL),
         IF(n_ambiguos > 0, 'FORMATO_AMBIGUO', NULL),
         IF(n_cientifico > 0, 'NOTACION_CIENTIFICA (¿exportado desde Excel?)', NULL),
         IF(n_no_numero > 0, 'VALORES_NO_NUMERICOS', NULL)
       ), x -> x IS NOT NULL) AS alertas
FROM a
WHERE n_numero_alguno / n_evaluados >= 0.5
ORDER BY size(alertas) DESC, columna;


/* ────────────────────────────────────────────────────────────────────────────
   [L2.06] Documentos e identificadores peruanos (DNI, RUC, ubigeo, teléfono)
   DOCSTRING (es-PE)
     Para columnas texto donde ≥ 50% de los valores tiene forma de DNI, RUC,
     ubigeo o teléfono, cuenta válidos e inválidos:
       RUC con forma correcta pero DÍGITO VERIFICADOR inválido (módulo 11),
       DNI de 7 dígitos (cero inicial perdido) o con letras,
       ubigeo con departamento fuera de 01-25, teléfonos no móviles.
     Incluye ejemplos de los inválidos.
   TOOLTIP ▸ Cómo leer e interpretar
     • ruc_dv_invalido > 0: error de digitación casi seguro (el DV existe
       justamente para atraparlo). Validen contra el padrón de SUNAT.
     • dni_7_digitos: se perdió el 0 inicial en algún Excel/CSV. Corrijan
       con lpad(dni, 8, '0') sólo si el origen lo confirma.
     • Ojo: un número de 8 dígitos no ES un DNI por sí solo; la columna debe
       llamarse/usarse como tal. Esto es evidencia, no prueba.
   ──────────────────────────────────────────────────────────────────────────── */
WITH a AS (
  SELECT columna,
         sum(n)                                                                AS n_evaluados,
         sum(IF(es_ruc_forma, n, 0))                                           AS n_ruc_forma,
         sum(IF(es_ruc_pe, n, 0))                                              AS n_ruc_valido,
         sum(IF(es_ruc_forma AND NOT es_ruc_pe, n, 0))                         AS n_ruc_dv_invalido,
         sum(IF(es_dni_pe, n, 0))                                              AS n_dni_8_digitos,
         sum(IF(t RLIKE '^[0-9]{7}$', n, 0))                                   AS n_dni_7_digitos,
         sum(IF(es_ubigeo_pe, n, 0))                                           AS n_ubigeo_valido,
         sum(IF(t RLIKE '^[0-9]{6}$' AND NOT es_ubigeo_pe, n, 0))              AS n_ubigeo_dpto_invalido,
         sum(IF(es_telefono_movil_pe, n, 0))                                   AS n_movil,
         sum(IF(es_telefono_fijo_pe, n, 0))                                    AS n_fijo,
         slice(collect_list(IF(es_ruc_forma AND NOT es_ruc_pe, t, NULL)), 1, 5) AS ej_ruc_dv_invalido,
         slice(collect_list(IF(t RLIKE '^[0-9]{7}$', t, NULL)), 1, 5)           AS ej_dni_7_digitos,
         slice(collect_list(IF(NOT (es_ruc_forma OR es_dni_pe OR es_ubigeo_pe OR es_telefono_movil_pe
                                    OR es_telefono_fijo_pe OR t RLIKE '^[0-9]{6,7}$'), t, NULL)), 1, 5) AS ej_otros
  FROM dq_l2_flags
  GROUP BY columna
)
SELECT columna, n_evaluados,
       CASE GREATEST(n_ruc_forma, n_dni_8_digitos + n_dni_7_digitos, n_ubigeo_valido + n_ubigeo_dpto_invalido, n_movil + n_fijo)
         WHEN n_ruc_forma THEN 'RUC'
         WHEN n_dni_8_digitos + n_dni_7_digitos THEN 'DNI'
         WHEN n_ubigeo_valido + n_ubigeo_dpto_invalido THEN 'UBIGEO'
         ELSE 'TELEFONO' END AS documento_probable,
       n_ruc_forma, n_ruc_valido, n_ruc_dv_invalido, n_dni_8_digitos, n_dni_7_digitos,
       n_ubigeo_valido, n_ubigeo_dpto_invalido, n_movil, n_fijo,
       ej_ruc_dv_invalido, ej_dni_7_digitos, ej_otros
FROM a
WHERE GREATEST(n_ruc_forma, n_dni_8_digitos + n_dni_7_digitos,
               n_ubigeo_valido + n_ubigeo_dpto_invalido, n_movil + n_fijo) >= 0.5 * n_evaluados
ORDER BY columna;


/* ────────────────────────────────────────────────────────────────────────────
   [L2.07] Códigos guardados como NÚMERO (ceros a la izquierda perdidos)
   DOCSTRING (es-PE)
     Para columnas declaradas numéricas enteras cuyo nombre sugiere código
     (dni, ruc, ubigeo, código, teléfono, cuenta...) o cuya longitud es casi
     fija (≥ 90% con el mismo largo y largo ≥ 5), cuenta valores MÁS CORTOS que la longitud dominante y muestra cómo
     quedarían con lpad.
   TOOLTIP ▸ Cómo leer e interpretar
     • dni_num = 1234567 (7 dígitos) era '01234567': el tipo numérico destruyó
       el cero. Si se cruza con otra tabla donde el DNI es STRING, el JOIN
       falla en silencio para ~10% de los peruanos (los DNI que empiezan
       con 0).
     • Recomendación estructural: los códigos van como STRING de largo fijo.
   ──────────────────────────────────────────────────────────────────────────── */
WITH l AS (
  SELECT f.columna, char_length(regexp_replace(f.valor, '^-', '')) AS largo, f.valor, f.n
  FROM dq_freq f
  JOIN dq_columnas c ON c.columna = f.columna
  WHERE c.familia = 'NUMERICO'
    AND NOT c.tipo_declarado RLIKE '^(FLOAT|DOUBLE|REAL|DECIMAL)'
    AND f.valor IS NOT NULL
    AND f.valor NOT LIKE '-%'
), m AS (
  SELECT columna, max_by(largo, n_largo) AS largo_dominante, max(n_largo) / sum(n_largo) AS pct_dominante
  FROM (SELECT columna, largo, sum(n) AS n_largo FROM l GROUP BY columna, largo)
  GROUP BY columna
)
SELECT l.columna, m.largo_dominante, round(m.pct_dominante, 4) AS pct_largo_dominante,
       sum(IF(l.largo < m.largo_dominante, l.n, 0))                            AS n_mas_cortos,
       round(sum(IF(l.largo < m.largo_dominante, l.n, 0)) / sum(l.n), 4)       AS pct_mas_cortos,
       slice(collect_list(IF(l.largo < m.largo_dominante,
                             concat(l.valor, ' → ', lpad(l.valor, m.largo_dominante, '0')), NULL)), 1, 5) AS ejemplos_lpad
FROM l
JOIN m ON m.columna = l.columna
WHERE lower(l.columna) RLIKE '(^|_)(dni|ruc|ubigeo|cod|codigo|telefono|celular|cuenta|cci|postal|zip|doc|documento)(_|$)'
   OR (m.pct_dominante >= 0.90 AND m.largo_dominante >= 5)
GROUP BY l.columna, m.largo_dominante, m.pct_dominante
HAVING sum(IF(l.largo < m.largo_dominante, l.n, 0)) > 0
ORDER BY pct_mas_cortos DESC;


/* ────────────────────────────────────────────────────────────────────────────
   [L2.08] Persistir el resultado de la inferencia (opcional)
   DOCSTRING (es-PE)
     Guarda en dq_metricas, por columna texto y tipo, el % de coincidencia
     (sólo tipos con pct > 0), para seguir en el tiempo la "conformidad de
     formato" de cada columna.
   TOOLTIP ▸ Cómo interpretar
     • Una caída del % del tipo dominante entre corridas es una alerta
       temprana: entró una fuente nueva o cambió un formato aguas arriba.
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_sql = IF(
  dq_esquema_trabajo = '',
  concat('SELECT ', dq_lit('persistencia desactivada (dq_esquema_trabajo vacío)'), ' AS info'),
  concat('INSERT INTO ', dq_esquema_trabajo, '.dq_metricas ',
         'SELECT ', dq_lit(dq_id_corrida), ', current_timestamp(), ', dq_lit(dq_tabla_fq), ', columna, ',
         dq_lit('L2'), ', concat(', dq_lit('pct_tipo_'), ', tipo), pct, NULL FROM dq_l2_tipos WHERE pct > 0'));
EXECUTE IMMEDIATE dq_sql;
