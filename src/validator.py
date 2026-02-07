from collections import deque
from typing import List, Tuple, Optional
from .base import MazeSolverBase, MazeEnvironment
from .generator import MazeGenerator


class MazeJudge:
    def __init__(self):
        self.generator = MazeGenerator()

    def _get_min_steps(self, env: MazeEnvironment) -> int:
        """Internal BFS to find the true shortest path for optimality check."""
        start = env.get_start()
        end = env.get_end()
        queue = deque([(start, 0)])
        visited = {start}

        while queue:
            curr, dist = queue.popleft()
            if curr == end:
                return dist
            for neighbor in env.get_successors(curr):
                if neighbor not in visited:
                    visited.add(neighbor)
                    queue.append((neighbor, dist + 1))
        return float("inf")

    def validate(
        self, path: List[Tuple[int, int]], env: MazeEnvironment, mode: str = "feasible"
    ) -> bool:
        """Checks if the path is valid and optionally optimal."""
        if not path or not isinstance(path, list):
            print("❌ Result is not a valid list of coordinates.")
            return False

        start = env.get_start()
        end = env.get_end()

        # 1. Start/End Check
        if path[0] != start:
            print(f"❌ Path must start at {start}.")
            return False
        if path[-1] != end:
            print(f"❌ Path must end at {end}.")
            return False

        # 2. Movement Check
        for i in range(1, len(path)):
            prev = path[i - 1]
            curr = path[i]

            # Distance must be 1
            dist = abs(curr[0] - prev[0]) + abs(curr[1] - prev[1])
            if dist != 1:
                print(f"❌ Illegal jump from {prev} to {curr}.")
                return False

            # Must be a valid neighbor (not a wall)
            if curr not in env.get_successors(prev):
                print(f"❌ Collision! {curr} is a wall or out of bounds.")
                return False

        # 3. Optimality
        actual_steps = len(path) - 1  # edges, not nodes
        if mode == "optimal":
            min_steps = self._get_min_steps(env)
            if actual_steps <= min_steps:
                print(f"🌟 Perfect! Optimal path found: {actual_steps} steps.")
                return True
            else:
                print(
                    f"❌ Feasible, but not optimal. Your steps: {actual_steps}, Best: {min_steps}"
                )
                return False

        print(f"✅ Feasible path found! Length: {actual_steps} steps.")
        return True

    def test_on_random(self, solver: MazeSolverBase, seed: int = 42):
        """Standard testing suite for learners."""
        print(f"--- Running Random Test (Seed: {seed}) ---")
        env = self.generator._generate_random(seed=seed)
        try:
            path = solver.search(env)
            self.validate(path, env, mode="optimal")
        except Exception as e:
            print(f"❌ Solver crashed during random test: {e}")
