"""
Aserciones: cada defecto sembrado en datos_sinteticos.py debe ser detectado
por la consulta del marco que corresponde.
"""


def _filas(resultados, etiqueta):
    return resultados.get(etiqueta, ([], []))[1]


def verificar(spark, resultados):
    fallas = []

    def chk(cond, msg):
        if not cond:
            fallas.append(msg)

    def uno(sql):
        return spark.sql(sql).collect()

    def buscar(etiqueta, **filtro):
        return [f for f in _filas(resultados, etiqueta)
                if all(f.asDict().get(k) == v for k, v in filtro.items())]

    # ── Configuración (C0.10): todas las pruebas internas deben dar true
    if "C0.10" in resultados:
        cols, filas = resultados["C0.10"]
        for c in cols:
            if c.startswith("prueba_"):
                chk(filas[0][c] is True, f"C0.10 {c} no es true")
    else:
        fallas.append("C0.10 no se ejecutó")

    # ── Preparación
    r = uno("SELECT count(*) AS n FROM dq_columnas")[0].n
    chk(r == 32, f"dq_columnas debería tener 32 columnas y tiene {r}")
    r = uno("SELECT count(*) AS n FROM dq_src")[0].n
    chk(r == 4005, f"dq_src debería tener 4005 filas y tiene {r}")
    r = uno("SELECT count(*) AS n FROM dq_long")[0].n
    chk(r == 4005 * 32, f"dq_long debería tener {4005 * 32} celdas y tiene {r}")
    r = uno("SELECT familia FROM dq_columnas WHERE columna = 'attrs'")[0].familia
    chk(r == "COMPLEJO", f"attrs debería ser COMPLEJO y es {r}")

    # ── Capa 0
    h = {(f.columna, f.hallazgo) for f in _filas(resultados, "L0.03")}
    for par in [("fecha_nac_txt", "FECHA_COMO_TEXTO"), ("dni_num", "CODIGO_COMO_NUMERO"),
                ("cod_cliente", "CODIGO_EN_FLOTANTE"), ("monto_txt", "MONTO_COMO_TEXTO")]:
        chk(par in h, f"L0.03 no detectó {par}")
    chk(bool(buscar("L0.04", columna="id_cliente")), "L0.04 no detectó id_cliente con tipos distintos")
    chk(bool(buscar("L0.06", tabla="landing_txt", alerta="TABLA_SIN_PK")), "L0.06 no marcó landing_txt sin PK")
    chk(any("CONSTANTE" in f.alertas for f in buscar("L0.10", columna="constante")), "L0.10 no marcó 'constante'")

    # ── Capa 1
    al = {f.columna: set(f.alertas) for f in _filas(resultados, "L1.01")}
    esperado = {"constante": "CONSTANTE", "dni": "NULOS_DISFRAZADOS", "comentario": "SALTOS_LINEA",
                "distrito": "MOJIBAKE", "fecha_nac_txt": "NULOS_DISFRAZADOS"}
    for col, a in esperado.items():
        chk(a in al.get(col, set()), f"L1.01 no marcó {a} en {col}")
    chk("CARACTERES_INVISIBLES" in al.get("comentario", set()), "L1.01 no detectó NBSP en comentario")
    chk("LONGITUD_IRREGULAR" in al.get("dni", set()), "L1.01 no detectó DNI de 7 dígitos")
    d = _filas(resultados, "L1.05")
    chk(d and d[0].n_duplicados_exactos == 5, f"L1.05 duplicados exactos != 5: {d}")
    d = _filas(resultados, "L1.07")
    chk(d and d[0].n_claves_duplicadas == 5, f"L1.07 claves duplicadas != 5: {d}")

    # ── Capa 2
    s = {f.columna: f for f in _filas(resultados, "L2.01")}
    chk(s.get("fecha_nac_txt") and s["fecha_nac_txt"].tipo_sugerido == "fecha_dmy"
        and s["fecha_nac_txt"].diagnostico == "DOMINANTE_CON_VIOLACIONES", "L2.01 fecha_nac_txt mal diagnosticada")
    chk(s.get("ruc") and s["ruc"].tipo_sugerido == "ruc_pe", "L2.01 ruc no sugerido como ruc_pe")
    chk(s.get("telefono") and s["telefono"].tipo_sugerido == "telefono_movil_pe", "L2.01 teléfono")
    chk(s.get("activo") and s["activo"].tipo_sugerido == "booleano", "L2.01 activo no es booleano")
    viol = {f.valor_sospechoso for f in buscar("L2.02", columna="fecha_nac_txt")}
    chk({"abc", "31/02/1990"} <= viol, f"L2.02 no listó 'abc' y '31/02/1990': {viol}")
    f = buscar("L2.04", columna="fecha_nac_txt")
    chk(f and {"CONVIVEN_DMY_Y_MDY", "FECHAS_IMPOSIBLES", "MULTIFORMATO"} <= set(f[0].alertas),
        f"L2.04 alertas de fecha incompletas: {f[0].alertas if f else None}")
    f = buscar("L2.05", columna="monto_txt")
    chk(f and "MONEDA_EMBEBIDA" in f[0].alertas, "L2.05 no detectó moneda embebida")
    f = buscar("L2.06", columna="ruc")
    chk(f and f[0].n_ruc_dv_invalido > 0, "L2.06 no detectó RUC con DV inválido")
    f = buscar("L2.06", columna="dni")
    chk(f and f[0].n_dni_7_digitos > 0, "L2.06 no detectó DNI de 7 dígitos")
    chk(bool(buscar("L2.07", columna="dni_num")), "L2.07 no detectó ceros perdidos en dni_num")
    chk(not buscar("L2.07", columna="edad"), "L2.07 falso positivo en edad")

    # ── Capa 3
    f = buscar("L3.03", columna="edad")
    chk(f and {"CENTINELAS", "HEAPING_MULTIPLOS_5"} <= set(f[0].alertas), "L3.03 edad sin centinelas/heaping")
    chk(not buscar("L3.03", columna="target"), "L3.03 no debe evaluar columnas binarias")
    f = buscar("L3.04", columna="edad")
    chk(f and f[0].n_sobre_rango > 0 and f[0].n_bajo_rango > 0, "L3.04 edad fuera de rango no detectada")
    f = buscar("L3.02", columna="monto")
    chk(f and f[0].n_atipicos_extremos > 0, "L3.02 sin atípicos extremos en monto")
    f = [x for x in _filas(resultados, "L3.01") if x.columna == "ingreso"]
    chk(f and "NAN_O_INFINITO" in f[0].alertas, "L3.01 no detectó NaN en ingreso")

    # ── Capa 4
    al = {f.columna: set(f.alertas) for f in _filas(resultados, "L4.01")}
    chk({"FECHAS_FUTURAS", "CENTINELAS"} <= al.get("fecha_alta", set()), "L4.01 fecha_alta")
    chk("DESFASE_ZONA_HORARIA" in al.get("ts_evento", set()), "L4.01 no detectó 05:00 UTC")
    chk("VALORES_NO_CONVERTIBLES" in al.get("fecha_nac_txt", set()), "L4.01 fecha_nac_txt no convertibles")

    # ── Capa 5
    f = [x for x in _filas(resultados, "L5.02") if x.columna == "distrito" and x.huella == "lima"]
    chk(f and f[0].n_formas >= 3, "L5.02 no agrupó variantes de Lima")
    f = buscar("L5.03", columna="distrito", forma_rara="miraflroes")
    chk(f and f[0].marca == "PROBABLE_TYPO", "L5.03 no detectó 'Miraflroes'")

    # ── Capa 6
    f = buscar("L6.01", columna="ingreso")
    chk(f and f[0].clasificacion == "SIGNIFICATIVO", "L6.01 deriva de ingreso no detectada")
    f = buscar("L6.01", columna="edad")
    chk(f and f[0].clasificacion == "ESTABLE", "L6.01 edad debería ser estable")
    f = buscar("L6.03", columna="ingreso")
    chk(f and f[0].resultado.startswith("DISTINTAS"), "L6.03 KS no detectó deriva de ingreso")

    # ── Capa 7
    v = {(x.col_a, x.col_b): x.v_cramer for x in _filas(resultados, "L7.02")}
    chk(v.get(("target", "flag_post"), 0) >= 0.9, f"L7.02 fuga target/flag_post: {v.get(('target', 'flag_post'))}")
    f = buscar("L7.04", columna_con_faltantes="ingreso", columna_condicion="segmento", valor_condicion="C")
    chk(bool(f), "L7.04 no detectó faltantes condicionales de ingreso por segmento")
    f = buscar("L7.05", col_a="fecha_inicio", col_b="fecha_fin")
    chk(f and "violada" in (f[0].regla_probable or ""), "L7.05 no detectó fecha_inicio > fecha_fin")
    f = buscar("L7.06", determinante="cod_distrito")
    chk(f and f[0].n_con_varias_dependientes > 0, "L7.06 no detectó cod_distrito inconsistente")
    f = _filas(resultados, "L7.07")
    chk(f and abs(f[0].pct_huerfanos - 0.03) < 0.01, f"L7.07 huérfanos ~3%: {f}")

    # ── Capa 8
    est = {x.id_regla: x.estado for x in _filas(resultados, "L8.01")}
    chk(est.get("R01") == "CUMPLE", f"L8.01 R01 debería cumplir: {est.get('R01')}")
    for r_ in ["R03", "R04", "R05", "R06", "R08", "R09", "R12"]:
        chk(est.get(r_) == "FALLA", f"L8.01 {r_} debería fallar: {est.get(r_)}")
    chk(len(_filas(resultados, "L8.02")) > 0, "L8.02 sin ejemplos")
    adv = {x.id_regla: x.advertencias for x in _filas(resultados, "L8.03")}
    chk(any("NO_PORTABLE" in a for a in adv.get("R03", [])), "L8.03 R03 debió marcarse no portable")
    chk(any("NO_DETERMINISTICA" in a for a in adv.get("R06", [])), "L8.03 R06 debió marcarse no determinística")
    dims = {x.dimension for x in _filas(resultados, "L8.04")}
    chk({"COMPLETITUD", "UNICIDAD", "VALIDEZ_FORMATO", "GLOBAL"} <= dims, f"L8.04 dimensiones: {dims}")
    f = buscar("L8.06", columna="flag_post")
    chk(f and f[0].poder_predictivo.startswith("SOSPECHOSO"), "L8.06 no marcó flag_post como fuga")
    chk(not buscar("L8.06", columna="target"), "L8.06 no debe incluir el propio target")
    rec = {x.columna: x.recomendacion for x in _filas(resultados, "L8.09")}
    chk(rec.get("constante") == "EXCLUIR", "L8.09 constante debería EXCLUIR")
    chk(rec.get("target") == "TARGET", "L8.09 target mal marcado")

    return fallas


def verificar_ventas(resultados_ventas):
    """Segunda pasada: tabla ventas preparada en modo INFERIDO."""
    fallas = []
    f = [x for x in _filas(resultados_ventas, "L4.03") if x.columna == "fecha_venta"]
    if not (f and f[0].hueco_mas_largo_dias >= 11):
        fallas.append(f"L4.03 no detectó el hueco de 11 días en ventas: {f}")
    f = _filas(resultados_ventas, "P2.08")
    if not (f and f[0].origen_metadatos == "INFERIDO" and f[0].n_columnas == 4):
        fallas.append(f"Modo INFERIDO no preparó ventas correctamente: {f}")
    return fallas


def verificar_fuentes(res):
    """Deriva en modo FUENTES: debe dar lo mismo que en modo SEGMENTO."""
    fallas = []
    f = [x for x in _filas(res, "L6.01") if x.columna == "ingreso"]
    if not (f and f[0].clasificacion == "SIGNIFICATIVO" and f[0].n_base == 2005):
        fallas.append(f"L6.01 (FUENTES) deriva de ingreso no detectada: {f}")
    return fallas
