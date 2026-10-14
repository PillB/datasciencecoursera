"""
Arnés de escenarios del modo SIN METADATOS (sin information_schema / DESCRIBE).

Ensambla, por escenario, la misma secuencia que tendrá el script final:
  00 → variables del escenario → dq_diccionario → ref_a (Zona 1 + preparación)
  → 02 desde P2.04 → 03..07 → ref_b (L6.00v2) → 08 sin L6.00 → 09 sin L7.07
  → ref_c (L0D + Capa D + reglas) → 10 sin L8.00/L8.02 → ref_d (L8.02v2 + LZ.01)
y verifica que cada defecto sembrado sea detectado y que no haya errores.
No se crea information_schema: si algo lo usara, fallaría.

Uso:  python ejecutar_escenarios.py [--sin-ansi] [--solo=A,B] [--verbose]
"""
import os
import sys
import glob
import tempfile

AQUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(AQUI, ".."))
sys.path.insert(0, AQUI)

from pyspark.sql import SparkSession  # noqa: E402
import ejecutar_pruebas as base  # noqa: E402  (partidor, etiquetas y lint)
import mocks_lynx as mk  # noqa: E402

DIR_SQL = os.path.join(AQUI, "..", "..", "sql")
VERBOSE = "--verbose" in sys.argv
ANSI = "--sin-ansi" not in sys.argv

SALTAR = {"P2.01", "P2.02", "P2.03", "L6.00", "L7.07", "L8.00", "L8.02"}

ESCENARIOS = {
    "A": {"tabla": "spark_catalog.lynx.tabular", "vars": {"dq_tipo_registro_objetivo": "'DETALLE'"}},
    "B": {"tabla": "spark_catalog.lynx.ancho_fijo", "vars": {
        "dq_tipo_registro_objetivo": "'DETALLE'", "dq_pos_tipo_registro": "1", "dq_len_tipo_registro": "2",
        "dq_ld_tipo_trailer": "'TRAILER'", "dq_ld_campo_conteo": "'CANT_REGISTROS'",
        "dq_ld_campo_suma_trailer": "'IMP_TOTAL'", "dq_ld_campo_suma_detalle": "'IMP_OPERACION'"}},
    "C": {"tabla": "spark_catalog.lynx.vacia", "vars": {"dq_tipo_registro_objetivo": "'DETALLE'"}},
    "D": {"tabla": "spark_catalog.lynx.delimitada", "vars": {"dq_tipo_registro_objetivo": "'DETALLE'"}},
    "E": {"tabla": "spark_catalog.lynx.ancho_fijo_limpio", "vars": {
        "dq_tipo_registro_objetivo": "'DETALLE'", "dq_pos_tipo_registro": "1", "dq_len_tipo_registro": "2",
        "dq_ld_tipo_trailer": "'TRAILER'", "dq_ld_campo_conteo": "'CANT_REGISTROS'",
        "dq_ld_campo_suma_trailer": "'IMP_TOTAL'", "dq_ld_campo_suma_detalle": "'IMP_OPERACION'"}},
    "F": {"tabla": None, "vars": {}},
    "G": {"tabla": "spark_catalog.lynx.volumen", "vars": {
        "dq_tipo_registro_objetivo": "'DETALLE'", "dq_lv_feriados": "'" + mk.FERIADOS_EXTRA_G + "'"}},
    "H": {"tabla": "spark_catalog.lynx.volumen_limpio", "vars": {
        "dq_tipo_registro_objetivo": "'DETALLE'", "dq_lv_feriados": "'" + mk.FERIADOS_EXTRA_G + "'"}},
}


def crear_datos(spark):
    spark.sql("DROP DATABASE IF EXISTS lynx CASCADE")
    spark.sql("CREATE DATABASE lynx")
    spark.createDataFrame(mk.filas_tabular(), mk.esquema_tabular()).write.saveAsTable("lynx.tabular")
    spark.createDataFrame(mk.lineas_ancho_fijo(True), mk.esquema_ancho_fijo()).write.saveAsTable("lynx.ancho_fijo")
    spark.createDataFrame(mk.lineas_ancho_fijo(False), mk.esquema_ancho_fijo()).write.saveAsTable("lynx.ancho_fijo_limpio")
    spark.createDataFrame([], mk.esquema_tabular()).write.saveAsTable("lynx.vacia")
    spark.createDataFrame(mk.filas_delimitado(), mk.esquema_delimitado()).write.saveAsTable("lynx.delimitada")
    spark.createDataFrame(mk.filas_volumen(True), mk.esquema_volumen()).write.saveAsTable("lynx.volumen")
    spark.createDataFrame(mk.filas_volumen(False), mk.esquema_volumen()).write.saveAsTable("lynx.volumen_limpio")
    spark.createDataFrame(mk.DICCIONARIO, mk.esquema_diccionario()).createOrReplaceGlobalTempView("dic_lynx")


def ejecutar(spark, texto, nombre, errores, res, saltar=frozenset(), detener_en_error=False):
    for s in base.partir_sql(texto):
        et = base.etiqueta(s)
        if et in saltar or "dq:solo-databricks" in s:
            continue
        try:
            df = spark.sql(s)
            filas = df.collect()
            res.setdefault(et, []).append((df.columns, filas))
            if VERBOSE and filas:
                print(f"   {et}: {len(filas)} filas")
                for f in filas[:8]:
                    print("      ", str(f)[:260])
        except Exception as e:  # noqa: BLE001
            msg = " ".join(str(e).split())[:400]
            errores.append(f"{nombre} {et}: {msg}")
            print(f"   ERROR {nombre} {et}: {msg}")
            if detener_en_error:
                return False
    return True


def leer(n):
    return open(n, encoding="utf-8").read()


def correr_escenario(spark, clave, cfg):
    errores, res = [], {}
    sql = {os.path.basename(f)[:2]: leer(f) for f in sorted(glob.glob(os.path.join(DIR_SQL, "*.sql")))}
    ref = {k: leer(os.path.join(AQUI, f"ref_{k}_{n}.sql"))
           for k, n in [("a", "preparacion"), ("b", "deriva"), ("c", "diccionario"), ("d", "cierre"), ("e", "volumen")]}
    ejecutar(spark, sql["00"], "00", errores, res)
    spark.sql("CREATE OR REPLACE TEMP VIEW dq_diccionario AS SELECT * FROM global_temp.dic_lynx")
    # Zona 1 con la tabla sin completar (F) debe detenerse limpiamente.
    texto_a = ref["a"]
    partes = base.partir_sql(texto_a)
    corte = next(i for i, s in enumerate(partes) if "[Z1.03] ZONA 1" in s)
    ejecutar(spark, ";\n".join(partes[:corte]) + ";", "ref_a", errores, res)
    if cfg["tabla"]:
        spark.sql(f"SET VAR dq_tabla_fq_manual = '{cfg['tabla']}'")
    for k, v in cfg["vars"].items():
        try:
            spark.sql(f"SET VAR {k} = {v}")
        except Exception as e:  # noqa: BLE001
            errores.append(f"config {k}: {e}")
    ok = ejecutar(spark, ";\n".join(partes[corte:]) + ";", "ref_a", errores, res, detener_en_error=True)
    if not ok:
        return errores, res, False
    ejecutar(spark, sql["02"], "02", errores, res, SALTAR)
    for k in ["03", "04", "05", "06", "07"]:
        ejecutar(spark, sql[k], k, errores, res, SALTAR)
    ejecutar(spark, ref["b"], "ref_b", errores, res)
    ejecutar(spark, sql["08"], "08", errores, res, SALTAR)
    ejecutar(spark, sql["09"], "09", errores, res, SALTAR)
    ejecutar(spark, ref["c"], "ref_c", errores, res)
    ejecutar(spark, ref["e"], "ref_e", errores, res)
    ejecutar(spark, sql["10"], "10", errores, res, SALTAR)
    ejecutar(spark, ref["d"], "ref_d", errores, res)
    return errores, res, True


def con_columna(res, col, sin=None):
    """Filas del último resultado que tenga la columna 'col' (y no 'sin'), independiente de la etiqueta."""
    cand = [fs for v in res.values() for (cols, fs) in v if col in cols and (sin is None or sin not in cols)]
    return cand[-1] if cand else []


def filas(res, et, i=-1):
    v = res.get(et, [])
    return v[i][1] if v else []


def verificar(clave, res, completo):
    f = []

    def chk(c, m):
        if not c:
            f.append(f"[{clave}] {m}")

    if clave == "F":
        chk(not completo, "F debía detenerse en la Zona 1")
        return f
    chk(completo, "la corrida se detuvo antes de terminar")
    fmt = [r for v in res.values() for (cols, fs) in v if "formato_detectado" in cols for r in fs]
    det = fmt[-1].formato_detectado if fmt else None
    esperado = {"A": "TABULAR", "B": "ANCHO_FIJO", "C": "TABULAR", "D": "DELIMITADO", "E": "ANCHO_FIJO",
                "G": "TABULAR", "H": "TABULAR"}[clave]
    chk(det == esperado, f"formato detectado {det} != {esperado}")
    lz = filas(res, "LZ.01")
    chk(len(lz) >= 4, "LZ.01 sin bitácora de escenarios")
    if clave == "A":
        rec = {r.campo: r for r in con_columna(res, "candidatos", sin="origen") if r.campo}
        if VERBOSE:
            for r in con_columna(res, "candidatos", sin="origen"):
                print("   REC", r.campo, r.columna, r.estado, r.metodo, list(r.candidatos))
        chk(rec.get("FEC_OPERACION") and rec["FEC_OPERACION"].columna == "fecha_operacion", "FEC_OPERACION no conciliada por sinónimo")
        chk(rec.get("NRO_DOC") and rec["NRO_DOC"].columna == "numero_documento", "NRO_DOC no conciliado")
        chk(rec.get("IMP_OPERACION") and rec["IMP_OPERACION"].estado == "AMBIGUO", "IMP_OPERACION debía ser AMBIGUO")
        chk(rec.get("NOMBRE_COMERCIO") and rec["NOMBRE_COMERCIO"].estado == "NO_ENCONTRADO", "NOMBRE_COMERCIO debía faltar")
        chk(any(r.columna == "nro_tarjeta" and r.diagnostico.startswith("ENMASCARADA") for r in filas(res, "LD.10")),
            "LD.10 no detectó nro_tarjeta enmascarada")
        ld2 = {r.campo: r for r in filas(res, "LD.02")}
        chk(ld2.get("FEC_OPERACION") and ld2["FEC_OPERACION"].n_invalidos == 0, "falso positivo: fecha tipada marcada inválida")
    if clave == "B":
        ld2 = {r.campo: r for r in filas(res, "LD.02")}
        chk(ld2.get("FEC_OPERACION") and ld2["FEC_OPERACION"].n_invalidos > 0 and ld2["FEC_OPERACION"].n_fecha_centinela > 0,
            "LD.02 fechas inválidas/centinela no detectadas")
        chk(ld2.get("IMP_OPERACION") and ld2["IMP_OPERACION"].n_overpunch > 0, "LD.02 overpunch no contado")
        ld5 = {r.campo: r for r in filas(res, "LD.05")}
        chk(ld5.get("COD_MONEDA") and ld5["COD_MONEDA"].n_fuera_de_dominio > 0, "LD.05 moneda 999 no detectada")
        chk(ld5.get("TIPO_DOC") and ld5["TIPO_DOC"].n_fuera_de_dominio > 0, "LD.05 tipo_doc 9 no detectado")
        ld7 = filas(res, "LD.07")
        chk(any(getattr(r, "n_con_cr", 0) > 0 for r in ld7), "LD.07 no detectó CRLF")
        chk(any(getattr(r, "n_con_bom", 0) > 0 for r in ld7), "LD.07 no detectó BOM")
        chk(any(getattr(r, "largo", 0) == 86 for r in ld7), "LD.07 no mostró el grupo de largo 86 (layout nuevo)")
        ld8 = filas(res, "LD.08")
        chk(ld8 and getattr(ld8[0], "diferencia_conteo", None) == -1, f"LD.08 diferencia_conteo esperada -1: {ld8}")
        ld9 = filas(res, "LD.09")
        chk(any(r.grupo.startswith("largo=86") and r.campo == "COD_MONEDA" and str(r.diagnostico).startswith("DESFASE k=1")
                for r in ld9), "LD.09 no detectó desfase +1 en el layout nuevo")
        chk(any(r.grupo == "largo=85" and r.campo == "COD_MONEDA" and r.diagnostico == "ALINEADO" for r in ld9),
            "LD.09 debía ver alineado el layout normal")
        chk(not any(r.columna == "tipo_reg" for r in filas(res, "LD.10")), "LD.10 falso positivo en tipo_reg (constante por diseño)")
        l801 = {r.id_regla: r.estado for r in filas(res, "L8.01")}
        chk("FALLA" in l801.values(), "L8.01 sin reglas en FALLA")
        ex = filas(res, "L8.02v2")
        chk(ex and all("nro_tarjeta" not in str(getattr(r, "fila", "")) or '"nro_tarjeta":"9999' in str(r.fila) for r in ex),
            "L8.02v2 expuso un PAN sin enmascarar")
    if clave == "C":
        chk(any(r.escenario == "TABLA_VACIA" for r in lz), "LZ.01 no reportó TABLA_VACIA")
    if clave == "D":
        ld5 = {r.campo: r for r in filas(res, "LD.05")}
        chk(ld5.get("COD_MONEDA") and ld5["COD_MONEDA"].n_fuera_de_dominio > 0, "LD.05 (delimitado) no detectó moneda 999")
    if clave == "E":
        for r in filas(res, "LD.02"):
            chk(r.n_invalidos == 0, f"falso positivo LD.02 en {r.campo}")
        for r in filas(res, "LD.05"):
            chk(r.n_fuera_de_dominio == 0, f"falso positivo LD.05 en {r.campo}")
        for r in filas(res, "LD.09"):
            chk(r.diagnostico in ("ALINEADO",) or r.diagnostico.startswith("NO_CONCLUYENTE"), f"LD.09 falso desfase {r.campo}")
        ld8 = filas(res, "LD.08")
        chk(ld8 and getattr(ld8[0], "diferencia_conteo", None) == 0, "LD.08 debía cuadrar en el control")
    verificar_volumen(clave, res, chk)
    return f


def verificar_volumen(clave, res, chk):
    """Clave de respuestas de la Capa V (LV.*)."""
    import datetime as dt
    D = dt.date.fromisoformat
    sel = {r.seleccion: r.columna for r in filas(res, "LV.00") if r.seleccion}
    lv1 = {r.rol: r for r in filas(res, "LV.01")}
    lv2 = [r for r in filas(res, "LV.02")]
    lv3 = [r for r in filas(res, "LV.03")]
    lv7 = [r for r in filas(res, "LV.07")]
    lv8 = [r for r in con_columna(res, "pct_vacios")]
    chk(len(lv1) == 3, "LV.01 debía devolver 3 relojes")
    if clave == "A":
        chk(sel.get("ELEGIDA_CARGA") == "fecha_carga", f"LV.00 carga esperada fecha_carga: {sel}")
        chk("CARGA_UNICA" in (lv1["CARGA"].diagnostico or []), "LV.01 debía ver CARGA_UNICA (snapshot)")
    if clave == "B":
        chk(sel.get("ELEGIDA_LOTE") == "archivo", f"LV.00 lote esperado archivo (columna conservada en ancho fijo): {sel}")
        chk(sel.get("ELEGIDA_NEGOCIO") == "fec_operacion", f"LV.00 negocio esperado fec_operacion: {sel}")
    if clave == "C":
        chk(all("NO_DISPONIBLE" in (r.diagnostico or []) for r in lv1.values()), "LV.01 en tabla vacía debía decir NO_DISPONIBLE")
    if clave in ("G", "H"):
        chk(sel == {"ELEGIDA_CARGA": "fecactualizacion", "ELEGIDA_NEGOCIO": "fec_operacion", "ELEGIDA_LOTE": "nombre_archivo"},
            f"LV.00 selección inesperada: {sel}")
        lv5 = filas(res, "LV.05")
        chk(lv5 and lv5[0].lag_p50 == 1, f"LV.05 latencia p50 esperada 1: {lv5}")
    if clave == "G":
        e = {(r.rol, r.fecha): r for r in lv2}

        def tiene(rol, f, est, etq=None):
            r = e.get((rol, D(f)))
            ok = r is not None and r.estado == est and (etq is None or etq in (r.etiquetas or []))
            chk(ok, f"LV.02 {rol} {f}: esperado {est}{'+' + etq if etq else ''}, obtenido "
                    f"{(r.estado, r.etiquetas) if r else None}")
        tiene("CARGA", "2024-03-13", "HUECO", "SIGUIENTE_ALTO")
        tiene("CARGA", "2024-03-14", "ALTO", "PREVIO_HUECO")
        tiene("CARGA", "2024-04-17", "BAJO")
        tiene("CARGA", "2024-05-23", "ALTO")
        tiene("CARGA", "2024-06-30", "RECIENTE_POSIBLE_INCOMPLETO")
        tiene("NEGOCIO", "2024-05-01", "BAJO", "FERIADO")
        tiene("NEGOCIO", "2024-03-28", "BAJO", "FERIADO")
        tiene("NEGOCIO", "2024-05-21", "ALTO")
        r3 = {(r.rol, r.desde): r for r in lv3}
        x = r3.get(("CARGA", D("2024-06-10")))
        chk(x is not None and x.dias == 3 and x.clasificacion == "HUECO_HABIL", f"LV.03 hueco 10-12 jun: {x}")
        x = r3.get(("CARGA", D("2024-03-13")))
        chk(x is not None and x.clasificacion == "HUECO_CON_RECUPERACION", f"LV.03 hueco 13 mar: {x}")
        lv4 = {(r.rol, r.mes): r for r in filas(res, "LV.04")}
        chk(lv4.get(("CARGA", "2024-06")) is not None and lv4[("CARGA", "2024-06")].dias_con_datos == 27,
            f"LV.04 junio CARGA días con datos esperado 27: {lv4.get(('CARGA', '2024-06'))}")
        lv6 = {(r.tipo, r.fecha): r for r in filas(res, "LV.06")}
        chk(("POR_FECHA_NEGOCIO", D("2024-05-21")) in lv6, f"LV.06 no detectó la carga repetida del 21-may: {list(lv6)[:6]}")
        m7 = {r.lote: r.marcas for r in lv7}
        chk("DUPLICADO_EXACTO" in m7.get("LYNX_20240522.txt", []) and "DUPLICADO_EXACTO" in m7.get("LYNX_20240522_REENVIO.txt", []),
            f"LV.07 duplicado exacto: {m7.get('LYNX_20240522.txt')}, {m7.get('LYNX_20240522_REENVIO.txt')}")
        chk("TAMANO_BAJO" in m7.get("LYNX_20240417.txt", []), f"LV.07 tamaño bajo 17-abr: {m7.get('LYNX_20240417.txt')}")
        chk(any(x.startswith("CARGADO_EN_OTRA_FECHA") for x in m7.get("LYNX_20240313.txt", [])),
            f"LV.07 carga diferida 13-mar: {m7.get('LYNX_20240313.txt')}")
        chk(any(str(r.periodo) == "2024-02-20" and r.columna == "cod_moneda" and r.diagnostico == "VACIO_ANOMALO" for r in lv8),
            f"LV.08 no detectó cod_moneda vacío el 20-feb: {[(str(r.periodo), r.columna) for r in lv8][:6]}")
    if clave == "H":
        fer = {D(x) for x in ["2024-01-01", "2024-03-28", "2024-03-29", "2024-05-01", "2024-06-07", "2024-06-29"]}
        for r in lv2:
            explicado = bool(set(r.etiquetas or []) & {"FERIADO", "DIA_POST_FERIADO"}) or r.estado == "RECIENTE_POSIBLE_INCOMPLETO"
            chk(explicado, f"LV.02 falso positivo en control: {r.rol} {r.fecha} {r.estado} {r.etiquetas}")
        chk(not [r for r in lv3 if r.clasificacion == "HUECO_HABIL"], "LV.03 falso hueco hábil en control")
        for r in lv7:
            ok = r.lote != "(OMITIDO)" and r.marcas == ["TAMANO_BAJO"] and r.fecha_nombre is not None and \
                (r.fecha_nombre - dt.timedelta(days=1)) in fer
            chk(ok, f"LV.07 falso positivo en control: {r.lote} {r.marcas}")
        chk(not lv8, f"LV.08 falso positivo en control: {[(str(r.periodo), r.columna) for r in lv8][:5]}")


def main():
    spark = (SparkSession.builder.master("local[4]")
             .config("spark.ui.enabled", "false").config("spark.driver.memory", "3g")
             .config("spark.sql.shuffle.partitions", "8")
             .config("spark.sql.ansi.enabled", str(ANSI).lower())
             .config("spark.sql.session.timeZone", "UTC")
             .config("spark.sql.warehouse.dir", tempfile.mkdtemp(prefix="dq-sinmeta-"))
             .getOrCreate())
    spark.sparkContext.setLogLevel("ERROR")
    print(f"Spark {spark.version} · ANSI={ANSI}")
    crear_datos(spark)
    solo = [a.split("=", 1)[1].split(",") for a in sys.argv if a.startswith("--solo=")]
    claves = solo[0] if solo else list(ESCENARIOS)
    problemas = []
    for f_ in glob.glob(os.path.join(AQUI, "ref_*.sql")):
        problemas += base.lint(os.path.basename(f_), leer(f_))
    todas = []
    for c in claves:
        print(f"══ Escenario {c}")
        errores, res, completo = correr_escenario(spark, c, ESCENARIOS[c])
        if c == "F":
            esperado = [e for e in errores if "[DQ-Z1]" in e]
            otros = [e for e in errores if "[DQ-Z1]" not in e]
            todas += [f"[F] error inesperado: {e}" for e in otros]
            if not esperado:
                todas.append("[F] no se detuvo con el mensaje [DQ-Z1]")
        else:
            todas += [f"[{c}] {e}" for e in errores]
        todas += verificar(c, res, completo)
    print("\n══ RESUMEN SIN METADATOS")
    print(f"Lint: {len(problemas)}")
    for p in problemas:
        print("  ✗", p)
    print(f"Fallas: {len(todas)}")
    for t in todas:
        print("  ✗", t)
    ok = not (problemas or todas)
    print("RESULTADO:", "OK ✔" if ok else "CON FALLAS")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
