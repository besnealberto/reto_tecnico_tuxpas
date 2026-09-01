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
Cadena de mapeo `sku_pos ↔ sku_erp ↔ handle` vía `sku_mappings`. Se detectaron huérfanos en tres formas distintas: 6 `sku_pos` de POS y 6 `handle` de Shopify sin ningún registro de mapeo, más 4 registros de `sku_mappings` que sí enlazan `sku_pos ↔ handle` pero dejan `sku_erp` explícitamente en `NULL` (mapeo parcial: se sabe que el producto se vende en tienda y en Shopify, pero no hay costo de ERP asociado). Total: 16 productos, exactamente lo que reporta `dq_productos_sin_trazabilidad` (ordenados por ingreso para priorizar qué huecos de información pesan más en dinero — top: `termo-mercancia-046` con **$1.17M MXN** en ventas sin costo asociado). Todos se preservan con `sin_costo_conocido = true`. En la Pregunta 4 aparecen como fila-resumen con `motivo_sin_margen = 'sin costo mapeado'`, nunca desaparecen en silencio.

**3. Huérfanos del lado de inventario (bug real, detectado y corregido en este proyecto).**
La primera versión de `dim_producto` solo se construía "de abajo hacia arriba" desde lo vendido (POS + Shopify + mapeados). Al correr los tests de conteo se detectó que **10 `sku_erp` del catálogo/ERP nunca aparecen en `sku_mappings`** — productos con costo e inventario tracked, pero jamás vendidos por un canal identificado. Como no tenían fila en `dim_producto`, sus **33,124 filas de snapshot (14.3% del total) se perdían en silencio** al construir `fact_inventario` — exactamente el red flag que advierte el reto ("corre sin error pero produce números incorrectos"). Se corrigió agregando estos huérfanos de inventario a `dim_producto`; el fix reveló, entre otras cosas, un quiebre de stock real de 4 días en `T023` para `ERP-PROV-MX-046-A` que antes era invisible. Test de regresión: `test_no_hay_perdida_silenciosa_de_inventario`.

  *Pregunta abierta para el cliente — dos niveles de evidencia distintos:*
  - **Coincidencia de numeración (evidencia débil):** 6 de estos 10 `sku_erp` huérfanos (`...-001-A, 011-C, 016-C, 021-A, 031-A, 041-D`) comparten numeración exacta con los 6 `sku_pos` huérfanos de POS (`CN-00001/11/16/21/31/41`). Podría ser el mismo producto físico con un mapeo roto en el ERP.
  - **Mapeo parcial ya existente (evidencia fuerte):** los otros 4 `sku_erp` huérfanos (`...-006-C, 026-A, 036-A, 046-A`) no solo comparten numeración — coinciden exacto con las 4 filas que **ya existen** en `sku_mappings` (`CN-00006/26/36/46`, ver punto 2), que enlazan `sku_pos ↔ handle` pero dejan `sku_erp` en `NULL`. Es decir, ya hay un registro de mapeo apuntando a ese número de producto, y le falta justo el campo `sku_erp` — evidencia bastante más convincente que la simple coincidencia de número.

  En ningún caso `sku_mappings` lo confirma explícitamente, así que **no se asume la unión** (fusionarlos sin evidencia sería fabricar un dato, el mismo tipo de error que este punto busca evitar). Se documenta como pregunta abierta para que CaféNorte lo confirme, con los 4 mapeos parciales como punto de partida más prometedor para esa conversación.

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

Vista complementaria de "señal temprana" (≥2 días): 244 rachas. Se genera en `output/q2b_quiebres_stock_senal_temprana.csv` al correr el pipeline (artefacto derivado, no se versiona en git — la query vive en [`sql/questions/q2b_quiebres_stock_senal_temprana.sql`](sql/questions/q2b_quiebres_stock_senal_temprana.sql)).

### Pregunta 3 — Crecimiento MoM de ventas por canal (últimos 12 meses)

| Mes | Ventas físico (MXN) | MoM físico | Ventas ecommerce (MXN) | MoM ecommerce |
|---|---:|---:|---:|---:|
| 2025-04 | 1,532,102.35 | — | 383,213.04 | — |
| 2025-05 | 1,639,657.50 | +7.02% | 365,088.18 | -4.73% |
| 2025-06 | 1,577,691.00 | -3.78% | 339,352.27 | -7.05% |
| 2025-07 | 1,644,239.29 | +4.22% | 350,578.50 | +3.31% |
| 2025-08 | 1,642,587.46 | -0.10% | 343,799.74 | -1.93% |
| 2025-09 | 1,563,129.38 | -4.84% | 345,453.77 | +0.48% |
| 2025-10 | 1,648,071.37 | +5.43% | 376,497.09 | +8.99% |
| 2025-11 | 1,544,897.09 | -6.26% | 359,337.68 | -4.56% |
| 2025-12 | 1,648,254.78 | +6.69% | 346,649.18 | -3.53% |
| 2026-01 | 1,553,376.66 | -5.76% | 344,899.04 | -0.50% |
| 2026-02 | 1,434,264.57 | -7.67% | 323,250.60 | -6.28% |
| 2026-03 | 1,543,956.27 | +7.65% | 350,763.45 | +8.51% |

El canal físico crece de forma más volátil mes a mes (rango -7.7% a +7.7%) que ecommerce (rango -7.1% a +9.0%); ningún canal muestra una tendencia sostenida de caída o crecimiento en el periodo — se lee como estacionalidad, no como una tendencia estructural.

### Pregunta 4 — Productos con margen negativo y en qué tiendas

Dos productos con margen negativo real en **las 40 tiendas**: `ERP-PROV-MX-015-D` (Especial Cafe Molido, hasta -$11,000 MXN en la tienda T036) y `ERP-PROV-MX-002-B` (Sándwich Comida Caliente, hasta -$3,021 MXN en T013). El resto de la tabla son 16 filas-resumen de productos sin costo mapeado (ver punto 2 de supuestos) — no se puede afirmar si tienen margen negativo, y se marcan como tal en vez de omitirse.

<details>
<summary>Ver detalle completo (80 filas: 2 productos × 40 tiendas, ordenado por margen ascendente)</summary>

| Producto | Tienda | Ingreso (MXN) | Costo (MXN) | Margen (MXN) |
|---|---|---:|---:|---:|
| ERP-PROV-MX-015-D | T036 | 34,721.77 | 45,722.24 | -11,000.47 |
| ERP-PROV-MX-015-D | T023 | 26,174.40 | 34,006.38 | -7,831.98 |
| ERP-PROV-MX-015-D | T004 | 25,374.32 | 32,992.78 | -7,618.46 |
| ERP-PROV-MX-015-D | T030 | 22,573.91 | 29,382.80 | -6,808.89 |
| ERP-PROV-MX-015-D | T029 | 21,022.03 | 27,587.08 | -6,565.05 |
| ERP-PROV-MX-015-D | T016 | 21,549.76 | 28,088.86 | -6,539.10 |
| ERP-PROV-MX-015-D | T019 | 21,370.63 | 27,897.62 | -6,526.99 |
| ERP-PROV-MX-015-D | T001 | 21,592.72 | 28,031.86 | -6,439.14 |
| ERP-PROV-MX-015-D | T026 | 20,130.23 | 26,497.86 | -6,367.63 |
| ERP-PROV-MX-015-D | T038 | 20,332.46 | 26,647.24 | -6,314.78 |
| ERP-PROV-MX-015-D | T034 | 19,531.76 | 25,804.72 | -6,272.96 |
| ERP-PROV-MX-015-D | T040 | 20,807.03 | 27,076.88 | -6,269.85 |
| ERP-PROV-MX-015-D | T033 | 21,219.84 | 27,417.62 | -6,197.78 |
| ERP-PROV-MX-015-D | T031 | 18,578.86 | 24,735.74 | -6,156.88 |
| ERP-PROV-MX-015-D | T032 | 21,245.09 | 27,375.60 | -6,130.51 |
| ERP-PROV-MX-015-D | T027 | 18,794.21 | 24,737.36 | -5,943.15 |
| ERP-PROV-MX-015-D | T011 | 17,492.81 | 23,322.62 | -5,829.81 |
| ERP-PROV-MX-015-D | T022 | 18,931.03 | 24,658.50 | -5,727.47 |
| ERP-PROV-MX-015-D | T035 | 17,532.20 | 23,124.66 | -5,592.46 |
| ERP-PROV-MX-015-D | T006 | 16,907.04 | 22,265.38 | -5,358.34 |
| ERP-PROV-MX-015-D | T037 | 17,003.83 | 22,361.00 | -5,357.17 |
| ERP-PROV-MX-015-D | T039 | 15,918.00 | 20,917.68 | -4,999.68 |
| ERP-PROV-MX-015-D | T007 | 16,379.27 | 21,372.50 | -4,993.23 |
| ERP-PROV-MX-015-D | T008 | 15,937.76 | 20,897.60 | -4,959.84 |
| ERP-PROV-MX-015-D | T005 | 15,593.69 | 20,405.86 | -4,812.17 |
| ERP-PROV-MX-015-D | T002 | 14,216.63 | 18,504.40 | -4,287.77 |
| ERP-PROV-MX-015-D | T018 | 13,386.77 | 17,666.90 | -4,280.13 |
| ERP-PROV-MX-015-D | T003 | 13,427.20 | 17,551.12 | -4,123.92 |
| ERP-PROV-MX-015-D | T014 | 13,481.58 | 17,569.58 | -4,088.00 |
| ERP-PROV-MX-015-D | T017 | 13,051.69 | 17,129.90 | -4,078.21 |
| ERP-PROV-MX-015-D | T015 | 12,590.54 | 16,616.38 | -4,025.84 |
| ERP-PROV-MX-015-D | T012 | 13,077.33 | 17,051.04 | -3,973.71 |
| ERP-PROV-MX-015-D | T025 | 11,968.17 | 15,765.44 | -3,797.27 |
| ERP-PROV-MX-015-D | T028 | 12,489.92 | 16,250.46 | -3,760.54 |
| ERP-PROV-MX-015-D | T024 | 11,631.05 | 15,199.94 | -3,568.89 |
| ERP-PROV-MX-015-D | T009 | 10,881.48 | 14,239.94 | -3,358.46 |
| ERP-PROV-MX-015-D | T020 | 10,163.17 | 13,325.28 | -3,162.11 |
| ERP-PROV-MX-015-D | T021 | 9,772.70 | 12,811.76 | -3,039.06 |
| ERP-PROV-MX-002-B | T013 | 10,791.28 | 13,812.43 | -3,021.15 |
| ERP-PROV-MX-015-D | T013 | 9,083.53 | 11,927.30 | -2,843.77 |
| ERP-PROV-MX-002-B | T029 | 9,580.23 | 12,336.16 | -2,755.93 |
| ERP-PROV-MX-015-D | T010 | 8,691.65 | 11,408.76 | -2,717.11 |
| ERP-PROV-MX-002-B | T036 | 9,182.84 | 11,884.38 | -2,701.54 |
| ERP-PROV-MX-002-B | T031 | 8,144.78 | 10,484.15 | -2,339.37 |
| ERP-PROV-MX-002-B | T037 | 7,549.39 | 9,802.58 | -2,253.19 |
| ERP-PROV-MX-002-B | T034 | 8,105.00 | 10,266.44 | -2,161.44 |
| ERP-PROV-MX-002-B | T011 | 7,551.65 | 9,596.79 | -2,045.14 |
| ERP-PROV-MX-002-B | T016 | 7,065.79 | 9,105.64 | -2,039.85 |
| ERP-PROV-MX-002-B | T040 | 7,138.26 | 9,151.42 | -2,013.16 |
| ERP-PROV-MX-002-B | T007 | 7,204.83 | 9,214.65 | -2,009.82 |
| ERP-PROV-MX-002-B | T020 | 6,852.78 | 8,787.69 | -1,934.91 |
| ERP-PROV-MX-002-B | T018 | 6,614.98 | 8,472.30 | -1,857.32 |
| ERP-PROV-MX-002-B | T014 | 6,367.40 | 8,131.20 | -1,763.80 |
| ERP-PROV-MX-002-B | T023 | 5,940.84 | 7,635.09 | -1,694.25 |
| ERP-PROV-MX-002-B | T009 | 5,778.43 | 7,427.31 | -1,648.88 |
| ERP-PROV-MX-002-B | T032 | 5,656.72 | 7,286.76 | -1,630.04 |
| ERP-PROV-MX-002-B | T008 | 5,656.79 | 7,256.25 | -1,599.46 |
| ERP-PROV-MX-002-B | T002 | 5,376.37 | 6,959.52 | -1,583.15 |
| ERP-PROV-MX-002-B | T005 | 5,136.71 | 6,608.29 | -1,471.58 |
| ERP-PROV-MX-002-B | T006 | 4,828.89 | 6,299.99 | -1,471.10 |
| ERP-PROV-MX-002-B | T035 | 5,300.31 | 6,755.93 | -1,455.62 |
| ERP-PROV-MX-002-B | T028 | 4,948.81 | 6,392.87 | -1,444.06 |
| ERP-PROV-MX-002-B | T027 | 5,002.33 | 6,428.66 | -1,426.33 |
| ERP-PROV-MX-002-B | T030 | 5,051.97 | 6,454.28 | -1,402.31 |
| ERP-PROV-MX-002-B | T022 | 4,889.26 | 6,278.90 | -1,389.64 |
| ERP-PROV-MX-002-B | T033 | 5,214.76 | 6,598.03 | -1,383.27 |
| ERP-PROV-MX-002-B | T025 | 4,564.96 | 5,905.11 | -1,340.15 |
| ERP-PROV-MX-002-B | T024 | 4,434.50 | 5,746.70 | -1,312.20 |
| ERP-PROV-MX-002-B | T021 | 4,568.78 | 5,878.21 | -1,309.43 |
| ERP-PROV-MX-002-B | T038 | 4,642.98 | 5,936.74 | -1,293.76 |
| ERP-PROV-MX-002-B | T015 | 4,655.25 | 5,934.56 | -1,279.31 |
| ERP-PROV-MX-002-B | T039 | 4,514.28 | 5,753.95 | -1,239.67 |
| ERP-PROV-MX-002-B | T017 | 4,346.87 | 5,551.47 | -1,204.60 |
| ERP-PROV-MX-002-B | T010 | 3,946.29 | 5,038.50 | -1,092.21 |
| ERP-PROV-MX-002-B | T001 | 3,980.34 | 5,064.35 | -1,084.01 |
| ERP-PROV-MX-002-B | T026 | 3,672.48 | 4,730.08 | -1,057.60 |
| ERP-PROV-MX-002-B | T012 | 4,001.84 | 5,058.63 | -1,056.79 |
| ERP-PROV-MX-002-B | T004 | 3,864.65 | 4,920.51 | -1,055.86 |
| ERP-PROV-MX-002-B | T003 | 3,539.78 | 4,573.49 | -1,033.71 |
| ERP-PROV-MX-002-B | T019 | 3,039.66 | 3,906.93 | -867.27 |

</details>

### Reporte de calidad de datos — productos sin trazabilidad

16 productos vendidos sin costo conocido, para llevar a revisión manual en tienda o en el ERP. Ordenado por ingreso para priorizar qué huecos pesan más en dinero (también exportable en `output/dq_productos_sin_trazabilidad.csv` al correr el pipeline):

| Producto | Origen | Unidades vendidas | Ingreso total (MXN) | Cobertura | Primera venta | Última venta |
|---|---|---:|---:|---|---|---|
| termo-mercancia-046 | POS+Shopify | 2,187 | 1,173,617.36 | 40 tiendas | 2024-10-01 | 2026-03-31 |
| POS:CN-00031 | POS | 1,752 | 946,403.47 | 40 tiendas | 2024-10-01 | 2026-03-31 |
| gourmet-cafe-grano-036 | POS+Shopify | 2,211 | 700,239.68 | 40 tiendas | 2024-10-01 | 2026-03-31 |
| estándar-cafe-grano-006 | POS+Shopify | 2,174 | 440,091.06 | 40 tiendas | 2024-10-01 | 2026-03-31 |
| premium-cafe-molido-026 | POS+Shopify | 2,019 | 316,300.43 | 40 tiendas | 2024-10-01 | 2026-03-31 |
| termo-mercancia-031 | Shopify | 421 | 237,700.11 | solo online | 2025-04-01 | 2026-03-30 |
| POS:CN-00016 | POS | 1,719 | 148,665.41 | 40 tiendas | 2024-10-01 | 2026-03-30 |
| POS:CN-00041 | POS | 1,704 | 132,037.96 | 40 tiendas | 2024-10-01 | 2026-03-31 |
| POS:CN-00001 | POS | 1,708 | 127,412.55 | 40 tiendas | 2024-10-01 | 2026-03-31 |
| molinillo-mercancia-030 | Shopify | 414 | 97,378.73 | solo online | 2025-04-01 | 2026-03-31 |
| selección-cafe-molido-013 | Shopify | 404 | 84,860.42 | solo online | 2025-04-01 | 2026-03-28 |
| americano-cafe-molido-052 | Shopify | 437 | 77,792.63 | solo online | 2025-04-02 | 2026-03-31 |
| POS:CN-00011 | POS | 1,747 | 49,968.79 | 40 tiendas | 2024-10-01 | 2026-03-31 |
| POS:CN-00021 | POS | 1,758 | 45,142.35 | 40 tiendas | 2024-10-01 | 2026-03-31 |
| americano-cafe-grano-032 | Shopify | 404 | 42,251.71 | solo online | 2025-04-01 | 2026-03-30 |
| gourmet-cafe-molido-041 | Shopify | 414 | 33,607.71 | solo online | 2025-04-01 | 2026-03-26 |

## Tests

9 tests en `tests/test_pipeline.py`, corridos contra el dataset real (no fixtures sintéticos, dado el alcance del reto). Cubren específicamente los puntos donde este pipeline podría "correr sin error pero dar números mal": pérdida silenciosa de filas al conciliar fuentes (incluye el test de regresión del bug de huérfanos de inventario descrito en el punto 3 de supuestos), signo de las notas de crédito, duplicados, conversión de moneda, manejo de `NULL` vs. `0` en inventario, y consistencia entre la respuesta oficial de Q2 y su vista de sensibilidad.

## Limitaciones conocidas

- La rotación combinada (Q1) es una aproximación para el canal Shopify — no hay datos de inventario dedicado al canal online.
- La posible correspondencia entre SKUs huérfanos de POS y de ERP (punto 3) no se resolvió automáticamente; requiere confirmación del cliente.
- PII de `ecommerce_orders.parquet` (nombre, email, RFC, dirección) se descarta en `staging` por minimización de datos — no se necesita para ninguna de las 4 preguntas.
