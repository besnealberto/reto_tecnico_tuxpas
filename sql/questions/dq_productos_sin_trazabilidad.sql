-- Reporte de calidad de datos (no es una de las 4 preguntas oficiales):
-- productos vendidos sin costo/inventario conocido, para que el cliente los
-- lleve a revisión manual en tienda o en su ERP. Ordenado por ingreso para
-- priorizar los huecos que más dinero representan (ver README §Supuestos, punto 2).

SELECT
    p.producto_id_canonico,
    CASE
        WHEN p.sku_pos IS NOT NULL AND p.handle IS NULL THEN 'POS'
        WHEN p.handle IS NOT NULL AND p.sku_pos IS NULL THEN 'Shopify'
        ELSE 'POS+Shopify'
    END AS origen,
    SUM(v.unidades_netas) AS unidades_vendidas,
    ROUND(SUM(v.monto_neto_mxn), 2) AS ingreso_total_mxn,
    STRING_AGG(DISTINCT v.tienda_id, ', ') AS tiendas_donde_se_vendio,
    MIN(v.fecha) AS primera_venta,
    MAX(v.fecha) AS ultima_venta
FROM dim_producto p
JOIN fact_ventas v USING (producto_id_canonico)
WHERE p.sin_costo_conocido
GROUP BY 1, 2
ORDER BY ingreso_total_mxn DESC;
