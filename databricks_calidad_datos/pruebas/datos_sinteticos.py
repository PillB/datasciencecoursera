"""
Genera datos sintéticos con defectos SEMBRADOS a propósito para probar el marco.

Cada defecto sembrado tiene una consulta del marco que lo debe detectar; las
aserciones están en ejecutar_pruebas.py. Datos 100 % ficticios (DNI/RUC/correos
inventados; los RUC se generan con dígito verificador válido o inválido a
propósito).
"""
import datetime as dt
import json
import math
import random

from pyspark.sql import types as T

N_CLIENTES = 4000
SEMILLA = 20241014


def _ruc(rnd, valido=True):
    pref = rnd.choice(["10", "20"])
    cuerpo = pref + "".join(str(rnd.randint(0, 9)) for _ in range(8))
    pesos = [5, 4, 3, 2, 7, 6, 5, 4, 3, 2]
    s = sum(int(d) * p for d, p in zip(cuerpo, pesos))
    r = 11 - (s % 11)
    dv = 0 if r == 10 else (1 if r == 11 else r)
    if not valido:
        dv = (dv + 1) % 10
    return cuerpo + str(dv)


def esquema_clientes():
    return T.StructType([
        T.StructField("id_cliente", T.LongType()),
        T.StructField("dni", T.StringType()),
        T.StructField("dni_num", T.LongType()),
        T.StructField("ruc", T.StringType()),
        T.StructField("fecha_nac_txt", T.StringType()),
        T.StructField("fecha_alta", T.DateType()),
        T.StructField("ts_evento", T.TimestampType()),
        T.StructField("monto", T.DecimalType(12, 2)),
        T.StructField("monto_txt", T.StringType()),
        T.StructField("ingreso", T.DoubleType()),
        T.StructField("distrito", T.StringType()),
        T.StructField("email", T.StringType()),
        T.StructField("telefono", T.StringType()),
        T.StructField("activo", T.StringType()),
        T.StructField("ubigeo", T.StringType()),
        T.StructField("segmento", T.StringType()),
        T.StructField("periodo", T.StringType()),
        T.StructField("edad", T.IntegerType()),
        T.StructField("target", T.IntegerType()),
        T.StructField("flag_post", T.IntegerType()),
        T.StructField("constante", T.StringType()),
        T.StructField("col con espacio", T.StringType()),
        T.StructField("año", T.IntegerType()),
        T.StructField("comentario", T.StringType()),
        T.StructField("payload", T.StringType()),
        T.StructField("tags", T.ArrayType(T.StringType())),
        T.StructField("attrs", T.MapType(T.StringType(), T.IntegerType())),
        T.StructField("info", T.StructType([T.StructField("a", T.IntegerType()),
                                            T.StructField("b", T.StringType())])),
        T.StructField("fecha_inicio", T.DateType()),
        T.StructField("fecha_fin", T.DateType()),
        T.StructField("codigo", T.StringType()),
        T.StructField("cod_distrito", T.StringType()),
    ])


def filas_clientes():
    rnd = random.Random(SEMILLA)
    distritos = ["Lima", "Miraflores", "San Isidro", "Surco", "Breña", "Jesús María"]
    cod_dist = {"Lima": "150101", "Miraflores": "150122", "San Isidro": "150131",
                "Surco": "150140", "Breña": "150105", "Jesús María": "150113"}
    filas = []
    for i in range(1, N_CLIENTES + 1):
        periodo = "BASE" if i <= N_CLIENTES // 2 else "ACTUAL"
        segmento = rnd.choice(["A", "B", "C"])
        u = rnd.random()
        # DNI texto: con ceros a la izquierda, algunos de 7 dígitos y placeholders
        dni_n = rnd.randint(1000000, 79999999)
        if u < 0.01:
            dni = "N/A"
        elif u < 0.02:
            dni = str(rnd.randint(1000000, 9999999))          # 7 dígitos (error)
        elif u < 0.025:
            dni = None
        else:
            dni = f"{dni_n:08d}"
        dni_num = dni_n                                       # código guardado como número
        ruc = _ruc(rnd, valido=rnd.random() > 0.03)
        nac = dt.date(1940, 1, 1) + dt.timedelta(days=rnd.randint(0, 25000))
        u = rnd.random()
        if u < 0.90:
            fnac = nac.strftime("%d/%m/%Y")
        elif u < 0.94:
            fnac = nac.strftime("%Y-%m-%d")
        elif u < 0.95:
            fnac = "31/02/1990"                               # fecha imposible
        elif u < 0.96:
            fnac = f"12/{rnd.randint(13, 28)}/1985"            # formato MM/dd (mezcla)
        elif u < 0.97:
            fnac = "abc"
        elif u < 0.98:
            fnac = ""
        else:
            fnac = None
        alta = dt.date(2018, 1, 1) + dt.timedelta(days=rnd.randint(0, 2400))
        u = rnd.random()
        if u < 0.02:
            alta = dt.date(1900, 1, 1)                        # centinela
        elif u < 0.03:
            alta = dt.date(2030, 6, 1)                        # futuro
        ts = dt.datetime(2023, 1, 1) + dt.timedelta(seconds=rnd.randint(0, 3600 * 24 * 600))
        if rnd.random() < 0.30:
            ts = ts.replace(hour=5, minute=0, second=0)       # medianoche Lima guardada en UTC
        monto = round(math.exp(rnd.gauss(6, 1)), 2)
        u = rnd.random()
        if u < 0.01:
            monto = -999.0                                    # centinela
        elif u < 0.015:
            monto = 9_999_999.99                              # atípico
        monto_dec = __import__("decimal").Decimal(f"{monto:.2f}")
        u = rnd.random()
        if u < 0.03:
            monto_txt = f"{monto:,.2f}"                      # separador de miles
        elif u < 0.05:
            monto_txt = f"S/ {monto:.2f}"                    # moneda
        elif u < 0.06:
            monto_txt = "abc"
        else:
            monto_txt = f"{monto:.2f}"
        base_ing = rnd.gauss(3000, 800) * (1.3 if periodo == "ACTUAL" else 1.0)
        p_nulo = 0.5 if segmento == "C" else 0.02            # faltante condicional (MAR)
        ingreso = None if rnd.random() < p_nulo else base_ing
        if ingreso is not None and rnd.random() < 0.005:
            ingreso = float("nan")
        pesos_d = [5, 2, 1, 1, 1, 1] if periodo == "BASE" else [2, 2, 2, 2, 1, 1]
        distrito = rnd.choices(distritos, weights=pesos_d)[0]
        cod_distrito = cod_dist[distrito] if rnd.random() > 0.01 else rnd.choice(list(cod_dist.values()))
        u = rnd.random()
        if u < 0.02:
            distrito = "LIMA"
        elif u < 0.03:
            distrito = " lima"
        elif u < 0.035:
            distrito = "Líma"
        elif u < 0.04:
            distrito = "BreÃ±a"                               # mojibake
        elif u < 0.045:
            distrito = "Miraflroes"                           # typo
        email = f"cliente{i}@correo.pe" if rnd.random() > 0.02 else rnd.choice(["juan@", "juan.correo.pe"])
        tel = f"9{rnd.randint(10000000, 99999999)}" if rnd.random() > 0.02 else "01-4567890"
        activo = rnd.choice(["S", "N"])
        u = rnd.random()
        if u < 0.05:
            activo = "si"
        elif u < 0.06:
            activo = "X"
        ubigeo = rnd.choice(["150101", "150122", "150131", "040101", "010101"])
        edad = rnd.randint(18, 90)
        if rnd.random() < 0.30:
            edad = 5 * round(edad / 5)                        # heaping
        u = rnd.random()
        if u < 0.01:
            edad = 999
        elif u < 0.015:
            edad = -1
        logit = -2.0 + 0.03 * (min(max(edad, 18), 90) - 50) + (0.8 if segmento == "C" else 0.0)
        target = 1 if rnd.random() < 1 / (1 + math.exp(-logit)) else 0
        flag_post = target if rnd.random() > 0.02 else 1 - target   # fuga de información
        u = rnd.random()
        palabras = rnd.choice(["hola", "cliente nuevo", "pago", "reclamo"])
        if u < 0.02:
            coment = palabras + "\nsegunda linea"
        elif u < 0.03:
            coment = palabras + " "
        elif u < 0.04:
            coment = "\t" + palabras
        elif u < 0.05:
            coment = " " + palabras + " "
        else:
            coment = palabras
        payload = json.dumps({"k": i}) if rnd.random() > 0.02 else '{"k": '
        ini = dt.date(2022, 1, 1) + dt.timedelta(days=rnd.randint(0, 600))
        fin = ini + dt.timedelta(days=rnd.randint(0, 90))
        if rnd.random() < 0.03:
            fin = ini - dt.timedelta(days=rnd.randint(1, 30))  # fin antes de inicio
        codigo = rnd.choice(["AB-1234", "AB-5678", "CD-0001"]) if rnd.random() > 0.01 else "ab_12"
        filas.append((
            i, dni, dni_num, ruc, fnac, alta, ts, monto_dec, monto_txt, ingreso, distrito,
            email, tel, activo, ubigeo, segmento, periodo, edad, target, flag_post, "X",
            rnd.choice(["uno", "dos", None]), rnd.randint(2018, 2024), coment, payload,
            ["a", "b"], {"x": i % 3}, (i % 5, "z"), ini, fin, codigo, cod_distrito,
        ))
    filas.extend(filas[:5])                                   # 5 filas duplicadas exactas
    return filas


def esquema_ventas():
    return T.StructType([
        T.StructField("id_venta", T.LongType()),
        T.StructField("id_cliente", T.LongType()),
        T.StructField("fecha_venta", T.DateType()),
        T.StructField("monto_venta", T.DoubleType()),
    ])


def filas_ventas():
    rnd = random.Random(SEMILLA + 1)
    filas = []
    for i in range(1, 3001):
        cli = rnd.randint(1, N_CLIENTES) if rnd.random() > 0.03 else rnd.randint(90000, 99999)
        f = dt.date(2024, 1, 1) + dt.timedelta(days=rnd.randint(0, 200))
        if dt.date(2024, 3, 10) <= f <= dt.date(2024, 3, 20):
            f = dt.date(2024, 3, 9)                           # hueco de 11 días sin ventas
        filas.append((i, cli, f, round(rnd.uniform(10, 500), 2)))
    return filas
