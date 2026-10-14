/* ════════════════════════════════════════════════════════════════════════════
   REFERENCIA C · CAPA 0 DESDE EL DICCIONARIO + CAPA D (CONFORMIDAD) + REGLAS
   ────────────────────────────────────────────────────────────────────────────
   DOCSTRING (es-PE)
     Sin information_schema, la capa 0 se apoya en el diccionario (L0D.*) y la
     conformidad de la data con la trama se mide en la Capa D (LD.*). Todas las
     consultas leen dq_mapa, dq_freq, dq_objetivo y, si hay línea cruda, la
     tabla original; nunca metadatos del catálogo. Al final genera dq_reglas
     (L8.00v2) sólo para campos conciliados, para que L8.01 no falle por
     columnas inexistentes.
     Contrato de dq_diccionario: tipo_registro, codigo_registro, orden, campo,
     pos_inicio, longitud, tipo_dato, familia_declarada (NUMERICO, IMPORTE,
     TEXTO, FECHA, HORA), decimales, con_signo, formato, obligatorio,
     valores_permitidos ARRAY<STRING>, pii, es_filler, descripcion.
   TOOLTIP ▸ Cómo leer
     • Cada hallazgo trae una columna "hipotesis" con explicaciones alternativas
       ordenadas y cómo distinguirlas. No asuman la primera sin revisar la
       evidencia que se indica.
   ════════════════════════════════════════════════════════════════════════════ */


/* ────────────────────────────────────────────────────────────────────────────
   [L0D.01] Consistencia interna del diccionario (por tipo de registro)
   DOCSTRING (es-PE)
     Revisa el propio diccionario: campos duplicados (sin contar FILLER),
     huecos y solapamientos entre posiciones, si las posiciones empiezan en 0
     o en 1, campos sin longitud o sin tipo, y el largo total del registro.
   TOOLTIP ▸ Cómo leer e interpretar
     • Un diccionario con huecos o solapamientos produce falsos errores en
       toda la Capa D: corríjanlo (o confirmen con el dueño) antes de culpar
       a la data.
     • inicia_en_0 = true ⇒ el diccionario cuenta posiciones desde 0 y el
       corte por posición estará corrido en 1 (sumen 1 a pos_inicio).
   ──────────────────────────────────────────────────────────────────────────── */
WITH p AS (
  SELECT tipo_registro, campo, orden, pos_inicio, longitud, es_filler, familia_declarada,
         pos_inicio + longitud - 1 AS pos_fin,
         lag(pos_inicio + longitud - 1) OVER (PARTITION BY tipo_registro ORDER BY pos_inicio, orden) AS fin_anterior
  FROM dq_diccionario
)
SELECT tipo_registro,
       count(*)                                                                AS n_campos,
       count(*) - count(DISTINCT IF(es_filler, NULL, lower(campo))) - count_if(es_filler) AS n_nombres_duplicados,
       count_if(pos_inicio IS NOT NULL AND fin_anterior IS NOT NULL AND pos_inicio > fin_anterior + 1) AS n_huecos,
       count_if(pos_inicio IS NOT NULL AND fin_anterior IS NOT NULL AND pos_inicio <= fin_anterior)    AS n_solapamientos,
       min(pos_inicio) = 0                                                     AS inicia_en_0,
       count_if(longitud IS NULL)                                              AS n_sin_longitud,
       count_if(familia_declarada IS NULL)                                     AS n_sin_tipo,
       max(pos_fin)                                                            AS largo_registro,
       sum(longitud)                                                           AS suma_longitudes,
       filter(array(
         IF(count(*) - count(DISTINCT IF(es_filler, NULL, lower(campo))) - count_if(es_filler) > 0, 'CAMPOS_DUPLICADOS', NULL),
         IF(count_if(pos_inicio > fin_anterior + 1) > 0, 'HUECOS_EN_POSICIONES', NULL),
         IF(count_if(pos_inicio <= fin_anterior) > 0, 'SOLAPAMIENTOS', NULL),
         IF(min(pos_inicio) = 0, 'POSICIONES_DESDE_0', NULL),
         IF(max(pos_fin) <> sum(longitud) + min(pos_inicio) - 1, 'LARGO_NO_CUADRA', NULL)
       ), x -> x IS NOT NULL)                                                  AS alertas
FROM p
GROUP BY tipo_registro
ORDER BY tipo_registro;


/* ────────────────────────────────────────────────────────────────────────────
   [L0D.02] Inventario declarado: tipos, PII y coherencia nombre ↔ tipo
   DOCSTRING (es-PE)
     Reemplaza a L0.02/L0.03 (que necesitaban information_schema) usando el
     diccionario: por campo muestra la familia declarada y marca nombres que
     sugieren otro tipo (fecha declarada como texto, código declarado como
     importe, etc.), campos PII y campos obligatorios sin dominio.
   TOOLTIP ▸ Cómo interpretar
     • Es evidencia sobre el DISEÑO de la trama, no sobre los datos.
   ──────────────────────────────────────────────────────────────────────────── */
SELECT tipo_registro, orden, campo, tipo_dato, familia_declarada, longitud, decimales, formato,
       obligatorio, pii, es_filler,
       filter(array(
         IF(dq_norm_sin(campo) RLIKE '(^|_)fec(_|$)' AND familia_declarada <> 'FECHA', 'NOMBRE_DE_FECHA_TIPO_' || familia_declarada, NULL),
         IF(dq_norm_sin(campo) RLIKE '(^|_)imp(_|$)' AND familia_declarada NOT IN ('IMPORTE', 'NUMERICO'), 'NOMBRE_DE_IMPORTE_NO_NUMERICO', NULL),
         IF(dq_norm_sin(campo) RLIKE '(^|_)(cod|nro|doc|cta)(_|$)' AND familia_declarada = 'IMPORTE', 'CODIGO_DECLARADO_COMO_IMPORTE', NULL),
         IF(familia_declarada = 'FECHA' AND coalesce(formato, '') = '', 'FECHA_SIN_FORMATO', NULL),
         IF(familia_declarada = 'IMPORTE' AND decimales IS NULL, 'IMPORTE_SIN_DECIMALES_DECLARADOS', NULL)
       ), x -> x IS NOT NULL) AS observaciones
FROM dq_diccionario
ORDER BY tipo_registro, orden;


/* ────────────────────────────────────────────────────────────────────────────
   [LD.01] Cobertura: campos del diccionario vs columnas de la data
   DOCSTRING (es-PE)
     Lista campos del diccionario sin columna (NO_ENCONTRADO), con varias
     candidatas (AMBIGUO), conciliados con confianza baja, y columnas reales
     que no están en el diccionario (EXTRA).
   TOOLTIP ▸ Cómo leer e interpretar (hipótesis alternativas)
     • NO_ENCONTRADO: (1) la ingesta renombró el campo → revisen candidatos y
       usen dq_modo_columnas = 'MANUAL'; (2) diccionario de otra versión →
       comparen la versión del xlsx con la fecha de carga; (3) el campo se
       descarta en la ingesta → pregunten a ingeniería de datos.
     • AMBIGUO: el script NO eligió; definan el mapeo a mano.
     • EXTRA: técnica (_rescued_data, fecha_carga) o campo nuevo no documentado.
   ──────────────────────────────────────────────────────────────────────────── */
SELECT 'DICCIONARIO' AS origen, m.campo, m.columna, m.estado, m.metodo, m.confianza,
       r.candidatos,
       CASE m.estado
         WHEN 'NO_ENCONTRADO' THEN '1) renombrado por la ingesta  2) diccionario de otra versión  3) campo descartado'
         WHEN 'AMBIGUO' THEN 'Varias columnas compiten: definir mapeo manual'
         ELSE IF(m.confianza = 'BAJA', 'Mapeo incierto: confirmar antes de usar sus hallazgos', NULL) END AS hipotesis
FROM dq_mapa m
LEFT JOIN dq_reconciliacion r ON r.campo = m.campo
WHERE m.estado <> 'MAPEADO' OR m.confianza = 'BAJA'
UNION ALL
SELECT 'DATA', NULL, columna, 'EXTRA', NULL, NULL, candidatos,
       IF(startswith(columna, '_'), 'Columna técnica de ingesta', 'Campo no documentado o nombre no reconocible')
FROM dq_reconciliacion
WHERE estado = 'EXTRA' AND dq_formato_detectado NOT IN ('ANCHO_FIJO', 'DELIMITADO');


/* ────────────────────────────────────────────────────────────────────────────
   [LD.02] Conformidad de formato por campo (tipo, fecha, número, signo)
   DOCSTRING (es-PE)
     Clasifica cada valor de cada campo conciliado según su tipo declarado:
     fecha en el formato del diccionario, fecha centinela (00000000,
     99999999), número sin signo, signo explícito o "overpunch" COBOL (sólo si
     el campo es con signo), número rellenado con espacios, y valores
     inválidos. Si la columna ya viene tipada (DATE, DECIMAL…) se da por
     conforme en formato (el tipo ya lo garantiza).
   TOOLTIP ▸ Cómo leer e interpretar (hipótesis alternativas)
     • pct_conforme < 50% en varios campos seguidos ⇒ lo más probable es un
       DESFASE de posiciones (layout distinto o bytes vs caracteres): miren
       [LD.09] antes de reportar errores de datos.
     • pct_conforme alto con pocos inválidos ⇒ errores puntuales de la fuente.
     • OVERPUNCH_NO_DECLARADO ⇒ el campo trae signo aunque el diccionario no
       lo dice: el diccionario está incompleto.
     • Si la columna tiene confianza de mapeo BAJA, el hallazgo puede deberse
       a mapear la columna equivocada.
   ──────────────────────────────────────────────────────────────────────────── */
WITH v AS (
  SELECT m.campo, m.columna, m.familia_declarada, m.formato, m.decimales, m.con_signo, m.pii, m.confianza,
         m.familia_real, f.valor, f.n, dq_limpiar(f.valor) AS t,
         CASE
           WHEN f.valor IS NULL THEN 'NULO'
           WHEN dq_limpiar(f.valor) = '' THEN 'VACIO'
           WHEN m.familia_real IN ('FECHA', 'TIMESTAMP', 'NUMERICO') THEN 'OK_TIPADO_EN_ORIGEN'
           WHEN m.familia_declarada = 'FECHA' AND dq_limpiar(f.valor) IN ('00000000', '99999999', '0') THEN 'FECHA_CENTINELA'
           WHEN m.familia_declarada = 'FECHA' AND dq_fecha_formato(f.valor, m.formato) IS NOT NULL THEN 'OK'
           WHEN m.familia_declarada = 'HORA'
                AND regexp_replace(dq_limpiar(f.valor), ':', '') RLIKE '^([01][0-9]|2[0-3])[0-5][0-9]([0-5][0-9])?$' THEN 'OK'
           WHEN m.familia_declarada IN ('NUMERICO', 'IMPORTE') AND f.valor RLIKE '^[0-9]+$' THEN 'OK'
           WHEN m.familia_declarada IN ('NUMERICO', 'IMPORTE') AND coalesce(m.con_signo, false)
                AND dq_limpiar(f.valor) RLIKE '^[0-9]*[{}A-R]$' THEN 'OK_OVERPUNCH'
           WHEN m.familia_declarada IN ('NUMERICO', 'IMPORTE') AND coalesce(m.con_signo, false)
                AND dq_limpiar(f.valor) RLIKE '^[+-][0-9]+$|^[0-9]+[+-]$' THEN 'OK_SIGNO'
           WHEN m.familia_declarada IN ('NUMERICO', 'IMPORTE') AND f.valor RLIKE '^ +[0-9]+ *$|^[0-9]+ +$' THEN 'RELLENO_CON_ESPACIOS'
           WHEN m.familia_declarada IN ('NUMERICO', 'IMPORTE') AND dq_limpiar(f.valor) RLIKE '^[0-9]*[{}A-R]$' THEN 'OVERPUNCH_NO_DECLARADO'
           WHEN m.familia_declarada IN ('TEXTO') OR m.familia_declarada IS NULL THEN 'OK'
           ELSE 'INVALIDO'
         END AS clase
  FROM dq_mapa m
  JOIN dq_freq f ON f.columna = m.columna
  WHERE m.estado = 'MAPEADO' AND NOT coalesce(m.es_filler, false)
), a AS (
  SELECT campo, columna, max(familia_declarada) AS familia_declarada, max(formato) AS formato,
         max(confianza) AS confianza, max(pii) AS pii,
         sum(n) AS n_total,
         sum(IF(clase IN ('NULO', 'VACIO'), n, 0)) AS n_vacios,
         sum(IF(clase LIKE 'OK%', n, 0)) AS n_conforme,
         sum(IF(clase = 'FECHA_CENTINELA', n, 0)) AS n_fecha_centinela,
         sum(IF(clase = 'OK_OVERPUNCH', n, 0)) AS n_overpunch,
         sum(IF(clase = 'RELLENO_CON_ESPACIOS', n, 0)) AS n_relleno_espacios,
         sum(IF(clase = 'OVERPUNCH_NO_DECLARADO', n, 0)) AS n_overpunch_no_declarado,
         sum(IF(clase = 'INVALIDO', n, 0)) AS n_invalidos,
         slice(collect_list(IF(clase = 'INVALIDO', dq_ver(valor, coalesce(pii, false) AND NOT dq_mostrar_pii), NULL)), 1, 5) AS ejemplos_invalidos,
         min(IF(familia_declarada = 'IMPORTE' AND clase LIKE 'OK%', dq_overpunch(valor) / power(10, coalesce(decimales, 0)), NULL)) AS importe_min,
         max(IF(familia_declarada = 'IMPORTE' AND clase LIKE 'OK%', dq_overpunch(valor) / power(10, coalesce(decimales, 0)), NULL)) AS importe_max
  FROM v
  GROUP BY campo, columna
)
SELECT campo, columna, familia_declarada, formato, confianza, n_total, n_vacios,
       round(n_conforme / NULLIF(n_total - n_vacios, 0), 4) AS pct_conforme,
       n_invalidos, n_fecha_centinela, n_overpunch, n_relleno_espacios, n_overpunch_no_declarado,
       ejemplos_invalidos, importe_min, importe_max,
       CASE
         WHEN n_total - n_vacios = 0 THEN 'Sin valores: campo siempre vacío (¿no se llena en origen o mapeo errado?)'
         WHEN n_conforme / NULLIF(n_total - n_vacios, 0) < 0.5 THEN '1) desfase de posiciones (ver LD.09)  2) columna mal mapeada  3) diccionario desactualizado  4) error masivo en origen'
         WHEN n_invalidos > 0 THEN '1) errores puntuales de captura en origen  2) valores especiales no documentados (agregarlos al diccionario)'
         WHEN n_overpunch_no_declarado > 0 THEN 'El campo trae signo overpunch no declarado: completar el diccionario'
         ELSE 'Conforme'
       END AS hipotesis
FROM a
ORDER BY pct_conforme ASC NULLS FIRST, campo;


/* ────────────────────────────────────────────────────────────────────────────
   [LD.03] Longitud y relleno por campo
   DOCSTRING (es-PE)
     Compara el largo de cada valor con la longitud declarada: valores MÁS
     LARGOS (desborde; en tablas tabulares indica truncamiento aguas arriba o
     longitud mal documentada), MÁS CORTOS (en ancho fijo: la línea terminó
     antes, típico de espacios finales recortados por la ingesta), y numéricos
     con espacios en lugar de ceros.
   TOOLTIP ▸ Cómo leer e interpretar (hipótesis alternativas)
     • n_mas_cortos alto SÓLO en los últimos campos del registro ⇒ la ingesta
       recortó espacios finales (no es error de la fuente).
     • n_mas_largos en tabular ⇒ el diccionario quedó chico o el campo cambió
       de definición; en ancho fijo no puede ocurrir (se corta por posición).
   ──────────────────────────────────────────────────────────────────────────── */
SELECT m.campo, m.columna, m.longitud, m.familia_declarada,
       sum(f.n)                                                                AS n_no_nulos,
       sum(IF(char_length(f.valor) > m.longitud, f.n, 0))                      AS n_mas_largos,
       sum(IF(char_length(f.valor) < m.longitud, f.n, 0))                      AS n_mas_cortos,
       sum(IF(m.familia_declarada IN ('NUMERICO', 'IMPORTE') AND f.valor RLIKE '^ +[0-9]', f.n, 0)) AS n_numerico_con_espacios_izq,
       sum(IF(m.familia_declarada = 'TEXTO' AND f.valor RLIKE '^ +[^ ]', f.n, 0))                  AS n_texto_alineado_derecha,
       CASE
         WHEN dq_formato_detectado = 'ANCHO_FIJO' AND sum(IF(char_length(f.valor) < m.longitud, f.n, 0)) > 0
           THEN 'Línea más corta que el layout: 1) espacios finales recortados en la ingesta  2) registro truncado  3) layout distinto (ver LD.07/LD.09)'
         WHEN sum(IF(char_length(f.valor) > m.longitud, f.n, 0)) > 0
           THEN '1) longitud del diccionario desactualizada  2) campo concatenado o con basura  3) columna mal mapeada'
         ELSE 'Conforme' END                                                    AS hipotesis
FROM dq_mapa m
JOIN dq_freq f ON f.columna = m.columna AND f.valor IS NOT NULL
WHERE m.estado = 'MAPEADO' AND m.longitud IS NOT NULL AND coalesce(m.familia_real, 'TEXTO') = 'TEXTO'
GROUP BY m.campo, m.columna, m.longitud, m.familia_declarada
ORDER BY n_mas_largos + n_mas_cortos DESC, m.campo;


/* ────────────────────────────────────────────────────────────────────────────
   [LD.04] Campos obligatorios: faltantes reales y disfrazados
   DOCSTRING (es-PE)
     Para los campos marcados como obligatorios en el diccionario: % de NULL,
     vacíos/espacios y placeholders (dq_es_placeholder), y fechas centinela.
   TOOLTIP ▸ Cómo leer e interpretar (hipótesis alternativas)
     • 100% faltante ⇒ el campo no se llena en origen o el mapeo es errado.
     • Faltantes concentrados en un periodo (ver L7.04 con segmento) ⇒ cambio
       en el sistema fuente desde esa fecha.
     • Faltantes repartidos ⇒ errores de captura.
   ──────────────────────────────────────────────────────────────────────────── */
SELECT m.campo, m.columna,
       sum(f.n)                                                                                   AS n_total,
       sum(IF(f.valor IS NULL, f.n, 0))                                                           AS n_nulos,
       sum(IF(f.valor IS NOT NULL AND dq_limpiar(f.valor) = '', f.n, 0))                          AS n_vacios,
       sum(IF(f.valor IS NOT NULL AND dq_es_placeholder(f.valor), f.n, 0))                        AS n_placeholder,
       sum(IF(m.familia_declarada = 'FECHA' AND dq_limpiar(f.valor) IN ('00000000', '99999999'), f.n, 0)) AS n_fecha_centinela,
       round(sum(IF(f.valor IS NULL OR dq_limpiar(f.valor) = '' OR dq_es_placeholder(f.valor), f.n, 0)) / NULLIF(sum(f.n), 0), 4) AS pct_faltante,
       CASE WHEN sum(IF(f.valor IS NULL OR dq_limpiar(f.valor) = '', f.n, 0)) = sum(f.n) AND sum(f.n) > 0
              THEN '1) no se llena en origen  2) columna mal mapeada  3) campo de otra versión del layout'
            WHEN sum(IF(f.valor IS NULL OR dq_limpiar(f.valor) = '' OR dq_es_placeholder(f.valor), f.n, 0)) > 0
              THEN '1) errores de captura  2) regla de obligatoriedad no aplicada en origen  3) cargas parciales (ver L7.04 por segmento)'
            ELSE 'Conforme' END                                                                   AS hipotesis
FROM dq_mapa m
JOIN dq_freq f ON f.columna = m.columna
WHERE m.estado = 'MAPEADO' AND coalesce(m.obligatorio, false) AND NOT coalesce(m.es_filler, false)
GROUP BY m.campo, m.columna
ORDER BY pct_faltante DESC;


/* ────────────────────────────────────────────────────────────────────────────
   [LD.05] Valores fuera del dominio declarado y dominios no usados
   DOCSTRING (es-PE)
     Para campos con valores permitidos en el diccionario: valores observados
     que no están en la lista (comparando sin espacios), con frecuencia y
     ejemplos; si el valor sí calza al agregar ceros a la izquierda se marca
     "posible pérdida de ceros"; y valores del dominio que nunca aparecen.
   TOOLTIP ▸ Cómo leer e interpretar (hipótesis alternativas)
     • Un valor fuera de dominio MUY frecuente ⇒ probablemente el diccionario
       está desactualizado (código nuevo) y no un error de datos.
     • Muchos valores raros distintos ⇒ campo mal mapeado o desfase.
     • Posible pérdida de ceros ⇒ la ingesta tipó el código como número.
   ──────────────────────────────────────────────────────────────────────────── */
WITH dom AS (
  SELECT campo, columna, pii, valores_permitidos,
         transform(valores_permitidos, x -> trim(x)) AS dominio
  FROM dq_mapa
  WHERE estado = 'MAPEADO' AND valores_permitidos IS NOT NULL AND size(valores_permitidos) > 0
), obs AS (
  SELECT d.campo, d.columna, d.pii, d.dominio, dq_limpiar(f.valor) AS t, f.n
  FROM dom d JOIN dq_freq f ON f.columna = d.columna
  WHERE f.valor IS NOT NULL AND dq_limpiar(f.valor) <> ''
)
SELECT campo, columna,
       sum(n)                                                                  AS n_valores,
       sum(IF(array_contains(dominio, t), 0, n))                               AS n_fuera_de_dominio,
       round(sum(IF(array_contains(dominio, t), 0, n)) / NULLIF(sum(n), 0), 5) AS pct_fuera_de_dominio,
       slice(sort_array(collect_list(IF(array_contains(dominio, t), NULL,
             named_struct('n', n, 'valor', dq_ver(t, coalesce(pii, false) AND NOT dq_mostrar_pii)))), false), 1, 8) AS top_fuera_de_dominio,
       sum(IF(NOT array_contains(dominio, t)
              AND exists(dominio, x -> x RLIKE '^[0-9]+$' AND char_length(x) > char_length(t) AND lpad(t, char_length(x), '0') = x), n, 0)) AS n_posible_perdida_ceros,
       array_except(max(dominio), collect_set(t))                              AS dominio_no_observado,
       CASE WHEN sum(IF(array_contains(dominio, t), 0, n)) = 0 THEN 'Conforme'
            WHEN max(n) FILTER (WHERE NOT array_contains(dominio, t)) >= 0.05 * sum(n)
              THEN '1) código nuevo no documentado (actualizar diccionario)  2) error sistemático de la fuente'
            ELSE '1) errores puntuales  2) desfase/mapeo (si hay muchos valores raros distintos)' END AS hipotesis
FROM obs
GROUP BY campo, columna
ORDER BY pct_fuera_de_dominio DESC;


/* ────────────────────────────────────────────────────────────────────────────
   [LD.06] Números de tarjeta (PAN): dígito Luhn y longitud
   DOCSTRING (es-PE)
     Para campos cuyo nombre o descripción sugiere tarjeta (tarjeta, pan,
     card): % de valores con 13-19 dígitos y % que pasan el dígito Luhn.
     Nunca muestra valores.
   TOOLTIP ▸ Cómo leer e interpretar (hipótesis alternativas)
     • pct_luhn_ok bajo con 16 dígitos ⇒ (1) números de prueba o tokenizados,
       (2) error de transcripción, (3) desfase de posiciones.
     • pct_formato bajo ⇒ el valor está enmascarado (****1234) o truncado:
       revisen [LD.10].
   ──────────────────────────────────────────────────────────────────────────── */
SELECT m.campo, m.columna,
       sum(f.n)                                                                          AS n_no_nulos,
       round(sum(IF(dq_limpiar(f.valor) RLIKE '^[0-9]{13,19}$', f.n, 0)) / NULLIF(sum(f.n), 0), 4) AS pct_formato_pan,
       round(sum(IF(dq_luhn(dq_limpiar(f.valor)), f.n, 0))
             / NULLIF(sum(IF(dq_limpiar(f.valor) RLIKE '^[0-9]{13,19}$', f.n, 0)), 0), 4)          AS pct_luhn_ok,
       CASE WHEN sum(IF(dq_limpiar(f.valor) RLIKE '^[0-9]{13,19}$', f.n, 0)) < 0.95 * sum(f.n)
              THEN '1) columna enmascarada o tokenizada (ver LD.10) 2) relleno o caracteres extra (LD.03) 3) desfase de posiciones (LD.09) 4) el campo no es un PAN'
            WHEN sum(IF(dq_luhn(dq_limpiar(f.valor)), f.n, 0)) < 0.99 * sum(IF(dq_limpiar(f.valor) RLIKE '^[0-9]{13,19}$', f.n, 0))
              THEN '1) números de prueba o internos sin dígito Luhn 2) truncamiento o desfase (LD.09) 3) errores de captura'
            ELSE 'Conforme: formato y dígito verificador correctos' END                     AS hipotesis
FROM dq_mapa m
JOIN dq_freq f ON f.columna = m.columna AND f.valor IS NOT NULL AND dq_limpiar(f.valor) <> ''
WHERE m.estado = 'MAPEADO'
  AND (dq_norm_sin(m.campo) RLIKE '(^|_)(tarjeta|tarj|pan|card)(_|$)' OR lower(coalesce(m.descripcion, '')) RLIKE 'tarjeta|pan|card')
GROUP BY m.campo, m.columna;


/* ────────────────────────────────────────────────────────────────────────────
   [LD.07] Estructura de la trama cruda (largo de línea, tipos de registro, BOM, CR)
   DOCSTRING (es-PE)
     Sólo si la fuente es ANCHO_FIJO o DELIMITADO: sobre la línea cruda cuenta
     líneas por código de tipo de registro y largo, líneas con \r final (CRLF),
     con BOM, con caracteres multibyte (bytes ≠ caracteres) y si el largo
     coincide con el del diccionario. En otro formato devuelve una fila
     explicando por qué se omite.
   TOOLTIP ▸ Cómo leer e interpretar (hipótesis alternativas)
     • Largo distinto en un grupo de líneas ⇒ (1) otra versión del layout
       (verifiquen por archivo o fecha), (2) espacios finales recortados,
       (3) CRLF (+1), (4) multibyte si el diccionario cuenta en bytes.
     • Códigos de registro no documentados ⇒ registro nuevo o línea basura.
     • Cabecera/trailer repetidos ⇒ concatenación de archivos o re-carga.
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_sql = IF(
  dq_formato_detectado IN ('ANCHO_FIJO', 'DELIMITADO') AND dq_col_linea <> '',
  concat(
    'WITH l AS (SELECT ', dq_id(dq_col_linea), ' AS cruda FROM ', dq_tabla_fq_manual, ' WHERE ', dq_id(dq_col_linea), ' IS NOT NULL), ',
    'x AS (SELECT ',
    IF(dq_len_tipo_registro > 0,
       concat('substr(regexp_replace(cruda, ', dq_lit('^\\x{FEFF}'), ', ', dq_lit(''), '), ', dq_pos_tipo_registro, ', ', dq_len_tipo_registro, ')'),
       dq_lit('(sin tipo)')),
    ' AS codigo, char_length(regexp_replace(regexp_replace(cruda, ', dq_lit('^\\x{FEFF}'), ', ', dq_lit(''), '), ', dq_lit('\\r$'), ', ', dq_lit(''), ')) AS largo, ',
    'cruda RLIKE ', dq_lit('\\r$'), ' AS con_cr, cruda RLIKE ', dq_lit('^\\x{FEFF}'), ' AS con_bom, ',
    'octet_length(cruda) <> char_length(cruda) AS multibyte FROM l) ',
    'SELECT x.codigo, coalesce(max(d.tipo_registro), ', dq_lit('NO_DOCUMENTADO'), ') AS tipo_registro, x.largo, ',
    'max(d.largo_esperado) AS largo_esperado, count(*) AS n_lineas, count_if(con_cr) AS n_con_cr, count_if(con_bom) AS n_con_bom, ',
    'count_if(multibyte) AS n_multibyte, ',
    'CASE WHEN max(d.tipo_registro) IS NULL THEN ', dq_lit('Código no documentado: registro nuevo, línea basura o tipo de registro mal ubicado'), ' ',
    '     WHEN x.largo = max(d.largo_esperado) THEN ', dq_lit('Conforme'), ' ',
    '     WHEN x.largo < max(d.largo_esperado) THEN ', dq_lit('Más corta: 1) espacios finales recortados  2) registro truncado  3) layout anterior'), ' ',
    '     ELSE ', dq_lit('Más larga: 1) layout nuevo con campos agregados  2) CR/BOM no limpiados  3) multibyte si el diccionario cuenta bytes'), ' END AS hipotesis ',
    'FROM x LEFT JOIN (SELECT codigo_registro, tipo_registro, max(pos_inicio + longitud - 1) AS largo_esperado FROM dq_diccionario ',
    '                  GROUP BY codigo_registro, tipo_registro) d ON d.codigo_registro = x.codigo ',
    'GROUP BY x.codigo, x.largo ORDER BY n_lineas DESC'),
  concat('SELECT ', dq_lit(concat('LD.07 omitida: formato ', dq_formato_detectado, ' (no hay línea cruda que revisar)')), ' AS info'));
EXECUTE IMMEDIATE dq_sql;


/* ────────────────────────────────────────────────────────────────────────────
   [LD.08] Totales de control del trailer vs detalle
   DOCSTRING (es-PE)
     Si se configuraron (en [Z1.01]) dq_ld_tipo_trailer, dq_ld_campo_conteo (campo del
     trailer con la cantidad de registros) y, opcionalmente,
     dq_ld_campo_suma_trailer / dq_ld_campo_suma_detalle (importe total vs
     importe por detalle), compara lo declarado en el trailer con lo que hay
     realmente en la data (tabla completa). Si no, explica por qué se omite.
   TOOLTIP ▸ Cómo leer e interpretar (hipótesis alternativas)
     • diferencia_conteo ≠ 0 ⇒ (1) carga incompleta o duplicada, (2) filtro
       de filas de Unity Catalog que oculta registros, (3) trailer mal
       calculado en origen, (4) varios archivos concatenados (varios trailers).
     • n_trailers > 1 ⇒ comparen por archivo antes de concluir.
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_sql = coalesce((
  SELECT IF(dq_formato_detectado = 'ANCHO_FIJO' AND dq_ld_tipo_trailer <> '' AND dq_ld_campo_conteo <> ''
            AND dq_len_tipo_registro > 0 AND max(IF(c.campo = dq_ld_campo_conteo AND c.tipo_registro = dq_ld_tipo_trailer, 1, 0)) = 1,
    concat(
      'WITH l AS (SELECT regexp_replace(regexp_replace(', dq_id(dq_col_linea), ', ', dq_lit('^\\x{FEFF}'), ', ', dq_lit(''), '), ',
                dq_lit('\\r$'), ', ', dq_lit(''), ') AS c FROM ', dq_tabla_fq_manual, '), ',
      't AS (SELECT count(*) AS n_trailers, ',
      'sum(try_cast(substr(c, ', max(IF(c.campo = dq_ld_campo_conteo AND c.tipo_registro = dq_ld_tipo_trailer, c.pos_inicio, NULL)), ', ',
                   max(IF(c.campo = dq_ld_campo_conteo AND c.tipo_registro = dq_ld_tipo_trailer, c.longitud, NULL)), ') AS BIGINT)) AS conteo_declarado, ',
      IF(dq_ld_campo_suma_trailer <> '',
         concat('sum(dq_overpunch(substr(c, ', coalesce(max(IF(c.campo = dq_ld_campo_suma_trailer AND c.tipo_registro = dq_ld_tipo_trailer, c.pos_inicio, NULL)), 1), ', ',
                coalesce(max(IF(c.campo = dq_ld_campo_suma_trailer AND c.tipo_registro = dq_ld_tipo_trailer, c.longitud, NULL)), 1), '))) AS suma_declarada '),
         'CAST(NULL AS DECIMAL(38,0)) AS suma_declarada '),
      'FROM l WHERE substr(c, ', dq_pos_tipo_registro, ', ', dq_len_tipo_registro, ') = ',
      dq_lit(coalesce(max(IF(c.tipo_registro = dq_ld_tipo_trailer, c.codigo_registro, NULL)), '')), '), ',
      'd AS (SELECT count(*) AS conteo_real, ',
      IF(dq_ld_campo_suma_detalle <> '',
         concat('sum(dq_overpunch(substr(c, ', coalesce(max(IF(c.campo = dq_ld_campo_suma_detalle AND c.tipo_registro = dq_tipo_registro_objetivo, c.pos_inicio, NULL)), 1), ', ',
                coalesce(max(IF(c.campo = dq_ld_campo_suma_detalle AND c.tipo_registro = dq_tipo_registro_objetivo, c.longitud, NULL)), 1), '))) AS suma_real '),
         'CAST(NULL AS DECIMAL(38,0)) AS suma_real '),
      'FROM l WHERE substr(c, ', dq_pos_tipo_registro, ', ', dq_len_tipo_registro, ') = ', dq_lit(dq_codigo_registro_obj), ') ',
      'SELECT t.n_trailers, t.conteo_declarado, d.conteo_real, d.conteo_real - t.conteo_declarado AS diferencia_conteo, ',
      't.suma_declarada, d.suma_real, d.suma_real - t.suma_declarada AS diferencia_suma_sin_decimales, ',
      'CASE WHEN t.n_trailers <> 1 THEN ', dq_lit('Hay varios (o ningún) trailer: comparar por archivo antes de concluir'), ' ',
      '     WHEN d.conteo_real = t.conteo_declarado AND coalesce(d.suma_real = t.suma_declarada, true) THEN ', dq_lit('Cuadra'), ' ',
      '     ELSE ', dq_lit('No cuadra: 1) carga incompleta/duplicada  2) filtro de filas en Unity Catalog  3) trailer mal calculado en origen'), ' END AS hipotesis ',
      'FROM t CROSS JOIN d'),
    concat('SELECT ', dq_lit('LD.08 omitida: configuren dq_ld_tipo_trailer y dq_ld_campo_conteo (sólo aplica a tramas de ancho fijo con trailer)'), ' AS info'))
  FROM dq_diccionario c),
  'SELECT 1 AS info');
EXECUTE IMMEDIATE dq_sql;


/* ────────────────────────────────────────────────────────────────────────────
   [LD.09] Diagnóstico de desfase de posiciones (causa raíz de errores masivos)
   DOCSTRING (es-PE)
     Sólo en ANCHO_FIJO: para cada campo verificable (numérico, fecha con
     formato, hora o con dominio) vuelve a cortar la línea corrida k = -2..+2
     posiciones y mide qué % de valores pasa su validación en cada k, por
     grupo de líneas (largo de línea y si tiene caracteres multibyte). Indica
     el desplazamiento que mejor calza.
   TOOLTIP ▸ Cómo leer e interpretar (hipótesis alternativas)
     • mejor_k = 0 ⇒ el corte está alineado: los errores de LD.02/LD.05 son de
       la data.
     • mejor_k ≠ 0 desde cierto campo en adelante y sólo en un grupo de largo
       ⇒ ese grupo usa otra versión del layout (campo ensanchado o agregado).
     • mejor_k ≠ 0 sólo en el grupo "multibyte" ⇒ el diccionario cuenta BYTES:
       usen dq_posiciones_en = 'BYTES'.
     • mejor_k = -1 en todos ⇒ posiciones del diccionario desde 0.
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_sql = coalesce((
  SELECT IF(dq_formato_detectado = 'ANCHO_FIJO' AND count(*) > 0,
    concat(
      'WITH s AS (SELECT concat(', dq_lit('largo='), ', char_length(_dq_linea), ',
      'IF(octet_length(_dq_linea) > char_length(_dq_linea), ', dq_lit(' multibyte'), ', ', dq_lit(''), ')) AS grupo, ',
      array_join(transform(array_sort(collect_list(struct(orden, proy))), y -> y.proy), ', '),
      ' FROM (SELECT _dq_linea FROM dq_objetivo LIMIT 20000) l), ',
      'e AS (SELECT grupo, z.campo, z.orden, z.k, z.ok FROM s LATERAL VIEW inline(array(',
      array_join(transform(array_sort(collect_list(struct(orden, est))), y -> y.est), ', '),
      ')) z AS campo, orden, k, ok), ',
      'a AS (SELECT grupo, campo, orden, k, avg(ok) AS pct_ok, count(*) AS n FROM e GROUP BY grupo, campo, orden, k) ',
      'SELECT grupo, campo, max(n) AS n_lineas, round(max(IF(k = 0, pct_ok, NULL)), 4) AS pct_ok_k0, ',
      'max_by(k, pct_ok * 10 - abs(k) / 10) AS mejor_k, round(max(pct_ok), 4) AS pct_ok_mejor, ',
      'CASE WHEN max(IF(k = 0, pct_ok, NULL)) >= 0.95 THEN ', dq_lit('ALINEADO'), ' ',
      '     WHEN max(pct_ok) - max(IF(k = 0, pct_ok, NULL)) >= 0.3 THEN concat(', dq_lit('DESFASE k='), ', max_by(k, pct_ok * 10 - abs(k) / 10)) ',
      '     ELSE ', dq_lit('NO_CONCLUYENTE (errores de datos o campo sin patrón)'), ' END AS diagnostico, ',
      'CASE WHEN max(IF(k = 0, pct_ok, NULL)) >= 0.95 THEN ', dq_lit('Posiciones correctas para este grupo de líneas'), ' ',
      '     WHEN max(pct_ok) - max(IF(k = 0, pct_ok, NULL)) >= 0.3 THEN ',
      dq_lit('1) versión de layout distinta en este grupo (change log del diccionario) 2) posiciones en bytes y no en caracteres, si el grupo es multibyte 3) campo agregado o retirado antes de éste'), ' ',
      '     ELSE ', dq_lit('1) errores reales de datos en el campo 2) campo sin patrón verificable 3) pocas líneas en el grupo'), ' END AS hipotesis ',
      'FROM a GROUP BY grupo, campo, orden ORDER BY grupo, orden'),
    concat('SELECT ', dq_lit(concat('LD.09 omitida: sólo aplica a tramas de ancho fijo (formato ', dq_formato_detectado, ')')), ' AS info'))
  FROM (SELECT orden,
               -- columnas ok_<orden>_<k> calculadas en una proyección (las funciones SQL no pueden ir dentro de inline/explode)
               array_join(transform(sequence(-2, 2), kk -> concat(
                 'IF(', replace(chequeo, '#V#', concat('substr(_dq_linea, ', CAST(greatest(1, pos_inicio + kk) AS STRING), ', ', CAST(longitud AS STRING), ')')),
                 ', 1, 0) AS ok_', CAST(orden AS STRING), '_', CAST(kk + 2 AS STRING))), ', ') AS proy,
               array_join(transform(sequence(-2, 2), kk -> concat(
                 'named_struct(', lit_campo, ', ', chr(39), 'orden', chr(39), ', ', CAST(orden AS STRING),
                 ', ', chr(39), 'k', chr(39), ', ', CAST(kk AS STRING),
                 ', ', chr(39), 'ok', chr(39), ', ok_', CAST(orden AS STRING), '_', CAST(kk + 2 AS STRING), ')')), ', ') AS est
        FROM (SELECT orden, pos_inicio, longitud,
                     concat(dq_lit('campo'), ', ', dq_lit(campo)) AS lit_campo,
                     CASE
                       WHEN familia_declarada = 'FECHA' THEN
                         concat('(dq_fecha_formato(#V#, ', dq_lit(coalesce(formato, '')), ') IS NOT NULL OR #V# IN (',
                                dq_lit('00000000'), ', ', dq_lit('99999999'), '))')
                       WHEN familia_declarada = 'HORA' THEN concat('#V# RLIKE ', dq_lit('^([01][0-9]|2[0-3])[0-5][0-9]([0-5][0-9])?$'))
                       WHEN valores_permitidos IS NOT NULL AND size(valores_permitidos) > 0 THEN
                         concat('trim(#V#) IN (', array_join(transform(valores_permitidos, x -> concat(chr(39), replace(replace(trim(x), chr(92), concat(chr(92), chr(92))), chr(39), concat(chr(92), chr(39))), chr(39))), ', '), ')')
                       WHEN familia_declarada IN ('NUMERICO', 'IMPORTE') THEN
                         IF(coalesce(con_signo, false), concat('#V# RLIKE ', dq_lit('^[0-9]*[0-9{}A-R]$')), concat('#V# RLIKE ', dq_lit('^[0-9]+$')))
                     END AS chequeo
              FROM dq_mapa
              WHERE estado = 'MAPEADO' AND NOT coalesce(es_filler, false) AND pos_inicio IS NOT NULL AND longitud IS NOT NULL) b
        WHERE chequeo IS NOT NULL)),
  'SELECT 1 AS info');
EXECUTE IMMEDIATE dq_sql;


/* ────────────────────────────────────────────────────────────────────────────
   [LD.10] Columnas enmascaradas o tokenizadas (Unity Catalog / origen)
   DOCSTRING (es-PE)
     Detecta columnas cuyos valores parecen máscaras (****, XXXX, ####,
     ****1234) o hashes (32-128 caracteres hexadecimales) en ≥ 95% de los
     valores, o con un único valor distinto en una columna que debería variar
     (se excluyen FILLER y campos cuyo dominio declarado tiene un solo valor,
     como el tipo de registro).
   TOOLTIP ▸ Cómo leer e interpretar (hipótesis alternativas)
     • Enmascarada ⇒ las validaciones de formato, dominio y Luhn de esa
       columna NO son interpretables: los "errores" son de la máscara, no de
       la data. Pidan acceso sin máscara o una vista autorizada.
     • Un solo valor ⇒ (1) máscara, (2) columna que no se llena, (3) default
       del sistema fuente.
   ──────────────────────────────────────────────────────────────────────────── */
SELECT f.columna,
       sum(f.n)                                                                                   AS n_no_nulos,
       count(*)                                                                                   AS n_distintos,
       round(sum(IF(f.valor RLIKE '^[*Xx#]{3,}' OR f.valor RLIKE '[*]{4,}' OR f.valor RLIKE '^[Xx#]+$', f.n, 0)) / NULLIF(sum(f.n), 0), 4) AS pct_patron_mascara,
       round(sum(IF(f.valor RLIKE '^[0-9a-fA-F]{32,128}$', f.n, 0)) / NULLIF(sum(f.n), 0), 4)  AS pct_patron_hash,
       CASE WHEN sum(IF(f.valor RLIKE '^[*Xx#]{3,}' OR f.valor RLIKE '[*]{4,}' OR f.valor RLIKE '^[Xx#]+$', f.n, 0)) >= 0.95 * sum(f.n)
              THEN 'ENMASCARADA: no interpretar validaciones de formato/dominio de esta columna'
            WHEN sum(IF(f.valor RLIKE '^[0-9a-fA-F]{32,128}$', f.n, 0)) >= 0.95 * sum(f.n)
              THEN 'TOKENIZADA/HASH: sólo sirven métricas de completitud y unicidad'
            ELSE 'UN_SOLO_VALOR: máscara, columna que no se llena o default del sistema' END     AS diagnostico,
       CASE WHEN count(*) = 1
              THEN '1) máscara de Unity Catalog que devuelve un valor fijo 2) columna que la fuente no llena 3) valor por defecto del sistema 4) constante legítima no declarada en el diccionario'
            ELSE '1) máscara de columna de Unity Catalog para su usuario 2) tokenización o enmascaramiento en el origen (PCI) 3) el dato real llega así por diseño' END AS hipotesis
FROM dq_freq f
LEFT JOIN dq_mapa m ON m.columna = f.columna
WHERE f.valor IS NOT NULL AND dq_limpiar(f.valor) <> ''
  AND NOT coalesce(size(m.valores_permitidos) = 1, false)
  AND NOT coalesce(m.es_filler, false)
GROUP BY f.columna
HAVING sum(IF(f.valor RLIKE '^[*Xx#]{3,}' OR f.valor RLIKE '[*]{4,}' OR f.valor RLIKE '^[Xx#]+$', f.n, 0)) >= 0.95 * sum(f.n)
    OR sum(IF(f.valor RLIKE '^[0-9a-fA-F]{32,128}$', f.n, 0)) >= 0.95 * sum(f.n)
    OR (count(*) = 1 AND sum(f.n) >= 100);


/* ────────────────────────────────────────────────────────────────────────────
   [L8.00v2] Catálogo de reglas generado desde el diccionario (reemplaza L8.00)
   DOCSTRING (es-PE)
     Genera dq_reglas SÓLO para campos conciliados (estado MAPEADO), así
     L8.01 nunca falla por una columna inexistente. Reglas: obligatoriedad,
     longitud máxima (columnas texto), formato de fecha/hora/número, dominio
     de valores permitidos y FILLER en blanco. Las expresiones aplican trim()
     porque en ancho fijo los valores vienen con relleno.
   TOOLTIP ▸ Cómo interpretar
     • Revisen el catálogo con SELECT * FROM dq_reglas; antes de L8.01.
     • Semántica de CHECK: NULL no cuenta como falla (se cuenta aparte).
     • Las reglas sobre columnas con confianza de mapeo BAJA se generan con
       activa = false: actívenlas después de confirmar el mapeo.
   ──────────────────────────────────────────────────────────────────────────── */
CREATE OR REPLACE TEMP VIEW dq_reglas AS
WITH m AS (
  SELECT *, concat('`', replace(columna, '`', '``'), '`') AS c
  FROM dq_mapa
  WHERE estado = 'MAPEADO'
), r AS (
  SELECT campo, orden, 'COMPLETITUD' AS dimension, concat('Campo obligatorio ', campo) AS descripcion,
         concat(c, ' IS NOT NULL AND trim(', c, ') <> ', chr(39), chr(39)) AS expresion, 'ALTA' AS severidad, confianza
  FROM m WHERE coalesce(obligatorio, false) AND NOT coalesce(es_filler, false)
  UNION ALL
  SELECT campo, orden, 'VALIDEZ', concat('Longitud máxima ', longitud, ' en ', campo),
         concat('char_length(', c, ') <= ', longitud), 'MEDIA', confianza
  FROM m WHERE longitud IS NOT NULL AND coalesce(familia_real, 'TEXTO') = 'TEXTO' AND NOT coalesce(es_filler, false)
  UNION ALL
  SELECT campo, orden, 'VALIDEZ', concat('Fecha ', campo, ' en formato ', coalesce(formato, '?')),
         concat('trim(', c, ') = ', chr(39), chr(39), ' OR trim(', c, ') IN (', chr(39), '00000000', chr(39), ', ', chr(39), '99999999', chr(39),
                ') OR dq_fecha_formato(', c, ', ', chr(39), coalesce(formato, ''), chr(39), ') IS NOT NULL'), 'ALTA', confianza
  FROM m WHERE familia_declarada = 'FECHA' AND coalesce(familia_real, 'TEXTO') = 'TEXTO'
  UNION ALL
  SELECT campo, orden, 'VALIDEZ', concat('Número válido en ', campo),
         concat('trim(', c, ') = ', chr(39), chr(39), ' OR trim(', c, ') RLIKE ', chr(39),
                IF(coalesce(con_signo, false), '^[0-9]*[0-9{}A-R]$|^[+-][0-9]+$', '^[0-9]+$'), chr(39)), 'ALTA', confianza
  FROM m WHERE familia_declarada IN ('NUMERICO', 'IMPORTE') AND coalesce(familia_real, 'TEXTO') = 'TEXTO'
  UNION ALL
  SELECT campo, orden, 'VALIDEZ', concat('Valor permitido en ', campo),
         concat('trim(', c, ') IN (',
                array_join(transform(valores_permitidos, x -> concat(chr(39), replace(replace(trim(x), chr(92), concat(chr(92), chr(92))), chr(39), concat(chr(92), chr(39))), chr(39))), ', '),
                ')'), 'ALTA', confianza
  FROM m WHERE valores_permitidos IS NOT NULL AND size(valores_permitidos) > 0
  UNION ALL
  SELECT campo, orden, 'VALIDEZ', concat('FILLER en blanco (', campo, ')'),
         concat('trim(', c, ') = ', chr(39), chr(39)), 'BAJA', confianza
  FROM m WHERE coalesce(es_filler, false)
)
SELECT concat('D', lpad(CAST(row_number() OVER (ORDER BY orden, dimension, descripcion) AS STRING), 3, '0')) AS id_regla,
       '*' AS tabla, dimension, descripcion, expresion, severidad,
       CAST(0.0 AS DECIMAL(4, 3)) AS tolerancia,
       coalesce(confianza, 'ALTA') <> 'BAJA' AS activa
FROM r;

SELECT id_regla, dimension, severidad, descripcion, expresion, activa FROM dq_reglas ORDER BY id_regla;
