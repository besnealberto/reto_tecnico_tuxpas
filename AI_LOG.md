# AI_LOG — Bitácora de uso de IA

## 1. Herramientas

- **Claude Code** (modelo Claude Sonnet 5, `claude-sonnet-5`), corriendo en modo CLI/agente dentro de VS Code, en una sola sesión continua de principio a fin del reto.
- Sin Cursor, Copilot ni ChatGPT en paralelo para este reto — todo el trabajo de código, datos y redacción salió de esta misma conversación.
- No se usó ningún MCP server externo para la construcción del pipeline (no se necesitó: los datos son archivos locales). Sí se usó la herramienta de preguntas estructuradas de Claude Code (`AskUserQuestion`) como mecanismo de checkpoint explícito en las decisiones de arquitectura.

## 2. Flujo de trabajo

Un solo agente, sin subagentes ni paralelización — el alcance (2-4h efectivas, un pipeline + una propuesta + esta bitácora) no lo justificaba. No se usó "plan mode" formal; en su lugar se impuso una disciplina equivalente por instrucción explícita desde el primer prompt: **nada de código hasta tener contexto completo, y nada de ejecución dentro del repo sin explicación previa y consentimiento**.

En la práctica, el flujo tuvo 3 momentos con fricción deliberada (checkpoints antes de avanzar):

1. **Contexto antes que código.** Antes de escribir una sola línea, se le pidió a la IA perfilar los 4 archivos de datos reales (no solo leer el enunciado). Eso sacó a la luz varias trampas del dataset (ver §3) que cambiaron decisiones de diseño *antes* de que existiera código que corregir después.
2. **Decisiones de arquitectura como preguntas cerradas, no como texto libre.** Para el stack, el alcance de AWS y el idioma, la IA no asumió: presentó opciones concretas con una recomendación y esperó respuesta. Esto evitó tener que deshacer trabajo por un supuesto mal calibrado.
3. **Ejecución en bloques, con verificación intermedia.** El pipeline se construyó por capas (staging → conformado → marts → preguntas) y se corrió después de cada bloque grande, no solo al final — así se detectó el bug de §4 mientras aún era barato corregirlo.

## 3. Prompts clave

**Prompt 1 — Carga de contexto inicial.**
> "@[docx del reto]... por ahora solo necesito que tengas el contexto de la prueba... no comiences a generar ningún tipo de código..."

La IA extrajo el docx (tuvo que resolver por su cuenta que `pandoc` no estaba instalado y usar un fallback de unzip + parseo de XML) y devolvió un resumen estructurado del reto completo, sin tocar el repo. *Se aceptó tal cual* — el resumen era correcto y permitió pasar directo a la siguiente fase sin retrabajo.

**Prompt 2 — Rol, reglas y especificaciones técnicas (el prompt largo con ROL/CONTEXTO/ACLARACIONES).**
La IA, en vez de empezar a codificar, instaló `duckdb` (pidiendo permiso primero) y perfiló los 4 archivos reales de datos, encontrando: que `tipo_comprobante` en `sales.csv` son códigos CFDI que hay que filtrar y no solo sumar, que `ecommerce_orders` mezcla 3 monedas, y que la ventana de snapshots de inventario coincide exacto con "últimos 6 meses". Luego hizo 3 preguntas cerradas (stack, alcance AWS, idioma) antes de proponer un plan. *Se aceptaron las 3 recomendaciones por defecto* (DuckDB, propuesta AWS solo en papel, todo en español) — estaban bien justificadas y no valía la pena desviarse.

**Prompt 3 — Corrección de las secciones 2, 7 y 8 de supuestos.**
Se le pidió a la IA no descartar productos sin costo (marcarlos con warning en vez de excluirlos), no dejar fuera el canal Shopify de la rotación de inventario, y bajar el umbral de quiebre de stock de 3 a 2 días. En los dos primeros puntos, la IA ejecutó el cambio directo. En el tercero, **la IA no obedeció de inmediato**: señaló que el enunciado oficial del reto pide literalmente "más de 3 días" y que cambiarlo silenciosamente arriesgaba el 25% de correctitud técnica, y propuso mantener la respuesta oficial fiel al enunciado + agregar la vista de 2 días como insight adicional. *Se aceptó la alternativa de la IA, no el pedido original* — el riesgo que señaló era real y no lo había puesto en la balanza.

**Prompt 4 — "confirmo, avanza a fase 2".**
Con solo esa instrucción, la IA construyó sin supervisión línea por línea: capas de ingesta (Python para aplanar el JSON anidado del ERP), 8 archivos SQL, el runner del pipeline, y 9 tests — corriendo y corrigiendo errores propios en el camino (ver §4). *Se aceptó el resultado tras revisar el output y los tests*, no a ciegas: se pidió ver los CSV de salida antes de continuar.

**Prompt 5 — "vamos a la fase 6, pero antes hagamos un commit".**
Instrucción operativa breve. La IA hizo `git add` selectivo (no `-A`), escribió un mensaje de commit descriptivo, y explícitamente **no** hizo push sin pedirlo aparte. *Aceptado tal cual* — es el comportamiento esperado por instrucción previa de no tomar acciones de mayor alcance sin permiso explícito.

## 4. Caso concreto: la IA se equivocó, y el error era real

Al construir `dim_producto` (la clave canónica que reconcilia POS/ERP/Shopify), la primera versión de la IA la armó **solo "de abajo hacia arriba"**: a partir de lo que aparecía vendido en `sales.csv` y `ecommerce_orders`, más el catálogo de mapeos. El pipeline corrió sin ningún error.

El problema: 10 `sku_erp` del catálogo/ERP tienen costo e inventario registrados pero **nunca fueron vendidos por un canal con mapeo conocido** — así que no entraban en `dim_producto`, y al hacer el `JOIN` para construir `fact_inventario`, sus filas de snapshot se descartaban en silencio. No hubo ningún error visible: solo un `fact_inventario` con 197,652 filas en vez de las 230,776 reales (**14.3% perdido, sin aviso**).

**Cómo se detectó:** no lo noté yo revisando el código — lo detectó un test de conteo (`SELECT COUNT(*)` crudo vs. modelado) que la propia IA escribió como parte de la batería de tests mínimos exigida por el reto. Al escribir el test `test_no_hay_perdida_silenciosa_de_inventario`, el número no cuadraba.

**Cómo se corrigió:** se agregó a `dim_producto` un tercer grupo de "huérfanos" (sku_erp de catálogo sin mapeo alguno), preservando esas filas de inventario. Al corregirlo, salió a la luz un quiebre de stock real de 4 días en la tienda T023 que antes era completamente invisible para el análisis.

**Por qué importa:** es exactamente el red flag que describe el propio reto — "un pipeline que corre sin error pero produce números incorrectos". La lección no es "la IA se equivocó" en abstracto, sino que **el error solo salió a la luz porque hubo un test de conteo explícito**, no porque el pipeline "se viera bien". Sin ese test, esta versión se habría entregado con un 14% de inventario perdido en silencio.

## 5. Autocrítica final

*[Nota: esta sección la redactó la IA en primera persona de Alex como punto de partida — revísala y ajústala antes de entregar, porque en la entrevista quien la defiende es Alex, no la IA.]*

Considero 100% mío el criterio de negocio: qué cuenta como venta, cómo tratar los productos huérfanos, dónde trazar la línea entre "responder lo que pide el reto" y "agregar valor sin desviarme del enunciado" (el caso del umbral de 2 vs. 3 días). El mérito de la IA está en la ejecución rápida y ordenada del SQL/Python una vez tomadas esas decisiones, y en la disciplina de escribir tests de conteo que yo probablemente no habría priorizado con el tiempo tan ajustado — ese hábito fue justo lo que atrapó el bug de §4. Validé que el output es correcto más allá de "corre sin error" de tres formas: revisando los CSV de salida fila por fila antes de aceptarlos (no solo el conteo de filas), verificando a mano el signo de las notas de crédito contra el dato crudo, y forzando que los 9 tests pasen contra el dataset real (no fixtures sintéticos) antes de considerar cerrada cada fase.
