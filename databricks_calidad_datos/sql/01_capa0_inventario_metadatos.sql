/* ════════════════════════════════════════════════════════════════════════════
   ARCHIVO 01 · CAPA 0 — INVENTARIO TRANSVERSAL Y SALUD DEL ESQUEMA
   (lo más general: todas las tablas del alcance, casi sin leer data)
   ────────────────────────────────────────────────────────────────────────────
   DOCSTRING (es-PE)
     Responde "¿qué tenemos y qué tan sano está el diseño?" antes de mirar
     valores. Se apoya en <catalogo>.information_schema (Unity Catalog) y,
     al final, en un perfil ligero multi-tabla (una sola pasada por tabla).
     Cubre los pilares de observabilidad "esquema" y "frescura" (Monte Carlo
     / Barr Moses) y las dimensiones de metadatos de DAMA-DMBOK e ISO 8000.
     Alcance: dq_catalogo + (dq_esquema | dq_regex_esquemas) + dq_regex_tablas.
   TOOLTIP ▸ Cómo usar
     • Corran L0.01 a L0.06 primero (son baratas). L0.07/L0.08 son de Delta
       para la tabla objetivo. L0.09-L0.11 sí leen data de TODAS las tablas
       del alcance: limiten el alcance o usen dq_max_filas_inventario.
     • Personalización futura: agreguen sus convenciones de nombres y las
       palabras clave de su dominio en L0.03/L0.05 (ver README §Personalizar).
   ════════════════════════════════════════════════════════════════════════════ */


/* ────────────────────────────────────────────────────────────────────────────
   [L0.00] Recalcular rutas (por si cambiaron catálogo/esquema/tabla)
   DOCSTRING (es-PE)
     Recalcula dq_info_schema y dq_tabla_fq con los valores actuales de las
     variables. No devuelve filas.
   TOOLTIP ▸ Cómo interpretar
     • Siempre córranla antes de la capa 0 si hicieron SET VAR de catálogo,
       esquema o tabla.
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_info_schema = concat(dq_id(dq_catalogo), '.information_schema');
SET VAR dq_tabla_fq = concat_ws('.',
  IF(dq_catalogo = '', NULL, dq_id(dq_catalogo)),
  IF(dq_esquema  = '', NULL, dq_id(dq_esquema)),
  dq_id(dq_tabla));


/* ────────────────────────────────────────────────────────────────────────────
   [L0.01] Inventario de tablas del alcance con alertas de diseño
   DOCSTRING (es-PE)
     Lista cada tabla/vista del alcance con su tipo, formato, dueño, fechas
     de creación y último cambio, número de columnas, % de columnas texto,
     % sin comentario, y un arreglo de alertas de diseño.
   TOOLTIP ▸ Cómo leer e interpretar
     • ESQUEMA_TODO_TEXTO (≥80% columnas STRING): típico de bronze/landing.
       Si es silver/gold, es deuda: los tipos no se están validando y los
       errores (fechas mal escritas, montos con coma) llegan a los modelos.
     • SIN_DOCUMENTAR: tabla sin comentario o >50% de columnas sin comentario
       → riesgo de interpretación (el "data dictionary" es parte de la calidad).
     • FORMATO_NO_DELTA: sin ACID, sin time travel ni constraints.
     • SIN_CAMBIOS_RECIENTES: last_altered más viejo que dq_sla_frescura_dias.
       Ojo: last_altered refleja cambios de la tabla (data o DDL) según UC;
       para frescura real de la data usen L4.01 sobre la columna de evento.
     • TABLA_MUY_ANCHA (>300 columnas): suele indicar pivotes o "tablas
       sábana"; complica el gobierno y el perfilado.
   ──────────────────────────────────────────────────────────────────────────── */
WITH col AS (
  SELECT table_schema, table_name,
         count(*)                                                        AS n_columnas,
         count_if(dq_familia(coalesce(full_data_type, data_type)) = 'TEXTO')    AS n_texto,
         count_if(dq_familia(coalesce(full_data_type, data_type)) = 'COMPLEJO') AS n_complejas,
         count_if(comment IS NULL OR trim(comment) = '')                 AS n_sin_comentario
  FROM IDENTIFIER(dq_info_schema || '.columns')
  GROUP BY table_schema, table_name
)
SELECT t.table_schema                                   AS esquema,
       t.table_name                                     AS tabla,
       t.table_type                                     AS tipo_tabla,
       t.data_source_format                             AS formato,
       t.table_owner                                    AS dueno,
       t.created                                        AS creada,
       t.last_altered                                   AS ultimo_cambio,
       datediff(current_date(), CAST(t.last_altered AS DATE)) AS dias_desde_ultimo_cambio,
       c.n_columnas,
       round(c.n_texto / NULLIF(c.n_columnas, 0), 3)          AS pct_columnas_texto,
       c.n_complejas,
       round(c.n_sin_comentario / NULLIF(c.n_columnas, 0), 3) AS pct_columnas_sin_comentario,
       filter(array(
         IF(c.n_texto / NULLIF(c.n_columnas, 0) >= 0.8 AND c.n_columnas >= 3, 'ESQUEMA_TODO_TEXTO', NULL),
         IF(t.comment IS NULL OR trim(t.comment) = '' OR c.n_sin_comentario / NULLIF(c.n_columnas, 0) > 0.5,
            'SIN_DOCUMENTAR', NULL),
         IF(t.table_type NOT RLIKE 'VIEW' AND upper(coalesce(t.data_source_format, '')) <> 'DELTA',
            'FORMATO_NO_DELTA', NULL),
         IF(datediff(current_date(), CAST(t.last_altered AS DATE)) > dq_sla_frescura_dias,
            'SIN_CAMBIOS_RECIENTES', NULL),
         IF(c.n_columnas > 300, 'TABLA_MUY_ANCHA', NULL),
         IF(c.n_columnas IS NULL, 'SIN_COLUMNAS_VISIBLES', NULL)
       ), x -> x IS NOT NULL)                           AS alertas
FROM IDENTIFIER(dq_info_schema || '.tables') t
LEFT JOIN col c
  ON c.table_schema = t.table_schema AND c.table_name = t.table_name
WHERE lower(t.table_schema) <> 'information_schema'
  AND ((dq_regex_esquemas = '' AND lower(t.table_schema) = lower(dq_esquema))
       OR (dq_regex_esquemas <> '' AND t.table_schema RLIKE dq_regex_esquemas))
  AND t.table_name RLIKE dq_regex_tablas
ORDER BY size(alertas) DESC, esquema, tabla;


/* ────────────────────────────────────────────────────────────────────────────
   [L0.02] Distribución de familias de tipos por tabla
   DOCSTRING (es-PE)
     Cuenta, por tabla, cuántas columnas hay de cada familia analítica
     (NUMERICO, TEXTO, FECHA, TIMESTAMP, BOOLEANO, COMPLEJO, ...).
   TOOLTIP ▸ Cómo leer e interpretar
     • Tablas de hechos sanas tienen varias NUMERICO y al menos una
       FECHA/TIMESTAMP. Si una tabla transaccional tiene 0 columnas de fecha
       pero sí columnas texto con nombre "fecha_*", el tipo se perdió en la
       ingesta (ver L0.03 y capa 2).
     • Muchas COMPLEJO (struct/map/array/variant) = JSON anidado sin aplanar:
       validen sus campos internos en la capa 8 con reglas específicas.
   ──────────────────────────────────────────────────────────────────────────── */
SELECT table_schema AS esquema,
       table_name   AS tabla,
       count(*)     AS n_columnas,
       count_if(dq_familia(coalesce(full_data_type, data_type)) = 'NUMERICO')  AS n_numerico,
       count_if(dq_familia(coalesce(full_data_type, data_type)) = 'TEXTO')     AS n_texto,
       count_if(dq_familia(coalesce(full_data_type, data_type)) = 'FECHA')     AS n_fecha,
       count_if(dq_familia(coalesce(full_data_type, data_type)) = 'TIMESTAMP') AS n_timestamp,
       count_if(dq_familia(coalesce(full_data_type, data_type)) = 'BOOLEANO')  AS n_booleano,
       count_if(dq_familia(coalesce(full_data_type, data_type)) = 'COMPLEJO')  AS n_complejo,
       count_if(dq_familia(coalesce(full_data_type, data_type)) IN ('BINARIO', 'INTERVALO', 'OTRO')) AS n_otros
FROM IDENTIFIER(dq_info_schema || '.columns')
WHERE lower(table_schema) <> 'information_schema'
  AND ((dq_regex_esquemas = '' AND lower(table_schema) = lower(dq_esquema))
       OR (dq_regex_esquemas <> '' AND table_schema RLIKE dq_regex_esquemas))
  AND table_name RLIKE dq_regex_tablas
GROUP BY table_schema, table_name
ORDER BY esquema, tabla;


/* ────────────────────────────────────────────────────────────────────────────
   [L0.03] Coherencia nombre ↔ tipo (tipos sospechosos por convención)
   DOCSTRING (es-PE)
     Busca columnas cuyo NOMBRE sugiere un tipo distinto al DECLARADO:
       FECHA_COMO_TEXTO/NUMERO : fecha_*, *_date, created_at... no son DATE/TIMESTAMP.
       MONTO_COMO_TEXTO        : monto, importe, precio, saldo... en STRING.
       MONTO_EN_FLOTANTE       : montos en FLOAT/DOUBLE (errores de redondeo:
                                 0.1 + 0.2 ≠ 0.3). Usar DECIMAL(p,s).
       CODIGO_COMO_NUMERO      : dni, ruc, ubigeo, teléfono, cuenta... en tipo
                                 numérico (se pierden ceros a la izquierda:
                                 DNI 01234567 → 1234567).
       CODIGO_EN_FLOTANTE      : ids/códigos en FLOAT/DOUBLE (pierden precisión
                                 sobre 2^53 y salen como 1.2345678E7).
       BANDERA_COMO_TEXTO      : flag_*, es_*, ind_*, activo... en STRING
                                 ('S','SI','Y','1','true' mezclados).
   TOOLTIP ▸ Cómo leer e interpretar
     • Es heurística por nombre: confirmen con la capa 2 (inferencia sobre los
       VALORES), que es la evidencia definitiva.
     • Personalización: agreguen sus prefijos/sufijos corporativos a las
       expresiones regulares (p.ej. 'fec_' , 'imp_', 'cod_').
   ──────────────────────────────────────────────────────────────────────────── */
WITH c AS (
  SELECT table_schema, table_name, column_name,
         upper(coalesce(full_data_type, data_type)) AS tipo,
         dq_familia(coalesce(full_data_type, data_type)) AS familia,
         lower(column_name) AS n
  FROM IDENTIFIER(dq_info_schema || '.columns')
  WHERE lower(table_schema) <> 'information_schema'
    AND ((dq_regex_esquemas = '' AND lower(table_schema) = lower(dq_esquema))
         OR (dq_regex_esquemas <> '' AND table_schema RLIKE dq_regex_esquemas))
    AND table_name RLIKE dq_regex_tablas
), h AS (
  SELECT *,
    CASE
      WHEN n RLIKE '(^|_)(fecha|fec|date|dt|ts|timestamp|vencimiento|nacimiento|created|updated|modified)(_|$)|(_at|_on)$'
           AND familia NOT IN ('FECHA', 'TIMESTAMP')
        THEN concat('FECHA_COMO_', familia)
      WHEN n RLIKE '(^|_)(monto|importe|precio|saldo|total|amount|amt|costo|ingreso|sueldo|salario|pago|deuda|tasa|rate)(_|$)'
           AND familia = 'TEXTO'
        THEN 'MONTO_COMO_TEXTO'
      WHEN n RLIKE '(^|_)(monto|importe|precio|saldo|total|amount|amt|costo|ingreso|sueldo|salario|pago|deuda)(_|$)'
           AND tipo RLIKE '^(FLOAT|DOUBLE|REAL)'
        THEN 'MONTO_EN_FLOTANTE'
      WHEN n RLIKE '(^|_)(id|cod|codigo|code|nro|numero|num|key|llave)(_|$)'
           AND tipo RLIKE '^(FLOAT|DOUBLE|REAL)'
        THEN 'CODIGO_EN_FLOTANTE'
      WHEN n RLIKE '(^|_)(dni|ruc|ubigeo|telefono|celular|cuenta|cci|ce|pasaporte|postal|zip|cuenta)(_|$)'
           AND familia = 'NUMERICO'
        THEN 'CODIGO_COMO_NUMERO'
      WHEN n RLIKE '^(flag|flg|es|is|has|tiene|ind|indicador)_|(^|_)(activo|habilitado|vigente|flag)$'
           AND familia = 'TEXTO'
        THEN 'BANDERA_COMO_TEXTO'
    END AS hallazgo
  FROM c
)
SELECT table_schema AS esquema, table_name AS tabla, column_name AS columna, tipo, hallazgo,
       CASE hallazgo
         WHEN 'MONTO_COMO_TEXTO'   THEN 'Validar con capa 2 (formato numérico/locale) y tipar como DECIMAL(p,s)'
         WHEN 'MONTO_EN_FLOTANTE'  THEN 'Migrar a DECIMAL(p,s) para evitar errores de redondeo'
         WHEN 'CODIGO_EN_FLOTANTE' THEN 'Usar BIGINT o STRING; un código no es una magnitud'
         WHEN 'CODIGO_COMO_NUMERO' THEN 'Usar STRING con longitud fija (lpad) para no perder ceros a la izquierda'
         WHEN 'BANDERA_COMO_TEXTO' THEN 'Normalizar a BOOLEAN; revisar valores distintos en capa 5'
         ELSE 'Validar con capa 2 qué % de valores es fecha y en qué formato; tipar como DATE/TIMESTAMP'
       END AS recomendacion
FROM h
WHERE hallazgo IS NOT NULL
ORDER BY hallazgo, esquema, tabla, columna;


/* ────────────────────────────────────────────────────────────────────────────
   [L0.04] Mismo nombre de columna con tipos distintos entre tablas
   DOCSTRING (es-PE)
     Agrupa por nombre de columna (en minúsculas) y reporta los que tienen más
     de un tipo declarado en el alcance (p.ej. id_cliente BIGINT en una tabla
     y STRING en otra).
   TOOLTIP ▸ Cómo leer e interpretar
     • Es causa raíz clásica de JOINs que "pierden" filas en silencio
       (casts implícitos, ceros a la izquierda, '001' ≠ 1) y de
       duplicados en modelos dimensionales.
     • Prioricen las columnas que son llaves (id_, cod_) y las que aparecen en
       más tablas (n_tablas alto).
   ──────────────────────────────────────────────────────────────────────────── */
SELECT lower(column_name)                                         AS columna,
       count(DISTINCT upper(coalesce(full_data_type, data_type))) AS n_tipos_distintos,
       count(DISTINCT concat(table_schema, '.', table_name))      AS n_tablas,
       sort_array(collect_set(concat(upper(coalesce(full_data_type, data_type)), ' ← ',
                                     table_schema, '.', table_name))) AS tipos_y_tablas
FROM IDENTIFIER(dq_info_schema || '.columns')
WHERE lower(table_schema) <> 'information_schema'
  AND ((dq_regex_esquemas = '' AND lower(table_schema) = lower(dq_esquema))
       OR (dq_regex_esquemas <> '' AND table_schema RLIKE dq_regex_esquemas))
  AND table_name RLIKE dq_regex_tablas
GROUP BY lower(column_name)
HAVING count(DISTINCT upper(coalesce(full_data_type, data_type))) > 1
ORDER BY n_tablas DESC, columna;


/* ────────────────────────────────────────────────────────────────────────────
   [L0.05] Convenciones de nombres de columnas
   DOCSTRING (es-PE)
     Reporta columnas que violan snake_case ASCII: mayúsculas, espacios,
     tildes/ñ, caracteres especiales, inicio con dígito, longitud > 64 o
     palabras reservadas/ambiguas de SQL (date, year, user, order, value...).
   TOOLTIP ▸ Cómo leer e interpretar
     • No es un error de datos, pero sí de mantenibilidad: obligan a usar
       backticks, rompen herramientas (exportes CSV, BI, pandas) y exigen
       column mapping en Delta.
     • Ojo con `año`: en algunos clientes/ODBC se vuelve 'a?o' (problema de
       encoding) y se pierde la columna en el join.
   ──────────────────────────────────────────────────────────────────────────── */
WITH c AS (
  SELECT table_schema, table_name, column_name
  FROM IDENTIFIER(dq_info_schema || '.columns')
  WHERE lower(table_schema) <> 'information_schema'
    AND ((dq_regex_esquemas = '' AND lower(table_schema) = lower(dq_esquema))
         OR (dq_regex_esquemas <> '' AND table_schema RLIKE dq_regex_esquemas))
    AND table_name RLIKE dq_regex_tablas
)
SELECT table_schema AS esquema, table_name AS tabla, column_name AS columna,
       filter(array(
         IF(column_name RLIKE '[A-Z]', 'MAYUSCULAS', NULL),
         IF(column_name RLIKE '\\s', 'ESPACIOS', NULL),
         IF(column_name RLIKE '[^\\x00-\\x7F]', 'NO_ASCII (tildes/ñ)', NULL),
         IF(column_name RLIKE '[^A-Za-z0-9_\\s\\x{0080}-\\x{FFFF}]', 'CARACTER_ESPECIAL', NULL),
         IF(column_name RLIKE '^[0-9]', 'EMPIEZA_CON_DIGITO', NULL),
         IF(char_length(column_name) > 64, 'MUY_LARGO', NULL),
         IF(lower(column_name) IN ('all', 'and', 'any', 'as', 'between', 'both', 'by', 'case', 'cast', 'check',
                                   'column', 'constraint', 'create', 'cross', 'current_date', 'current_timestamp',
                                   'current_user', 'date', 'day', 'desc', 'asc', 'distinct', 'else', 'end',
                                   'except', 'false', 'for', 'foreign', 'from', 'full', 'group', 'having', 'hour',
                                   'in', 'inner', 'interval', 'is', 'join', 'key', 'left', 'like', 'limit',
                                   'minute', 'month', 'natural', 'not', 'null', 'on', 'or', 'order', 'outer',
                                   'primary', 'range', 'references', 'right', 'rows', 'second', 'select', 'table',
                                   'then', 'time', 'timestamp', 'to', 'true', 'type', 'union', 'unique', 'user',
                                   'using', 'value', 'values', 'when', 'where', 'window', 'with', 'year', 'comment',
                                   'location', 'partition'),
            'PALABRA_RESERVADA', NULL)
       ), x -> x IS NOT NULL) AS problemas
FROM c
WHERE NOT column_name RLIKE '^[a-z][a-z0-9_]{0,63}$'
   OR lower(column_name) IN ('date', 'day', 'month', 'year', 'hour', 'minute', 'second', 'time', 'timestamp',
                             'user', 'value', 'values', 'key', 'type', 'order', 'group', 'comment', 'location',
                             'partition', 'range', 'rows', 'window', 'interval', 'limit', 'desc', 'asc', 'table',
                             'select', 'from', 'where', 'end', 'case', 'when', 'like', 'in', 'is', 'on', 'to', 'by')
ORDER BY esquema, tabla, columna;


/* ────────────────────────────────────────────────────────────────────────────
   [L0.06] Restricciones declaradas (PK / FK) y tablas sin llave primaria
   DOCSTRING (es-PE)
     Une table_constraints, key_column_usage y referential_constraints para
     listar las PK y FK declaradas en Unity Catalog (informativas, NO se
     hacen cumplir) y marca las tablas del alcance que no declaran PK.
   TOOLTIP ▸ Cómo leer e interpretar
     • En Databricks las PK/FK son INFORMATIVAS: el motor no impide
       duplicados ni huérfanos. Por eso se validan con datos en L1.05
       (unicidad) y L7.07/L7.08 (integridad referencial).
     • Tabla sin PK = no hay definición formal de "grano"; acuérdenlo con el
       negocio y configúrenlo en dq_columnas_clave.
     • Si sale vacío y saben que hay constraints, revisen permisos sobre
       information_schema.
   ──────────────────────────────────────────────────────────────────────────── */
WITH alcance AS (
  SELECT table_schema, table_name
  FROM IDENTIFIER(dq_info_schema || '.tables')
  WHERE lower(table_schema) <> 'information_schema'
    AND ((dq_regex_esquemas = '' AND lower(table_schema) = lower(dq_esquema))
         OR (dq_regex_esquemas <> '' AND table_schema RLIKE dq_regex_esquemas))
    AND table_name RLIKE dq_regex_tablas
), restr AS (
  SELECT tc.table_schema, tc.table_name, tc.constraint_name, tc.constraint_type,
         array_join(transform(array_sort(collect_list(struct(k.ordinal_position, k.column_name))),
                              x -> x.column_name), ', ') AS columnas,
         max(rc.unique_constraint_name) AS restriccion_referenciada
  FROM IDENTIFIER(dq_info_schema || '.table_constraints') tc
  JOIN alcance a ON a.table_schema = tc.table_schema AND a.table_name = tc.table_name
  LEFT JOIN IDENTIFIER(dq_info_schema || '.key_column_usage') k
    ON k.constraint_schema = tc.constraint_schema AND k.constraint_name = tc.constraint_name
  LEFT JOIN IDENTIFIER(dq_info_schema || '.referential_constraints') rc
    ON rc.constraint_schema = tc.constraint_schema AND rc.constraint_name = tc.constraint_name
  GROUP BY tc.table_schema, tc.table_name, tc.constraint_name, tc.constraint_type
)
SELECT a.table_schema AS esquema, a.table_name AS tabla,
       r.constraint_type AS tipo_restriccion, r.constraint_name AS restriccion,
       r.columnas, r.restriccion_referenciada,
       IF(NOT exists(collect_list(r.constraint_type) OVER (PARTITION BY a.table_schema, a.table_name),
                     x -> x = 'PRIMARY KEY'),
          'TABLA_SIN_PK', NULL) AS alerta
FROM alcance a
LEFT JOIN restr r ON r.table_schema = a.table_schema AND r.table_name = a.table_name
ORDER BY esquema, tabla, tipo_restriccion;


/* ────────────────────────────────────────────────────────────────────────────
   [L0.07] Detalle físico Delta de la tabla objetivo (sólo Databricks)
   DOCSTRING (es-PE)
     DESCRIBE DETAIL: número de archivos, tamaño, columnas de partición y de
     clustering, propiedades y versión de protocolo de la tabla objetivo.
   TOOLTIP ▸ Cómo leer e interpretar
     • tamaño_promedio_archivo = sizeInBytes / numFiles. Si es < 32 MB con
       miles de archivos → problema de "small files": OPTIMIZE / liquid
       clustering. Particiones con < 1 GB cada una = sobre-particionado.
     • partitionColumns de alta cardinalidad (p.ej. id) = anti-patrón.
     • No aplica a vistas ni a tablas no-Delta (dará error: es esperado).
   ──────────────────────────────────────────────────────────────────────────── */
-- dq:solo-databricks
SET VAR dq_sql = concat('DESCRIBE DETAIL ', dq_tabla_fq);
-- dq:solo-databricks
EXECUTE IMMEDIATE dq_sql;


/* ────────────────────────────────────────────────────────────────────────────
   [L0.08] Historia de operaciones Delta de la tabla objetivo (sólo Databricks)
   DOCSTRING (es-PE)
     DESCRIBE HISTORY (últimas 30 versiones): quién escribió, qué operación
     (WRITE, MERGE, DELETE, OPTIMIZE...), cuándo y métricas por operación.
   TOOLTIP ▸ Cómo leer e interpretar
     • Frescura real: timestamp de la última operación de escritura.
     • Volumen: operationMetrics.numOutputRows por corrida; caídas o picos
       bruscos (p.ej. 0 filas un día) son la alerta de "volumen" de la
       observabilidad de datos.
     • Muchas operaciones DELETE/UPDATE/RESTORE no planificadas = señal de
       correcciones manuales: pregunten la causa raíz.
     • Las versiones sirven para la capa 6 (deriva entre versiones con
       VERSION AS OF).
   ──────────────────────────────────────────────────────────────────────────── */
-- dq:solo-databricks
SET VAR dq_sql = concat('DESCRIBE HISTORY ', dq_tabla_fq, ' LIMIT 30');
-- dq:solo-databricks
EXECUTE IMMEDIATE dq_sql;


/* ────────────────────────────────────────────────────────────────────────────
   [L0.09] Perfil ligero multi-tabla (genera y crea la vista dq_l0_perfil_ligero)
   DOCSTRING (es-PE)
     Genera UN SQL que recorre todas las tablas del alcance (excepto vistas)
     y, en una sola pasada por tabla, calcula por columna: nulos, distintos
     aproximados (HyperLogLog++ con error relativo ~1%), vacíos (texto) y mín/máx.
     El resultado queda en la vista temporal dq_l0_perfil_ligero.
   TOOLTIP ▸ Cómo leer e interpretar
     • Esta sentencia NO devuelve el perfil: lo deja en la vista; véanlo con
       L0.10 y L0.11.
     • Costo ≈ un escaneo completo de cada tabla del alcance. Para alcances
       grandes: restrinjan dq_regex_tablas o pongan dq_max_filas_inventario
       (primeras N filas: rápido pero sesgado, sólo para "olfatear").
     • Ojo: la vista se recalcula cada vez que se consulta; si el alcance es
       grande, guarden el resultado (L0.12) en dq_esquema_trabajo.
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_sql = (
  WITH c AS (
    SELECT c.table_schema, c.table_name, c.column_name, c.ordinal_position,
           dq_familia(coalesce(c.full_data_type, c.data_type)) AS familia
    FROM IDENTIFIER(dq_info_schema || '.columns') c
    JOIN IDENTIFIER(dq_info_schema || '.tables') t
      ON t.table_schema = c.table_schema AND t.table_name = c.table_name
    WHERE lower(c.table_schema) <> 'information_schema'
      AND ((dq_regex_esquemas = '' AND lower(c.table_schema) = lower(dq_esquema))
           OR (dq_regex_esquemas <> '' AND c.table_schema RLIKE dq_regex_esquemas))
      AND c.table_name RLIKE dq_regex_tablas
      AND coalesce(t.table_type, '') NOT RLIKE 'VIEW'
  ), e AS (
    SELECT table_schema, table_name, ordinal_position,
           concat(dq_lit(column_name), ', ', dq_lit(familia), ', ',
                  'm', CAST(ordinal_position AS STRING), '_nul, ',
                  'm', CAST(ordinal_position AS STRING), '_dis, ',
                  'm', CAST(ordinal_position AS STRING), '_vac, ',
                  'm', CAST(ordinal_position AS STRING), '_min, ',
                  'm', CAST(ordinal_position AS STRING), '_max') AS e_stack,
           concat('count_if(', dq_id(column_name), ' IS NULL) AS m', CAST(ordinal_position AS STRING), '_nul, ',
                  'approx_count_distinct(',
                     IF(familia IN ('COMPLEJO'), concat('to_json(', dq_id(column_name), ')'), dq_id(column_name)),
                  ', 0.01) AS m', CAST(ordinal_position AS STRING), '_dis, ',
                  IF(familia = 'TEXTO',
                     concat('count_if(trim(', dq_id(column_name), ') = ', dq_lit(''), ')'),
                     'CAST(NULL AS BIGINT)'),
                  ' AS m', CAST(ordinal_position AS STRING), '_vac, ',
                  IF(familia IN ('COMPLEJO', 'BINARIO', 'OTRO', 'INTERVALO'), 'CAST(NULL AS STRING)',
                     concat('CAST(min(', dq_id(column_name), ') AS STRING)')),
                  ' AS m', CAST(ordinal_position AS STRING), '_min, ',
                  IF(familia IN ('COMPLEJO', 'BINARIO', 'OTRO', 'INTERVALO'), 'CAST(NULL AS STRING)',
                     concat('CAST(max(', dq_id(column_name), ') AS STRING)')),
                  ' AS m', CAST(ordinal_position AS STRING), '_max') AS e_agg
    FROM c
  ), por_tabla AS (
    SELECT concat(
             'SELECT ', dq_lit(table_schema), ' AS esquema, ', dq_lit(table_name), ' AS tabla, n_filas, ',
             'stack(', CAST(count(*) AS STRING), ', ',
             array_join(transform(array_sort(collect_list(struct(ordinal_position, e_stack))), x -> x.e_stack), ', '),
             ') AS (columna, familia, n_nulos, n_distintos_aprox, n_vacios, min_valor, max_valor) ',
             'FROM (SELECT count(*) AS n_filas, ',
             array_join(transform(array_sort(collect_list(struct(ordinal_position, e_agg))), x -> x.e_agg), ', '),
             ' FROM (SELECT * FROM ', dq_id(dq_catalogo), '.', dq_id(table_schema), '.', dq_id(table_name),
             IF(dq_max_filas_inventario > 0, concat(' LIMIT ', CAST(dq_max_filas_inventario AS STRING)), ''),
             ') t) a') AS sql_tabla
    FROM e
    GROUP BY table_schema, table_name
  )
  SELECT concat('CREATE OR REPLACE TEMP VIEW dq_l0_perfil_ligero AS ',
                coalesce(array_join(collect_list(sql_tabla), ' UNION ALL '),
                         'SELECT CAST(NULL AS STRING) AS esquema, CAST(NULL AS STRING) AS tabla, 0L AS n_filas, CAST(NULL AS STRING) AS columna, CAST(NULL AS STRING) AS familia, 0L AS n_nulos, 0L AS n_distintos_aprox, 0L AS n_vacios, CAST(NULL AS STRING) AS min_valor, CAST(NULL AS STRING) AS max_valor WHERE false'))
  FROM por_tabla
);
EXECUTE IMMEDIATE dq_sql;


/* ────────────────────────────────────────────────────────────────────────────
   [L0.10] Perfil ligero por columna con alertas (todas las tablas)
   DOCSTRING (es-PE)
     Lee dq_l0_perfil_ligero y agrega % de nulos, % de vacíos, ratio de
     cardinalidad y alertas por columna, ordenado por gravedad.
   TOOLTIP ▸ Cómo leer e interpretar
     • COLUMNA_100%_NULA: columna muerta (o el pipeline no la está llenando
       desde algún cambio en la fuente: revisen DESCRIBE HISTORY).
     • CONSTANTE: un solo valor; no aporta información (ni a BI ni a ML).
     • NULOS_CRITICO / NULOS_ALERTA según dq_umbral_nulos_critico/alerta.
     • TEXTO_CON_VACIOS: '' o espacios en lugar de NULL → completitud
       sobreestimada si sólo se mira IS NULL.
     • POSIBLE_ID: distintos ≈ filas (ratio ≥ 0.98, ojo que es aproximado;
       se excluyen numéricos con decimales, que son medidas y no llaves).
   ──────────────────────────────────────────────────────────────────────────── */
SELECT esquema, tabla, columna, familia, n_filas, n_nulos,
       round(n_nulos / NULLIF(n_filas, 0), 4)                           AS pct_nulos,
       n_vacios,
       round(n_vacios / NULLIF(n_filas, 0), 4)                          AS pct_vacios,
       n_distintos_aprox,
       round(n_distintos_aprox / NULLIF(n_filas - n_nulos, 0), 4)       AS ratio_cardinalidad,
       min_valor, max_valor,
       filter(array(
         IF(n_filas > 0 AND n_nulos = n_filas, 'COLUMNA_100%_NULA', NULL),
         IF(n_nulos < n_filas AND n_distintos_aprox <= 1, 'CONSTANTE', NULL),
         IF(n_nulos / NULLIF(n_filas, 0) >= dq_umbral_nulos_critico AND n_nulos < n_filas, 'NULOS_CRITICO',
            IF(n_nulos / NULLIF(n_filas, 0) >= dq_umbral_nulos_alerta, 'NULOS_ALERTA', NULL)),
         IF(coalesce(n_vacios, 0) > 0, 'TEXTO_CON_VACIOS', NULL),
         IF(n_distintos_aprox / NULLIF(n_filas - n_nulos, 0) >= 0.98 AND n_filas - n_nulos > 100
            AND familia IN ('TEXTO', 'NUMERICO')
            AND NOT (familia = 'NUMERICO' AND (min_valor RLIKE '[.eE]' OR max_valor RLIKE '[.eE]')),
            'POSIBLE_ID', NULL),
         IF(n_filas = 0, 'TABLA_VACIA', NULL)
       ), x -> x IS NOT NULL) AS alertas
FROM dq_l0_perfil_ligero
ORDER BY size(alertas) DESC, esquema, tabla, columna;


/* ────────────────────────────────────────────────────────────────────────────
   [L0.11] Resumen de salud por tabla (todas las tablas del alcance)
   DOCSTRING (es-PE)
     Consolida el perfil ligero a nivel tabla: filas, columnas, columnas
     100% nulas, constantes, % de celdas nulas y un índice simple de
     completitud (1 - celdas nulas o vacías / celdas totales).
   TOOLTIP ▸ Cómo leer e interpretar
     • Úsenlo para PRIORIZAR qué tablas pasan a las capas 1-8 primero:
       las de índice de completitud más bajo o con más columnas muertas.
     • Una tabla con 0 filas en producción casi siempre es un incidente
       (pipeline caído o filtro mal puesto).
   ──────────────────────────────────────────────────────────────────────────── */
SELECT esquema, tabla,
       max(n_filas)                                                        AS n_filas,
       count(*)                                                            AS n_columnas,
       count_if(n_filas > 0 AND n_nulos = n_filas)                         AS n_columnas_100_nulas,
       count_if(n_nulos < n_filas AND n_distintos_aprox <= 1)              AS n_columnas_constantes,
       count_if(n_nulos / NULLIF(n_filas, 0) >= dq_umbral_nulos_alerta)    AS n_columnas_nulos_alerta,
       round(sum(n_nulos) / NULLIF(sum(n_filas), 0), 4)                    AS pct_celdas_nulas,
       round(1 - (sum(n_nulos) + sum(coalesce(n_vacios, 0))) / NULLIF(sum(n_filas), 0), 4) AS indice_completitud
FROM dq_l0_perfil_ligero
GROUP BY esquema, tabla
ORDER BY indice_completitud ASC, esquema, tabla;


/* ────────────────────────────────────────────────────────────────────────────
   [L0.12] Persistir el perfil ligero en la historia de métricas (opcional)
   DOCSTRING (es-PE)
     Si dq_esquema_trabajo está configurado, inserta en dq_metricas (formato
     largo) las métricas n_filas, n_nulos, pct_nulos y n_distintos_aprox de
     cada columna del alcance, con la marca de la corrida.
   TOOLTIP ▸ Cómo interpretar
     • Si dq_esquema_trabajo está vacío sólo verán 'persistencia desactivada'.
     • Con varias corridas, grafiquen pct_nulos por fecha en un dashboard
       para detectar degradaciones (alerta temprana de "data downtime").
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_sql = IF(
  dq_esquema_trabajo = '',
  concat('SELECT ', dq_lit('persistencia desactivada (dq_esquema_trabajo vacío)'), ' AS info'),
  concat('INSERT INTO ', dq_esquema_trabajo, '.dq_metricas ',
         'SELECT ', dq_lit(dq_id_corrida), ', current_timestamp(), concat(esquema, ', dq_lit('.'), ', tabla), ',
         'columna, ', dq_lit('L0'), ', metrica, valor, NULL ',
         'FROM dq_l0_perfil_ligero ',
         'LATERAL VIEW stack(4, ', dq_lit('n_filas'), ', CAST(n_filas AS DOUBLE), ',
                               dq_lit('n_nulos'), ', CAST(n_nulos AS DOUBLE), ',
                               dq_lit('pct_nulos'), ', n_nulos / NULLIF(n_filas, 0), ',
                               dq_lit('n_distintos_aprox'), ', CAST(n_distintos_aprox AS DOUBLE)) s AS metrica, valor'));
EXECUTE IMMEDIATE dq_sql;
