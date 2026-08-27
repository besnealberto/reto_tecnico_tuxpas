"""Punto de entrada: python run_pipeline.py"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "src"))

from cafenorte.pipeline import main

if __name__ == "__main__":
    main()
