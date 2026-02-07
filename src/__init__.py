from .generator import MazeGenerator


def get_new_quiz(size=10):
    gen = MazeGenerator(size)
    return gen.generate()
