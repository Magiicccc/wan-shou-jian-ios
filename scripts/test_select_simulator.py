import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location(
    "select_simulator", Path(__file__).with_name("select-simulator.py")
)
selector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(selector)


class SimulatorSelectionTests(unittest.TestCase):
    def test_selects_newest_supported_available_iphone(self):
        payload = {"devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-16-4": [
                {"name": "iPhone 14", "udid": "old", "isAvailable": True}],
            "com.apple.CoreSimulator.SimRuntime.iOS-17-5": [
                {"name": "iPhone 15", "udid": "supported", "isAvailable": True}],
            "com.apple.CoreSimulator.SimRuntime.iOS-18-6": [
                {"name": "iPhone 16 Pro", "udid": "new", "isAvailable": True},
                {"name": "iPad Pro", "udid": "tablet", "isAvailable": True}],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
                {"name": "iPhone 17", "udid": "unavailable", "isAvailable": False}],
            "com.apple.CoreSimulator.SimRuntime.tvOS-26-0": [
                {"name": "iPhone fake", "udid": "wrong-runtime", "isAvailable": True}],
        }}
        self.assertEqual(selector.choose_simulator(payload), "new")

    def test_empty_and_unsupported_return_empty_id(self):
        self.assertEqual(selector.choose_simulator({}), "")
        self.assertEqual(selector.choose_simulator({"devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-16-4": [
                {"name": "iPhone 14", "udid": "old", "isAvailable": True}]
        }}), "")

    def test_orders_runtime_versions_numerically(self):
        payload = {"devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-18-9": [
                {"name": "iPhone", "udid": "nine", "isAvailable": True}],
            "com.apple.CoreSimulator.SimRuntime.iOS-18-10": [
                {"name": "iPhone", "udid": "ten", "isAvailable": True}],
        }}
        self.assertEqual(selector.choose_simulator(payload), "ten")


if __name__ == "__main__":
    unittest.main()
