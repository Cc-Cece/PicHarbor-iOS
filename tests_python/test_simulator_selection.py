import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("simulator_selector", Path(__file__).resolve().parents[1] / "tools/select_simulator.py")
selector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(selector)


class SimulatorSelectionTests(unittest.TestCase):
    def test_oldest_available_runtime_is_not_selected_for_new_sdk(self):
        devices = {"com.apple.CoreSimulator.SimRuntime.iOS-18-5": [{"name": "iPhone 16 Pro", "udid": "old"}],
                   "com.apple.CoreSimulator.SimRuntime.iOS-26-2": [{"name": "iPhone 17 Pro", "udid": "matching"}]}
        self.assertEqual(selector.select(devices, "26.2")[1], "matching")

    def test_incompatible_runtime_fails_before_building_or_launching(self):
        with self.assertRaisesRegex(RuntimeError, "matching iOS SDK"):
            selector.select({"com.apple.CoreSimulator.SimRuntime.iOS-18-5": [{"name": "iPhone", "udid": "old"}]}, "26.2")

    def test_unavailable_and_non_phone_devices_are_excluded(self):
        with self.assertRaises(RuntimeError):
            selector.select({"com.apple.CoreSimulator.SimRuntime.iOS-26-2": [
                {"name": "iPhone", "udid": "offline", "isAvailable": False},
                {"name": "iPad", "udid": "tablet"}]}, "26.2")
