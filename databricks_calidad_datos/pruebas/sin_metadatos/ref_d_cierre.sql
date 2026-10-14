/* ════════════════════════════════════════════════════════════════════════════
   REFERENCIA D · CIERRE: EJEMPLOS ENMASCARADOS Y RESUMEN DE ESCENARIOS
   ────────────────────────────────────────────────────────────────────────────
   DOCSTRING (es-PE)
     L8.02v2 reemplaza a L8.02 (que mostraba filas completas con PII) y LZ.01
     cierra la corrida mostrando la bitácora de escenarios dq_log: qué detectó
     el script, qué omitió y cómo interpretar cada caso.
   TOOLTIP ▸ Cómo usar
     • Descarguen el resultado de LZ.01 como CSV y envíenlo junto con L1.01,
       L2.01, LD.* y L8.01 para la siguiente iteración.
   ════════════════════════════════════════════════════════════════════════════ */


/* ────────────────────────────────────────────────────────────────────────────
   [L8.02v2] Ejemplos de filas que fallan una regla, con PII enmascarada
   DOCSTRING (es-PE)
     Igual que L8.02 pero cada columna marcada como PII en el diccionario se
     muestra enmascarada (dígito → 9, letra → A/a) salvo que
     dq_mostrar_pii = true. Por defecto toma la primera regla con fallas.
   TOOLTIP ▸ Cómo interpretar
     • Sirve para armar el caso con el dueño de la fuente sin exponer datos
       personales. Cambien de regla con SET VAR dq_id_regla = 'D007';
   ──────────────────────────────────────────────────────────────────────────── */
DECLARE OR REPLACE VARIABLE dq_id_regla STRING DEFAULT '';
SET VAR dq_id_regla = coalesce(nullif(dq_id_regla, ''),
  (SELECT min(x.id_regla) FROM dq_l8_resultados x WHERE x.n_fallas > 0), '');

SET VAR dq_sql = coalesce((
  SELECT concat('SELECT ', dq_lit(max(r.id_regla)), ' AS id_regla, ', dq_lit(max(r.descripcion)), ' AS descripcion, ',
                'to_json(named_struct(', max(p.proy), ')) AS fila FROM ', dq_tabla_fq,
                ' WHERE NOT (', max(r.expresion), ') LIMIT ', CAST(dq_top_n AS STRING))
  FROM dq_reglas r
  CROSS JOIN (
    SELECT array_join(transform(array_sort(collect_list(struct(ordinal, e))), x -> x.e), ', ') AS proy
    FROM (SELECT c.ordinal,
                 concat(dq_lit(c.columna), ', ',
                        IF(coalesce(m.pii, false) AND NOT dq_mostrar_pii,
                           concat('dq_mascara(CAST(', dq_id(c.columna), ' AS STRING))'),
                           concat('CAST(', dq_id(c.columna), ' AS STRING)'))) AS e
          FROM dq_columnas c LEFT JOIN dq_mapa m ON m.columna = c.columna)) p
  WHERE r.id_regla = dq_id_regla
  HAVING count(*) > 0),
  concat('SELECT ', dq_lit('Ninguna regla con fallas (o dq_id_regla no existe)'), ' AS info'));
EXECUTE IMMEDIATE dq_sql;


/* ────────────────────────────────────────────────────────────────────────────
   [LZ.01] Resumen de escenarios de la corrida e interpretación
   DOCSTRING (es-PE)
     Muestra, en orden, cada decisión que tomó el script (modo de columnas,
     formato detectado, campos conciliados, estado de la tabla, capas
     omitidas) con su detalle y su interpretación, más una fila final con el
     estado global.
   TOOLTIP ▸ Cómo leer e interpretar
     • Léanlo PRIMERO: explica en qué escenario se corrió el análisis y, por
       tanto, cómo leer el resto. Por ejemplo, si la deriva fue omitida, una
       capa 6 vacía no significa estabilidad; si el formato es
       TABULAR_PARCIAL, la Capa D sólo cubre los campos conciliados.
     • Si algo no cuadra con lo que esperaban (p.ej. ANCHO_FIJO cuando la
       tabla ya viene en columnas), fijen la variable correspondiente
       (dq_formato_fuente, dq_modo_columnas) y vuelvan a correr.
   ──────────────────────────────────────────────────────────────────────────── */
SELECT pos + 1 AS n, e.paso, e.escenario, e.detalle, e.interpretacion
FROM (SELECT posexplode(dq_log) AS (pos, e))
UNION ALL
SELECT 999, 'FINAL', dq_estado,
       concat('formato=', dq_formato_detectado, '; filas perfiladas≈', round(dq_n_filas_total * dq_frac_muestra),
              ' de ', dq_n_filas_total, '; muestra=', round(dq_frac_muestra, 4)),
       CASE WHEN dq_estado = 'OK' THEN 'Corrida completa. Interpreten los hallazgos según el formato y la confianza de mapeo.'
            ELSE 'Corrida completa con advertencias: revisen las filas anteriores antes de sacar conclusiones.' END
ORDER BY n;
