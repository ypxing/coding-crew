import os


class Tracker:
    """A tracker."""

    def __init__(self, root):
        self.root = root

    async def fetch(self, ref):
        return os.path.join(self.root, ref)


def parse(text):
    return text.strip()


async def walk(root):
    for entry in os.listdir(root):
        yield entry
