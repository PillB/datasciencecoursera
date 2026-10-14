/* ════════════════════════════════════════════════════════════════════════════
   ARCHIVO 00 · CONFIGURACIÓN Y FUNCIONES AUXILIARES
   Marco de Validación, Perfilado y EDA por capas para Databricks SQL
   ────────────────────────────────────────────────────────────────────────────
   DOCSTRING (es-PE)
     Este archivo se corre PRIMERO y una sola vez por sesión (o cada vez que
     cambien de tabla o de umbrales). Declara las variables de sesión que
     gobiernan todo el marco, las funciones temporales reutilizables y,
     opcionalmente, la tabla donde se historizan las métricas.
     Requisitos: Databricks SQL (warehouse Pro/Serverless) o DBR 14.3 LTS+.
     Probado con ANSI activado (por defecto en Databricks SQL): todas las
     conversiones usan try_cast / try_divide / NULLIF para no reventar.
   TOOLTIP ▸ Cómo usar
     • Editen los DEFAULT de la sección 1 y 2, o después hagan
       SET VAR dq_tabla = 'otra_tabla'; y vuelvan a correr el archivo 02.
     • Ojo: los nombres de variables empiezan con dq_ para que no choquen con
       nombres de columnas (en Databricks la columna le gana a la variable).
       Si una tabla tuviera una columna llamada igual, usen system.session.dq_x.
     • Los umbrales son puntos de partida de la literatura/industria; en rondas
       futuras ajústenlos por tabla con lo que el negocio considere tolerable.
   ════════════════════════════════════════════════════════════════════════════ */


/* ────────────────────────────────────────────────────────────────────────────
   [C0.01] Variables: tabla objetivo y alcance del inventario
   DOCSTRING (es-PE)
     Define qué tabla se va a perfilar a fondo (capas 1 a 8) y qué esquemas
     entran al inventario transversal (capa 0).
       dq_catalogo / dq_esquema / dq_tabla : tabla objetivo (Unity Catalog).
       dq_regex_esquemas : regex de esquemas para la capa 0 ('' = sólo dq_esquema).
       dq_regex_tablas   : regex de tablas para la capa 0 ('.*' = todas).
       dq_regex_excluir_columnas : regex de columnas a excluir del perfilado
                           (p.ej. '^(_rescued_data|_metadata)$'). '' = ninguna.
       dq_origen_metadatos : 'INFORMATION_SCHEMA' (Unity Catalog, por defecto)
                           o 'INFERIDO' (hive_metastore, vistas temporales o
                           cuando no tengan acceso a information_schema: lee 1 fila
                           y deduce nombres y tipos con typeof()).
   TOOLTIP ▸ Cómo interpretar / ajustar
     • Si el archivo 02 dice "no se encontraron columnas", revisen mayúsculas,
       permisos (USE CATALOG/USE SCHEMA/SELECT) o cambien a 'INFERIDO'.
   ──────────────────────────────────────────────────────────────────────────── */
DECLARE OR REPLACE VARIABLE dq_catalogo               STRING DEFAULT 'main';
DECLARE OR REPLACE VARIABLE dq_esquema                STRING DEFAULT 'default';
DECLARE OR REPLACE VARIABLE dq_tabla                  STRING DEFAULT 'mi_tabla';
DECLARE OR REPLACE VARIABLE dq_regex_esquemas         STRING DEFAULT '';
DECLARE OR REPLACE VARIABLE dq_regex_tablas           STRING DEFAULT '.*';
DECLARE OR REPLACE VARIABLE dq_regex_excluir_columnas STRING DEFAULT '';
DECLARE OR REPLACE VARIABLE dq_origen_metadatos       STRING DEFAULT 'INFORMATION_SCHEMA';


/* ────────────────────────────────────────────────────────────────────────────
   [C0.02] Variables: muestreo, claves y expresiones de negocio
   DOCSTRING (es-PE)
     dq_max_filas_muestra : tope de filas a perfilar. Si la tabla es más grande
                            se toma una muestra DETERMINÍSTICA por hash (misma
                            muestra en cada corrida; reproducible y auditable).
     dq_columnas_clave    : columnas de la clave de negocio separadas por coma
                            ('id_cliente' o 'id_cliente, fecha'). Si se informa,
                            la muestra se hace por hash de la clave: así TODAS
                            las filas de una misma clave caen juntas y el
                            chequeo de unicidad sigue siendo válido en muestra.
     dq_expr_segmento     : expresión SQL sobre la tabla cruda para segmentar
                            (p.ej. "date_format(fecha_registro, 'yyyy-MM')" o
                            "CASE WHEN fecha < '2025-01-01' THEN 'TRAIN' ELSE 'TEST' END").
                            Se usa en faltantes condicionales, deriva (PSI) y ML.
     dq_expr_objetivo     : expresión del target / etiqueta para la capa 8 (ML).
                            'NULL' = no aplica.
     dq_valor_positivo    : valor del target que cuenta como clase positiva.
     dq_max_filas_inventario : tope de filas por tabla en el perfil ligero
                            multi-tabla de la capa 0 (0 = tabla completa; >0 =
                            primeras N filas, rápido pero SESGADO).
   TOOLTIP ▸ Cómo interpretar / ajustar
     • Con 2 millones de filas las métricas de distribución son muy estables;
       para conteos exactos (duplicados, huérfanos) usen dq_max_filas_muestra
       grande o las consultas marcadas como "tabla completa".
     • Ojo: las expresiones se pegan tal cual dentro del SQL generado; sólo
       úsenlas con texto propio (no con entradas de terceros).
   ──────────────────────────────────────────────────────────────────────────── */
DECLARE OR REPLACE VARIABLE dq_max_filas_muestra BIGINT DEFAULT 2000000;
DECLARE OR REPLACE VARIABLE dq_columnas_clave    STRING DEFAULT '';
DECLARE OR REPLACE VARIABLE dq_expr_segmento     STRING DEFAULT 'NULL';
DECLARE OR REPLACE VARIABLE dq_expr_objetivo     STRING DEFAULT 'NULL';
DECLARE OR REPLACE VARIABLE dq_valor_positivo    STRING DEFAULT '1';
DECLARE OR REPLACE VARIABLE dq_max_filas_inventario BIGINT DEFAULT 0;


/* ────────────────────────────────────────────────────────────────────────────
   [C0.03] Variables: umbrales de alerta (puntos de partida)
   DOCSTRING (es-PE)
     Umbrales usados por las consultas para levantar banderas. Fuentes:
     Tukey (1977) para IQR, Iglewicz y Hoaglin (1993) para z robusto (3.5),
     Siddiqi (2006) / Yurdakul (2018) para PSI (0.10 / 0.25), Nigrini (2012)
     para Benford, práctica de scoring crediticio para IV (>0.5 = sospechoso).
   TOOLTIP ▸ Cómo interpretar / ajustar
     • dq_umbral_tipo_dominante = 0.90 significa: "si 90% o más de los valores
       de una columna texto parecen fechas, la tratamos como fecha y el 10%
       restante son SOSPECHOSOS de error". Súbanlo a 0.98 en tablas curadas
       (silver/gold) y bájenlo a 0.80 en zonas crudas (bronze/landing).
     • dq_orden_fecha_texto: 'DMY' (dd/MM/yyyy, convención peruana) o 'MDY'.
   ──────────────────────────────────────────────────────────────────────────── */
DECLARE OR REPLACE VARIABLE dq_umbral_tipo_dominante  DOUBLE DEFAULT 0.90;
DECLARE OR REPLACE VARIABLE dq_umbral_nulos_alerta    DOUBLE DEFAULT 0.20;
DECLARE OR REPLACE VARIABLE dq_umbral_nulos_critico   DOUBLE DEFAULT 0.50;
DECLARE OR REPLACE VARIABLE dq_umbral_raro            DOUBLE DEFAULT 0.001;
DECLARE OR REPLACE VARIABLE dq_umbral_correlacion     DOUBLE DEFAULT 0.95;
DECLARE OR REPLACE VARIABLE dq_umbral_psi_moderado    DOUBLE DEFAULT 0.10;
DECLARE OR REPLACE VARIABLE dq_umbral_psi_alto        DOUBLE DEFAULT 0.25;
DECLARE OR REPLACE VARIABLE dq_umbral_z_robusto       DOUBLE DEFAULT 3.5;
DECLARE OR REPLACE VARIABLE dq_umbral_iv_sospechoso   DOUBLE DEFAULT 0.5;
DECLARE OR REPLACE VARIABLE dq_min_n_segmento         BIGINT DEFAULT 30;
DECLARE OR REPLACE VARIABLE dq_fecha_min_valida       DATE   DEFAULT DATE'1900-01-01';
DECLARE OR REPLACE VARIABLE dq_tolerancia_futuro_dias INT    DEFAULT 1;
DECLARE OR REPLACE VARIABLE dq_sla_frescura_dias      INT    DEFAULT 2;
DECLARE OR REPLACE VARIABLE dq_orden_fecha_texto      STRING DEFAULT 'DMY';
DECLARE OR REPLACE VARIABLE dq_top_n                  INT    DEFAULT 10;
DECLARE OR REPLACE VARIABLE dq_max_cardinalidad_cat   INT    DEFAULT 50;
DECLARE OR REPLACE VARIABLE dq_max_columnas_pares     INT    DEFAULT 60;
DECLARE OR REPLACE VARIABLE dq_max_dias_calendario    INT    DEFAULT 3700;


/* ────────────────────────────────────────────────────────────────────────────
   [C0.04] Variables: deriva (capa 6), persistencia y variables internas
   DOCSTRING (es-PE)
     dq_modo_deriva     : 'SEGMENTO' compara dos valores de dq_expr_segmento
                          (dq_segmento_base vs dq_segmento_actual) usando la
                          muestra ya preparada; 'FUENTES' compara dos orígenes
                          arbitrarios (dq_fuente_base vs dq_fuente_actual),
                          p.ej. 'main.ventas.tx VERSION AS OF 120' vs
                          'main.ventas.tx' (time travel de Delta) o
                          "main.ml.train" vs "main.ml.scoring".
     dq_esquema_trabajo : 'catalogo.esquema' donde se pueden materializar
                          intermedios y guardar la historia de métricas.
                          '' = no se escribe nada (sólo lectura).
     dq_materializar    : true = guarda dq_src y dq_freq como tablas Delta en
                          dq_esquema_trabajo (recomendado si la tabla es grande:
                          evita re-escanear la fuente en cada consulta).
     dq_id_corrida      : identificador de la corrida para la historia.
     dq_sql, dq_* (resto): variables internas; no las toquen.
   TOOLTIP ▸ Cómo interpretar / ajustar
     • Para monitoreo continuo: dejen dq_esquema_trabajo configurado y
       programen los archivos como Job; la tabla dq_metricas permite ver
       tendencias y detectar anomalías sobre las propias métricas.
   ──────────────────────────────────────────────────────────────────────────── */
DECLARE OR REPLACE VARIABLE dq_modo_deriva      STRING DEFAULT 'SEGMENTO';
DECLARE OR REPLACE VARIABLE dq_segmento_base    STRING DEFAULT '';
DECLARE OR REPLACE VARIABLE dq_segmento_actual  STRING DEFAULT '';
DECLARE OR REPLACE VARIABLE dq_fuente_base      STRING DEFAULT '';
DECLARE OR REPLACE VARIABLE dq_fuente_actual    STRING DEFAULT '';
DECLARE OR REPLACE VARIABLE dq_esquema_trabajo  STRING DEFAULT '';
DECLARE OR REPLACE VARIABLE dq_materializar     BOOLEAN DEFAULT false;
DECLARE OR REPLACE VARIABLE dq_id_corrida       STRING DEFAULT uuid();
-- Internas (las llenan los archivos 02 en adelante):
DECLARE OR REPLACE VARIABLE dq_sql              STRING DEFAULT '';
DECLARE OR REPLACE VARIABLE dq_tabla_fq         STRING DEFAULT '';
DECLARE OR REPLACE VARIABLE dq_info_schema      STRING DEFAULT '';
DECLARE OR REPLACE VARIABLE dq_n_filas_total    BIGINT DEFAULT 0;
DECLARE OR REPLACE VARIABLE dq_frac_muestra     DOUBLE DEFAULT 1.0;
DECLARE OR REPLACE VARIABLE dq_n_columnas       INT    DEFAULT 0;
DECLARE OR REPLACE VARIABLE dq_proyeccion       STRING DEFAULT '';
DECLARE OR REPLACE VARIABLE dq_stack            STRING DEFAULT '';
DECLARE OR REPLACE VARIABLE dq_lista_columnas   STRING DEFAULT '';
DECLARE OR REPLACE VARIABLE dq_expr_hash        STRING DEFAULT '';
DECLARE OR REPLACE VARIABLE dq_filtro_muestra   STRING DEFAULT '';


/* ────────────────────────────────────────────────────────────────────────────
   [C0.05] Funciones auxiliares de construcción de SQL dinámico
   DOCSTRING (es-PE)
     dq_id(nombre)  : devuelve el identificador entre backticks y escapado
                      (soporta espacios, tildes, ñ, puntos y backticks).
     dq_lit(texto)  : devuelve un literal SQL entre comillas simples y
                      escapado (usa chr(39)=' y chr(92)=\ para no depender
                      del modo de escape del parser).
   TOOLTIP ▸ Cómo interpretar
     • Son la defensa contra columnas con nombres "raros" (p.ej. `año`,
       `monto total`, `it's`) que rompen el SQL dinámico. Ojo: no se pueden
       usar dentro de lambdas (transform/filter); ahí se escribe en línea.
   ──────────────────────────────────────────────────────────────────────────── */
CREATE OR REPLACE TEMPORARY FUNCTION dq_id(nombre STRING)
  RETURNS STRING
  RETURN concat('`', replace(nombre, '`', '``'), '`');

CREATE OR REPLACE TEMPORARY FUNCTION dq_lit(texto STRING)
  RETURNS STRING
  RETURN concat(chr(39),
                replace(replace(texto, chr(92), concat(chr(92), chr(92))), chr(39), concat(chr(92), chr(39))),
                chr(39));


/* ────────────────────────────────────────────────────────────────────────────
   [C0.06] Función dq_familia: tipo físico → familia analítica
   DOCSTRING (es-PE)
     Clasifica el tipo declarado (information_schema o typeof()) en una familia:
     NUMERICO, TEXTO, FECHA, TIMESTAMP, BOOLEANO, BINARIO, COMPLEJO,
     INTERVALO u OTRO. Cada capa decide qué validar según la familia.
   TOOLTIP ▸ Cómo interpretar
     • VARCHAR/CHAR caen en TEXTO; TIMESTAMP_NTZ en TIMESTAMP; VARIANT,
       ARRAY, MAP y STRUCT en COMPLEJO (se perfilan como JSON de texto).
   ──────────────────────────────────────────────────────────────────────────── */
CREATE OR REPLACE TEMPORARY FUNCTION dq_familia(tipo STRING)
  RETURNS STRING
  RETURN CASE
    WHEN upper(tipo) RLIKE '^(TINYINT|SMALLINT|INT|INTEGER|BIGINT|LONG|SHORT|BYTE|FLOAT|REAL|DOUBLE|DECIMAL|DEC|NUMERIC)' THEN 'NUMERICO'
    WHEN upper(tipo) RLIKE '^(STRING|VARCHAR|CHAR)'                         THEN 'TEXTO'
    WHEN upper(tipo) RLIKE '^DATE'                                          THEN 'FECHA'
    WHEN upper(tipo) RLIKE '^TIMESTAMP'                                     THEN 'TIMESTAMP'
    WHEN upper(tipo) RLIKE '^(BOOLEAN|BOOL)'                                THEN 'BOOLEANO'
    WHEN upper(tipo) RLIKE '^BINARY'                                        THEN 'BINARIO'
    WHEN upper(tipo) RLIKE '^(ARRAY|MAP|STRUCT|VARIANT|OBJECT)'             THEN 'COMPLEJO'
    WHEN upper(tipo) RLIKE '^INTERVAL'                                      THEN 'INTERVALO'
    ELSE 'OTRO'
  END;


/* ────────────────────────────────────────────────────────────────────────────
   [C0.07] Funciones de higiene de texto
   DOCSTRING (es-PE)
     dq_limpiar(v)        : quita blancos de los bordes incluyendo tab, salto de
                            línea, espacio duro (NBSP, típico de Excel/web),
                            zero-width y BOM. Base de todas las inferencias.
     dq_es_placeholder(v) : true si el valor es un "nulo disfrazado": 'NULL',
                            'N/A', '-', 'sin dato', '#N/A', '#¡VALOR!', etc.
     dq_mascara(v)        : "forma" del valor: dígito→9, mayúscula→A,
                            minúscula→a (perfilado de patrones estilo
                            Informatica/Talend/OpenRefine).
     dq_huella(v)         : huella (fingerprint) de OpenRefine: minúsculas, sin
                            tildes ni signos, tokens ordenados y únicos. Dos
                            valores con la misma huella son la "misma" cosa
                            escrita distinto (LIMA / Lima / lima. / Líma).
   TOOLTIP ▸ Cómo interpretar / ajustar
     • Agreguen a la lista de placeholders los "valores mágicos" de sus
       sistemas fuente (p.ej. 'SIN INFORMACION', 'NO APLICA', '99999').
   ──────────────────────────────────────────────────────────────────────────── */
CREATE OR REPLACE TEMPORARY FUNCTION dq_limpiar(v STRING)
  RETURNS STRING
  RETURN regexp_replace(v, '^[\\s\\x{00A0}\\x{200B}\\x{FEFF}]+|[\\s\\x{00A0}\\x{200B}\\x{FEFF}]+$', '');

CREATE OR REPLACE TEMPORARY FUNCTION dq_es_placeholder(v STRING)
  RETURNS BOOLEAN
  RETURN lower(dq_limpiar(v)) IN (
    'null', '(null)', '<null>', 'none', 'nan', 'nil', 'undefined', 'missing',
    'n/a', 'na', 'n.a.', 'n.a', 'nd', 'n.d.', 'n/d', 's/d', 'sd', 's.d.',
    'sin dato', 'sin datos', 'sin informacion', 'sin información', 'no aplica',
    'no disponible', 'desconocido', 'vacio', 'vacío', '-', '--', '---', '?', '??', '.',
    '#n/a', '#n/d', '#value!', '#¡valor!', '#ref!', '#¡ref!', '#div/0!', '#¡div/0!',
    '#name?', '#¿nombre?', '#num!', '#¡num!', '#null!', '#¡nulo!',
    '0000-00-00', '00/00/0000', '0000-00-00 00:00:00'
  );

CREATE OR REPLACE TEMPORARY FUNCTION dq_mascara(v STRING)
  RETURNS STRING
  RETURN regexp_replace(
           regexp_replace(
             regexp_replace(v, '[0-9]', '9'),
           '[A-ZÁÉÍÓÚÜÑ]', 'A'),
         '[a-záéíóúüñ]', 'a');

CREATE OR REPLACE TEMPORARY FUNCTION dq_huella(v STRING)
  RETURNS STRING
  RETURN array_join(
           array_sort(array_distinct(
             split(trim(regexp_replace(
               translate(lower(dq_limpiar(v)), 'áéíóúüàèìòùñç', 'aeiouuaeiounc'),
               '[^a-z0-9]+', ' ')), ' ')
           )), ' ');


/* ────────────────────────────────────────────────────────────────────────────
   [C0.08] Funciones semánticas: fechas en texto y documentos peruanos
   DOCSTRING (es-PE)
     dq_fecha_texto(v, orden) : intenta convertir texto a DATE probando, en este
        orden: yyyy-MM-dd (con o sin hora), yyyy/MM/dd, dd/MM/yyyy ó MM/dd/yyyy
        (según orden 'DMY'/'MDY'; acepta / - . como separador pero EXIGE el
        mismo separador en ambos lados) y yyyyMMdd (sólo años 19xx/20xx).
        Valida el calendario real (31/02 → NULL). No usa to_date con patrón,
        así evita errores de parser legacy/ANSI.
     dq_ruc_valido(v) : valida un RUC de SUNAT (11 dígitos, prefijo 10/15/16/17/20)
        con su dígito verificador módulo 11 (pesos 5,4,3,2,7,6,5,4,3,2), que
        calcula dq_ruc_digito_verificador (sin lambdas: Databricks no permite
        llamar funciones SQL temporales dentro de funciones de orden superior).
   TOOLTIP ▸ Cómo interpretar / ajustar
     • Si sus fuentes traen otros formatos (p.ej. '05-ENE-2024' de Oracle),
       agreguen una rama WHEN más; todo el marco la heredará.
     • Un RUC con forma correcta pero dígito verificador inválido es casi
       siempre un error de digitación: vale la pena reportarlo al dueño.
   ──────────────────────────────────────────────────────────────────────────── */
CREATE OR REPLACE TEMPORARY FUNCTION dq_fecha_texto(v STRING, orden STRING)
  RETURNS DATE
  RETURN CASE
    WHEN dq_limpiar(v) RLIKE '^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}$'
      THEN try_cast(dq_limpiar(v) AS DATE)
    WHEN dq_limpiar(v) RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{1,2}:[0-9]{2}'
      THEN try_cast(substr(dq_limpiar(v), 1, 10) AS DATE)
    WHEN dq_limpiar(v) RLIKE '^[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}$'
      THEN try_cast(replace(dq_limpiar(v), '/', '-') AS DATE)
    WHEN dq_limpiar(v) RLIKE '^[0-9]{1,2}([/.-])[0-9]{1,2}\\1[0-9]{4}$' AND upper(orden) = 'MDY'
      THEN try_cast(regexp_replace(dq_limpiar(v), '^([0-9]{1,2})([/.-])([0-9]{1,2})\\2([0-9]{4})$', '$4-$1-$3') AS DATE)
    WHEN dq_limpiar(v) RLIKE '^[0-9]{1,2}([/.-])[0-9]{1,2}\\1[0-9]{4}$'
      THEN try_cast(regexp_replace(dq_limpiar(v), '^([0-9]{1,2})([/.-])([0-9]{1,2})\\2([0-9]{4})$', '$4-$3-$1') AS DATE)
    WHEN dq_limpiar(v) RLIKE '^(19|20)[0-9]{6}$'
      THEN try_cast(regexp_replace(dq_limpiar(v), '^([0-9]{4})([0-9]{2})([0-9]{2})$', '$1-$2-$3') AS DATE)
    ELSE NULL
  END;

CREATE OR REPLACE TEMPORARY FUNCTION dq_ruc_digito_verificador(r STRING)
  RETURNS INT
  RETURN CASE 11 - pmod(
                 5 * CAST(substr(r, 1, 1) AS INT) + 4 * CAST(substr(r, 2, 1) AS INT)
               + 3 * CAST(substr(r, 3, 1) AS INT) + 2 * CAST(substr(r, 4, 1) AS INT)
               + 7 * CAST(substr(r, 5, 1) AS INT) + 6 * CAST(substr(r, 6, 1) AS INT)
               + 5 * CAST(substr(r, 7, 1) AS INT) + 4 * CAST(substr(r, 8, 1) AS INT)
               + 3 * CAST(substr(r, 9, 1) AS INT) + 2 * CAST(substr(r, 10, 1) AS INT), 11)
           WHEN 10 THEN 0
           WHEN 11 THEN 1
           ELSE 11 - pmod(
                 5 * CAST(substr(r, 1, 1) AS INT) + 4 * CAST(substr(r, 2, 1) AS INT)
               + 3 * CAST(substr(r, 3, 1) AS INT) + 2 * CAST(substr(r, 4, 1) AS INT)
               + 7 * CAST(substr(r, 5, 1) AS INT) + 6 * CAST(substr(r, 6, 1) AS INT)
               + 5 * CAST(substr(r, 7, 1) AS INT) + 4 * CAST(substr(r, 8, 1) AS INT)
               + 3 * CAST(substr(r, 9, 1) AS INT) + 2 * CAST(substr(r, 10, 1) AS INT), 11)
         END;

CREATE OR REPLACE TEMPORARY FUNCTION dq_ruc_valido(v STRING)
  RETURNS BOOLEAN
  RETURN CASE
    WHEN dq_limpiar(v) RLIKE '^(10|15|16|17|20)[0-9]{9}$'
      THEN CAST(substr(dq_limpiar(v), 11, 1) AS INT) = dq_ruc_digito_verificador(dq_limpiar(v))
    ELSE false
  END;


/* ────────────────────────────────────────────────────────────────────────────
   [C0.09] Ruta de information_schema y tabla de historia de métricas (opcional)
   DOCSTRING (es-PE)
     Calcula la ruta a <catalogo>.information_schema y, SOLO si
     dq_esquema_trabajo no está vacío, crea la tabla Delta dq_metricas en
     formato largo (corrida, tabla, columna, capa, métrica, valor). Es el
     "repositorio de métricas" que proponen Deequ (Amazon) y Lakehouse
     Monitoring: permite tendencias y alertas sobre las propias métricas.
   TOOLTIP ▸ Cómo interpretar
     • Si dq_esquema_trabajo está vacío, el resultado sólo dice
       'persistencia desactivada' y no se escribe nada.
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_info_schema = concat(dq_id(dq_catalogo), '.information_schema');

SET VAR dq_sql = IF(
  dq_esquema_trabajo = '',
  concat('SELECT ', dq_lit('persistencia desactivada (dq_esquema_trabajo vacío)'), ' AS info'),
  concat('CREATE TABLE IF NOT EXISTS ', dq_esquema_trabajo, '.dq_metricas (',
         'id_corrida STRING, ts_corrida TIMESTAMP, tabla STRING, columna STRING, ',
         'capa STRING, metrica STRING, valor DOUBLE, valor_texto STRING) ',
         'COMMENT ', dq_lit('Historia de métricas de calidad de datos (marco dq por capas)'))
);
EXECUTE IMMEDIATE dq_sql;


/* ────────────────────────────────────────────────────────────────────────────
   [C0.10] Verificación de la configuración
   DOCSTRING (es-PE)
     Muestra en una sola fila cómo quedó configurada la sesión y prueba las
     funciones auxiliares con casos conocidos (autodiagnóstico).
   TOOLTIP ▸ Cómo interpretar
     • Todas las columnas prueba_* deben salir true. Si alguna sale false,
       el motor se está comportando distinto a lo esperado (versión de DBR,
       modo de escape de strings): no sigan hasta resolverlo.
   ──────────────────────────────────────────────────────────────────────────── */
SELECT
  dq_catalogo, dq_esquema, dq_tabla, dq_origen_metadatos, dq_info_schema,
  dq_max_filas_muestra, dq_umbral_tipo_dominante, dq_orden_fecha_texto,
  dq_esquema_trabajo, dq_materializar, dq_id_corrida,
  dq_fecha_texto('31/12/2024', 'DMY') = DATE'2024-12-31'                  AS prueba_fecha_dmy,
  dq_fecha_texto('12/31/2024', 'MDY') = DATE'2024-12-31'                  AS prueba_fecha_mdy,
  dq_fecha_texto('31/02/2024', 'DMY') IS NULL                             AS prueba_fecha_invalida,
  dq_fecha_texto('31/12-2024', 'DMY') IS NULL                             AS prueba_separador_mixto,
  dq_ruc_valido('20131312955') AND NOT dq_ruc_valido('20131312954')       AS prueba_ruc,
  dq_es_placeholder('  N/A ') AND NOT dq_es_placeholder('Nadia')          AS prueba_placeholder,
  dq_mascara('AB-12c') = 'AA-99a'                                         AS prueba_mascara,
  dq_huella(' Lima,  PERÚ ') = dq_huella('peru lima')                     AS prueba_huella,
  dq_limpiar(concat(chr(160), 'x', chr(9))) = 'x'                         AS prueba_limpiar,
  dq_id('a`b c') = '`a``b c`'                                            AS prueba_id,
  dq_lit(concat('it', chr(39), 's')) = concat(chr(39), 'it', chr(92), chr(39), 's', chr(39)) AS prueba_lit;
