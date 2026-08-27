"""Orquesta el pipeline de CaféNorte: ingesta -> staging -> conformado -> marts -> preguntas."""
from pathlib import Path

import duckdb

from cafenorte.ingest import build_raw_views

ROOT = Path(__file__).resolve().parents[2]
SQL_DIR = ROOT / "sql"
OUTPUT_DIR = ROOT / "output"


def run_sql_script(con: duckdb.DuckDBPyConnection, sql_path: Path) -> None:
    """Ejecuta un archivo .sql con una o más sentencias separadas por ';'.

    Los comentarios de línea (-- ...) se descartan antes de partir por ';',
    porque el propio texto de los comentarios de este proyecto usa ';' como
    puntuación normal.
    """
    script = sql_path.read_text(encoding="utf-8")
    lines_without_comments = [
        line.split("--", 1)[0] for line in script.splitlines()
    ]
    clean_script = "\n".join(lines_without_comments)
    for statement in clean_script.split(";"):
        statement = statement.strip()
        if statement:
            con.execute(statement)


def build_pipeline(con: duckdb.DuckDBPyConnection) -> None:
    build_raw_views(con)
    for layer in ("staging", "conformed", "marts"):
        for sql_file in sorted((SQL_DIR / layer).glob("*.sql")):
            run_sql_script(con, sql_file)


def run_questions(con: duckdb.DuckDBPyConnection, output_dir: Path = OUTPUT_DIR) -> dict[str, "pd.DataFrame"]:
    output_dir.mkdir(parents=True, exist_ok=True)
    results = {}
    for sql_file in sorted((SQL_DIR / "questions").glob("*.sql")):
        df = con.execute(sql_file.read_text(encoding="utf-8")).fetchdf()
        results[sql_file.stem] = df
        df.to_csv(output_dir / f"{sql_file.stem}.csv", index=False)
    return results


def get_connection(db_path: Path | None = None) -> duckdb.DuckDBPyConnection:
    target = str(db_path) if db_path else str(ROOT / "cafenorte.duckdb")
    return duckdb.connect(target)


def main() -> None:
    con = get_connection()
    build_pipeline(con)
    results = run_questions(con)
    for name, df in results.items():
        print(f"\n=== {name} ({len(df)} filas) ===")
        print(df.to_string(index=False))


if __name__ == "__main__":
    main()
