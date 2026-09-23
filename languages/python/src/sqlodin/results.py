"""Owned, immutable results: iteration, named columns, and explicit cardinality."""
from collections.abc import Iterator, Mapping, Sequence
from dataclasses import dataclass
from typing import Any, overload


@dataclass(frozen=True)
class Row(Mapping[str, Any]):
    _columns: tuple[str, ...]
    _values: tuple[Any, ...]

    def __getitem__(self, key: str | int) -> Any:
        if isinstance(key, int):
            return self._values[key]
        try:
            return self._values[self._columns.index(key)]
        except ValueError:
            raise KeyError(key) from None

    def __iter__(self) -> Iterator[str]:
        return iter(dict.fromkeys(self._columns))

    def __len__(self) -> int:
        return len(set(self._columns))

    def as_tuple(self) -> tuple[Any, ...]:
        return self._values


@dataclass(frozen=True)
class Rows(Sequence[Row]):
    columns: tuple[str, ...]
    _rows: tuple[Row, ...]
    applied: int
    node: int

    @overload
    def __getitem__(self, index: int) -> Row: ...
    @overload
    def __getitem__(self, index: slice) -> tuple[Row, ...]: ...
    def __getitem__(self, index):
        return self._rows[index]

    def __len__(self) -> int:
        return len(self._rows)

    def first(self) -> Row | None:
        return self._rows[0] if self._rows else None

    def one(self) -> Row:
        if len(self) != 1:
            raise ValueError(f"Expected exactly one row, received {len(self)}")
        return self._rows[0]

    def scalar(self) -> Any:
        row = self.one()
        if len(self.columns) != 1:
            raise ValueError(f"Expected one column, received {len(self.columns)}")
        return row[0]


@dataclass(frozen=True)
class WriteResult:
    changes: int
    applied: int
    node: int
    sequence: int
