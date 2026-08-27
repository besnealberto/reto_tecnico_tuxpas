-- Rachas de días consecutivos con stock en cero, por tienda y producto,
-- acotadas al último trimestre calendario disponible en los datos (Q1 2026,
-- ver README §Supuestos, punto 6). Técnica "gaps and islands": se resta un
-- contador secuencial a la fecha para agrupar corridas consecutivas.

CREATE OR REPLACE VIEW v_rachas_quiebre AS
WITH stock_trimestre AS (
    SELECT tienda_id, producto_id_canonico, fecha, cantidad_en_stock
    FROM fact_inventario
    WHERE fecha BETWEEN DATE '2026-01-01' AND DATE '2026-03-31'
),
marcado AS (
    SELECT *, (cantidad_en_stock = 0) AS en_cero
    FROM stock_trimestre
),
islas AS (
    SELECT *,
        fecha - (
            ROW_NUMBER() OVER (PARTITION BY tienda_id, producto_id_canonico, en_cero ORDER BY fecha)
            * INTERVAL 1 DAY
        ) AS isla
    FROM marcado
)
SELECT
    tienda_id,
    producto_id_canonico,
    MIN(fecha) AS inicio_quiebre,
    MAX(fecha) AS fin_quiebre,
    COUNT(*) AS dias_consecutivos
FROM islas
WHERE en_cero
GROUP BY tienda_id, producto_id_canonico, isla;
