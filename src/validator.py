from collections import deque
from typing import List, Tuple, Optional, Set
import numpy as np


class MazeJudge:
    def __init__(self, grid: np.ndarray, start: Tuple[int, int], end: Tuple[int, int]):
        self.grid = grid
        self.start = start
        self.end = end
        self.optimal_path = self._find_shortest_path()
        self.min_steps = len(self.optimal_path) if self.optimal_path else float("inf")

    def _find_shortest_path(self) -> Optional[List[Tuple[int, int]]]:
        """Exhaustive BFS to find the absolute shortest path."""
        queue = deque([(self.start, [self.start])])
        visited = {self.start}

        while queue:
            (curr_r, curr_c), path = queue.popleft()
            if (curr_r, curr_c) == self.end:
                return path

            for dr, dc in [(0, 1), (0, -1), (1, 0), (-1, 0)]:
                nr, nc = curr_r + dr, curr_c + dc
                if (
                    0 <= nr < self.grid.shape[0]
                    and 0 <= nc < self.grid.shape[1]
                    and self.grid[nr, nc] == 0
                    and (nr, nc) not in visited
                ):
                    visited.add((nr, nc))
                    queue.append(((nr, nc), path + [(nr, nc)]))
        return None

    def validate(
        self, learner_path: List[Tuple[int, int]], mode: str = "feasible"
    ) -> bool:
        """
        Modes:
        - 'feasible': Checks if the path is valid and reaches the goal.
        - 'optimal': Checks if the path is the shortest possible.
        """
        # 1. Basic Validity (Walls, Jumps, Bounds)
        if not self._is_valid_structure(learner_path):
            return False

        # 2. Feasibility Check (Did they reach the end?)
        if learner_path[-1] != self.end:
            print(f"❌ Path ends at {learner_path[-1]}, but goal is {self.end}")
            return False

        if mode == "feasible":
            print(f"✅ Feasible path found! Length: {len(learner_path)}")
            return True

        # 3. Optimality Check
        if mode == "optimal":
            if len(learner_path) <= self.min_steps:
                print(
                    f"🌟 Perfect! You found the optimal path of {len(learner_path)} steps."
                )
                return True
            else:
                print(
                    f"❌ Path is feasible, but not optimal. Your steps: {len(learner_path)}, Best: {self.min_steps}"
                )
                return False

        return False

    def _is_valid_structure(self, path: List[Tuple[int, int]]) -> bool:
        if path is None:
            print("❌ Result is None. No path found.")
            return False

        # 1. Check Start and End
        if path[0] != self.start or path[-1] != self.end:
            print(f"❌ Path must start at {self.start} and end at {self.end}.")
            return False

        # 2. Check Continuity and Walls
        for i in range(len(path)):
            r, c = path[i]

            # Is it inside the grid?
            if not (0 <= r < self.grid.shape[0] and 0 <= c < self.grid.shape[1]):
                print(f"❌ Step {path[i]} is outside the grid!")
                return False

            # Is it a wall?
            if self.grid[r, c] == 1:
                print(f"❌ Collision! Step {path[i]} is a wall.")
                return False

            # Is it a valid move from the previous step? (Distance = 1)
            if i > 0:
                prev_r, prev_c = path[i - 1]
                dist = abs(r - prev_r) + abs(c - prev_c)
                if dist != 1:
                    print(f"❌ Illegal jump from {path[i-1]} to {path[i]}.")
                    return False

        print("✅ Success! You found a valid path.")
        return True
