"""
Arnés de pruebas locales del marco de calidad de datos (PySpark >= 4.0).

Qué hace:
  1. Levanta Spark local con ANSI activado (igual que Databricks SQL).
  2. Crea tablas sintéticas con defectos sembrados (datos_sinteticos.py) y
     simula <catalogo>.information_schema (columns, tables, constraints).
  3. Ejecuta los archivos SQL en orden, sentencia por sentencia, tal como lo
     haría el editor SQL de Databricks.
  4. Verifica con aserciones que cada defecto sembrado sea detectado.
  5. Revisa "lint": docstring + tooltip en cada consulta y ausencia de
     patrones que el editor de Databricks confunde con parámetros.

Uso:
  python ejecutar_pruebas.py            # ANSI on (por defecto)
  python ejecutar_pruebas.py --sin-ansi # repite con ANSI off
  python ejecutar_pruebas.py --verbose  # imprime resultados de cada consulta
  python ejecutar_pruebas.py --solo=00,02,05  # sólo esos archivos (sin aserciones)

Lo que NO se puede probar localmente (específico de Databricks/Delta):
  DESCRIBE DETAIL / DESCRIBE HISTORY y la materialización con column mapping.
  Esas sentencias se omiten aquí y están marcadas en el SQL.
"""
import os
import re
import sys
import glob
import tempfile
import datetime as dt

from pyspark.sql import SparkSession

import datos_sinteticos as ds

AQUI = os.path.dirname(os.path.abspath(__file__))
DIR_SQL = os.path.join(AQUI, "..", "sql")
VERBOSE = "--verbose" in sys.argv
ANSI = "--sin-ansi" not in sys.argv

# Sentencias que sólo existen en Databricks/Delta: se omiten en local.
OMITIR = [re.compile(p, re.I | re.S) for p in [
    r"^\s*DESCRIBE\s+(DETAIL|HISTORY)\b",
]]


# ─────────────────────────────────────────────────────────────────────────────
# Partidor de sentencias SQL (respeta comentarios, strings y backticks)
# ─────────────────────────────────────────────────────────────────────────────
def _escanear(texto):
    """Genera (tipo, trozo) con tipo en {'coment', 'str', 'pyc', 'cod'}."""
    i, n = 0, len(texto)
    while i < n:
        c = texto[i]
        if texto.startswith("--", i):
            j = texto.find("\n", i)
            j = n if j == -1 else j
            yield "coment", texto[i:j]
            i = j
            continue
        if texto.startswith("/*", i):
            j = texto.find("*/", i + 2)
            j = n if j == -1 else j + 2
            yield "coment", texto[i:j]
            i = j
            continue
        if c in ("'", '"', "`"):
            j = i + 1
            while j < n:
                if texto[j] == "\\" and c != "`":
                    j += 2
                    continue
                if texto[j] == c:
                    if c == "`" and j + 1 < n and texto[j + 1] == "`":
                        j += 2
                        continue
                    break
                j += 1
            yield "str", texto[i:j + 1]
            i = j + 1
            continue
        if c == ";":
            yield "pyc", c
            i += 1
            continue
        yield "cod", c
        i += 1


def partir_sql(texto):
    sentencias, actual = [], []
    for tipo, trozo in _escanear(texto):
        if tipo == "pyc":
            sentencias.append("".join(actual))
            actual = []
        else:
            actual.append(trozo)
    sentencias.append("".join(actual))
    return [s for s in sentencias if quitar_comentarios(s).strip()]


def quitar_comentarios(s):
    return "".join(t if k != "coment" else " " for k, t in _escanear(s))


def solo_codigo(s):
    """Quita comentarios y reemplaza strings por '' (para lint)."""
    return "".join(" " if k == "coment" else ("''" if k == "str" and t.startswith("'") else t)
                   for k, t in _escanear(s))


_ULTIMA = ["?"]


def etiqueta(s):
    m = re.findall(r"\[([A-Z][A-Z0-9]*\.[0-9]{2}[a-z0-9]*)\]", s)
    if m:
        _ULTIMA[0] = m[0]
    return _ULTIMA[0]


# ─────────────────────────────────────────────────────────────────────────────
# Lint: docstring + tooltip por consulta y patrones peligrosos
# ─────────────────────────────────────────────────────────────────────────────
def lint(archivo, texto):
    problemas = []
    bloques = re.split(r"\n(?=/\* ─|/\* ═)", texto)
    for b in bloques:
        cuerpo = quitar_comentarios(b)
        tiene_select = re.search(r"\bSELECT\b", cuerpo, re.I)
        if b.startswith("/*") and tiene_select:
            if "DOCSTRING" not in b or "TOOLTIP" not in b:
                problemas.append(f"{archivo}: bloque {etiqueta(b)} sin DOCSTRING/TOOLTIP")
    # ":palabra" fuera de strings/comentarios = parámetro del editor Databricks
    sin_str = solo_codigo(texto)
    for m in re.finditer(r"(?<![:\w]):[A-Za-z_]\w*", sin_str):
        problemas.append(f"{archivo}: posible marcador de parámetro '{m.group(0)}'")
    if "{{" in sin_str:
        problemas.append(f"{archivo}: contiene '{{{{' (parámetro legacy)")
    return problemas


# ─────────────────────────────────────────────────────────────────────────────
# Entorno simulado
# ─────────────────────────────────────────────────────────────────────────────
def crear_entorno(spark):
    spark.sql("DROP DATABASE IF EXISTS dq_prueba CASCADE")
    spark.sql("DROP DATABASE IF EXISTS information_schema CASCADE")
    spark.sql("CREATE DATABASE dq_prueba")
    spark.sql("CREATE DATABASE information_schema")
    spark.createDataFrame(ds.filas_clientes(), ds.esquema_clientes()) \
        .write.mode("overwrite").format("parquet").saveAsTable("dq_prueba.clientes")
    spark.createDataFrame(ds.filas_ventas(), ds.esquema_ventas()) \
        .write.mode("overwrite").format("parquet").saveAsTable("dq_prueba.ventas")
    # tabla "todo string" para la capa 0
    spark.sql("""CREATE TABLE dq_prueba.landing_txt USING parquet AS
                 SELECT CAST(id_cliente AS STRING) AS id_cliente,
                        CAST(fecha_alta AS STRING) AS fecha_registro,
                        CAST(monto AS STRING) AS monto_total,
                        CAST(id_cliente AS DOUBLE) AS cod_cliente
                 FROM dq_prueba.clientes""")

    cols, tabs = [], []
    ahora = dt.datetime(2026, 10, 1)
    for t in ["clientes", "ventas", "landing_txt"]:
        for pos, c in enumerate(spark.table(f"dq_prueba.{t}").schema.fields):
            simple = c.dataType.simpleString()
            cols.append(("spark_catalog", "dq_prueba", t, c.name, pos, "YES",
                         simple, re.split(r"[<(]", simple)[0].upper(),
                         None if c.name != "id_cliente" else "Identificador del cliente"))
        tabs.append(("spark_catalog", "dq_prueba", t, "MANAGED", "DELTA",
                     dt.datetime(2024, 1, 1), ahora - dt.timedelta(days=40 if t == "ventas" else 1),
                     "Tabla de prueba" if t == "clientes" else None, "dueño@empresa.pe"))
    spark.createDataFrame(cols, "table_catalog string, table_schema string, table_name string, "
                          "column_name string, ordinal_position int, is_nullable string, "
                          "full_data_type string, data_type string, comment string") \
        .write.mode("overwrite").saveAsTable("information_schema.columns")
    spark.createDataFrame(tabs, "table_catalog string, table_schema string, table_name string, "
                          "table_type string, data_source_format string, created timestamp, "
                          "last_altered timestamp, comment string, table_owner string") \
        .write.mode("overwrite").saveAsTable("information_schema.tables")
    spark.createDataFrame(
        [("spark_catalog", "dq_prueba", "pk_clientes", "spark_catalog", "dq_prueba", "clientes", "PRIMARY KEY"),
         ("spark_catalog", "dq_prueba", "fk_ventas_cli", "spark_catalog", "dq_prueba", "ventas", "FOREIGN KEY")],
        "constraint_catalog string, constraint_schema string, constraint_name string, table_catalog string, "
        "table_schema string, table_name string, constraint_type string") \
        .write.mode("overwrite").saveAsTable("information_schema.table_constraints")
    spark.createDataFrame(
        [("spark_catalog", "dq_prueba", "pk_clientes", "spark_catalog", "dq_prueba", "clientes", "id_cliente", 1),
         ("spark_catalog", "dq_prueba", "fk_ventas_cli", "spark_catalog", "dq_prueba", "ventas", "id_cliente", 1)],
        "constraint_catalog string, constraint_schema string, constraint_name string, table_catalog string, "
        "table_schema string, table_name string, column_name string, ordinal_position int") \
        .write.mode("overwrite").saveAsTable("information_schema.key_column_usage")
    spark.createDataFrame(
        [("spark_catalog", "dq_prueba", "fk_ventas_cli", "spark_catalog", "dq_prueba", "pk_clientes")],
        "constraint_catalog string, constraint_schema string, constraint_name string, "
        "unique_constraint_catalog string, unique_constraint_schema string, unique_constraint_name string") \
        .write.mode("overwrite").saveAsTable("information_schema.referential_constraints")


CONFIG_PRUEBA = """
SET VAR dq_catalogo = 'spark_catalog';
SET VAR dq_esquema = 'dq_prueba';
SET VAR dq_tabla = 'clientes';
SET VAR dq_columnas_clave = 'id_cliente';
SET VAR dq_expr_segmento = 'periodo';
SET VAR dq_expr_objetivo = 'target';
SET VAR dq_segmento_base = 'BASE';
SET VAR dq_segmento_actual = 'ACTUAL';
SET VAR dq_info_schema = '`spark_catalog`.information_schema';
"""


def ejecutar_archivo(spark, ruta, errores, resultados):
    texto = open(ruta, encoding="utf-8").read()
    for s in partir_sql(texto):
        et = etiqueta(s)
        cuerpo = quitar_comentarios(s).strip()
        if "dq:solo-databricks" in s or any(p.search(cuerpo) for p in OMITIR):
            print(f"   [omitida en local] {et}: {cuerpo[:60]}")
            continue
        try:
            df = spark.sql(s)
            filas = df.collect()
            resultados[et] = (df.columns, filas)
            if VERBOSE and filas:
                print(f"   {et}: {len(filas)} filas · {df.columns[:8]}")
                for f in filas[:6]:
                    print("      ", str(f)[:300])
        except Exception as e:  # noqa: BLE001
            msg = " ".join(str(e).split())[:500]
            errores.append(f"{os.path.basename(ruta)} {et}: {msg}\n      SQL: {cuerpo[:200]}")
            print(f"   ERROR {et}: {msg}")


def main():
    spark = (SparkSession.builder.master("local[4]")
             .config("spark.ui.enabled", "false")
             .config("spark.driver.memory", "3g")
             .config("spark.sql.shuffle.partitions", "8")
             .config("spark.sql.ansi.enabled", str(ANSI).lower())
             .config("spark.sql.session.timeZone", "UTC")
             .config("spark.sql.warehouse.dir", tempfile.mkdtemp(prefix="dq-warehouse-"))
             .getOrCreate())
    spark.sparkContext.setLogLevel("ERROR")
    print(f"Spark {spark.version} · ANSI={ANSI}")
    crear_entorno(spark)

    archivos = sorted(glob.glob(os.path.join(DIR_SQL, "*.sql")))
    solo = [a.split("=", 1)[1].split(",") for a in sys.argv if a.startswith("--solo=")]
    if solo:  # p.ej. --solo=00,02,05 (útil para iterar rápido; las aserciones se omiten)
        archivos = [a for a in archivos if os.path.basename(a)[:2] in solo[0]]
    errores, resultados, problemas = [], {}, []
    for ruta in archivos:
        nombre = os.path.basename(ruta)
        problemas += lint(nombre, open(ruta, encoding="utf-8").read())
        print(f"── {nombre}")
        ejecutar_archivo(spark, ruta, errores, resultados)
        if nombre.startswith("00_"):
            for s in partir_sql(CONFIG_PRUEBA):
                spark.sql(s)

    import aserciones
    fallas = []
    if not solo:
        fallas = aserciones.verificar(spark, resultados)
        # Pasada de deriva en modo FUENTES (dos orígenes arbitrarios, p.ej. time travel)
        print("── Pasada de deriva en modo FUENTES")
        for s_ in partir_sql("""
            SET VAR dq_modo_deriva = 'FUENTES';
            SET VAR dq_fuente_base = 'spark_catalog.dq_prueba.clientes WHERE periodo = \\'BASE\\'';
            SET VAR dq_fuente_actual = 'spark_catalog.dq_prueba.clientes WHERE periodo = \\'ACTUAL\\'';
        """):
            spark.sql(s_)
        resultados_fuentes = {}
        for ruta in archivos:
            if os.path.basename(ruta)[:2] == "08":
                ejecutar_archivo(spark, ruta, errores, resultados_fuentes)
        fallas += aserciones.verificar_fuentes(resultados_fuentes)
        # Segunda pasada: otra tabla, metadatos INFERIDOS, sin clave/segmento/target
        print("── Segunda pasada: dq_prueba.ventas (modo INFERIDO)")
        for s_ in partir_sql("""
            SET VAR dq_tabla = 'ventas';
            SET VAR dq_origen_metadatos = 'INFERIDO';
            SET VAR dq_columnas_clave = '';
            SET VAR dq_expr_segmento = 'NULL';
            SET VAR dq_expr_objetivo = 'NULL';
        """):
            spark.sql(s_)
        resultados_ventas = {}
        for ruta in archivos:
            if os.path.basename(ruta)[:2] in ("02", "03", "06"):
                ejecutar_archivo(spark, ruta, errores, resultados_ventas)
        fallas += aserciones.verificar_ventas(resultados_ventas)

    print("\n══ RESUMEN")
    print(f"Errores de ejecución: {len(errores)}")
    for e in errores:
        print("  ✗", e)
    print(f"Problemas de lint: {len(problemas)}")
    for p in problemas:
        print("  ✗", p)
    print(f"Aserciones fallidas: {len(fallas)}")
    for f in fallas:
        print("  ✗", f)
    ok = not (errores or problemas or fallas)
    print("RESULTADO:", "OK ✔" if ok else "CON FALLAS")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
