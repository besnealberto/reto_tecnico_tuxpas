-- Staging: tipado y renombrado mínimo desde las vistas raw_*.
-- Decisión: no se propagan columnas de PII de ecommerce (customer_name,
-- customer_email, customer_rfc, shipping_*) porque ninguna de las 4 preguntas
-- de negocio las requiere, y es la práctica correcta de minimización de datos.

CREATE OR REPLACE TABLE stg_sales AS
SELECT
    venta_id,
    CAST(fecha_hora AS TIMESTAMP) AS fecha_hora,
    tienda_id,
    sku AS sku_pos,
    cantidad,
    monto,
    moneda,
    tipo_comprobante
FROM raw_sales;

CREATE OR REPLACE TABLE stg_tiendas AS
SELECT tienda_id, ciudad, region, timezone
FROM raw_tiendas;

CREATE OR REPLACE TABLE stg_sku_mappings AS
SELECT sku_pos, sku_erp, handle
FROM raw_sku_mappings;

CREATE OR REPLACE TABLE stg_cost_history AS
SELECT
    sku_erp,
    nombre,
    categoria,
    CAST(fecha_vigencia AS DATE) AS fecha_vigencia,
    costo_mxn,
    proveedor
FROM raw_cost_history;

-- cantidad_en_stock llega como VARCHAR: ~1.9% de las 230,776 filas (4,417)
-- traen el literal 'N/A' en vez de un entero, repartido de forma pareja entre
-- las 40 tiendas, los 70 SKUs y los 182 días (no es un patrón sistemático de
-- una tienda/fecha puntual, luce como ruido del ERP legacy). Se castea a NULL
-- explícito -- NUNCA a 0 -- para no fabricar quiebres de stock falsos; ver
-- README §Supuestos, punto 9.
CREATE OR REPLACE TABLE stg_snapshots AS
SELECT
    CAST(fecha AS DATE) AS fecha,
    tienda_id,
    sku_erp,
    TRY_CAST(cantidad_en_stock AS INTEGER) AS cantidad_en_stock
FROM raw_snapshots;

CREATE OR REPLACE TABLE stg_ecommerce AS
SELECT
    order_id,
    CAST(fecha AS TIMESTAMP) AS fecha_hora,
    CAST(fecha AS DATE) AS fecha,
    product_handle AS handle,
    cantidad,
    amount,
    currency
FROM raw_ecommerce;

CREATE OR REPLACE TABLE stg_exchange_rates AS
SELECT
    CAST(fecha AS DATE) AS fecha,
    currency,
    rate_to_mxn
FROM raw_exchange_rates;
