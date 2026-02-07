from abc import ABC, abstractmethod
from typing import List, Tuple, Optional


class MazeSolverBase(ABC):
    """
    Template for the learner's solver.
    The learner MUST override the search method.
    """

    @abstractmethod
    def search(
        self, grid: List[List[int]], start: Tuple[int, int], end: Tuple[int, int]
    ) -> Optional[List[Tuple[int, int]]]:
        """
        Your implementation goes here.
        """
        pass
