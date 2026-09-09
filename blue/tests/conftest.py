from pathlib import Path

import pytest
from blue.cli import load_yaml

FIXTURE = Path(__file__).parent.parent.parent / "test" / "fixtures" / "colors.yml"


@pytest.fixture
def fixture() -> dict:
    state = load_yaml(FIXTURE.read_text())
    return {**state, "provider-backend":"r2", "blue/state-file": str(FIXTURE)}
