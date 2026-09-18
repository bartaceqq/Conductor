"""A tiny retained-mode widget tree with a global registry, like an embedded UI toolkit."""

from __future__ import annotations

# Every live widget is registered here so the renderer can walk them without recursing.
REGISTRY: list["Widget"] = []


class Widget:
    def __init__(self, name: str) -> None:
        self.name = name
        self.parent: Widget | None = None
        self.children: list[Widget] = []
        REGISTRY.append(self)

    def add_child(self, child: "Widget") -> None:
        child.parent = self
        self.children.append(child)

    def destroy(self) -> None:
        """Release this widget and everything below it."""
        for child in list(self.children):
            child.destroy()
        self.children.clear()
        if self.parent is not None and self in self.parent.children:
            self.parent.children.remove(self)
        self.parent = None
        if self in REGISTRY:
            REGISTRY.remove(self)


def live_widget_count() -> int:
    return len(REGISTRY)
