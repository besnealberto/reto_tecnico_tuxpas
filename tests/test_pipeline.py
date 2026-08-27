"""Tests mínimos de confiabilidad del pipeline de CaféNorte.

No buscan cobertura exhaustiva: verifican los puntos donde un pipeline puede
"correr sin error pero producir números incorrectos" (el red flag explícito
del reto) -- pérdida silenciosa de filas al conciliar fuentes, signo de las
notas de crédito, y duplicados.
"""


def test_no_se_pierden_filas_de_ventas_fisicas(con):
    """fact_ventas_fisico debe explicar el 100% de las filas de sales.csv:
    las que entran (I, E) más las que se excluyen a propósito (P, N, T)."""
    total_raw = con.execute("SELECT COUNT(*) FROM stg_sales").fetchone()[0]
    incluidas = con.execute("SELECT COUNT(*) FROM fact_ventas_fisico").fetchone()[0]
    excluidas_a_proposito = con.execute(
        "SELECT COUNT(*) FROM stg_sales WHERE tipo_comprobante IN ('P','N','T')"
    ).fetchone()[0]
    assert incluidas + excluidas_a_proposito == total_raw


def test_no_hay_perdida_silenciosa_de_inventario(con):
    """Regresión: dim_producto debe cubrir TODO sku_erp del catálogo/snapshots,
    incluyendo los que nunca se vendieron por un canal mapeado. La primera
    versión del modelo los omitía y fact_inventario perdía ~14% de sus filas
    sin ningún error visible."""
    total_raw_snapshots = con.execute("SELECT COUNT(*) FROM stg_snapshots").fetchone()[0]
    total_fact_inventario = con.execute("SELECT COUNT(*) FROM fact_inventario").fetchone()[0]
    assert total_fact_inventario == total_raw_snapshots


def test_no_hay_ventas_duplicadas(con):
    dup_fisico = con.execute(
        "SELECT COUNT(*) - COUNT(DISTINCT venta_id) FROM fact_ventas_fisico"
    ).fetchone()[0]
    dup_ecommerce = con.execute(
        "SELECT COUNT(*) - COUNT(DISTINCT venta_id) FROM fact_ventas_ecommerce"
    ).fetchone()[0]
    assert dup_fisico == 0
    assert dup_ecommerce == 0


def test_notas_de_credito_restan_no_suman(con):
    """tipo_comprobante='E' llega en positivo en la fuente; el modelo debe
    invertir el signo, nunca sumarlo tal cual (ver README §Supuestos, punto 1)."""
    fila = con.execute(
        "SELECT monto FROM stg_sales WHERE tipo_comprobante = 'E' LIMIT 1"
    ).fetchone()
    assert fila is not None and fila[0] > 0, "la fuente debe traer montos positivos para E"

    neto = con.execute(
        "SELECT monto_neto_mxn FROM fact_ventas_fisico WHERE tipo_comprobante = 'E' LIMIT 1"
    ).fetchone()[0]
    assert neto < 0


def test_conversion_moneda_mxn_no_se_altera(con):
    """Las órdenes ya en MXN no deben pasar por el tipo de cambio (rate=1)."""
    fila = con.execute(
        """
        SELECT e.amount, fv.monto_neto_mxn
        FROM stg_ecommerce e
        JOIN fact_ventas_ecommerce fv ON fv.venta_id = e.order_id
        WHERE e.currency = 'MXN'
        LIMIT 1
        """
    ).fetchone()
    amount, monto_neto = fila
    assert monto_neto == amount


def test_conversion_moneda_usd_aplica_tipo_de_cambio(con):
    fila = con.execute(
        """
        SELECT e.amount, e.fecha, fv.monto_neto_mxn
        FROM stg_ecommerce e
        JOIN fact_ventas_ecommerce fv ON fv.venta_id = e.order_id
        WHERE e.currency = 'USD'
        LIMIT 1
        """
    ).fetchone()
    amount, fecha, monto_neto = fila
    rate = con.execute(
        "SELECT rate_to_mxn FROM stg_exchange_rates WHERE currency='USD' AND fecha = ?",
        [fecha],
    ).fetchone()[0]
    assert round(amount * rate, 2) == monto_neto


def test_valores_na_de_inventario_se_vuelven_null_no_cero(con):
    """cantidad_en_stock='N/A' en la fuente debe quedar NULL, nunca 0 -- un 0
    fabricado inflaría artificialmente los conteos de quiebre de stock."""
    n_null = con.execute(
        "SELECT COUNT(*) FROM stg_snapshots WHERE cantidad_en_stock IS NULL"
    ).fetchone()[0]
    assert n_null > 0  # se sabe que la fuente trae 'N/A' -- si esto es 0, algo cambió upstream
    n_cero_literal = con.execute(
        "SELECT COUNT(*) FROM raw_snapshots WHERE TRY_CAST(cantidad_en_stock AS INTEGER) = 0"
    ).fetchone()[0]
    n_cero_tabla = con.execute(
        "SELECT COUNT(*) FROM stg_snapshots WHERE cantidad_en_stock = 0"
    ).fetchone()[0]
    assert n_cero_tabla == n_cero_literal  # los NULL no se contaron como 0


def test_senal_temprana_quiebre_es_superconjunto_de_respuesta_oficial(con):
    """La vista de 2 días (señal temprana) nunca debe reportar MENOS quiebres
    que la respuesta oficial de >3 días -- si eso pasa, hay un bug de umbral."""
    oficial = con.execute(
        "SELECT COUNT(*) FROM v_rachas_quiebre WHERE dias_consecutivos > 3"
    ).fetchone()[0]
    sensibilidad = con.execute(
        "SELECT COUNT(*) FROM v_rachas_quiebre WHERE dias_consecutivos >= 2"
    ).fetchone()[0]
    assert sensibilidad >= oficial


def test_productos_sin_costo_no_desaparecen_de_margen(con):
    """Todo producto huérfano con ventas debe aparecer en el reporte de
    trazabilidad (README punto 2) Y como fila-resumen en Q4, nunca desaparecer
    silenciosamente del análisis."""
    from pathlib import Path

    sql_dir = Path(__file__).resolve().parents[1] / "sql" / "questions"

    huerfanos_con_ventas = {
        row[0]
        for row in con.execute(
            """
            SELECT DISTINCT p.producto_id_canonico
            FROM dim_producto p
            JOIN fact_ventas v USING (producto_id_canonico)
            WHERE p.sin_costo_conocido
            """
        ).fetchall()
    }
    assert len(huerfanos_con_ventas) > 0

    en_reporte_dq = {
        row[0]
        for row in con.execute(
            (sql_dir / "dq_productos_sin_trazabilidad.sql").read_text(encoding="utf-8")
        ).fetchall()
    }
    en_q4 = {
        row[0]
        for row in con.execute(
            (sql_dir / "q4_margen_negativo.sql").read_text(encoding="utf-8")
        ).fetchall()
        if row[7] == "sin costo mapeado"
    }
    assert huerfanos_con_ventas <= en_reporte_dq
    assert huerfanos_con_ventas <= en_q4
