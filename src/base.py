from abc import ABC, abstractmethod
from typing import List, Tuple, Optional


class MazeEnvironment(ABC):
    """
    The interface the learner uses to interact with the maze.
    In 'Blind' mode, get_grid() will raise an error.
    """

    @abstractmethod
    def get_start(self) -> Tuple[int, int]:
        """Returns the (r, c) starting position."""
        pass

    @abstractmethod
    def get_end(self) -> Tuple[int, int]:
        """Returns the (r, c) goal position."""
        pass

    @abstractmethod
    def get_successors(self, pos: Tuple[int, int]) -> List[Tuple[int, int]]:
        """Returns a list of walkable adjacent (r, c) coordinates."""
        pass

    @abstractmethod
    def get_heuristic(self, pos: Tuple[int, int]) -> float:
        """Returns the estimated distance from pos to the goal."""
        pass

    @abstractmethod
    def get_grid(self) -> List[List[int]]:
        """
        Returns the full matrix.
        Only works if the environment was created in 'visible' mode.
        """
        pass


class MazeSolverBase(ABC):
    """
    Template for the learner's solver.
    """

    @abstractmethod
    def search(self, env: MazeEnvironment) -> Optional[List[Tuple[int, int]]]:
        """
        Learner implementation.
        Should return a list of (r, c) tuples from start to end.
        """
        pass


class MazeGeneratorBase(ABC):
    """
    Base class for different types of maze generators (Standard, Faulty, etc.)
    """

    @abstractmethod
    def generate_fixed(self) -> MazeEnvironment:
        """Generates a known, static maze."""
        pass

    @abstractmethod
    def _generate_random(self, seed: Optional[int] = None) -> MazeEnvironment:
        """Generates a maze with randomized start/end and layout."""
        pass
