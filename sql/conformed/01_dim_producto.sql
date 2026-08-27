-- Clave canónica de producto: une sku_pos (POS) <-> sku_erp (inventario/costo) <-> handle (Shopify).
-- Preserva explícitamente los huérfanos de ambos lados (ver README §Supuestos, punto 2)
-- en vez de descartarlos: alimentan el reporte dq_productos_sin_trazabilidad.

CREATE OR REPLACE TABLE dim_producto AS
WITH mapeados AS (
    SELECT sku_pos, sku_erp, handle FROM stg_sku_mappings
),
huerfanos_pos AS (
    -- sku_pos vendidos en tienda sin ningún mapeo a ERP ni Shopify
    SELECT DISTINCT sku_pos, CAST(NULL AS VARCHAR) AS sku_erp, CAST(NULL AS VARCHAR) AS handle
    FROM stg_sales
    WHERE sku_pos NOT IN (SELECT sku_pos FROM mapeados)
),
huerfanos_shopify AS (
    -- handles vendidos en Shopify sin mapeo a sku_erp/sku_pos
    SELECT CAST(NULL AS VARCHAR) AS sku_pos, CAST(NULL AS VARCHAR) AS sku_erp, h.handle
    FROM (SELECT DISTINCT handle FROM stg_ecommerce) h
    WHERE h.handle NOT IN (SELECT handle FROM mapeados WHERE handle IS NOT NULL)
),
huerfanos_inventario AS (
    -- sku_erp con costo/inventario en el ERP que jamás aparecen en sku_mappings
    -- (ni desde POS ni desde Shopify). Sin este bloque, sus 33,124 filas de
    -- snapshot se perdían en silencio al construir fact_inventario -- exactamente
    -- el tipo de "número incorrecto sin error visible" que advierte el reto.
    -- Nota: 5 de estos 10 sku_erp (...-001-A, 011-C, 021-A, 031-A, 041-D)
    -- comparten numeración con los 5 sku_pos huérfanos (CN-00001/11/21/31/41):
    -- podría ser el mismo producto con un mapeo roto en el ERP, pero como
    -- sku_mappings no lo confirma, NO se asume la unión -- se documenta como
    -- pregunta abierta al cliente (ver README §Supuestos, punto 2 y propuesta técnica).
    SELECT CAST(NULL AS VARCHAR) AS sku_pos, c.sku_erp, CAST(NULL AS VARCHAR) AS handle
    FROM (SELECT DISTINCT sku_erp FROM stg_cost_history) c
    WHERE c.sku_erp NOT IN (SELECT sku_erp FROM mapeados WHERE sku_erp IS NOT NULL)
),
todo AS (
    SELECT * FROM mapeados
    UNION ALL
    SELECT * FROM huerfanos_pos
    UNION ALL
    SELECT * FROM huerfanos_shopify
    UNION ALL
    SELECT * FROM huerfanos_inventario
),
catalogo AS (
    SELECT DISTINCT sku_erp, nombre, categoria FROM stg_cost_history
)
SELECT
    COALESCE(t.sku_erp, t.handle, 'POS:' || t.sku_pos) AS producto_id_canonico,
    t.sku_pos,
    t.sku_erp,
    t.handle,
    -- Nombre legible incluso sin catálogo: usa el handle de Shopify o el sku_pos
    -- de POS como respaldo, para que los reportes no muestren NULL.
    COALESCE(c.nombre, t.handle, 'SKU POS ' || t.sku_pos) AS nombre,
    c.categoria,
    (t.sku_erp IS NULL) AS sin_costo_conocido
FROM todo t
LEFT JOIN catalogo c USING (sku_erp);
