import numpy as np
import random
from typing import List, Tuple, Optional, Callable
from .base import MazeEnvironment, MazeGeneratorBase


class InternalMazeEnv(MazeEnvironment):
    """
    Concrete implementation of the environment.
    Allows for custom heuristic functions to be passed in.
    """

    def __init__(
        self,
        grid: np.ndarray,
        start: Tuple[int, int],
        end: Tuple[int, int],
        visible: bool = False,
        heuristic_func: Optional[
            Callable[[Tuple[int, int], Tuple[int, int]], float]
        ] = None,
    ):
        self._grid = grid
        self._start = start
        self._end = end
        self._visible = visible
        self.rows, self.cols = grid.shape

        # Use provided function or default to Manhattan distance
        self._heuristic_func = heuristic_func or self._default_manhattan

    def _default_manhattan(self, p1: Tuple[int, int], p2: Tuple[int, int]) -> float:
        return float(abs(p1[0] - p2[0]) + abs(p1[1] - p2[1]))

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
        # Calculate using the internal function
        return float(self._heuristic_func(pos, self._end))

    def get_grid(self) -> List[List[int]]:
        if not self._visible:
            raise PermissionError(
                "Access Denied: You cannot view the full grid in this mode."
            )
        return self._grid.tolist()


class StandardMazeGenerator(MazeGeneratorBase):
    """Normal generator with accurate heuristics."""

    def _get_layouts(self) -> List[np.ndarray]:
        """Centralized list of maze layouts. Index 0 is used for 'fixed' mode."""
        return [
            # Index 0: Fixed Maze (5x5)
            np.array(
                [
                    [0, 0, 0, 0, 0],
                    [0, 1, 1, 0, 0],
                    [0, 0, 0, 0, 0],
                    [0, 0, 1, 0, 0],
                    [0, 0, 1, 0, 0],
                ]
            ),
            # Maze A: 6x6
            np.array(
                [
                    [0, 0, 0, 1, 0, 0],
                    [1, 1, 0, 1, 0, 1],
                    [0, 0, 0, 0, 0, 0],
                    [0, 1, 1, 1, 1, 0],
                    [0, 0, 0, 1, 0, 0],
                    [1, 1, 0, 0, 0, 0],
                ]
            ),
            # Maze B: 7x5
            np.array(
                [
                    [0, 1, 0, 0, 0],
                    [0, 1, 0, 1, 0],
                    [0, 0, 0, 1, 0],
                    [1, 1, 0, 1, 0],
                    [0, 0, 0, 0, 0],
                    [0, 1, 1, 1, 0],
                    [0, 0, 0, 0, 0],
                ]
            ),
            # Maze C: 8x8
            np.array(
                [
                    [0, 0, 0, 0, 0, 0, 0, 0],
                    [0, 1, 1, 1, 1, 1, 1, 0],
                    [0, 1, 0, 0, 0, 0, 1, 0],
                    [0, 1, 0, 1, 1, 0, 1, 0],
                    [0, 1, 0, 1, 1, 0, 1, 0],
                    [0, 1, 0, 0, 0, 0, 1, 0],
                    [0, 1, 1, 1, 1, 1, 1, 0],
                    [0, 0, 0, 0, 0, 0, 0, 0],
                ]
            ),
        ]

    def generate_fixed(self) -> MazeEnvironment:
        """Returns the first layout with the full map visible."""
        grid = self._get_layouts()[0]
        return InternalMazeEnv(grid, (0, 0), (4, 4), visible=True)

    def _generate_random(
        self, seed: Optional[int] = None, heuristic_func: Optional[Callable] = None
    ) -> MazeEnvironment:
        """Returns a randomly selected maze (excluding fixed) with optional custom heuristic."""
        if seed is not None:
            random.seed(seed)
            np.random.seed(seed)

        # We skip index 0 to ensure 'random' doesn't just pick the 'fixed' one
        grid = random.choice(self._get_layouts()[1:])
        valid_cells = list(zip(*np.where(grid == 0)))
        start, end = random.sample(valid_cells, k=2)

        return InternalMazeEnv(
            grid, start, end, visible=False, heuristic_func=heuristic_func
        )


class FaultyMazeGenerator(StandardMazeGenerator):
    """
    Challenge Generator: Heuristics are multiplied by 1-5 randomly.
    Affects both fixed and random modes.
    """

    def _apply_faulty_logic(
        self,
        grid: np.ndarray,
        start: Tuple[int, int],
        end: Tuple[int, int],
        visible: bool,
        heuristic_func: Optional[Callable],
    ) -> MazeEnvironment:
        """Helper to create the environment with a faulty wrapper."""
        base_h_func = heuristic_func or self._default_manhattan_static

        # Every time get_heuristic is called, a new random multiplier is applied
        def faulty_wrapper(p1: Tuple[int, int], p2: Tuple[int, int]) -> float:
            return float(base_h_func(p1, p2)) * random.uniform(1.0, 5.0)

        return InternalMazeEnv(
            grid, start, end, visible=visible, heuristic_func=faulty_wrapper
        )

    def generate_fixed(self) -> MazeEnvironment:
        """Returns the fixed maze but with a faulty heuristic function."""
        grid = self._get_layouts()[0]
        return self._apply_faulty_logic(
            grid, (0, 0), (4, 4), visible=True, heuristic_func=None
        )

    def _generate_random(
        self, seed: Optional[int] = None, heuristic_func: Optional[Callable] = None
    ) -> MazeEnvironment:
        """Override to inject faulty logic into random generation."""
        if seed is not None:
            random.seed(seed)
            np.random.seed(seed)

        grid = random.choice(self._get_layouts()[1:])
        valid_cells = list(zip(*np.where(grid == 0)))
        start, end = random.sample(valid_cells, k=2)

        return self._apply_faulty_logic(grid, start, end, False, heuristic_func)

    def _default_manhattan_static(
        self, p1: Tuple[int, int], p2: Tuple[int, int]
    ) -> float:
        """Static helper for the faulty wrapper."""
        return float(abs(p1[0] - p2[0]) + abs(p1[1] - p2[1]))
