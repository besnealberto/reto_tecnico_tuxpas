-- Pregunta 4: Productos con margen negativo y en qué tiendas ocurren.
-- Costo por venta resuelto vía ASOF JOIN (point-in-time, ver conformed/02).
--
-- Los productos sin costo mapeado (README §Supuestos, punto 2) NO se excluyen,
-- pero tampoco se desglosan por tienda aquí -- eso ya vive en el reporte
-- dq_productos_sin_trazabilidad.sql con el detalle completo. Mezclarlos a
-- nivel tienda en esta tabla (~450 filas de "sin costo mapeado" vs. un puñado
-- de márgenes negativos reales) tapaba la señal real bajo ruido.
-- Aquí van: (a) los márgenes negativos reales, por producto y tienda; (b) una
-- fila-resumen por producto huérfano, a modo de aviso con puntero al reporte.

WITH margen_conocido AS (
    SELECT
        p.producto_id_canonico,
        p.nombre,
        COALESCE(fv.tienda_id, 'ECOMMERCE') AS tienda_id,
        fv.canal,
        ROUND(SUM(fv.monto_neto_mxn), 2) AS ingreso_mxn,
        ROUND(SUM(fv.unidades_netas * fv.costo_mxn), 2) AS costo_total_mxn,
        ROUND(SUM(fv.monto_neto_mxn) - SUM(fv.unidades_netas * fv.costo_mxn), 2) AS margen_mxn,
        CAST(NULL AS VARCHAR) AS motivo_sin_margen
    FROM fact_ventas_costo fv
    JOIN dim_producto p USING (producto_id_canonico)
    WHERE NOT p.sin_costo_conocido
    GROUP BY 1, 2, 3, 4
    HAVING margen_mxn < 0
),
sin_costo_resumen AS (
    SELECT
        p.producto_id_canonico,
        p.nombre,
        'ver dq_productos_sin_trazabilidad' AS tienda_id,
        CAST(NULL AS VARCHAR) AS canal,
        ROUND(SUM(v.monto_neto_mxn), 2) AS ingreso_mxn,
        CAST(NULL AS DOUBLE) AS costo_total_mxn,
        CAST(NULL AS DOUBLE) AS margen_mxn,
        'sin costo mapeado' AS motivo_sin_margen
    FROM dim_producto p
    JOIN fact_ventas v USING (producto_id_canonico)
    WHERE p.sin_costo_conocido
    GROUP BY 1, 2
)
SELECT * FROM margen_conocido
UNION ALL
SELECT * FROM sin_costo_resumen
ORDER BY margen_mxn ASC NULLS LAST;
