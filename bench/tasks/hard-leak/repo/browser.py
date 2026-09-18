"""The browser screen: the one users open and close over and over."""

from __future__ import annotations

from widgets import Widget


def build_browser(screen: Widget) -> None:
    toolbar = Widget("toolbar")
    screen.add_child(toolbar)
    for label in ("back", "forward", "reload", "home"):
        toolbar.add_child(Widget(f"button:{label}"))

    content = Widget("content")
    screen.add_child(content)
    for index in range(8):
        content.add_child(Widget(f"row:{index}"))
