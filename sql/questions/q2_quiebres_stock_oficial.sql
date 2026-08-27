-- Pregunta 2 (respuesta oficial, tal como pide el enunciado):
-- Tiendas con quiebres de stock de más de 3 días en el último trimestre (Q1 2026).

SELECT tienda_id, producto_id_canonico, inicio_quiebre, fin_quiebre, dias_consecutivos
FROM v_rachas_quiebre
WHERE dias_consecutivos > 3
ORDER BY dias_consecutivos DESC, tienda_id;
