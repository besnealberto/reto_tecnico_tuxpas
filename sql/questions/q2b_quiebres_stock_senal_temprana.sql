-- Vista complementaria (NO reemplaza la respuesta oficial de la Pregunta 2):
-- misma métrica con umbral de 2 días, como "señal temprana" de quiebre para
-- el cliente. Ver conversación de negocio en README §Supuestos, punto 8.

SELECT tienda_id, producto_id_canonico, inicio_quiebre, fin_quiebre, dias_consecutivos
FROM v_rachas_quiebre
WHERE dias_consecutivos >= 2
ORDER BY dias_consecutivos DESC, tienda_id;
