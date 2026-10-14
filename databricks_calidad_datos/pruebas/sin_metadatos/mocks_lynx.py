"""
Datos y diccionario simulados de una trama tipo "Lynx" (100 % ficticios) para
probar el modo sin metadatos. Cada escenario siembra defectos conocidos; el
arnés verifica que la consulta indicada los detecte.

Escenarios:
  A  tabular con nombres cambiados, columna faltante, extra, ambigua, tipada y enmascarada
  B  ancho fijo con cabecera/detalle/trailer y defectos (BOM, CRLF, recorte, desfase, etc.)
  C  tabla vacía
  D  delimitada por '|' en una sola columna
  E  ancho fijo limpio (control de falsos positivos)
"""
import datetime as dt
import decimal
import random

from pyspark.sql import types as T

SEMILLA = 7

# (tipo_registro, codigo, orden, campo, pos, long, tipo_dato, familia, dec, signo, formato, oblig, dominio, pii, filler, desc)
DICCIONARIO = [
    ("CABECERA", "01", 1, "TIPO_REG", 1, 2, "N", "NUMERICO", None, False, None, True, ["01"], False, False, "Tipo de registro"),
    ("CABECERA", "01", 2, "FEC_PROCESO", 3, 8, "Fecha AAAAMMDD", "FECHA", None, False, "AAAAMMDD", True, None, False, False, "Fecha de proceso"),
    ("CABECERA", "01", 3, "COD_ENTIDAD", 11, 4, "N", "NUMERICO", None, False, None, True, None, False, False, "Código de entidad"),
    ("CABECERA", "01", 4, "FILLER", 15, 71, "X(71)", "TEXTO", None, False, None, False, None, False, True, "Relleno"),
    ("DETALLE", "02", 1, "TIPO_REG", 1, 2, "N", "NUMERICO", None, False, None, True, ["02"], False, False, "Tipo de registro"),
    ("DETALLE", "02", 2, "NRO_TARJETA", 3, 16, "9(16)", "NUMERICO", None, False, None, True, None, True, False, "Número de tarjeta"),
    ("DETALLE", "02", 3, "FEC_OPERACION", 19, 8, "Fecha AAAAMMDD", "FECHA", None, False, "AAAAMMDD", True, None, False, False, "Fecha de la operación"),
    ("DETALLE", "02", 4, "HORA_OPERACION", 27, 6, "Hora HHMMSS", "HORA", None, False, "HHMMSS", False, None, False, False, "Hora"),
    ("DETALLE", "02", 5, "IMP_OPERACION", 33, 13, "S9(11)V99", "IMPORTE", 2, True, None, True, None, False, False, "Importe con signo"),
    ("DETALLE", "02", 6, "COD_MONEDA", 46, 3, "N", "NUMERICO", None, False, None, True, ["604", "840"], False, False, "Moneda ISO"),
    ("DETALLE", "02", 7, "TIPO_DOC", 49, 1, "N", "NUMERICO", None, False, None, False, ["1", "4", "6"], False, False, "Tipo de documento"),
    ("DETALLE", "02", 8, "NRO_DOC", 50, 11, "AN", "TEXTO", None, False, None, False, None, True, False, "Número de documento"),
    ("DETALLE", "02", 9, "NOMBRE_COMERCIO", 61, 20, "X(20)", "TEXTO", None, False, None, False, None, False, False, "Comercio"),
    ("DETALLE", "02", 10, "ESTADO", 81, 1, "A", "TEXTO", None, False, None, True, ["A", "R"], False, False, "A=Aprobada, R=Rechazada"),
    ("DETALLE", "02", 11, "FILLER", 82, 4, "X(4)", "TEXTO", None, False, None, False, None, False, True, "Relleno"),
    ("TRAILER", "99", 1, "TIPO_REG", 1, 2, "N", "NUMERICO", None, False, None, True, ["99"], False, False, "Tipo de registro"),
    ("TRAILER", "99", 2, "CANT_REGISTROS", 3, 9, "9(9)", "NUMERICO", None, False, None, True, None, False, False, "Cantidad de detalles"),
    ("TRAILER", "99", 3, "IMP_TOTAL", 12, 15, "S9(13)V99", "IMPORTE", 2, True, None, True, None, False, False, "Suma de importes"),
    ("TRAILER", "99", 4, "FILLER", 27, 59, "X(59)", "TEXTO", None, False, None, False, None, False, True, "Relleno"),
]
LARGO = 85


def esquema_diccionario():
    return T.StructType([
        T.StructField("tipo_registro", T.StringType()), T.StructField("codigo_registro", T.StringType()),
        T.StructField("orden", T.IntegerType()), T.StructField("campo", T.StringType()),
        T.StructField("pos_inicio", T.IntegerType()), T.StructField("longitud", T.IntegerType()),
        T.StructField("tipo_dato", T.StringType()), T.StructField("familia_declarada", T.StringType()),
        T.StructField("decimales", T.IntegerType()), T.StructField("con_signo", T.BooleanType()),
        T.StructField("formato", T.StringType()), T.StructField("obligatorio", T.BooleanType()),
        T.StructField("valores_permitidos", T.ArrayType(T.StringType())), T.StructField("pii", T.BooleanType()),
        T.StructField("es_filler", T.BooleanType()), T.StructField("descripcion", T.StringType()),
    ])


def _overpunch(n_centavos, ancho):
    """Entero con signo → texto zoned decimal (último dígito con overpunch)."""
    neg = n_centavos < 0
    s = str(abs(n_centavos)).zfill(ancho)
    ult = int(s[-1])
    car = ("}JKLMNOPQR" if neg else "{ABCDEFGHI")[ult]
    return s[:-1] + car


def _pan(rnd):
    base = [4] + [rnd.randint(0, 9) for _ in range(14)]
    tot = 0
    for i, d in enumerate(reversed(base)):
        d2 = d * 2 if i % 2 == 0 else d
        tot += d2 - 9 if d2 > 9 else d2
    return "".join(map(str, base)) + str((10 - tot % 10) % 10)


def _detalles(rnd, n, defectos=True):
    filas = []
    for i in range(n):
        f = dt.date(2024, 5, 1) + dt.timedelta(days=rnd.randint(0, 59))
        cent = rnd.randint(100, 500000) * (-1 if rnd.random() < 0.05 else 1)
        reg = {
            "TIPO_REG": "02", "NRO_TARJETA": _pan(rnd), "FEC_OPERACION": f.strftime("%Y%m%d"),
            "HORA_OPERACION": f"{rnd.randint(0, 23):02d}{rnd.randint(0, 59):02d}{rnd.randint(0, 59):02d}",
            "centavos": cent, "COD_MONEDA": rnd.choice(["604", "604", "840"]),
            "TIPO_DOC": rnd.choice(["1", "1", "6"]), "NRO_DOC": f"{rnd.randint(10000000, 79999999)}",
            "NOMBRE_COMERCIO": rnd.choice(["TIENDA SAC", "PEÑA SAC", "BODEGA LIMA"]),
            "ESTADO": rnd.choice(["A", "A", "R"]), "archivo": "LYNX_20240501.txt",
        }
        if defectos:
            u = rnd.random()
            if u < 0.01:
                reg["FEC_OPERACION"] = "20240231"           # fecha imposible
            elif u < 0.02:
                reg["FEC_OPERACION"] = "00000000"           # centinela
            elif u < 0.03:
                reg["COD_MONEDA"] = "999"                   # fuera de dominio
            elif u < 0.04:
                reg["TIPO_DOC"] = "9"                       # fuera de dominio
            elif u < 0.05:
                reg["ESTADO"] = " "                         # obligatorio vacío
            if i >= n * 0.85:
                reg["archivo"] = "LYNX_20240601.txt"        # layout nuevo (importe de 14)
        filas.append(reg)
    return filas


def _linea_detalle(r, ancho_importe=13):
    return ("02" + r["NRO_TARJETA"] + r["FEC_OPERACION"] + r["HORA_OPERACION"]
            + _overpunch(r["centavos"], ancho_importe) + r["COD_MONEDA"] + r["TIPO_DOC"]
            + r["NRO_DOC"].ljust(11) + r["NOMBRE_COMERCIO"].ljust(20) + r["ESTADO"] + " " * 4)


def lineas_ancho_fijo(defectos=True):
    rnd = random.Random(SEMILLA if defectos else SEMILLA + 1)
    det = _detalles(rnd, 3000, defectos)
    cab = ("01" + "20240702" + "0042").ljust(LARGO)
    lineas = []
    lineas.append(("﻿" + cab) if defectos else cab)
    if defectos:
        lineas.append(cab)                                   # cabecera duplicada
    for r in det:
        ancho = 14 if r["archivo"] == "LYNX_20240601.txt" else 13
        lineas.append(_linea_detalle(r, ancho))
    total = sum(r["centavos"] for r in det)
    cant = len(det) + (1 if defectos else 0)                 # trailer descuadrado en 1
    lineas.append(("99" + str(cant).zfill(9) + _overpunch(total, 15)).ljust(LARGO))
    filas = []
    for k, l in enumerate(lineas):
        if defectos and 0 < k < len(lineas) - 1:
            u = rnd.random()
            if u < 0.30:
                l = l + "\r"                                 # CRLF
            elif u < 0.40:
                l = l.rstrip(" ")                            # espacios finales recortados
        archivo = det[k - 2]["archivo"] if 2 <= k < len(lineas) - 1 and defectos else "LYNX_20240501.txt"
        filas.append((l, archivo))
    return filas


def esquema_ancho_fijo():
    return T.StructType([T.StructField("value", T.StringType()), T.StructField("archivo", T.StringType())])


def filas_tabular():
    rnd = random.Random(SEMILLA + 2)
    det = _detalles(rnd, 2000, True)
    filas = []
    for r in det:
        imp = decimal.Decimal(r["centavos"]) / 100
        filas.append(("02", "************" + r["NRO_TARJETA"][-4:],
                      dt.date(int(r["FEC_OPERACION"][:4]), 5, 1) if r["FEC_OPERACION"][:4] != "0000" else None,
                      r["HORA_OPERACION"], imp, imp, r["COD_MONEDA"], r["COD_MONEDA"],
                      r["TIPO_DOC"], r["NRO_DOC"], r["ESTADO"], None, dt.datetime(2024, 7, 2, 1, 0)))
    return filas


def esquema_tabular():
    return T.StructType([
        T.StructField("tipo_reg", T.StringType()), T.StructField("nro_tarjeta", T.StringType()),
        T.StructField("fecha_operacion", T.DateType()), T.StructField("hora_operacion", T.StringType()),
        T.StructField("importe_operacion", T.DecimalType(15, 2)), T.StructField("monto_operacion", T.DecimalType(15, 2)),
        T.StructField("cod_moneda", T.StringType()), T.StructField("codigo_moneda", T.StringType()),
        T.StructField("tipo_documento", T.StringType()), T.StructField("numero_documento", T.StringType()),
        T.StructField("estado", T.StringType()), T.StructField("_rescued_data", T.StringType()),
        T.StructField("fecha_carga", T.TimestampType()),
    ])


def filas_delimitado():
    rnd = random.Random(SEMILLA + 3)
    det = _detalles(rnd, 1500, True)
    return [("|".join(["02", r["NRO_TARJETA"], r["FEC_OPERACION"], r["HORA_OPERACION"],
                       _overpunch(r["centavos"], 13), r["COD_MONEDA"], r["TIPO_DOC"], r["NRO_DOC"],
                       r["NOMBRE_COMERCIO"], r["ESTADO"], ""]),) for r in det]


def esquema_delimitado():
    return T.StructType([T.StructField("linea", T.StringType())])


# ── Escenarios G / H: volumen por fecha de carga (Capa V) ──────────────────
# Carga diaria D con las operaciones del día anterior (95%) y un 5% tardío
# (llega en D+1). Volumen de negocio: lun-vie ≈300, sáb ≈150, dom ≈60;
# feriados al 20%. Defectos sembrados SOLO en G (clave de respuestas):
#   G1 2024-03-13 carga no ejecutada; su archivo LYNX_20240313 se carga el 14
#   G2 2024-04-17 carga parcial (25%) nunca recuperada
#   G3 LYNX_20240522 reenviado como LYNX_20240522_REENVIO y cargado el 23
#   G4 2024-06-10..12 sin cargas (nunca recuperadas)
#   G5 2024-02-20 cod_moneda vacío en toda la carga
#   G6 2024-06-30 (último día) sólo 40% (datos aún en camino)
FERIADOS_2024 = {dt.date(2024, 1, 1), dt.date(2024, 3, 28), dt.date(2024, 3, 29), dt.date(2024, 5, 1),
                 dt.date(2024, 6, 7), dt.date(2024, 6, 29)}
FERIADOS_EXTRA_G = "2024-03-28,2024-03-29"   # Semana Santa: no está en la lista fija


def filas_volumen(defectos=True):
    rnd = random.Random(SEMILLA + (10 if defectos else 11))
    ini, fin = dt.date(2024, 1, 1), dt.date(2024, 6, 29)       # fechas de negocio
    por_carga = {}
    b = ini
    while b <= fin:
        base = {5: 150, 6: 60}.get(b.weekday(), 300)
        n = int(base * rnd.uniform(0.92, 1.08) * (0.2 if b in FERIADOS_2024 else 1))
        for _ in range(n):
            d = b + dt.timedelta(days=1 if rnd.random() < 0.95 else 2)
            por_carga.setdefault(d, []).append(b)
        b += dt.timedelta(days=1)
    filas = []

    def fila(b, d_carga, archivo, moneda_vacia=False):
        cent = rnd.randint(100, 500000)
        ts = dt.datetime.combine(d_carga, dt.time(6, rnd.randint(0, 59), rnd.randint(0, 59)))
        return ["02", "************" + str(rnd.randint(1000, 9999)), b.strftime("%Y%m%d"),
                f"{rnd.randint(0, 23):02d}{rnd.randint(0, 59):02d}00", decimal.Decimal(cent) / 100,
                "" if moneda_vacia else rnd.choice(["604", "604", "840"]), rnd.choice(["1", "1", "6"]),
                f"{rnd.randint(10000000, 79999999)}", rnd.choice(["TIENDA SAC", "PEÑA SAC", "BODEGA LIMA"]),
                rnd.choice(["A", "A", "R"]), ts, archivo]

    for d in sorted(por_carga):
        negocios = por_carga[d]
        archivo = f"LYNX_{d:%Y%m%d}.txt"
        d_carga = d
        if defectos:
            if d == dt.date(2024, 3, 13):
                d_carga = dt.date(2024, 3, 14)                               # G1
            if d == dt.date(2024, 4, 17):
                negocios = negocios[: len(negocios) // 4]                    # G2
            if dt.date(2024, 6, 10) <= d <= dt.date(2024, 6, 12):
                continue                                                     # G4
            if d == dt.date(2024, 6, 30):
                negocios = negocios[: int(len(negocios) * 0.4)]              # G6
        nuevas = [fila(b, d_carga, archivo, defectos and d == dt.date(2024, 2, 20)) for b in negocios]   # G5
        filas += nuevas
        if defectos and d == dt.date(2024, 5, 22):                           # G3
            ts = dt.datetime(2024, 5, 23, 9, 0)
            filas += [r[:10] + [ts, "LYNX_20240522_REENVIO.txt"] for r in nuevas]
    return [tuple(r) for r in filas]


def esquema_volumen():
    return T.StructType([
        T.StructField("tipo_reg", T.StringType()), T.StructField("nro_tarjeta", T.StringType()),
        T.StructField("fec_operacion", T.StringType()), T.StructField("hora_operacion", T.StringType()),
        T.StructField("imp_operacion", T.DecimalType(15, 2)), T.StructField("cod_moneda", T.StringType()),
        T.StructField("tipo_doc", T.StringType()), T.StructField("nro_doc", T.StringType()),
        T.StructField("nombre_comercio", T.StringType()), T.StructField("estado", T.StringType()),
        T.StructField("fecactualizacion", T.TimestampType()), T.StructField("nombre_archivo", T.StringType()),
    ])
