# CaféNorte — Pipeline de datos unificado

Reto técnico de Data Solutions Engineer para Tuxpas. Consolida ventas de POS, inventario de ERP legacy y órdenes de Shopify en un modelo analítico único, y responde las 4 preguntas de negocio del reto.

## Cómo correr

```bash
pip install -r requirements.txt
python run_pipeline.py      # construye cafenorte.duckdb y exporta output/*.csv
pytest tests/ -v            # 9 tests de confiabilidad
```

No requiere credenciales ni servicios externos: `duckdb` corre embebido, sin servidor.

## Por qué este stack

**Python + DuckDB + SQL declarativo**, sin frameworks adicionales (no dbt, no Spark):

- Los 3 orígenes (CSV, JSON anidado, Parquet) y sus ~330k registros combinados caben cómodos en un proceso embebido — no hay necesidad de un motor distribuido.
- DuckDB lee CSV/Parquet nativamente y soporta `ASOF JOIN`, clave para resolver el costo vigente a la fecha de cada venta sin subconsultas correlacionadas.
- El único preprocesamiento en Python es aplanar `inventory.json` (mezcla metadata, catálogo y snapshots en un solo objeto, no es tabular de origen); todo lo demás — reconciliación, negocio, agregaciones — es SQL auditable en `sql/`.
- Stack proporcional al problema: el reto pide señal de criterio, no un despliegue de producción real (eso vive en la propuesta técnica de AWS, sección aparte).

## Estructura del pipeline

```
data/raw/          # las 4 fuentes tal como llegaron
src/cafenorte/
  ingest.py        # aplana inventory.json (JSON anidado -> DataFrames) y registra las 4 fuentes en DuckDB
  pipeline.py       # orquesta: ingesta -> staging -> conformado -> marts -> preguntas
sql/
  staging/          # tipado mínimo desde crudo, sin lógica de negocio
  conformed/         # dim_producto (clave canónica), fact_ventas, fact_inventario
  marts/             # v_rachas_quiebre (reutilizable por Q2 oficial y la vista de 2 días)
  questions/         # una consulta por pregunta de negocio + el reporte de calidad de datos
tests/               # 9 tests de reconciliación (pytest, corren contra el dataset real)
output/              # CSV exportado de cada pregunta tras correr el pipeline
```

## Supuestos y decisiones de conciliación

**1. Definición de "venta" (el hallazgo de mayor riesgo del dataset).**
`sales.csv.tipo_comprobante` trae 5 valores que corresponden a tipos de comprobante fiscal CFDI mexicano: `I` (Ingreso), `E` (Egreso/nota de crédito), `P` (Pago), `N` (Nómina), `T` (Traslado) — **todos con `monto` almacenado en positivo**, incluidas las `E`. Un `SUM(monto)` ingenuo sobreestima ingresos: duplica ventas ya facturadas (`P` es un complemento de pago sobre un `I` ya contado), mezcla nómina/traslados internos, y suma en vez de restar devoluciones. Se calcula venta neta = `SUM(monto WHERE I) − SUM(monto WHERE E)`, excluyendo `P`, `N`, `T`. Verificado con test (`test_notas_de_credito_restan_no_suman`).

**2. Productos sin costo/trazabilidad conocida — no se descartan, se marcan.**
Cadena de mapeo `sku_pos ↔ sku_erp ↔ handle` vía `sku_mappings`. Se detectaron huérfanos en ambos sentidos: 5 `sku_pos` de POS y 6 `handle` de Shopify sin ningún mapeo. Estos productos se preservan con `sin_costo_conocido = true` y alimentan `dq_productos_sin_trazabilidad` (16 productos, ordenados por ingreso para priorizar qué huecos de información pesan más en dinero — top: `termo-mercancia-046` con **$1.17M MXN** en ventas sin costo asociado). En la Pregunta 4 aparecen como fila-resumen con `motivo_sin_margen = 'sin costo mapeado'`, nunca desaparecen en silencio.

**3. Huérfanos del lado de inventario (bug real, detectado y corregido en este proyecto).**
La primera versión de `dim_producto` solo se construía "de abajo hacia arriba" desde lo vendido (POS + Shopify + mapeados). Al correr los tests de conteo se detectó que **10 `sku_erp` del catálogo/ERP nunca aparecen en `sku_mappings`** — productos con costo e inventario tracked, pero jamás vendidos por un canal identificado. Como no tenían fila en `dim_producto`, sus **33,124 filas de snapshot (14.3% del total) se perdían en silencio** al construir `fact_inventario` — exactamente el red flag que advierte el reto ("corre sin error pero produce números incorrectos"). Se corrigió agregando estos huérfanos de inventario a `dim_producto`; el fix reveló, entre otras cosas, un quiebre de stock real de 4 días en `T023` para `ERP-PROV-MX-046-A` que antes era invisible. Test de regresión: `test_no_hay_perdida_silenciosa_de_inventario`.

  *Pregunta abierta para el cliente:* 5 de estos 10 `sku_erp` huérfanos (`...-001-A, 011-C, 021-A, 031-A, 041-D`) comparten numeración exacta con los 5 `sku_pos` huérfanos de POS (`CN-00001/11/21/31/41`). Podría ser el mismo producto físico con un mapeo roto en el ERP — pero como `sku_mappings` no lo confirma explícitamente, **no se asume la unión** (fusionarlos sin evidencia sería fabricar un dato, el mismo tipo de error que este punto busca evitar). Se documenta como pregunta abierta para que CaféNorte lo confirme.

**4. Moneda.** `sales.csv` es 100% MXN. `ecommerce_orders.parquet` mezcla MXN/USD/EUR — se convierte a MXN uniendo por `DATE(fecha)` contra `exchange_rates.csv` (cobertura verificada: 0 fechas huérfanas).

**5. Costo con vigencia temporal.** `catalogo.cost_history` es SCD2 limpio (sin fechas de vigencia solapadas, verificado). El costo aplicado a cada venta es el vigente más reciente `<=` fecha de venta, resuelto con `ASOF JOIN`.

**6. Zona horaria.** `sales.csv.fecha_hora` no trae timezone explícito; se asume que ya está en hora local de cada tienda (dato nativo de POS). No se aplica conversión porque las 4 preguntas de negocio son a granularidad diaria/mensual.

**7. Ventana temporal de las preguntas de negocio.** Los snapshots de inventario cubren exactamente 2025-10-01 → 2026-03-31 (182 días = 6 meses calendario). **"Últimos 6 meses" (Q1) = todo el rango de snapshots disponible**; **"último trimestre" (Q2) = Q1 2026 (ene–mar)**. Ambas ventanas están ancladas a los datos, no a la fecha real de hoy, porque el dataset termina en marzo 2026.

**8. Rotación de inventario con canal Shopify incluido (Q1).** No existe `tienda_id` en `ecommerce_orders`, así que no se puede prorratear a una tienda física. Se entregan dos vistas: `rotacion_fisica` (unidades POS ÷ inventario promedio, dato exacto por tienda) y `rotacion_combinada` (unidades POS + Shopify ÷ inventario agregado de las 40 tiendas, asumiendo que Shopify se abastece del inventario corporativo al no existir bodega propia declarada — aproximación documentada). El ranking del Top 10 usa `rotacion_combinada` para no dejar fuera el canal online; la columna `vendido_en_ecommerce` hace explícito cuándo el dato es exacto vs. aproximado.

**9. Quiebre de stock (Q2).** Respuesta oficial: racha de **más de 3 días consecutivos** en `cantidad_en_stock = 0`, tal como pide el enunciado. Se entrega además una vista complementaria con umbral de **2 días** ("señal temprana"), que **no reemplaza** la respuesta oficial — decisión explícita para no desviarnos de lo que pregunta el reto mientras igual se entrega el insight de negocio solicitado.

**10. Valores `'N/A'` en snapshots de inventario.** `cantidad_en_stock` llega como VARCHAR: 4,417 de 230,776 filas (1.9%) traen el literal `'N/A'` en vez de un entero, repartido de forma pareja entre las 40 tiendas, 70 SKUs y 182 días (ruido del ERP legacy, no un patrón sistemático). Se castea a `NULL` explícito con `TRY_CAST` — **nunca a 0** — porque un 0 fabricado inflaría artificialmente los quiebres de stock. Verificado con test.

## Resultados

### Pregunta 1 — Top 10 SKUs por rotación de inventario (últimos 6 meses)

| producto_id_canonico | nombre | categoria | unidades_fisico | unidades_todas | inventario_promedio | rotacion_fisica | rotacion_combinada | vendido_en_ecommerce |
|---|---|---|---|---|---|---|---|---|
| ERP-PROV-MX-057-C | Premium Cafe Grano | cafe_grano | 1783.0 | 2191.0 | 470.0 | 3.79 | 4.66 | True |
| ERP-PROV-MX-037-C | Tradicional Cafe Molido | cafe_molido | 1855.0 | 2278.0 | 587.8 | 3.16 | 3.88 | True |
| ERP-PROV-MX-014-D | Descafeinado Cafe Grano | cafe_grano | 1816.0 | 2239.0 | 626.9 | 2.90 | 3.57 | True |
| ERP-PROV-MX-004-B | Prensa Francesa Mercancia | mercancia | 1817.0 | 2215.0 | 622.6 | 2.92 | 3.56 | True |
| ERP-PROV-MX-012-B | Sándwich Comida Caliente | comida_caliente | 1800.0 | 1800.0 | 516.3 | 3.49 | 3.49 | False |
| ERP-PROV-MX-034-D | Estándar Cafe Molido | cafe_molido | 1774.0 | 2144.0 | 632.2 | 2.81 | 3.39 | True |
| ERP-PROV-MX-003-D | Filtros Mercancia | mercancia | 1671.0 | 2111.0 | 622.9 | 2.68 | 3.39 | True |
| ERP-PROV-MX-008-C | Empanada Panaderia | panaderia | 1725.0 | 1725.0 | 516.4 | 3.34 | 3.34 | False |
| ERP-PROV-MX-062-B | Wrap Comida Caliente | comida_caliente | 1801.0 | 1801.0 | 543.3 | 3.32 | 3.32 | False |
| ERP-PROV-MX-030-C | Molinillo Mercancia | mercancia | 1783.0 | 1783.0 | 551.0 | 3.24 | 3.24 | False |

### Pregunta 2 — Tiendas con quiebres de stock (último trimestre, Q1 2026)

**Respuesta oficial (>3 días):**

| tienda_id | producto_id_canonico | inicio_quiebre | fin_quiebre | dias_consecutivos |
|---|---|---|---|---|
| T015 | ERP-PROV-MX-014-D | 2026-02-09 | 2026-02-12 | 4 |
| T023 | ERP-PROV-MX-046-A | 2026-01-25 | 2026-01-28 | 4 |
| T038 | ERP-PROV-MX-040-A | 2026-03-18 | 2026-03-21 | 4 |

Vista complementaria de "señal temprana" (≥2 días): 244 rachas — ver `output/q2b_quiebres_stock_senal_temprana.csv`.

### Pregunta 3 — Crecimiento MoM de ventas por canal (últimos 12 meses)

Ver `output/q3_crecimiento_mom_por_canal.csv` (24 filas: 12 meses × 2 canales). El canal físico crece de forma más volátil mes a mes (rango -7.7% a +7.7%) que ecommerce (rango -7.1% a +9.0%); ningún canal muestra una tendencia sostenida de caída o crecimiento en el periodo — se lee como estacionalidad, no como una tendencia estructural.

### Pregunta 4 — Productos con margen negativo y en qué tiendas

Dos productos con margen negativo real en **las 40 tiendas**: `ERP-PROV-MX-015-D` (Especial Cafe Molido, hasta -$11,000 MXN en la tienda T036) y `ERP-PROV-MX-002-B` (Sándwich Comida Caliente, hasta -$3,021 MXN en T013). El resto de la tabla son 16 filas-resumen de productos sin costo mapeado (ver punto 2 de supuestos) — no se puede afirmar si tienen margen negativo, y se marcan como tal en vez de omitirse. Detalle completo en `output/q4_margen_negativo.csv`.

### Reporte de calidad de datos — productos sin trazabilidad

`output/dq_productos_sin_trazabilidad.csv`: 16 productos vendidos sin costo conocido, para llevar a revisión manual en tienda o en el ERP. Los 3 de mayor exposición económica:

| producto_id_canonico | origen | unidades_vendidas | ingreso_total_mxn |
|---|---|---|---|
| termo-mercancia-046 | POS+Shopify | 2187.0 | 1,173,617.36 |
| POS:CN-00031 | POS | 1752.0 | 946,403.47 |
| gourmet-cafe-grano-036 | POS+Shopify | 2211.0 | 700,239.68 |

## Tests

9 tests en `tests/test_pipeline.py`, corridos contra el dataset real (no fixtures sintéticos, dado el alcance del reto). Cubren específicamente los puntos donde este pipeline podría "correr sin error pero dar números mal": pérdida silenciosa de filas al conciliar fuentes (incluye el test de regresión del bug de huérfanos de inventario descrito en el punto 3 de supuestos), signo de las notas de crédito, duplicados, conversión de moneda, manejo de `NULL` vs. `0` en inventario, y consistencia entre la respuesta oficial de Q2 y su vista de sensibilidad.

## Limitaciones conocidas

- La rotación combinada (Q1) es una aproximación para el canal Shopify — no hay datos de inventario dedicado al canal online.
- La posible correspondencia entre SKUs huérfanos de POS y de ERP (punto 3) no se resolvió automáticamente; requiere confirmación del cliente.
- PII de `ecommerce_orders.parquet` (nombre, email, RFC, dirección) se descarta en `staging` por minimización de datos — no se necesita para ninguna de las 4 preguntas.
