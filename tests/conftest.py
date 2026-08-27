import sys
from pathlib import Path

import duckdb
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from cafenorte.pipeline import build_pipeline  # noqa: E402


@pytest.fixture(scope="session")
def con() -> duckdb.DuckDBPyConnection:
    """Corre el pipeline completo una sola vez, en memoria, para toda la sesión de tests."""
    connection = duckdb.connect(":memory:")
    build_pipeline(connection)
    return connection
