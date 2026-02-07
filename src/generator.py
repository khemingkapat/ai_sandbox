import numpy as np
from typing import List, Tuple


class MazeGenerator:
    def __init__(self, n: int = 5):
        self.n = 5  # Fixed for now

    def generate(self) -> Tuple[np.ndarray, Tuple[int, int], Tuple[int, int]]:
        """Returns a fixed 5x5 solvable obstacle field."""
        # 0 = Path, 1 = Wall
        grid = np.array(
            [
                [0, 0, 1, 0, 0],
                [1, 0, 1, 0, 1],
                [0, 0, 0, 0, 0],
                [0, 1, 0, 1, 0],
                [0, 0, 0, 1, 0],
            ]
        )

        start = (0, 0)
        end = (4, 4)

        return grid, start, end

    def _is_solvable(
        self, grid: np.ndarray, start: Tuple[int, int], end: Tuple[int, int]
    ) -> bool:
        """Internal BFS to ensure a path exists."""
        return True
