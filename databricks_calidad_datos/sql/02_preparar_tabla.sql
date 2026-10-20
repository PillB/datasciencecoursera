/* ════════════════════════════════════════════════════════════════════════════
   ARCHIVO 02 · PREPARACIÓN DE LA TABLA OBJETIVO (se corre por cada tabla)
   ────────────────────────────────────────────────────────────────────────────
   DOCSTRING (es-PE)
     Construye las 4 vistas temporales sobre las que trabajan las capas 1 a 8:
       dq_columnas : metadatos (columna, ordinal, tipo declarado, familia).
       dq_src      : la tabla (o su muestra determinística) con TODAS las
                     columnas convertidas a texto de forma controlada
                     (complejos → JSON, binarios → base64, CHAR → sin relleno)
                     + _dq_segmento y _dq_objetivo evaluados sobre la data cruda.
       dq_long     : formato largo (columna, valor) vía stack(): una fila por
                     celda. Permite perfilar N columnas con UNA sola consulta,
                     sin importar cuántas columnas tenga la tabla.
       dq_freq     : frecuencias (columna, valor, n). Casi todas las métricas
                     de texto se calculan sobre valores DISTINTOS ponderados
                     por n, lo cual es mucho más barato que fila por fila.
     Requisitos: archivo 00 ejecutado en la misma sesión. EXECUTE IMMEDIATE
     (DBR 14.3+ / Databricks SQL).
   TOOLTIP ▸ Cómo usar
     • Para cambiar de tabla: SET VAR dq_tabla = 'otra'; y vuelvan a correr
       este archivo completo. Las capas 1-8 se recalculan solas.
     • Si la tabla es grande, configuren dq_esquema_trabajo y
       SET VAR dq_materializar = true; así la fuente se lee una sola vez.
   ════════════════════════════════════════════════════════════════════════════ */


/* ────────────────────────────────────────────────────────────────────────────
   [P2.01] Nombre totalmente calificado y escapado de la tabla objetivo
   DOCSTRING (es-PE)
     Arma `catalogo`.`esquema`.`tabla` con backticks (soporta nombres raros).
     Si dq_catalogo o dq_esquema están vacíos se omiten (útil para vistas
     temporales o para hive_metastore con el esquema por defecto).
   TOOLTIP ▸ Cómo interpretar
     • No devuelve filas; el valor queda en dq_tabla_fq (ver P2.08).
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_tabla_fq = concat_ws('.',
  IF(dq_catalogo = '', NULL, dq_id(dq_catalogo)),
  IF(dq_esquema  = '', NULL, dq_id(dq_esquema)),
  dq_id(dq_tabla));

SET VAR dq_info_schema = concat(dq_id(dq_catalogo), '.information_schema');


/* ────────────────────────────────────────────────────────────────────────────
   [P2.02] Metadatos base de columnas (information_schema o inferidos)
   DOCSTRING (es-PE)
     Crea la vista dq_columnas_base con el listado de columnas en orden:
       • 'INFORMATION_SCHEMA': lee <catalogo>.information_schema.columns
         (no escanea data; trae tipo, nulabilidad y comentario).
       • 'INFERIDO': lee UNA fila de la tabla y saca los nombres con
         json_object_keys(to_json(struct(*))) — funciona con hive_metastore,
         vistas y vistas temporales.
     Aplica la exclusión dq_regex_excluir_columnas.
   TOOLTIP ▸ Cómo interpretar
     • No devuelve filas. Si luego P2.03 reporta 0 columnas, el filtro de
       catálogo/esquema/tabla no calza (revisen mayúsculas o permisos).
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_sql = IF(
  upper(dq_origen_metadatos) = 'INFERIDO',
  concat(
    'CREATE OR REPLACE TEMP VIEW dq_columnas_base AS ',
    'SELECT columna, ordinal, CAST(NULL AS STRING) AS tipo_declarado, ',
    '       CAST(NULL AS STRING) AS es_nulable, CAST(NULL AS STRING) AS comentario ',
    'FROM (SELECT posexplode(json_object_keys(to_json(struct(*), map(',
            dq_lit('ignoreNullFields'), ', ', dq_lit('false'), ')))) AS (ordinal, columna) ',
    '      FROM (SELECT * FROM ', dq_tabla_fq, ' LIMIT 1) t) k ',
    IF(dq_regex_excluir_columnas = '', '',
       concat('WHERE NOT columna RLIKE ', dq_lit(dq_regex_excluir_columnas)))),
  concat(
    'CREATE OR REPLACE TEMP VIEW dq_columnas_base AS ',
    'SELECT column_name AS columna, ordinal_position AS ordinal, ',
    '       upper(coalesce(full_data_type, data_type)) AS tipo_declarado, ',
    '       is_nullable AS es_nulable, comment AS comentario ',
    'FROM ', dq_info_schema, '.columns ',
    'WHERE lower(table_schema) = lower(', dq_lit(dq_esquema), ') ',
    '  AND lower(table_name)   = lower(', dq_lit(dq_tabla), ') ',
    IF(dq_regex_excluir_columnas = '', '',
       concat('AND NOT column_name RLIKE ', dq_lit(dq_regex_excluir_columnas))))
);
EXECUTE IMMEDIATE dq_sql;


/* ────────────────────────────────────────────────────────────────────────────
   [P2.03] Vista dq_columnas con familia analítica + controles de seguridad
   DOCSTRING (es-PE)
     En modo INFERIDO obtiene el tipo real de cada columna con typeof() sobre
     una fila; en modo INFORMATION_SCHEMA usa el tipo declarado. Luego cuenta
     columnas y filas, y aborta con un mensaje claro si la tabla no existe,
     no tiene columnas visibles o está vacía.
   TOOLTIP ▸ Cómo interpretar
     • Si sale el error "[DQ] ...", lean el mensaje: dice qué revisar.
     • dq_n_filas_total usa count(*): en Delta se resuelve con estadísticas
       (barato); en vistas complejas puede tardar.
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_sql = IF(
  upper(dq_origen_metadatos) = 'INFERIDO',
  (SELECT concat(
     'CREATE OR REPLACE TEMP VIEW dq_columnas AS ',
     'SELECT b.columna, b.ordinal, upper(t.tipo) AS tipo_declarado, ',
     '       dq_familia(t.tipo) AS familia, b.es_nulable, b.comentario ',
     'FROM dq_columnas_base b JOIN (SELECT stack(', CAST(count(*) AS STRING), ', ',
     array_join(transform(array_sort(collect_list(struct(ordinal, par))), x -> x.par), ', '),
     ') AS (columna, tipo) FROM (SELECT * FROM ', dq_tabla_fq, ' LIMIT 1) s) t ',
     'ON b.columna = t.columna')
   FROM (SELECT ordinal, concat(dq_lit(columna), ', typeof(', dq_id(columna), ')') AS par
         FROM dq_columnas_base)),
  'CREATE OR REPLACE TEMP VIEW dq_columnas AS
   SELECT columna, ordinal, tipo_declarado, dq_familia(tipo_declarado) AS familia,
          es_nulable, comentario
   FROM dq_columnas_base'
);
EXECUTE IMMEDIATE dq_sql;

SET VAR dq_n_columnas    = (SELECT count(*) FROM dq_columnas);
SET VAR dq_n_filas_total = (SELECT count(*) FROM IDENTIFIER(dq_tabla_fq));
SET VAR dq_frac_muestra  = least(1.0, dq_max_filas_muestra / greatest(dq_n_filas_total, 1));

SELECT CASE
         WHEN dq_n_columnas = 0 THEN raise_error(concat(
           '[DQ] No se encontraron columnas para ', dq_tabla_fq,
           '. Revisen catálogo/esquema/tabla, permisos, dq_regex_excluir_columnas ',
           'o usen SET VAR dq_origen_metadatos = ', dq_lit('INFERIDO')))
         WHEN dq_n_filas_total = 0 THEN raise_error(concat(
           '[DQ] La tabla ', dq_tabla_fq, ' está vacía: no hay nada que perfilar.'))
         ELSE concat('OK: ', dq_n_columnas, ' columnas, ', dq_n_filas_total, ' filas')
       END AS verificacion;


/* ────────────────────────────────────────────────────────────────────────────
   [P2.04] Generación del SQL dinámico (proyección a texto, stack y muestreo)
   DOCSTRING (es-PE)
     Construye, a partir de dq_columnas, los fragmentos SQL que usan las vistas:
       dq_proyeccion : cada columna convertida a texto según su familia.
       dq_stack      : stack(N, 'col1', `col1`, ...) para pasar a formato largo.
       dq_expr_hash  : hash de la clave de negocio (o de toda la fila).
       dq_filtro_muestra : WHERE pmod(hash, 1e6) < frac·1e6 (muestra
                       determinística; vacío si se procesa la tabla completa).
   TOOLTIP ▸ Cómo interpretar / personalizar
     • Si quieren ver el SQL generado: SELECT dq_proyeccion, dq_stack;
     • Para una conversión especial de alguna columna (p.ej. descifrar o
       enmascarar PII antes de perfilar), agreguen un WHEN en el CASE.
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_proyeccion = (
  SELECT array_join(transform(array_sort(collect_list(struct(ordinal, expr))), x -> x.expr), ', ')
  FROM (
    SELECT ordinal,
           concat(CASE
                    WHEN familia = 'TEXTO' AND tipo_declarado RLIKE '^CHAR'
                         THEN concat('rtrim(CAST(', dq_id(columna), ' AS STRING))')
                    WHEN familia = 'BINARIO'   THEN concat('base64(', dq_id(columna), ')')
                    WHEN familia = 'COMPLEJO'  THEN concat('to_json(', dq_id(columna), ')')
                    ELSE concat('CAST(', dq_id(columna), ' AS STRING)')
                  END,
                  ' AS ', dq_id(columna)) AS expr
    FROM dq_columnas));

SET VAR dq_lista_columnas = (
  SELECT array_join(transform(array_sort(collect_list(struct(ordinal, ident))), x -> x.ident), ', ')
  FROM (SELECT ordinal, dq_id(columna) AS ident FROM dq_columnas));

SET VAR dq_stack = (
  SELECT concat('stack(', CAST(count(*) AS STRING), ', ',
                array_join(transform(array_sort(collect_list(struct(ordinal, par))), x -> x.par), ', '),
                ') AS (columna, valor)')
  FROM (SELECT ordinal, concat(dq_lit(columna), ', ', dq_id(columna)) AS par FROM dq_columnas));

SET VAR dq_expr_hash = IF(
  trim(dq_columnas_clave) = '',
  concat('xxhash64(', dq_lista_columnas, ')'),
  concat('xxhash64(',
         array_join(transform(split(dq_columnas_clave, ','),
                              k -> concat('`', replace(trim(k), '`', '``'), '`')), ', '),
         ')'));

SET VAR dq_filtro_muestra = IF(
  dq_frac_muestra >= 1.0, '',
  concat(' WHERE pmod(', dq_expr_hash, ', 1000000) < ',
         CAST(CAST(ceil(dq_frac_muestra * 1000000) AS BIGINT) AS STRING)));


/* ────────────────────────────────────────────────────────────────────────────
   [P2.05] Vista dq_src (opcionalmente materializada en Delta)
   DOCSTRING (es-PE)
     Proyecta la tabla a texto controlado, agrega _dq_segmento y _dq_objetivo
     (evaluados sobre la data CRUDA y tipada) y aplica la muestra.
     Si dq_materializar = true y hay dq_esquema_trabajo, primero escribe una
     tabla Delta dq_tmp_src_<tabla> (con column mapping para soportar nombres
     de columnas con espacios o tildes) y la vista apunta a ella.
   TOOLTIP ▸ Cómo interpretar
     • El hash de muestreo se calcula sobre los valores en texto, así que
       es estable entre corridas mientras la data no cambie.
     • Ojo: si dq_expr_segmento/objetivo tienen un error de sintaxis, aquí
       saltará el error (no en las capas siguientes).
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_sql = concat(
  'SELECT * FROM (SELECT ', dq_proyeccion,
  ', CAST((', dq_expr_segmento, ') AS STRING) AS _dq_segmento',
  ', CAST((', dq_expr_objetivo, ') AS STRING) AS _dq_objetivo',
  ' FROM ', dq_tabla_fq, ') s', dq_filtro_muestra);

SET VAR dq_sql = IF(
  dq_materializar AND dq_esquema_trabajo <> '',
  concat('CREATE OR REPLACE TABLE ', dq_esquema_trabajo, '.dq_tmp_src_',
         regexp_replace(lower(dq_tabla), '[^a-z0-9_]', '_'),
         ' TBLPROPERTIES (', dq_lit('delta.columnMapping.mode'), ' = ', dq_lit('name'), ', ',
         dq_lit('delta.minReaderVersion'), ' = ', dq_lit('2'), ', ',
         dq_lit('delta.minWriterVersion'), ' = ', dq_lit('5'), ') AS ', dq_sql),
  concat('CREATE OR REPLACE TEMP VIEW dq_src AS ', dq_sql));
EXECUTE IMMEDIATE dq_sql;

SET VAR dq_sql = IF(
  dq_materializar AND dq_esquema_trabajo <> '',
  concat('CREATE OR REPLACE TEMP VIEW dq_src AS SELECT * FROM ', dq_esquema_trabajo,
         '.dq_tmp_src_', regexp_replace(lower(dq_tabla), '[^a-z0-9_]', '_')),
  concat('SELECT ', dq_lit('dq_src creada como vista (sin materializar)'), ' AS info'));
EXECUTE IMMEDIATE dq_sql;


/* ────────────────────────────────────────────────────────────────────────────
   [P2.06] Vista dq_long (formato largo: una fila por celda)
   DOCSTRING (es-PE)
     Despivotea dq_src con stack(): (_dq_segmento, _dq_objetivo, columna, valor).
     Conserva los NULL (stack no los descarta), cosa clave para medir
     completitud.
   TOOLTIP ▸ Cómo interpretar
     • Tamaño = filas_muestra × columnas. Con 2 MM de filas y 100 columnas son
       200 MM de celdas: manejable en un warehouse Medium; si es mucho, bajen
       dq_max_filas_muestra o excluyan columnas.
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_sql = concat(
  'CREATE OR REPLACE TEMP VIEW dq_long AS SELECT _dq_segmento, _dq_objetivo, ',
  dq_stack, ' FROM dq_src');
EXECUTE IMMEDIATE dq_sql;


/* ────────────────────────────────────────────────────────────────────────────
   [P2.07] Vista dq_freq (frecuencia de cada valor distinto por columna)
   DOCSTRING (es-PE)
     Agrupa dq_long por (columna, valor). Es la base de las capas 1, 2 y 5.
     Si dq_materializar = true se guarda como Delta (dq_tmp_freq_<tabla>).
   TOOLTIP ▸ Cómo interpretar
     • Filas de dq_freq = suma de la cardinalidad de cada columna. Columnas
       tipo ID (todo distinto) dominan el tamaño; es normal.
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_sql = IF(
  dq_materializar AND dq_esquema_trabajo <> '',
  concat('CREATE OR REPLACE TABLE ', dq_esquema_trabajo, '.dq_tmp_freq_',
         regexp_replace(lower(dq_tabla), '[^a-z0-9_]', '_'),
         ' AS SELECT columna, valor, count(*) AS n FROM dq_long GROUP BY columna, valor'),
  'CREATE OR REPLACE TEMP VIEW dq_freq AS SELECT columna, valor, count(*) AS n FROM dq_long GROUP BY columna, valor');
EXECUTE IMMEDIATE dq_sql;

SET VAR dq_sql = IF(
  dq_materializar AND dq_esquema_trabajo <> '',
  concat('CREATE OR REPLACE TEMP VIEW dq_freq AS SELECT * FROM ', dq_esquema_trabajo,
         '.dq_tmp_freq_', regexp_replace(lower(dq_tabla), '[^a-z0-9_]', '_')),
  concat('SELECT ', dq_lit('dq_freq creada como vista (sin materializar)'), ' AS info'));
EXECUTE IMMEDIATE dq_sql;


/* ────────────────────────────────────────────────────────────────────────────
   [P2.08] Resumen de la preparación
   DOCSTRING (es-PE)
     Muestra la tabla procesada, filas totales, fracción muestreada, filas
     efectivas en la muestra, columnas por familia y el modo de metadatos.
   TOOLTIP ▸ Cómo interpretar
     • filas_en_muestra ≈ filas_total × fraccion_muestra. Si es 1.0, todo lo
       que sigue es EXACTO; si es menor, los conteos son de la muestra y los
       porcentajes son estimaciones (error típico ≈ sqrt(p(1-p)/n)).
     • columnas_por_familia: si casi todo es TEXTO en una tabla que debería
       estar tipada, ya tienen el primer hallazgo (esquema "todo string").
   ──────────────────────────────────────────────────────────────────────────── */
SELECT
  dq_tabla_fq                                            AS tabla,
  dq_origen_metadatos                                    AS origen_metadatos,
  dq_n_filas_total                                       AS filas_total,
  round(dq_frac_muestra, 6)                              AS fraccion_muestra,
  (SELECT count(*) FROM dq_src)                          AS filas_en_muestra,
  dq_n_columnas                                          AS n_columnas,
  (SELECT to_json(map_from_entries(collect_list(struct(familia, n))))
     FROM (SELECT familia, count(*) AS n FROM dq_columnas GROUP BY familia)) AS columnas_por_familia,
  IF(dq_columnas_clave = '', '(sin clave: hash de fila)', dq_columnas_clave) AS base_muestreo,
  dq_expr_segmento                                       AS expr_segmento,
  dq_expr_objetivo                                       AS expr_objetivo;
