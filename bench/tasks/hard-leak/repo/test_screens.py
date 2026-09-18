import unittest

import widgets
from browser import build_browser
from screen_manager import ScreenManager


class ScreenLifecycleTests(unittest.TestCase):
    def test_opening_and_closing_the_browser_does_not_grow_the_registry(self) -> None:
        manager = ScreenManager()
        baseline = widgets.live_widget_count()
        for _ in range(20):
            manager.open_screen(build_browser)
            manager.close_screen()
        self.assertEqual(widgets.live_widget_count(), baseline)


if __name__ == "__main__":
    unittest.main()
