"""Source-boundary regressions; these do not replace SDK/device tests."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CameraPolicyTests(unittest.TestCase):
    def setUp(self):
        self.meeting = (ROOT / "CameraAccess/ViewModels/MeetingInterpreterViewModel.swift").read_text(encoding="utf-8")
        self.stream = (ROOT / "CameraAccess/ViewModels/StreamSessionViewModel.swift").read_text(encoding="utf-8")

    def test_only_explicit_photo_path_starts_camera(self):
        before, photo = self.meeting.split("    func describeCurrentScene()", 1)
        photo, after = photo.split("    private func handlePlaybackStateChange", 1)
        self.assertNotIn("handleStartStreaming()", before + after)
        self.assertEqual(photo.count("handleStartStreaming()"), 1)
        self.assertIn("guard mode.permitsCamera else { return }", photo)
        self.assertNotIn("visualAssist", self.meeting)

    def test_idle_camera_stop_returns_before_sdk_wait(self):
        stop = self.stream.split("  func stopSession() async {", 1)[1].split("  func dismissError", 1)[0]
        guard = "guard sessionStartTask != nil || streamingStatus != .stopped || captureOwner != nil else { return }"
        self.assertLess(stop.index(guard), stop.index("await sessionStartTask?.value"))
        self.assertLess(stop.index(guard), stop.index("await streamSession.stop()"))

    def test_camera_released_before_analysis_and_on_cancellation(self):
        photo = self.meeting.split("    func describeCurrentScene()", 1)[1].split("    private func handlePlaybackStateChange", 1)[0]
        self.assertLess(photo.index("await streamViewModel.stopSession()"), photo.index("try await jev.evaluate("))
        failure = photo.split("            } catch {", 1)[1]
        self.assertLess(failure.index("await streamViewModel.stopSession()"), failure.index("guard generation == self.generation"))

    def test_automatic_camera_setting_removed(self):
        settings = (ROOT / "CameraAccess/Views/UnifiedSettingsView.swift").read_text(encoding="utf-8")
        self.assertNotIn("MeetingSceneMode", settings)


if __name__ == "__main__":
    unittest.main()
