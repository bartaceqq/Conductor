"""Screen lifecycle for the embedded UI."""

from __future__ import annotations

from widgets import Widget


class ScreenManager:
    def __init__(self) -> None:
        self._stack: list[Widget] = []
        self.root = Widget("root")

    def open_screen(self, builder) -> Widget:
        screen = Widget("screen")
        self.root.add_child(screen)
        builder(screen)
        self._stack.append(screen)
        return screen

    def close_screen(self) -> None:
        if not self._stack:
            return
        screen = self._stack.pop()
        # Detach the screen from the root so it stops being drawn.
        self.root.children.remove(screen)
        screen.parent = None
