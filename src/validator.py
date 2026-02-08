from collections import deque
from typing import List, Tuple, Optional
from .base import MazeSolverBase, MazeEnvironment


class MazeJudge:
    def __init__(self, generator):
        self.generator = generator

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
        """
        Checks if the path is valid and optionally optimal.
        Raises ValueError or RuntimeError if the path is invalid.
        """
        # 0. Type Check
        if not path or not isinstance(path, list):
            raise ValueError("The result must be a valid list of (r, c) tuples.")

        start = env.get_start()
        end = env.get_end()

        # 1. Start/End Check
        if path[0] != start:
            raise ValueError(
                f"Invalid Start: Path must start at {start}, but started at {path[0]}."
            )
        if path[-1] != end:
            raise ValueError(
                f"Invalid End: Path must end at {end}, but ended at {path[-1]}."
            )

        # 2. Movement Check
        for i in range(1, len(path)):
            prev = path[i - 1]
            curr = path[i]

            # Distance check (no diagonal moves or teleports)
            dist = abs(curr[0] - prev[0]) + abs(curr[1] - prev[1])
            if dist != 1:
                raise RuntimeError(
                    f"Illegal Jump: Movement from {prev} to {curr} is not adjacent."
                )

            # Successor check (ensure it's not a wall)
            if curr not in env.get_successors(prev):
                raise RuntimeError(
                    f"Collision: {curr} is a wall or out of bounds from {prev}."
                )

        # 3. Optimality Check
        actual_steps = len(path) - 1
        if mode == "optimal":
            min_steps = self._get_min_steps(env)
            if actual_steps > min_steps:
                raise RuntimeError(
                    f"Suboptimal Path: Your path took {actual_steps} steps, "
                    f"but the best possible is {min_steps} steps."
                )

            return True

        return True

    def test_on_random(
        self, solver: MazeSolverBase, seed: Optional[int] = 42, num_tests: int = 1
    ):
        """
        Standard testing suite for learners.
        Runs multiple tests to ensure the solver works across different maze instances.
        """
        print(f"--- Running {num_tests} Random Test(s) ---")

        for i in range(num_tests):
            current_seed = seed + i if seed is not None else None
            env = self.generator._generate_random(seed=current_seed)

            try:
                path = solver.search(env)
                self.validate(path, env, mode="optimal")
                print(f"✅ Test {i+1}/{num_tests} passed!")
            except (ValueError, RuntimeError, PermissionError) as e:
                # Re-raise the error to stop execution and force the learner to fix it
                print(f"❌ Test {i+1}/{num_tests} failed.")
                raise type(e)(f"Validation Failed on test {i+1}: {e}")
            except Exception as e:
                print(f"💥 Test {i+1}/{num_tests} crashed.")
                raise RuntimeError(f"Solver crashed with an unexpected error: {e}")

        print(f"\n🌟 All {num_tests} tests passed successfully!")
