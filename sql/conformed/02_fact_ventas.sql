-- Hecho de ventas unificado (físico + ecommerce), en MXN, neto de devoluciones.
-- Reglas aplicadas (ver README §Supuestos, punto 1):
--   * Canal físico: solo tipo_comprobante IN ('I','E'). 'I' suma, 'E' (nota de
--     crédito) resta -- el dato viene en positivo, por eso se invierte el signo.
--     Se excluyen 'P' (pago, ya contado en su 'I' original), 'N' (nómina) y
--     'T' (traslado interno): ninguno es una venta a cliente final.
--   * Canal ecommerce: no se observaron montos negativos (sin devoluciones
--     registradas), se toma tal cual, convertido a MXN con el tipo de cambio
--     del día de la orden.

CREATE OR REPLACE TABLE fact_ventas_fisico AS
SELECT
    s.venta_id,
    s.fecha_hora,
    CAST(s.fecha_hora AS DATE) AS fecha,
    s.tienda_id,
    d.producto_id_canonico,
    'fisico' AS canal,
    s.tipo_comprobante,
    CASE WHEN s.tipo_comprobante = 'E' THEN -s.cantidad ELSE s.cantidad END AS unidades_netas,
    CASE WHEN s.tipo_comprobante = 'E' THEN -s.monto ELSE s.monto END AS monto_neto_mxn
FROM stg_sales s
JOIN dim_producto d ON d.sku_pos = s.sku_pos
WHERE s.tipo_comprobante IN ('I', 'E');

CREATE OR REPLACE TABLE fact_ventas_ecommerce AS
SELECT
    e.order_id AS venta_id,
    e.fecha_hora,
    e.fecha,
    CAST(NULL AS VARCHAR) AS tienda_id,
    d.producto_id_canonico,
    'ecommerce' AS canal,
    'I' AS tipo_comprobante,
    e.cantidad AS unidades_netas,
    ROUND(e.amount * COALESCE(r.rate_to_mxn, 1.0), 2) AS monto_neto_mxn
FROM stg_ecommerce e
JOIN dim_producto d ON d.handle = e.handle
LEFT JOIN stg_exchange_rates r
    ON r.fecha = e.fecha AND r.currency = e.currency;

CREATE OR REPLACE TABLE fact_ventas AS
SELECT * FROM fact_ventas_fisico
UNION ALL
SELECT * FROM fact_ventas_ecommerce;

-- Costo vigente a la fecha de venta (SCD2 sin solapes, ver README punto 4):
-- ASOF JOIN toma el costo con fecha_vigencia más reciente <= fecha de la venta.
CREATE OR REPLACE VIEW fact_ventas_costo AS
SELECT v.*, ch.costo_mxn
FROM fact_ventas v
ASOF LEFT JOIN stg_cost_history ch
    ON v.producto_id_canonico = ch.sku_erp AND v.fecha >= ch.fecha_vigencia;
