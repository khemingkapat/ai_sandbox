import numpy as np
from typing import List, Tuple, Optional
from .base import MazeEnvironment


class InternalMazeEnv(MazeEnvironment):
    """
    Concrete implementation of the environment.
    Uses 'visible' flag to prevent cheating in random mode.
    """

    def __init__(
        self,
        grid: np.ndarray,
        start: Tuple[int, int],
        end: Tuple[int, int],
        visible: bool = False,
    ):
        self._grid = grid
        self._start = start
        self._end = end
        self._visible = visible
        self.rows, self.cols = grid.shape

    def get_start(self) -> Tuple[int, int]:
        return self._start

    def get_end(self) -> Tuple[int, int]:
        return self._end

    def get_successors(self, pos: Tuple[int, int]) -> List[Tuple[int, int]]:
        r, c = pos
        neighbors = []
        for dr, dc in [(0, 1), (0, -1), (1, 0), (-1, 0)]:
            nr, nc = r + dr, c + dc
            if 0 <= nr < self.rows and 0 <= nc < self.cols:
                if self._grid[nr, nc] == 0:  # 0 is path, 1 is wall
                    neighbors.append((nr, nc))
        return neighbors

    def get_heuristic(self, pos: Tuple[int, int]) -> float:
        # Manhattan Distance: |x1 - x2| + |y1 - y2|
        return float(abs(pos[0] - self._end[0]) + abs(pos[1] - self._end[1]))

    def get_grid(self) -> List[List[int]]:
        if not self._visible:
            raise PermissionError(
                "Access Denied: You cannot view the full grid in this mode. Use get_successors() instead."
            )
        return self._grid.tolist()


class MazeGenerator:
    def generate_fixed(self) -> MazeEnvironment:
        """Returns a 5x5 maze where the learner can see the whole map."""
        grid = np.array(
            [
                [0, 0, 1, 0, 0],
                [1, 0, 1, 0, 1],
                [0, 0, 0, 0, 0],
                [0, 1, 0, 1, 0],
                [0, 0, 0, 1, 0],
            ]
        )
        return InternalMazeEnv(grid, (0, 0), (4, 4), visible=True)

    def _generate_random(self, seed: Optional[int] = None) -> MazeEnvironment:
        """
        System-only: Returns a maze where get_grid() is disabled.
        Currently returns a static 'test' maze for logic verification.
        """
        if seed is not None:
            np.random.seed(seed)

        # Placeholder: Different from fixed to check if they hardcoded
        grid = np.array(
            [
                [0, 1, 0, 0, 0],
                [0, 1, 0, 1, 0],
                [0, 0, 0, 1, 0],
                [1, 1, 0, 1, 0],
                [0, 0, 0, 0, 0],
            ]
        )
        return InternalMazeEnv(grid, (0, 0), (4, 4), visible=False)
