/* ════════════════════════════════════════════════════════════════════════════
   REFERENCIA B · L6.00v2 — DERIVA SIN DETENER LA CORRIDA (reemplaza L6.00)
   ────────────────────────────────────────────────────────────────────────────
   DOCSTRING (es-PE)
     Versión de L6.00 que no usa raise_error: si la deriva no está configurada
     (sin segmento, o sin fuentes en modo FUENTES) crea dq_deriva_long vacía
     con las mismas columnas y registra el motivo en dq_log. Así el resto de
     la capa 6 corre y devuelve resultados vacíos en lugar de cortar el "Run all".
   TOOLTIP ▸ Cómo interpretar
     • Si la capa 6 sale vacía, revisen [LZ.01]: dirá por qué se omitió.
     • En modo FUENTES no se recomienda VERSION AS OF sin permisos de historia.
   ════════════════════════════════════════════════════════════════════════════ */


/* ────────────────────────────────────────────────────────────────────────────
   [L6.00v2] Construcción tolerante de dq_deriva_long
   DOCSTRING (es-PE)
     Arma dq_deriva_long (grupo, columna, valor) desde los segmentos o desde dos
     fuentes, o vacía si falta configuración, y anota el escenario.
   TOOLTIP ▸ Cómo interpretar
     • escenario DERIVA_OMITIDA ⇒ configuren dq_expr_segmento (antes de la
       preparación), dq_segmento_base y dq_segmento_actual para activarla.
   ──────────────────────────────────────────────────────────────────────────── */
SET VAR dq_sql = CASE
  WHEN upper(dq_modo_deriva) = 'SEGMENTO' AND dq_segmento_base <> '' AND dq_segmento_actual <> '' THEN
    concat('CREATE OR REPLACE TEMP VIEW dq_deriva_long AS ',
           'SELECT IF(_dq_segmento = ', dq_lit(dq_segmento_base), ', ', dq_lit('BASE'), ', ', dq_lit('ACTUAL'), ') AS grupo, ',
           'columna, valor FROM dq_long WHERE _dq_segmento IN (', dq_lit(dq_segmento_base), ', ', dq_lit(dq_segmento_actual), ')')
  WHEN upper(dq_modo_deriva) = 'FUENTES' AND dq_fuente_base <> '' AND dq_fuente_actual <> '' THEN
    concat('CREATE OR REPLACE TEMP VIEW dq_deriva_long AS ',
           'SELECT ', dq_lit('BASE'), ' AS grupo, ', dq_stack,
           ' FROM (SELECT ', dq_proyeccion, ' FROM (SELECT * FROM ', dq_fuente_base, ') s0) s1 ',
           'UNION ALL SELECT ', dq_lit('ACTUAL'), ' AS grupo, ', dq_stack,
           ' FROM (SELECT ', dq_proyeccion, ' FROM (SELECT * FROM ', dq_fuente_actual, ') s0) s1')
  ELSE 'CREATE OR REPLACE TEMP VIEW dq_deriva_long AS SELECT CAST(NULL AS STRING) AS grupo, CAST(NULL AS STRING) AS columna, CAST(NULL AS STRING) AS valor WHERE false'
END;
EXECUTE IMMEDIATE dq_sql;

SET VAR dq_log = array_append(dq_log, named_struct(
  'paso', 'L6.00v2',
  'escenario', IF((upper(dq_modo_deriva) = 'SEGMENTO' AND dq_segmento_base <> '' AND dq_segmento_actual <> '')
                  OR (upper(dq_modo_deriva) = 'FUENTES' AND dq_fuente_base <> '' AND dq_fuente_actual <> ''),
                  concat('DERIVA_', upper(dq_modo_deriva)), 'DERIVA_OMITIDA'),
  'detalle', concat('modo=', dq_modo_deriva, '; base=', dq_segmento_base, dq_fuente_base, '; actual=', dq_segmento_actual, dq_fuente_actual),
  'interpretacion', 'Si se omitió, la capa 6 devuelve resultados vacíos: no significa estabilidad, significa que no se midió.'));

SELECT grupo, count(*) AS celdas FROM dq_deriva_long GROUP BY grupo;
