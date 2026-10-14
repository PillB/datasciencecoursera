/* ════════════════════════════════════════════════════════════════════════════
   REFERENCIA A · ZONA 1 + PREPARACIÓN SIN METADATOS (sin information_schema)
   ────────────────────────────────────────────────────────────────────────────
   DOCSTRING (es-PE)
     Implementación de referencia, probada en Spark 4.2 (ANSI on/off), para
     correr el marco cuando el equipo NO puede consultar information_schema,
     SHOW ni DESCRIBE y sólo tiene SELECT sobre la tabla Lynx. Reemplaza a
     P2.01-P2.03 del archivo 02. Requiere: archivo 00 ejecutado y la vista
     dq_diccionario (generada desde trama_lynx.xlsx) ya creada.
     Flujo: Zona 1 (chequeos que SÍ pueden detener la corrida, con un mensaje
     claro) → nombres y tipos reales de columnas con un solo SELECT … LIMIT 1
     (funciona aun con la tabla vacía) → conciliación diccionario ↔ columnas →
     detección del formato (tabular / ancho fijo / delimitado) → vista
     dq_objetivo → dq_columnas para el resto del marco.
   TOOLTIP ▸ Cómo usar
     • Completen dq_tabla_fq_manual tal como lo escribirían en un FROM.
     • Si la corrida se detiene en la Zona 1, el mensaje de error ES el
       diagnóstico: vean la tabla de errores en [Z1.03].
   ════════════════════════════════════════════════════════════════════════════ */


/* ────────────────────────────────────────────────────────────────────────────
   [Z1.01] Variables para operar sin metadatos
   DOCSTRING (es-PE)
     dq_tabla_fq_manual  : tabla Lynx tal como se escribe en un FROM
                           (p.ej. lynx_cat.bronze.trama_detalle). Se usa cruda.
     dq_modo_columnas    : 'DICCIONARIO' (nombres reales leídos de 1 fila) o
                           'MANUAL' (lista pegada en dq_columnas_manual).
     dq_formato_fuente   : 'AUTO', 'TABULAR', 'ANCHO_FIJO' o 'DELIMITADO'.
     dq_posiciones_en    : 'CARACTERES' o 'BYTES' (cómo cuenta el diccionario).
     dq_tipo_registro_objetivo / dq_pos_tipo_registro / dq_len_tipo_registro :
                           qué tipo de registro perfilar y dónde está su código.
     dq_mostrar_pii      : false = los ejemplos de campos PII salen enmascarados.
     dq_ld_*             : campos del trailer para los totales de control [LD.08].
     dq_estado / dq_log  : estado de la corrida y bitácora de escenarios.
   TOOLTIP ▸ Cómo interpretar
     • No devuelve filas. Todo lo que el script decida queda en dq_log; al
       final [LZ.01] lo muestra completo con su interpretación.
   ──────────────────────────────────────────────────────────────────────────── */
DECLARE OR REPLACE VARIABLE dq_tabla_fq_manual        STRING  DEFAULT '<<COMPLETAR catalogo.esquema.tabla>>';
DECLARE OR REPLACE VARIABLE dq_modo_columnas          STRING  DEFAULT 'DICCIONARIO';
DECLARE OR REPLACE VARIABLE dq_columnas_manual        STRING  DEFAULT '';
DECLARE OR REPLACE VARIABLE dq_formato_fuente         STRING  DEFAULT 'AUTO';
DECLARE OR REPLACE VARIABLE dq_posiciones_en          STRING  DEFAULT 'CARACTERES';
DECLARE OR REPLACE VARIABLE dq_tipo_registro_objetivo STRING  DEFAULT '';
DECLARE OR REPLACE VARIABLE dq_pos_tipo_registro      INT     DEFAULT 0;
DECLARE OR REPLACE VARIABLE dq_len_tipo_registro      INT     DEFAULT 0;
DECLARE OR REPLACE VARIABLE dq_mostrar_pii            BOOLEAN DEFAULT false;
DECLARE OR REPLACE VARIABLE dq_ld_tipo_trailer        STRING  DEFAULT '';
DECLARE OR REPLACE VARIABLE dq_ld_campo_conteo        STRING  DEFAULT '';
DECLARE OR REPLACE VARIABLE dq_ld_campo_suma_trailer  STRING  DEFAULT '';
DECLARE OR REPLACE VARIABLE dq_ld_campo_suma_detalle  STRING  DEFAULT '';
DECLARE OR REPLACE VARIABLE dq_estado                 STRING  DEFAULT 'OK';
DECLARE OR REPLACE VARIABLE dq_log ARRAY<STRUCT<paso STRING, escenario STRING, detalle STRING, interpretacion STRING>>
  DEFAULT CAST(array() AS ARRAY<STRUCT<paso STRING, escenario STRING, detalle STRING, interpretacion STRING>>);
-- Internas (las llena el script):
DECLARE OR REPLACE VARIABLE dq_formato_detectado      STRING  DEFAULT '';
DECLARE OR REPLACE VARIABLE dq_col_linea              STRING  DEFAULT '';
DECLARE OR REPLACE VARIABLE dq_largo_linea_prom       DOUBLE  DEFAULT 0;
DECLARE OR REPLACE VARIABLE dq_pct_match              DOUBLE  DEFAULT 0;
DECLARE OR REPLACE VARIABLE dq_pct_largo_ok           DOUBLE  DEFAULT 0;
DECLARE OR REPLACE VARIABLE dq_delimitador            STRING  DEFAULT '';
DECLARE OR REPLACE VARIABLE dq_pct_delim_estable      DOUBLE  DEFAULT 0;
DECLARE OR REPLACE VARIABLE dq_largos_esperados       STRING  DEFAULT '';
DECLARE OR REPLACE VARIABLE dq_codigo_registro_obj    STRING  DEFAULT '';
DECLARE OR REPLACE VARIABLE dq_n_filas_acceso         BIGINT  DEFAULT 0;


/* ────────────────────────────────────────────────────────────────────────────
   [Z1.02] Funciones auxiliares adicionales (normalización, formatos, PII)
   DOCSTRING (es-PE)
     dq_norm(v)            : nombre normalizado (minúsculas, sin tildes, todo lo
                             que no es letra/dígito → '_').
     dq_norm_sin(v)        : dq_norm + sinónimos frecuentes en tramas
                             (numero/num/nro → nro, fecha/fec → fec, codigo →
                             cod, importe/monto → imp, cuenta → cta,
                             documento → doc, descripcion → des, tipo → tip).
     dq_fecha_formato(v,f) : fecha según formato del diccionario (AAAAMMDD,
                             DDMMAAAA, DD/MM/AAAA, AAAA-MM-DD…); NULL si no vale.
     dq_overpunch(v)       : valor entero de un campo con signo "overpunch"
                             COBOL ({ A-I positivo, } J-R negativo).
     dq_luhn(v)            : dígito verificador Luhn (números de tarjeta).
     dq_ver(v, ocultar)    : muestra v o su máscara (9/A/a) si ocultar = true.
   TOOLTIP ▸ Cómo interpretar
     • Ninguna se usa dentro de lambdas (regla del marco).
   ──────────────────────────────────────────────────────────────────────────── */
CREATE OR REPLACE TEMPORARY FUNCTION dq_norm(v STRING)
  RETURNS STRING
  RETURN regexp_replace(regexp_replace(
           translate(lower(dq_limpiar(v)), 'áéíóúüàèìòùñç°º', 'aeiouuaeiounc  '),
           '[^a-z0-9]+', '_'), '^_+|_+$', '');

CREATE OR REPLACE TEMPORARY FUNCTION dq_norm_sin(v STRING)
  RETURNS STRING
  RETURN regexp_replace(regexp_replace(regexp_replace(regexp_replace(
         regexp_replace(regexp_replace(regexp_replace(regexp_replace(
           concat('_', dq_norm(v), '_'),
           '_(numero|num|nro|no|n)(?=_)', '_nro'),
           '_(fecha|fec|fch|f)(?=_)', '_fec'),
           '_(codigo|cod|cd|cdg)(?=_)', '_cod'),
           '_(importe|monto|imp|mto|mnt)(?=_)', '_imp'),
           '_(cuenta|cta|cnta)(?=_)', '_cta'),
           '_(documento|doc|dcto|docu)(?=_)', '_doc'),
           '_(descripcion|desc|des|dsc|glosa)(?=_)', '_des'),
           '_(tipo|tip|tp)(?=_)', '_tip');

CREATE OR REPLACE TEMPORARY FUNCTION dq_fecha_formato(v STRING, formato STRING)
  RETURNS DATE
  RETURN CASE upper(regexp_replace(coalesce(formato, ''), '[^A-Za-z]', ''))
    WHEN 'AAAAMMDD' THEN IF(dq_limpiar(v) RLIKE '^[0-9]{8}$',
         try_cast(regexp_replace(dq_limpiar(v), '^([0-9]{4})([0-9]{2})([0-9]{2})$', '$1-$2-$3') AS DATE), NULL)
    WHEN 'YYYYMMDD' THEN IF(dq_limpiar(v) RLIKE '^[0-9]{8}$',
         try_cast(regexp_replace(dq_limpiar(v), '^([0-9]{4})([0-9]{2})([0-9]{2})$', '$1-$2-$3') AS DATE), NULL)
    WHEN 'DDMMAAAA' THEN IF(dq_limpiar(v) RLIKE '^[0-9]{8}$',
         try_cast(regexp_replace(dq_limpiar(v), '^([0-9]{2})([0-9]{2})([0-9]{4})$', '$3-$2-$1') AS DATE), NULL)
    WHEN 'DDMMYYYY' THEN IF(dq_limpiar(v) RLIKE '^[0-9]{8}$',
         try_cast(regexp_replace(dq_limpiar(v), '^([0-9]{2})([0-9]{2})([0-9]{4})$', '$3-$2-$1') AS DATE), NULL)
    WHEN 'MMDDAAAA' THEN dq_fecha_texto(regexp_replace(dq_limpiar(v), '^([0-9]{2})([0-9]{2})([0-9]{4})$', '$1/$2/$3'), 'MDY')
    ELSE dq_fecha_texto(v, IF(upper(coalesce(formato, '')) RLIKE '^MM', 'MDY', 'DMY'))
  END;

CREATE OR REPLACE TEMPORARY FUNCTION dq_overpunch(v STRING)
  RETURNS DECIMAL(38, 0)
  RETURN CASE
    WHEN dq_limpiar(v) RLIKE '^[0-9]*[{A-I]$' THEN
      try_cast(concat(substr(dq_limpiar(v), 1, char_length(dq_limpiar(v)) - 1),
                      translate(substr(dq_limpiar(v), -1), '{ABCDEFGHI', '0123456789')) AS DECIMAL(38, 0))
    WHEN dq_limpiar(v) RLIKE '^[0-9]*[}J-R]$' THEN
      -try_cast(concat(substr(dq_limpiar(v), 1, char_length(dq_limpiar(v)) - 1),
                       translate(substr(dq_limpiar(v), -1), '}JKLMNOPQR', '0123456789')) AS DECIMAL(38, 0))
    WHEN dq_limpiar(v) RLIKE '^[+-]?[0-9]+$' THEN try_cast(dq_limpiar(v) AS DECIMAL(38, 0))
    WHEN dq_limpiar(v) RLIKE '^[0-9]+[+-]$' THEN
      try_cast(concat(substr(dq_limpiar(v), -1), substr(dq_limpiar(v), 1, char_length(dq_limpiar(v)) - 1)) AS DECIMAL(38, 0))
  END;

CREATE OR REPLACE TEMPORARY FUNCTION dq_luhn(v STRING)
  RETURNS BOOLEAN
  RETURN v RLIKE '^[0-9]{12,19}$'
     AND pmod(aggregate(sequence(1, char_length(v)), 0,
           (acc, i) -> acc + CASE WHEN pmod(char_length(v) - i, 2) = 1
                                  THEN IF(CAST(substr(v, i, 1) AS INT) * 2 > 9,
                                          CAST(substr(v, i, 1) AS INT) * 2 - 9,
                                          CAST(substr(v, i, 1) AS INT) * 2)
                                  ELSE CAST(substr(v, i, 1) AS INT) END), 10) = 0;

CREATE OR REPLACE TEMPORARY FUNCTION dq_ver(v STRING, ocultar BOOLEAN)
  RETURNS STRING
  RETURN IF(ocultar AND v IS NOT NULL, dq_mascara(v), v);


/* ────────────────────────────────────────────────────────────────────────────
   [Z1.03] ZONA 1 · ¿Está completada la tabla y tenemos acceso? (puede detener)
   DOCSTRING (es-PE)
     Primero verifica que dq_tabla_fq_manual no siga con el texto por
     defecto; luego lee UNA fila de la tabla. Es la única parte del script que
     se permite detener la corrida, porque sin tabla no hay nada que analizar.
   TOOLTIP ▸ Cómo interpretar el error si se detiene aquí
     • "[DQ-Z1] Completen dq_tabla_fq_manual" → falta poner el nombre.
     • TABLE_OR_VIEW_NOT_FOUND → nombre mal escrito, falta el catálogo o el
       esquema, o no tienen permiso de USE CATALOG / USE SCHEMA (UC responde
       "no encontrada" cuando no se puede ver el objeto).
     • INSUFFICIENT_PERMISSIONS / PERMISSION_DENIED → falta SELECT sobre la
       tabla: pídanlo al dueño de los datos.
     • PARSE_SYNTAX_ERROR o UNRESOLVED_ROUTINE en DECLARE / CREATE TEMPORARY
       FUNCTION / EXECUTE IMMEDIATE (archivo 00) → la versión de Databricks SQL
       es anterior a la requerida (DBR 14.3+ / warehouse actual).
     • Si pasa: filas_leidas = 1 (o 0 si la tabla está vacía; el script sigue).
   ──────────────────────────────────────────────────────────────────────────── */
SELECT CASE WHEN dq_tabla_fq_manual RLIKE '^<<' OR trim(dq_tabla_fq_manual) = ''
            THEN raise_error('[DQ-Z1] Completen dq_tabla_fq_manual con el nombre de la tabla Lynx (tal como va en un FROM).')
            ELSE 'OK: tabla configurada' END AS verificacion_configuracion;

SET VAR dq_n_filas_acceso = (SELECT count(*) FROM (SELECT 1 FROM IDENTIFIER(dq_tabla_fq_manual) LIMIT 1));

SELECT dq_tabla_fq_manual AS tabla, dq_n_filas_acceso AS filas_leidas,
       IF(dq_n_filas_acceso = 0, 'La tabla existe y es accesible pero está VACÍA (o un filtro de filas oculta todo): el script sigue y lo explicará.',
          'Acceso de lectura confirmado.') AS interpretacion;


/* ────────────────────────────────────────────────────────────────────────────
   [Z2.01] Nombres y tipos reales de las columnas (sin information_schema)
   DOCSTRING (es-PE)
     Crea dq_cols_reales (ordinal, columna, tipo_real, familia_real) leyendo
     los nombres desde las claves JSON de UNA fila y los tipos con typeof().
     Usa un LEFT JOIN contra una fila ficticia: así funciona aun si la tabla
     está vacía. En modo MANUAL toma la lista de dq_columnas_manual.
   TOOLTIP ▸ Cómo interpretar
     • No muestra valores, sólo nombres y tipos (seguro para PII).
     • Ojo: si una columna tiene máscara de Unity Catalog, el tipo es el real
       pero los valores vendrán enmascarados (ver [LD.10]).
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_sql = IF(
  upper(dq_modo_columnas) = 'MANUAL',
  concat('CREATE OR REPLACE TEMP VIEW dq_cols_nombres AS ',
         'SELECT row_number() OVER (ORDER BY pos) AS ordinal, trim(col) AS columna ',
         'FROM (SELECT posexplode(split(', dq_lit(dq_columnas_manual), ', ', dq_lit(','), ')) AS (pos, col)) ',
         'WHERE trim(col) <> ', dq_lit('')),
  concat('CREATE OR REPLACE TEMP VIEW dq_cols_nombres AS ',
         'SELECT pos + 1 AS ordinal, col AS columna ',
         'FROM (SELECT posexplode(json_object_keys(to_json(struct(s.*), map(',
                dq_lit('ignoreNullFields'), ', ', dq_lit('false'), ')))) AS (pos, col) ',
         '      FROM (SELECT 1 AS _dq_uno) u LEFT JOIN (SELECT * FROM ', dq_tabla_fq_manual, ' LIMIT 1) s ON true)'));
EXECUTE IMMEDIATE dq_sql;

SET VAR dq_sql = coalesce((
  SELECT IF(count(*) = 0,
            'CREATE OR REPLACE TEMP VIEW dq_cols_reales AS SELECT CAST(NULL AS INT) AS ordinal, CAST(NULL AS STRING) AS columna, CAST(NULL AS STRING) AS tipo_real, CAST(NULL AS STRING) AS familia_real WHERE false',
            concat('CREATE OR REPLACE TEMP VIEW dq_cols_reales AS ',
                   'SELECT n.ordinal, n.columna, upper(t.tipo) AS tipo_real, dq_familia(t.tipo) AS familia_real ',
                   'FROM dq_cols_nombres n LEFT JOIN (SELECT stack(', CAST(count(*) AS STRING), ', ',
                   array_join(transform(array_sort(collect_list(struct(ordinal, par))), x -> x.par), ', '),
                   ') AS (columna, tipo) FROM (SELECT 1 AS _dq_uno) u LEFT JOIN (SELECT * FROM ', dq_tabla_fq_manual,
                   ' LIMIT 1) s ON true) t ON t.columna = n.columna'))
  FROM (SELECT ordinal, concat(dq_lit(columna), ', typeof(s.', dq_id(columna), ')') AS par FROM dq_cols_nombres)),
  'SELECT 1');
EXECUTE IMMEDIATE dq_sql;

SET VAR dq_log = array_append(dq_log, named_struct(
  'paso', 'Z2.01', 'escenario', concat('MODO_COLUMNAS_', upper(dq_modo_columnas)),
  'detalle', concat((SELECT count(*) FROM dq_cols_reales), ' columnas reales; filas leídas = ', dq_n_filas_acceso),
  'interpretacion', 'Nombres y tipos obtenidos sin information_schema (una sola lectura de 1 fila).'));

SELECT ordinal, columna, tipo_real, familia_real FROM dq_cols_reales ORDER BY ordinal;


/* ────────────────────────────────────────────────────────────────────────────
   [Z2.02] Conciliación diccionario ↔ columnas reales (cascada de coincidencia)
   DOCSTRING (es-PE)
     Para cada campo del diccionario (del tipo de registro objetivo) busca la
     columna real en este orden: 1 exacto, 2 igual sin mayúsculas, 3 nombre
     normalizado, 4 normalizado con sinónimos, 5 huella (tokens ordenados),
     6 Levenshtein ≤ 2 sobre el nombre con sinónimos, 7 por orden (sólo si
     ambos tienen la misma cantidad de columnas). Si un campo o una columna
     tiene más de un candidato en su mejor nivel → AMBIGUO (nunca se elige al
     azar). Crea dq_reconciliacion y la muestra.
   TOOLTIP ▸ Cómo leer e interpretar
     • confianza ALTA (1-3), MEDIA (4-5), BAJA (6-7). Todo hallazgo sobre una
       columna con confianza BAJA debe leerse como "mapeo incierto".
     • NO_ENCONTRADO: el campo no está en la tabla. Hipótesis: (a) la tabla
       es una trama cruda de ancho fijo (ver [Z2.03]), (b) la ingesta
       renombró la columna de forma no prevista, (c) el diccionario es de
       otra versión, (d) el campo se descarta en la ingesta.
     • EXTRA: columna real sin campo en el diccionario (técnica o nueva).
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_sql = concat(
  'CREATE OR REPLACE TEMP VIEW dq_reconciliacion AS ',
  'WITH d AS (SELECT campo, orden, dq_norm(campo) AS n1, dq_norm_sin(campo) AS n2, dq_huella(campo) AS n3 ',
  '           FROM dq_diccionario WHERE ', dq_lit(dq_tipo_registro_objetivo), ' = ', dq_lit(''),
  '           OR tipo_registro = ', dq_lit(dq_tipo_registro_objetivo), '), ',
  'r AS (SELECT columna, ordinal, dq_norm(columna) AS n1, dq_norm_sin(columna) AS n2, dq_huella(columna) AS n3 ',
  '      FROM dq_cols_reales WHERE NOT startswith(columna, ', dq_lit('_'), ')), ',
  'cnt AS (SELECT (SELECT count(*) FROM d) AS nd, (SELECT count(*) FROM r) AS nr), ',
  'cand AS (SELECT d.campo, r.columna, CASE ',
  '   WHEN d.campo = r.columna THEN 1 WHEN lower(d.campo) = lower(r.columna) THEN 2 ',
  '   WHEN d.n1 = r.n1 THEN 3 WHEN d.n2 = r.n2 THEN 4 WHEN d.n3 = r.n3 AND d.n3 <> ', dq_lit(''), ' THEN 5 ',
  '   WHEN least(char_length(d.n2), char_length(r.n2)) >= 5 AND levenshtein(d.n2, r.n2) <= 2 THEN 6 ',
  '   WHEN (SELECT nd FROM cnt) = (SELECT nr FROM cnt) AND d.orden = r.ordinal THEN 7 END AS nivel ',
  '  FROM d CROSS JOIN r), ',
  'c AS (SELECT * FROM cand WHERE nivel IS NOT NULL), ',
  'mejor_campo AS (SELECT campo, min(nivel) AS nivel FROM c GROUP BY campo), ',
  'mc AS (SELECT c.* FROM c JOIN mejor_campo m ON m.campo = c.campo AND m.nivel = c.nivel), ',
  'k AS (SELECT mc.*, count(*) OVER (PARTITION BY campo) AS n_col, count(*) OVER (PARTITION BY columna) AS n_campo FROM mc) ',
  'SELECT d.campo, d.orden, ',
  '  IF(max(k.n_col) = 1 AND max(k.n_campo) = 1, max(k.columna), NULL) AS columna, ',
  '  CASE WHEN count(k.columna) = 0 THEN ', dq_lit('NO_ENCONTRADO'),
  '       WHEN max(k.n_col) = 1 AND max(k.n_campo) = 1 THEN ', dq_lit('MAPEADO'), ' ELSE ', dq_lit('AMBIGUO'), ' END AS estado, ',
  '  min(k.nivel) AS nivel, ',
  '  CASE min(k.nivel) WHEN 1 THEN ', dq_lit('EXACTO'), ' WHEN 2 THEN ', dq_lit('MAYUSCULAS'), ' WHEN 3 THEN ', dq_lit('NORMALIZADO'),
  '       WHEN 4 THEN ', dq_lit('SINONIMOS'), ' WHEN 5 THEN ', dq_lit('HUELLA'), ' WHEN 6 THEN ', dq_lit('LEVENSHTEIN'),
  '       WHEN 7 THEN ', dq_lit('POR_ORDEN'), ' END AS metodo, ',
  '  CASE WHEN min(k.nivel) <= 3 THEN ', dq_lit('ALTA'), ' WHEN min(k.nivel) <= 5 THEN ', dq_lit('MEDIA'),
  '       WHEN min(k.nivel) IS NOT NULL THEN ', dq_lit('BAJA'), ' END AS confianza, ',
  '  sort_array(collect_list(k.columna)) AS candidatos ',
  'FROM d LEFT JOIN k ON k.campo = d.campo GROUP BY d.campo, d.orden ',
  'UNION ALL ',
  'SELECT CAST(NULL AS STRING), CAST(NULL AS INT), x.columna, ', dq_lit('EXTRA'), ', CAST(NULL AS INT), CAST(NULL AS STRING), CAST(NULL AS STRING), array(x.columna) ',
  'FROM dq_cols_reales x WHERE x.columna NOT IN (SELECT columna FROM mc)');
EXECUTE IMMEDIATE dq_sql;

SET VAR dq_pct_match = coalesce((SELECT count_if(estado = 'MAPEADO') / NULLIF(count_if(campo IS NOT NULL), 0) FROM dq_reconciliacion), 0);

SELECT campo, columna, estado, metodo, confianza, candidatos
FROM dq_reconciliacion
ORDER BY CASE estado WHEN 'AMBIGUO' THEN 0 WHEN 'NO_ENCONTRADO' THEN 1 WHEN 'EXTRA' THEN 2 ELSE 3 END, orden;


/* ────────────────────────────────────────────────────────────────────────────
   [Z2.03] Detección del formato de la fuente (tabular / ancho fijo / delimitado)
   DOCSTRING (es-PE)
     Si dq_formato_fuente = 'AUTO': (1) si ≥ 50% de campos se concilian →
     TABULAR; (2) si no, busca entre ≤ 3 columnas texto la de líneas más
     largas y mide en 10 000 líneas: % con largo igual (± 2) a algún largo
     de registro del diccionario → ANCHO_FIJO si ≥ 80%; y estabilidad del
     número de separadores (| ; tab ,) → DELIMITADO si ≥ 95%;
     (3) si nada aplica → TABULAR_PARCIAL o DESCONOCIDO. Registra todo en dq_log.
   TOOLTIP ▸ Cómo interpretar
     • formato_detectado decide cómo se arma dq_objetivo (la vista que se
       perfila). Si creen que la detección se equivocó, fijen
       dq_formato_fuente a mano y vuelvan a correr desde aquí.
     • pct_largo_ok bajo con líneas "casi" del largo correcto suele ser: CRLF
       (\r final), espacios finales recortados en la ingesta, o una versión
       distinta del layout (ver [LD.07] y [LD.09]).
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_largos_esperados = coalesce((
  SELECT array_join(array_sort(collect_set(CAST(largo AS STRING))), ',')
  FROM (SELECT tipo_registro, max(pos_inicio + longitud - 1) AS largo FROM dq_diccionario
        WHERE pos_inicio IS NOT NULL AND longitud IS NOT NULL GROUP BY tipo_registro)), '');

SET VAR dq_codigo_registro_obj = coalesce((
  SELECT max(codigo_registro) FROM dq_diccionario WHERE tipo_registro = dq_tipo_registro_objetivo), '');

SET VAR dq_sql = coalesce((
  SELECT IF(count(*) BETWEEN 1 AND 3 AND dq_largos_esperados <> '' AND dq_pct_match < 0.5,
            concat('SELECT max_by(c, l), max(l) FROM (SELECT stack(', CAST(count(*) AS STRING), ', ',
                   array_join(transform(array_sort(collect_list(struct(ordinal, e))), x -> x.e), ', '),
                   ') AS (c, l) FROM (SELECT * FROM ', dq_tabla_fq_manual, ' LIMIT 1000) t)'),
            concat('SELECT ', dq_lit(''), ', CAST(0 AS DOUBLE)'))
  FROM (SELECT ordinal, concat(dq_lit(columna), ', avg(char_length(', dq_id(columna), '))') AS e
        FROM dq_cols_reales WHERE familia_real = 'TEXTO' AND NOT startswith(columna, '_'))),
  'SELECT CAST(NULL AS STRING), CAST(0 AS DOUBLE)');
EXECUTE IMMEDIATE dq_sql INTO dq_col_linea, dq_largo_linea_prom;
SET VAR dq_col_linea = coalesce(dq_col_linea, '');

SET VAR dq_sql = IF(dq_col_linea = '',
  'SELECT CAST(0 AS DOUBLE), CAST(NULL AS STRING), CAST(0 AS DOUBLE)',
  concat(
    'WITH l AS (SELECT regexp_replace(regexp_replace(', dq_id(dq_col_linea), ', ', dq_lit('^\\x{FEFF}'), ', ', dq_lit(''), '), ',
                dq_lit('\\r$'), ', ', dq_lit(''), ') AS c FROM (SELECT * FROM ', dq_tabla_fq_manual, ' LIMIT 10000) t ',
                'WHERE ', dq_id(dq_col_linea), ' IS NOT NULL), ',
    'lg AS (SELECT avg(IF(exists(array(', IF(dq_largos_esperados = '', '0', dq_largos_esperados), '), x -> abs(x - char_length(c)) <= 2), 1, 0)) AS p FROM l), ',
    'x AS (SELECT d, size(split(c, rx)) - 1 AS k FROM l LATERAL VIEW stack(4, ', dq_lit('|'), ', ', dq_lit('[|]'), ', ',
           dq_lit(';'), ', ', dq_lit(';'), ', ', dq_lit('TAB'), ', chr(9), ', dq_lit(','), ', ', dq_lit(','), ') s AS d, rx), ',
    'f AS (SELECT d, k, count(*) AS n FROM x GROUP BY d, k), ',
    'm AS (SELECT d, max_by(k, n) AS k_moda, max(n) / sum(n) AS pct FROM f GROUP BY d) ',
    'SELECT (SELECT p FROM lg), max_by(d, IF(k_moda >= 1, pct, -1)), max(IF(k_moda >= 1, pct, 0)) FROM m'));
EXECUTE IMMEDIATE dq_sql INTO dq_pct_largo_ok, dq_delimitador, dq_pct_delim_estable;

SET VAR dq_formato_detectado = CASE
  WHEN upper(dq_formato_fuente) <> 'AUTO' THEN upper(dq_formato_fuente)
  WHEN dq_pct_match >= 0.5 THEN 'TABULAR'
  WHEN dq_col_linea <> '' AND coalesce(dq_pct_largo_ok, 0) >= 0.8 THEN 'ANCHO_FIJO'
  WHEN dq_col_linea <> '' AND coalesce(dq_pct_delim_estable, 0) >= 0.95 THEN 'DELIMITADO'
  WHEN dq_pct_match > 0 THEN 'TABULAR_PARCIAL'
  ELSE 'DESCONOCIDO' END;

SET VAR dq_log = array_append(dq_log, named_struct(
  'paso', 'Z2.03', 'escenario', concat('FORMATO_', dq_formato_detectado),
  'detalle', concat('pct_campos_conciliados=', round(dq_pct_match, 3), '; columna_linea=', dq_col_linea,
                    '; pct_largo_ok=', round(coalesce(dq_pct_largo_ok, 0), 3), '; delimitador=', coalesce(dq_delimitador, ''),
                    '; pct_delim_estable=', round(coalesce(dq_pct_delim_estable, 0), 3),
                    '; largos_esperados=', dq_largos_esperados),
  'interpretacion', CASE dq_formato_detectado
    WHEN 'TABULAR' THEN 'Tabla ya separada en columnas: se perfilan sus columnas y se comparan con el diccionario por nombre.'
    WHEN 'ANCHO_FIJO' THEN 'Trama cruda de ancho fijo: se parte cada línea por posiciones del diccionario antes de perfilar.'
    WHEN 'DELIMITADO' THEN 'Líneas con separador estable: se separan por el delimitador en el orden del diccionario (verifiquen que el orden coincida).'
    WHEN 'TABULAR_PARCIAL' THEN 'Pocos campos conciliados: se perfila la tabla tal cual; las comparaciones contra el diccionario cubren sólo lo conciliado. Revisen [Z2.02].'
    ELSE 'No se reconoce el formato: se perfila la tabla tal cual y las validaciones del diccionario se omiten. Revisen nombre de tabla, tipo de registro y largos del diccionario.' END));

SELECT dq_formato_detectado AS formato_detectado, round(dq_pct_match, 4) AS pct_campos_conciliados,
       dq_col_linea AS columna_linea, round(coalesce(dq_pct_largo_ok, 0), 4) AS pct_largo_ok,
       dq_delimitador AS delimitador, round(coalesce(dq_pct_delim_estable, 0), 4) AS pct_delim_estable,
       dq_largos_esperados AS largos_esperados;


/* ────────────────────────────────────────────────────────────────────────────
   [Z2.04] Vista dq_objetivo (lo que se perfila) y mapa campo → columna
   DOCSTRING (es-PE)
     Según el formato detectado arma:
       TABULAR / TABULAR_PARCIAL / DESCONOCIDO : dq_objetivo = la tabla tal cual.
       ANCHO_FIJO : una columna por campo del tipo de registro objetivo,
         cortada por posición (en CARACTERES o en BYTES; en bytes se decodifica
         como ISO-8859-1 porque cortar un carácter UTF-8 por la mitad hace
         fallar decode()), sobre la línea sin BOM ni \r final; más _dq_linea y
         _dq_tipo_registro. Nombres = dq_norm(campo) (+ sufijo si se repite).
       DELIMITADO : una columna por campo, por orden del diccionario.
     También crea dq_mapa (campo → columna en dq_objetivo + atributos del
     diccionario + tipo real) que usan la Capa D y las reglas.
   TOOLTIP ▸ Cómo interpretar
     • Las columnas que empiezan con _dq_ son técnicas y se excluyen del
       perfilado (dq_regex_excluir_columnas).
     • En ANCHO_FIJO los valores NO se recortan: el relleno se evalúa en [LD.03].
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_sql = CASE
  WHEN dq_formato_detectado = 'ANCHO_FIJO' THEN coalesce((
    SELECT concat(
      'CREATE OR REPLACE TEMP VIEW dq_objetivo AS SELECT ',
      array_join(transform(array_sort(collect_list(struct(orden, e))), x -> x.e), ', '),
      ', _dq_linea, _dq_tipo_registro FROM (SELECT l AS _dq_linea, ',
      IF(dq_len_tipo_registro > 0, concat('substr(l, ', dq_pos_tipo_registro, ', ', dq_len_tipo_registro, ')'), 'CAST(NULL AS STRING)'),
      ' AS _dq_tipo_registro FROM (SELECT regexp_replace(regexp_replace(', dq_id(dq_col_linea), ', ',
      dq_lit('^\\x{FEFF}'), ', ', dq_lit(''), '), ', dq_lit('\\r$'), ', ', dq_lit(''), ') AS l FROM ', dq_tabla_fq_manual,
      ' WHERE ', dq_id(dq_col_linea), ' IS NOT NULL) a) b',
      IF(dq_len_tipo_registro > 0 AND dq_codigo_registro_obj <> '',
         concat(' WHERE _dq_tipo_registro = ', dq_lit(dq_codigo_registro_obj)), ''))
    FROM (SELECT orden,
                 concat(IF(upper(dq_posiciones_en) = 'BYTES',
                           concat('decode(substr(encode(_dq_linea, ', dq_lit('UTF-8'), '), ', pos_inicio, ', ', longitud, '), ', dq_lit('ISO-8859-1'), ')'),
                           concat('substr(_dq_linea, ', pos_inicio, ', ', longitud, ')')),
                        ' AS ', dq_id(nombre)) AS e
          FROM (SELECT orden, pos_inicio, longitud,
                       concat(dq_norm(campo), IF(row_number() OVER (PARTITION BY dq_norm(campo) ORDER BY orden) > 1,
                                                 concat('_', row_number() OVER (PARTITION BY dq_norm(campo) ORDER BY orden)), '')) AS nombre
                FROM dq_diccionario
                WHERE (dq_tipo_registro_objetivo = '' OR tipo_registro = dq_tipo_registro_objetivo)
                  AND pos_inicio IS NOT NULL AND longitud IS NOT NULL))),
    concat('CREATE OR REPLACE TEMP VIEW dq_objetivo AS SELECT * FROM ', dq_tabla_fq_manual))
  WHEN dq_formato_detectado = 'DELIMITADO' THEN coalesce((
    SELECT concat(
      'CREATE OR REPLACE TEMP VIEW dq_objetivo AS SELECT ',
      array_join(transform(array_sort(collect_list(struct(orden, e))), x -> x.e), ', '),
      ', _dq_linea FROM (SELECT ', dq_id(dq_col_linea), ' AS _dq_linea, split(', dq_id(dq_col_linea), ', ',
      CASE dq_delimitador WHEN 'TAB' THEN 'chr(9)' WHEN '|' THEN dq_lit('[|]') ELSE dq_lit(dq_delimitador) END,
      ') AS _dq_partes FROM ', dq_tabla_fq_manual, ') a')
    FROM (SELECT orden, concat('try_element_at(_dq_partes, ', CAST(rn AS STRING), ') AS ', dq_id(nombre)) AS e
          FROM (SELECT orden, row_number() OVER (ORDER BY orden) AS rn,
                       concat(dq_norm(campo), IF(row_number() OVER (PARTITION BY dq_norm(campo) ORDER BY orden) > 1,
                                                 concat('_', row_number() OVER (PARTITION BY dq_norm(campo) ORDER BY orden)), '')) AS nombre
                FROM dq_diccionario
                WHERE dq_tipo_registro_objetivo = '' OR tipo_registro = dq_tipo_registro_objetivo))),
    concat('CREATE OR REPLACE TEMP VIEW dq_objetivo AS SELECT * FROM ', dq_tabla_fq_manual))
  ELSE concat('CREATE OR REPLACE TEMP VIEW dq_objetivo AS SELECT * FROM ', dq_tabla_fq_manual)
END;
EXECUTE IMMEDIATE dq_sql;

SET VAR dq_sql = concat(
  'CREATE OR REPLACE TEMP VIEW dq_mapa AS ',
  'WITH d AS (SELECT *, concat(dq_norm(campo), IF(row_number() OVER (PARTITION BY dq_norm(campo) ORDER BY orden) > 1, ',
  '           concat(', dq_lit('_'), ', row_number() OVER (PARTITION BY dq_norm(campo) ORDER BY orden)), ', dq_lit(''), ')) AS nombre_parseado ',
  '           FROM dq_diccionario WHERE ', dq_lit(dq_tipo_registro_objetivo), ' = ', dq_lit(''),
  '           OR tipo_registro = ', dq_lit(dq_tipo_registro_objetivo), ') ',
  'SELECT d.*, ',
  IF(dq_formato_detectado IN ('ANCHO_FIJO', 'DELIMITADO'),
     concat('d.nombre_parseado AS columna, ', dq_lit('MAPEADO'), ' AS estado, ', dq_lit('POSICION'), ' AS metodo, ', dq_lit('ALTA'), ' AS confianza, ',
            dq_lit('STRING'), ' AS tipo_real, ', dq_lit('TEXTO'), ' AS familia_real FROM d'),
     concat('r.columna, coalesce(r.estado, ', dq_lit('NO_ENCONTRADO'), ') AS estado, r.metodo, r.confianza, c.tipo_real, c.familia_real ',
            'FROM d LEFT JOIN dq_reconciliacion r ON r.campo = d.campo LEFT JOIN dq_cols_reales c ON c.columna = r.columna')));
EXECUTE IMMEDIATE dq_sql;

SET VAR dq_log = array_append(dq_log, named_struct(
  'paso', 'Z2.04', 'escenario', concat('OBJETIVO_', dq_formato_detectado),
  'detalle', concat((SELECT count_if(estado = 'MAPEADO') FROM dq_mapa), ' de ', (SELECT count(*) FROM dq_mapa),
                    ' campos del diccionario disponibles para validar'),
  'interpretacion', 'Las validaciones contra el diccionario (Capa D y reglas) sólo cubren los campos MAPEADO.'));


/* ────────────────────────────────────────────────────────────────────────────
   [P2.01v2-P2.03v2] Preparación del marco sobre dq_objetivo (reemplaza P2.01-P2.03)
   DOCSTRING (es-PE)
     Apunta el marco a la vista dq_objetivo y arma dq_columnas con nombres y
     tipos de esa vista (mismo truco de una fila, sirve con tabla vacía), sin
     raise_error: si no hay columnas o filas, deja dq_estado y lo registra.
     Después se ejecuta el archivo 02 desde P2.04 tal cual.
   TOOLTIP ▸ Cómo interpretar
     • El resumen P2.08 muestra cuántas filas y columnas se perfilan.
     • dq_estado = 'TABLA_VACIA' ⇒ todas las métricas saldrán en cero o
       vacías: es esperado, no es un error del script.
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_catalogo = '';
SET VAR dq_esquema = '';
SET VAR dq_tabla = 'dq_objetivo';
SET VAR dq_tabla_fq = '`dq_objetivo`';
SET VAR dq_regex_excluir_columnas = IF(dq_regex_excluir_columnas = '', '^_dq_', concat('(', dq_regex_excluir_columnas, ')|^_dq_'));

SET VAR dq_sql = concat(
  'CREATE OR REPLACE TEMP VIEW dq_columnas_base AS ',
  'SELECT columna, ordinal, CAST(NULL AS STRING) AS tipo_declarado, CAST(NULL AS STRING) AS es_nulable, CAST(NULL AS STRING) AS comentario ',
  'FROM (SELECT posexplode(json_object_keys(to_json(struct(s.*), map(', dq_lit('ignoreNullFields'), ', ', dq_lit('false'), ')))) AS (ordinal, columna) ',
  '      FROM (SELECT 1 AS _dq_uno) u LEFT JOIN (SELECT * FROM dq_objetivo LIMIT 1) s ON true) k ',
  'WHERE NOT columna RLIKE ', dq_lit(dq_regex_excluir_columnas));
EXECUTE IMMEDIATE dq_sql;

SET VAR dq_sql = coalesce((
  SELECT IF(count(*) = 0,
            'CREATE OR REPLACE TEMP VIEW dq_columnas AS SELECT CAST(NULL AS STRING) AS columna, CAST(NULL AS INT) AS ordinal, CAST(NULL AS STRING) AS tipo_declarado, CAST(NULL AS STRING) AS familia, CAST(NULL AS STRING) AS es_nulable, CAST(NULL AS STRING) AS comentario WHERE false',
            concat('CREATE OR REPLACE TEMP VIEW dq_columnas AS ',
                   'SELECT b.columna, b.ordinal, upper(t.tipo) AS tipo_declarado, dq_familia(t.tipo) AS familia, b.es_nulable, b.comentario ',
                   'FROM dq_columnas_base b JOIN (SELECT stack(', CAST(count(*) AS STRING), ', ',
                   array_join(transform(array_sort(collect_list(struct(ordinal, par))), x -> x.par), ', '),
                   ') AS (columna, tipo) FROM (SELECT 1 AS _dq_uno) u LEFT JOIN (SELECT * FROM dq_objetivo LIMIT 1) s ON true) t ',
                   'ON b.columna = t.columna'))
  FROM (SELECT ordinal, concat(dq_lit(columna), ', typeof(s.', dq_id(columna), ')') AS par FROM dq_columnas_base)),
  'SELECT 1');
EXECUTE IMMEDIATE dq_sql;

SET VAR dq_n_columnas    = (SELECT count(*) FROM dq_columnas);
SET VAR dq_n_filas_total = (SELECT count(*) FROM dq_objetivo);
SET VAR dq_frac_muestra  = least(1.0, dq_max_filas_muestra / greatest(dq_n_filas_total, 1));
SET VAR dq_estado = CASE WHEN dq_n_columnas = 0 THEN 'SIN_COLUMNAS'
                         WHEN dq_n_filas_total = 0 THEN 'TABLA_VACIA'
                         ELSE dq_estado END;

SET VAR dq_log = array_append(dq_log, named_struct(
  'paso', 'P2.03v2', 'escenario', dq_estado,
  'detalle', concat(dq_n_columnas, ' columnas a perfilar; ', dq_n_filas_total, ' filas en dq_objetivo'),
  'interpretacion', CASE dq_estado
    WHEN 'TABLA_VACIA' THEN 'Sin filas: las capas correrán pero sus resultados estarán vacíos. Hipótesis: carga no ejecutada, filtro de filas de Unity Catalog, o tipo de registro objetivo que no existe en la data.'
    WHEN 'SIN_COLUMNAS' THEN 'Ninguna columna perfilable: revisen dq_regex_excluir_columnas y el formato detectado.'
    ELSE 'Preparación correcta.' END));
