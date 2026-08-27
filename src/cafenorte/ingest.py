"""Carga las 4 fuentes crudas de CaféNorte como vistas de DuckDB, sin transformar.

inventory.json no es tabular: mezcla metadata, catálogo de tiendas, mapeo de SKUs
y snapshots diarios en un solo objeto anidado. Aquí se aplana cada arreglo a su
propio DataFrame antes de registrarlo; la limpieza/tipado real ocurre después,
en sql/staging.
"""
import json
from pathlib import Path

import duckdb
import pandas as pd

DATA_DIR = Path(__file__).resolve().parents[2] / "data" / "raw"


def _load_inventory_json(path: Path) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)

    tiendas_df = pd.DataFrame(data["tiendas_info"])
    sku_map_df = pd.DataFrame(data["sku_mappings"])
    snapshots_df = pd.DataFrame(data["snapshots"])

    cost_rows = []
    for producto in data["catalogo"]["productos"]:
        for costo in producto["cost_history"]:
            cost_rows.append(
                {
                    "sku_erp": producto["sku_erp"],
                    "nombre": producto["nombre"],
                    "categoria": producto["categoria"],
                    **costo,
                }
            )
    cost_df = pd.DataFrame(cost_rows)
    return tiendas_df, sku_map_df, snapshots_df, cost_df


def build_raw_views(con: duckdb.DuckDBPyConnection, data_dir: Path = DATA_DIR) -> None:
    """Registra las 4 fuentes como vistas raw_* dentro de la conexión dada."""
    tiendas_df, sku_map_df, snapshots_df, cost_df = _load_inventory_json(
        data_dir / "inventory.json"
    )
    con.register("raw_tiendas", tiendas_df)
    con.register("raw_sku_mappings", sku_map_df)
    con.register("raw_snapshots", snapshots_df)
    con.register("raw_cost_history", cost_df)

    sales_path = (data_dir / "sales.csv").as_posix()
    ecommerce_path = (data_dir / "ecommerce_orders.parquet").as_posix()
    rates_path = (data_dir / "exchange_rates.csv").as_posix()

    con.execute(f"CREATE OR REPLACE VIEW raw_sales AS SELECT * FROM read_csv_auto('{sales_path}')")
    con.execute(f"CREATE OR REPLACE VIEW raw_ecommerce AS SELECT * FROM read_parquet('{ecommerce_path}')")
    con.execute(f"CREATE OR REPLACE VIEW raw_exchange_rates AS SELECT * FROM read_csv_auto('{rates_path}')")
