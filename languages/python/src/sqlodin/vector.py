"""Immutable, finite float32 vectors with explicit dimensional bounds."""
import math
import struct
from collections.abc import Iterable, Iterator, Sequence
from dataclasses import dataclass


@dataclass(frozen=True, init=False)
class Vector(Sequence[float]):
    values: tuple[float, ...]

    def __init__(self, values: Iterable[float]):
        if isinstance(values, (str, bytes, bytearray)):
            raise TypeError('Vector expects numeric components; use Vector.from_bytes for a BLOB')
        normalized = []
        for value in values:
            if len(normalized) == 384:
                raise ValueError('A vector supports at most 384 dimensions')
            try:
                number = float(value)
                number = struct.unpack('<f', struct.pack('<f', number))[0]
            except (TypeError, ValueError, OverflowError, struct.error) as exc:
                raise ValueError('Vector components must fit finite float32') from exc
            if not math.isfinite(number):
                raise ValueError('Vector components must be finite')
            normalized.append(number)
        if not normalized:
            raise ValueError('A vector must have at least one dimension')
        object.__setattr__(self, 'values', tuple(normalized))

    def __len__(self) -> int:
        return len(self.values)

    def __getitem__(self, index):
        return self.values[index]

    def __iter__(self) -> Iterator[float]:
        return iter(self.values)

    def to_bytes(self) -> bytes:
        return struct.pack(f'<{len(self)}f', *self.values)

    @classmethod
    def from_bytes(cls, value: bytes) -> 'Vector':
        if not value or len(value) % 4 or len(value) > 384 * 4:
            raise ValueError('A float32 vector BLOB needs 1..384 four-byte components')
        return cls(struct.unpack(f'<{len(value) // 4}f', value))
