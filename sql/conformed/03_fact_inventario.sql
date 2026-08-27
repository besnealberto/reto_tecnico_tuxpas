-- Hecho de inventario: snapshots diarios de stock por tienda, mapeados a la
-- clave canónica de producto. Solo cubre canal físico (no existe tracking de
-- stock para Shopify en las fuentes -- ver README §Supuestos, punto 7).

CREATE OR REPLACE TABLE fact_inventario AS
SELECT
    sn.fecha,
    sn.tienda_id,
    d.producto_id_canonico,
    sn.cantidad_en_stock
FROM stg_snapshots sn
JOIN dim_producto d ON d.sku_erp = sn.sku_erp;
