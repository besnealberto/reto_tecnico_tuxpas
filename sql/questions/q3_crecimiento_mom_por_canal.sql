-- Pregunta 3: Crecimiento MoM de ventas por canal (físico vs ecommerce) en el
-- último año. "Último año" = 2025-04-01 a 2026-03-31, los últimos 12 meses
-- completos comunes a ambos canales en los datos (ver README §Supuestos, punto 6).

WITH ventas_mensuales AS (
    SELECT DATE_TRUNC('month', fecha) AS mes, canal, SUM(monto_neto_mxn) AS ventas_mxn
    FROM fact_ventas
    WHERE fecha BETWEEN DATE '2025-04-01' AND DATE '2026-03-31'
    GROUP BY 1, 2
)
SELECT
    mes,
    canal,
    ROUND(ventas_mxn, 2) AS ventas_mxn,
    ROUND(LAG(ventas_mxn) OVER (PARTITION BY canal ORDER BY mes), 2) AS ventas_mes_anterior,
    ROUND(
        100.0 * (ventas_mxn - LAG(ventas_mxn) OVER (PARTITION BY canal ORDER BY mes))
        / NULLIF(LAG(ventas_mxn) OVER (PARTITION BY canal ORDER BY mes), 0),
        2
    ) AS crecimiento_mom_pct
FROM ventas_mensuales
ORDER BY canal, mes;
