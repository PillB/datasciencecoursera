# Marco de Validación, Perfilado y EDA por Capas para Databricks SQL

Conjunto de consultas SQL para el **editor SQL de Databricks** que perfila,
valida y caracteriza tablas y columnas **de lo general a lo específico**:
primero el inventario de todo el esquema, luego un perfil universal de cada
columna, después inferencia de tipos, estadística por familia de datos,
deriva (PSI), relaciones entre columnas y tablas y, al final, reglas de
negocio específicas y preparación para ML.

Cada consulta trae un **DOCSTRING en español peruano** (qué hace, entradas,
salida) y un **TOOLTIP** (cómo leer el resultado, umbrales y acción
sugerida). Todo está probado con datos sintéticos que traen defectos
sembrados a propósito (ver [Pruebas](#pruebas)).

---

## 1. Arquitectura

```
                        ┌──────────────────────────────────────────┐
  00_configuracion  ──► │ variables dq_*, funciones dq_*, umbrales │
                        └──────────────────────────────────────────┘
  01  CAPA 0  Inventario transversal (todas las tablas, casi sin leer data)
  02  PREPARACIÓN (por tabla) ──► dq_columnas · dq_src · dq_long · dq_freq
  03  CAPA 1  Perfil universal (cualquier tipo)
  04  CAPA 2  Inferencia semántica de tipos en columnas TEXTO
  05  CAPA 3  Numéricas: descriptiva, varianza, atípicos, Benford
  06  CAPA 4  Temporales: rangos, centinelas, zona horaria, frescura, volumen
  07  CAPA 5  Categóricas: entropía, rareza, variantes, typos
  08  CAPA 6  Deriva/estabilidad: PSI, Jensen-Shannon, KS, SMD
  09  CAPA 7  Relaciones: correlación, Cramér, faltantes, orden, FD, FK
  10  CAPA 8  Reglas de negocio, CHECK/DLT, scorecard y preparación ML
        ▲ general / barato                       específico / con conocimiento ▼
```

### Idea central: formato largo con `stack()`

El archivo 02 convierte la tabla (o una muestra determinística) en:

| Vista | Contenido | Para qué |
|---|---|---|
| `dq_columnas` | columna, ordinal, tipo declarado, **familia** (NUMERICO, TEXTO, FECHA, TIMESTAMP, BOOLEANO, COMPLEJO…) | decidir qué validar |
| `dq_src` | la tabla con **todas las columnas como texto controlado** + `_dq_segmento` + `_dq_objetivo` | chequeos a nivel fila |
| `dq_long` | `(columna, valor)` — una fila por celda, generado con `stack()` | perfilar N columnas con **una** consulta |
| `dq_freq` | `(columna, valor, n)` | métricas sobre valores distintos ponderados (barato) |

Así **ninguna consulta depende de los nombres de columnas**: sirven para
cualquier tabla. El SQL dinámico (cuando se necesita una columna por
pareja, p.ej. correlaciones) se genera desde `dq_columnas` y se ejecuta con
`EXECUTE IMMEDIATE`.

### Decisiones de diseño (y por qué)

| Decisión | Motivo |
|---|---|
| `try_cast` + regex en vez de `CAST`/`to_date` | Databricks SQL corre con **ANSI activado**: un `CAST('abc' AS INT)` revienta la consulta. Además `try_cast('1d' AS DOUBLE)` **sí** convierte (Java acepta sufijos), por eso se valida la forma con regex antes. |
| Fechas en texto validadas con regex + reordenamiento + `try_cast(... AS DATE)` | evita los errores del parser legacy/`timeParserPolicy` y rechaza fechas imposibles (31/02). Exige el mismo separador (`12/03-2020` no es fecha). |
| Muestra por **hash** (`xxhash64`) y no `rand()` | reproducible entre corridas; si se configura la clave, todas las filas de una clave caen juntas y el chequeo de unicidad sigue siendo válido en muestra. |
| Las vistas temporales **no** referencian variables de sesión | portabilidad entre versiones; cuando una vista necesita un parámetro (p.ej. DMY/MDY) se crea con `EXECUTE IMMEDIATE` "congelando" el valor. |
| Funciones `dq_*` temporales nunca dentro de lambdas | Spark/Databricks no permite UDF SQL dentro de `transform/filter` (error `LAMBDA_FUNCTION_WITH_SQL_UDF`). |
| Escapado con `dq_id()` / `dq_lit()` (`chr(39)`, `chr(92)`) | columnas con espacios, tildes, `ñ`, comillas o backticks no rompen el SQL dinámico. |
| Nulos **disfrazados** (`''`, `'N/A'`, `'-'`, `'#N/A'`, `'#¡VALOR!'`, `'0000-00-00'`…) separados de NULL | la completitud real casi siempre es peor que la que muestra `IS NULL`. |
| Sin marcadores `:param` ni `{{ }}` en el código | el editor de Databricks los interpreta como parámetros; el arnés de pruebas lo verifica. |

---

## 2. Cómo ejecutar

**Requisitos:** Databricks SQL warehouse (Pro/Serverless) o clúster con
DBR **14.3 LTS o superior** (`DECLARE VARIABLE`, `EXECUTE IMMEDIATE`,
`IDENTIFIER`). Permisos `USE CATALOG`, `USE SCHEMA`, `SELECT` y lectura de
`information_schema`.

1. Abran `00_configuracion.sql`, editen los `DEFAULT` de catálogo, esquema,
   tabla y (opcional) clave, segmento y target. Ejecútenlo **completo**.
   La consulta `[C0.10]` debe mostrar todas las columnas `prueba_*` en `true`.
2. Ejecuten `01_...` (capa 0) para todo el esquema.
3. Ejecuten `02_preparar_tabla.sql` para la tabla objetivo.
4. Ejecuten los archivos 03 → 10 en orden. Cada consulta es independiente:
   pueden correr una por una (cursor dentro de la consulta y
   *Ctrl/Cmd + Shift + Enter*) o "Run all" (el editor nuevo muestra un
   resultado por sentencia).
5. Para otra tabla: `SET VAR dq_tabla = 'otra';` y repitan desde el paso 3.

> **Todo en la misma sesión.** Las variables y vistas son de sesión: si el
> warehouse se reinicia o abren otra pestaña, vuelvan a correr 00 y 02.

**Tablas grandes.** Por defecto se perfilan hasta 2 millones de filas
(`dq_max_filas_muestra`). Para no re-leer la fuente en cada consulta:

```sql
SET VAR dq_esquema_trabajo = 'mi_catalogo.calidad';   -- debe existir
SET VAR dq_materializar = true;
```

Con `dq_esquema_trabajo` configurado, además, cada capa puede guardar sus
métricas en la tabla `dq_metricas` (formato largo) para ver tendencias y
alertar sobre las propias métricas.

**hive_metastore / vistas temporales.** Si no hay `information_schema`:
`SET VAR dq_origen_metadatos = 'INFERIDO';` (lee una fila y obtiene tipos
con `typeof()`).

---

## 3. Qué hace cada capa

| Capa | Archivo | Consultas principales | Defectos típicos que encuentra |
|---|---|---|---|
| 0 Inventario | 01 | L0.01 tablas con alertas · L0.03 nombre↔tipo · L0.04 mismo nombre con tipos distintos · L0.05 convenciones · L0.06 PK/FK · L0.07/08 DESCRIBE DETAIL/HISTORY · L0.09-11 perfil ligero multi-tabla | esquemas "todo string", fechas/montos guardados como texto, DNI como número, montos en FLOAT, `id_cliente` BIGINT vs STRING entre tablas, tablas sin PK, columnas 100% nulas o constantes, small files |
| 1 Universal | 03 | L1.01 tablero · L1.02 top-N · L1.03 longitudes · L1.04 higiene con caracteres visibles · L1.05-06 duplicados · L1.07-08 clave de negocio | nulos disfrazados, constantes, casi-únicas, longitud irregular (DNI de 7), espacios/NBSP/saltos de línea, **mojibake** (`BreÃ±a`), duplicados exactos y casi-duplicados, claves duplicadas con conflicto |
| 2 Tipos en texto | 04 | L2.01 tipo sugerido + diagnóstico · **L2.02 valores que no calzan** · L2.03 máscaras · L2.04 fechas · L2.05 números/locale · L2.06 DNI/RUC/ubigeo/teléfono · L2.07 códigos como número | columna "casi toda fecha" con valores basura, fechas imposibles, **dd/MM mezclado con MM/dd**, coma vs punto decimal, moneda embebida (`S/ 100`), ceros a la izquierda, RUC con dígito verificador inválido |
| 3 Numéricas | 05 | L3.01 media, mediana, **varianza**, desviación, CV, asimetría, curtosis, percentiles · L3.02 Tukey + MAD · L3.03 centinelas/heaping/último dígito · L3.04 dominio por nombre · L3.05 histograma · L3.06 Benford | -999/9999 como "nulo", edades 999, redondeo humano, montos negativos, colas pesadas, no conformidad con Benford |
| 4 Temporales | 06 | L4.01 perfil · L4.02 volumen mensual · L4.03 huecos · L4.04 anomalías diarias por día de semana · L4.05 hora×día | fechas futuras, 1900-01-01 / 1899-12-30 (Excel), **05:00:00 = medianoche de Lima en UTC**, timestamps que son sólo fecha, días sin carga, falta de frescura |
| 5 Categóricas | 07 | L5.01 entropía/Gini/rareza · **L5.02 variantes (huella)** · L5.03 typos (Levenshtein) · L5.04 mayúsculas · L5.05 raras | `LIMA`/`Lima `/`Líma`, `Miraflroes`, flags con `X`, dominios abiertos, desbalance |
| 6 Deriva | 08 | L6.01 **PSI** + Jensen-Shannon · L6.02 detalle por cubeta · L6.03 **KS** · L6.04 SMD, Δ nulos, categorías nuevas · L6.05 PSI por segmento (serie) | cambio de población entre periodos o entre train y scoring, deriva de completitud, categorías desconocidas en producción |
| 7 Relaciones | 09 | L7.01 Pearson · L7.02 **V de Cramér** (incluye target) · L7.03 patrones de faltantes · **L7.04 faltantes condicionales** · L7.05 reglas de orden · L7.06 código→descripción · L7.07 **huérfanos (FK)** | redundancia, fuga de información, faltantes MAR/MNAR, `fecha_inicio > fecha_fin`, catálogos inconsistentes, integridad referencial rota |
| 8 Específica | 10 | L8.00 catálogo de reglas · L8.01 evaluación · L8.02 filas que fallan · L8.03 **CHECK de Delta y expectativas DLT** · L8.04 **scorecard** · L8.05-09 ML: target, **IV/WoE con alerta de fuga**, etiquetas en conflicto, solapamiento train/test, recomendación por variable | incumplimiento de reglas de negocio con severidad y tolerancia; preparación de features |

---

## 4. Cómo personalizar cada capa en las siguientes rondas

La regla general: **lo que se aprende en una capa se "promueve" a la
siguiente más específica**, hasta terminar como regla formal en la capa 8
(y luego como `CHECK` o expectativa DLT en el pipeline).

### Capa 0 — Inventario (`01`)
- **Alcance:** `dq_regex_esquemas` (p.ej. `'^(bronze|silver)_'`) y `dq_regex_tablas`.
- **Convenciones propias:** en L0.03 agreguen sus prefijos (`fec_`, `imp_`, `cod_`, `flg_`) a las regex; en L0.05 su estándar de nombres.
- **Frescura:** ajusten `dq_sla_frescura_dias` por tabla (diaria = 1-2, mensual = 35).
- Cuando tengan el **diccionario de datos**, carguen los comentarios en UC (`COMMENT ON COLUMN`): L0.01 deja de marcar `SIN_DOCUMENTAR`.

### Capa 1 — Universal (`03`)
- **Placeholders del negocio:** agreguen a `dq_es_placeholder` (archivo 00) los "valores mágicos" de sus sistemas (`'SIN INFORMACION'`, `'NO APLICA'`, `'99999'`). Quiten `'na'` si es un valor válido (país Namibia).
- **Clave de negocio:** `SET VAR dq_columnas_clave = 'id_cliente, fecha';` habilita L1.07/L1.08 y el muestreo por clave.
- **Columnas técnicas:** excluyan `_rescued_data`, `fecha_carga`, etc. con `dq_regex_excluir_columnas` para encontrar duplicados "de negocio".

### Capa 2 — Tipos en texto (`04`)
- **Umbral:** `dq_umbral_tipo_dominante` = 0.98 en silver/gold, 0.80 en bronze.
- **Convención de fechas:** `dq_orden_fecha_texto` = `'DMY'` (Perú) o `'MDY'`.
- **Tipos nuevos** (placa `AAA-999`, CCI de 20 dígitos, CUSPP, código de producto): (1) agreguen el flag en la vista `dq_l2_flags`, (2) una entrada en el `stack(...)` de `dq_l2_valor_tipo` (y suban el número de `stack(N`), (3) una fila en `dq_l2_catalogo_tipos` con su especificidad.
- **Formatos de fecha propios** (`05-ENE-2024` de Oracle): agreguen una rama `WHEN` en `dq_fecha_texto` (archivo 00); todas las capas la heredan.

### Capa 3 — Numéricas (`05`)
- **Dominios exactos:** reemplacen las filas por patrón de nombre del `VALUES` de L3.04 por rangos por columna exacta (`'^edad_cliente$'`, 18, 99).
- **Centinelas propios:** editen la lista `IN (-1, -999, ...)` de L3.03.
- **Columnas texto tratadas como número:** hoy entran si el nombre sugiere magnitud o tienen decimales; para forzar una, agreguen su nombre a la regex `nombre_magnitud` de `dq_l3_cols`.
- **Atípicos:** `dq_umbral_z_robusto` (3.5 por defecto). Para montos log-normales, apliquen L3.02 sobre `log10(x)`.

### Capa 4 — Temporales (`06`)
- Definan **la columna de evento** de cada tabla y su SLA; las demás fechas (nacimiento, alta) no se evalúan por frescura ni huecos.
- **Centinelas de fecha** propios: lista en L4.00. **Calendario:** si el proceso no carga fines de semana/feriados, ignoren esos huecos en L4.03 (o crucen con una tabla de feriados).
- `dq_fecha_min_valida` y `dq_tolerancia_futuro_dias` por dominio (vencimientos sí pueden ser futuros).
- **Ojo:** L4.02-L4.04 cuentan volumen sobre la **muestra** (`dq_long`). Para
  detectar cargas fallidas, parciales o duplicadas usen la **Capa V**
  (`pruebas/sin_metadatos/ref_e_volumen.sql`, LV.00-LV.08), que cuenta la
  tabla completa por fecha de carga (p.ej. `fecactualizacion`), fecha de
  negocio y archivo, con línea base por día de semana, feriados de Perú,
  latencia, recargas, archivos duplicados y columnas que se vacían en una
  carga.

### Capa 5 — Categóricas (`07`)
- Con **catálogos maestros** (ubigeo INEI, monedas ISO, productos) validen dominio cerrado como regla en la capa 8: `distrito IN (SELECT nombre FROM maestro.ubigeo)`.
- La salida de L5.02/L5.03 es una **tabla de homologación** (`valor_crudo → canonico`): guárdenla y aplíquenla en silver.
- `dq_max_cardinalidad_cat` define qué se considera categórico (50 por defecto).

### Capa 6 — Deriva (`08`)
- **Modo SEGMENTO:** `dq_expr_segmento = "date_format(fecha_evento, 'yyyy-MM')"`, base y actual = dos meses. **Modo FUENTES:** `dq_fuente_base = 'cat.esq.tabla VERSION AS OF 120'` (time travel) o `'cat.ml.train'` vs `'cat.ml.scoring'`.
- Ajusten `dq_umbral_psi_moderado/alto` por criticidad de la variable; excluyan columnas de tiempo e IDs (derivan por construcción).
- Para monitoreo continuo: programen 02 + 08 como Job mensual con `dq_esquema_trabajo` y grafiquen `dq_metricas`. Complementa (no reemplaza) a **Lakehouse Monitoring**.

### Capa 7 — Relaciones (`09`)
- Plantillas: `dq_fd_determinante/dq_fd_dependiente` (código→descripción) y `dq_ri_columna_hija/dq_ri_tabla_padre/dq_ri_columna_padre` (FK manual).
- Mejor aún: **declaren las PK/FK** en Unity Catalog (`ALTER TABLE ... ADD CONSTRAINT ... FOREIGN KEY`); L7.07 las verifica todas automáticamente.
- Reglas de orden confirmadas en L7.05 → pásenlas a la capa 8.

### Capa 8 — Reglas y ML (`10`)
- **El catálogo `dq_reglas` es el lugar del conocimiento de negocio.** Cada regla: expresión booleana, dimensión, severidad y tolerancia. Para que viva más allá de la sesión, conviertan el `VALUES` en una tabla Delta (`CREATE TABLE cat.calidad.reglas AS SELECT * FROM dq_reglas`) y cambien la vista para leerla.
- Cuando una regla esté en `CUMPLE` de forma estable, usen L8.03 para volverla `CHECK` (Delta) o `EXPECT` (Lakeflow/DLT).
- Funciones como `dq_ruc_valido` deben crearse como funciones de Unity Catalog para usarse en producción.
- **ML:** configuren `dq_expr_objetivo`, `dq_valor_positivo` y, si hay partición, `dq_expr_segmento = "CASE WHEN fecha < '2025-01-01' THEN 'TRAIN' ELSE 'TEST' END"`.

---

## 5. Variables principales

| Variable | Defecto | Uso |
|---|---|---|
| `dq_catalogo`, `dq_esquema`, `dq_tabla` | main / default / mi_tabla | tabla objetivo |
| `dq_regex_esquemas`, `dq_regex_tablas` | '' / '.*' | alcance de la capa 0 |
| `dq_origen_metadatos` | INFORMATION_SCHEMA | o INFERIDO |
| `dq_max_filas_muestra` | 2 000 000 | tope de filas perfiladas |
| `dq_columnas_clave` | '' | clave de negocio |
| `dq_expr_segmento`, `dq_expr_objetivo`, `dq_valor_positivo` | NULL / NULL / '1' | segmento, target |
| `dq_umbral_tipo_dominante` | 0.90 | inferencia de tipos |
| `dq_umbral_nulos_alerta/critico` | 0.20 / 0.50 | completitud |
| `dq_umbral_psi_moderado/alto` | 0.10 / 0.25 | deriva |
| `dq_umbral_z_robusto` | 3.5 | atípicos |
| `dq_umbral_iv_sospechoso` | 0.5 | fuga en ML |
| `dq_orden_fecha_texto` | DMY | dd/MM vs MM/dd |
| `dq_esquema_trabajo`, `dq_materializar` | '' / false | persistencia |

Si una tabla tuviera una columna con el mismo nombre que una variable, la
columna gana; usen `system.session.dq_x` para referirse a la variable.

---

## 6. Limitaciones conocidas

- Las métricas sobre muestra son estimaciones (error típico ≈ √(p(1-p)/n));
  las consultas marcadas "tabla completa" (reglas L8.01, FK L7.07) no usan muestra.
- `percentile_approx` y `approx_count_distinct` son aproximados (suficiente para EDA).
- Pearson sólo capta relaciones lineales; no se incluye Spearman (requiere
  ordenar cada columna: costoso a escala).
- L0.07/L0.08 (`DESCRIBE DETAIL/HISTORY`) y la materialización con column
  mapping son específicas de Delta y **no se pudieron probar localmente**.
- Las heurísticas por nombre (montos, códigos, dominios) son evidencia, no
  prueba: confírmenlas con negocio y conviértanlas en reglas.

---

## 7. Pruebas

`pruebas/` contiene un arnés en PySpark (≥ 4.0, ANSI activado como en
Databricks SQL) que:

1. genera tablas sintéticas con **defectos sembrados** (DNI de 7 dígitos,
   RUC con DV inválido, fechas 31/02 y dd/MM mezclado con MM/dd, montos con
   `S/` y separador de miles, NBSP, mojibake, centinelas -999/999/1900-01-01,
   05:00 UTC, deriva de ingreso +30%, faltantes MAR por segmento, fuga del
   target, fin < inicio, 3% de FK huérfanas, duplicados exactos…);
2. simula `information_schema` (columns, tables, constraints);
3. ejecuta todos los archivos sentencia por sentencia;
4. verifica con aserciones que **cada defecto sembrado sea detectado**;
5. hace *lint*: cada consulta tiene DOCSTRING y TOOLTIP y no hay patrones
   que el editor confunda con parámetros.

```bash
pip install pyspark          # requiere Java 17+
cd pruebas
python ejecutar_pruebas.py             # ANSI on
python ejecutar_pruebas.py --sin-ansi  # ANSI off
python ejecutar_pruebas.py --verbose   # ver resultados
```

**Modo sin metadatos** (sin `information_schema` ni `DESCRIBE`, sólo
`SELECT`): `pruebas/sin_metadatos/` tiene las piezas de referencia
(`ref_a`…`ref_e`) que usa `HANDOVER_AGENTE_TRAMA_LYNX.md` y un arnés con 8
escenarios (tabular renombrado, ancho fijo con defectos, tabla vacía,
delimitado, control limpio, tabla sin completar, volumen con cargas
defectuosas y su control limpio):

```bash
cd pruebas/sin_metadatos
python ejecutar_escenarios.py              # ANSI on
python ejecutar_escenarios.py --sin-ansi   # ANSI off
python ejecutar_escenarios.py --solo=G,H --verbose
```

---

## 8. Referencias y estándares en los que se basa

- **DAMA-DMBOK 2** e **ISO/IEC 25012** (dimensiones de calidad), **ISO 8000** (datos maestros).
- Schelter et al., *Automating Large-Scale Data Quality Verification* (VLDB 2018) — **Amazon Deequ** (perfiles, repositorio de métricas, anomalías sobre métricas).
- Breck et al., *Data Validation for Machine Learning* (MLSys 2019) y *The ML Test Score* (2017) — **TensorFlow Data Validation** (esquema inferido, drift y training-serving skew).
- Sambasivan et al., *"Everyone wants to do the model work, not the data work": Data Cascades* (CHI 2021).
- **DeepLearning.AI** — *MLOps Specialization* (Andrew Ng): Data-Centric AI, consistencia de etiquetas, baseline de datos.
- Gebru et al., *Datasheets for Datasets* (2018).
- **Great Expectations**, **Soda Core**, **dbt tests** (unique, not_null, accepted_values, relationships), **Lakeflow/DLT expectations**, **Databricks Lakehouse Monitoring**.
- Barr Moses — los 5 pilares de la *data observability* (frescura, volumen, esquema, distribución, linaje).
- Tukey (1977) IQR · Iglewicz & Hoaglin (1993) z robusto con MAD · Nigrini (2012) Benford · Siddiqi (2006) / Yurdakul (2018) PSI e IV · Little (1988) / Rubin (1976) mecanismos de faltantes · OpenRefine (clustering por huella).
- SUNAT — algoritmo módulo 11 del dígito verificador del RUC.
