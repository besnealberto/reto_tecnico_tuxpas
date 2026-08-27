-- Pregunta 1: Top 10 SKUs por rotación de inventario en los últimos 6 meses.
-- "Últimos 6 meses" = todo el rango de snapshots disponible, 2025-10-01 a
-- 2026-03-31 (182 días exactos -- ver README §Supuestos, punto 6).
--
-- rotacion_fisica    = unidades vendidas en tienda / inventario promedio (dato exacto).
-- rotacion_combinada = (unidades tienda + unidades Shopify) / mismo inventario,
--                       asumiendo que Shopify se abastece del inventario
--                       corporativo agregado, al no existir bodega propia
--                       declarada (aproximación documentada, README punto 7).
-- El ranking usa rotacion_combinada para no dejar fuera el canal ecommerce;
-- rotacion_fisica queda visible para poder distinguir cuánto de eso es dato
-- exacto vs. aproximado.

WITH ventas_fisico AS (
    SELECT producto_id_canonico, SUM(unidades_netas) AS unidades_fisico
    FROM fact_ventas
    WHERE canal = 'fisico'
    GROUP BY 1
),
ventas_todas AS (
    SELECT producto_id_canonico, SUM(unidades_netas) AS unidades_todas
    FROM fact_ventas
    GROUP BY 1
),
inventario_diario AS (
    SELECT fecha, producto_id_canonico, SUM(cantidad_en_stock) AS stock_total
    FROM fact_inventario
    GROUP BY 1, 2
),
inventario_promedio AS (
    SELECT producto_id_canonico, AVG(stock_total) AS inv_promedio
    FROM inventario_diario
    GROUP BY 1
)
SELECT
    p.producto_id_canonico,
    p.nombre,
    p.categoria,
    COALESCE(vf.unidades_fisico, 0) AS unidades_fisico,
    COALESCE(vt.unidades_todas, 0) AS unidades_todas,
    ROUND(ip.inv_promedio, 1) AS inventario_promedio,
    ROUND(COALESCE(vf.unidades_fisico, 0) / NULLIF(ip.inv_promedio, 0), 2) AS rotacion_fisica,
    ROUND(COALESCE(vt.unidades_todas, 0) / NULLIF(ip.inv_promedio, 0), 2) AS rotacion_combinada,
    (p.handle IS NOT NULL) AS vendido_en_ecommerce
FROM dim_producto p
JOIN inventario_promedio ip USING (producto_id_canonico)
LEFT JOIN ventas_fisico vf USING (producto_id_canonico)
LEFT JOIN ventas_todas vt USING (producto_id_canonico)
ORDER BY rotacion_combinada DESC
LIMIT 10;
