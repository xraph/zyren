import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    "run_check", Path(__file__).with_name("run_check.py"))
run_check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(run_check)


class SourceSnapshotTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        original = run_check.ROOT
        self.addCleanup(setattr, run_check, "ROOT", original)
        run_check.ROOT = self.root
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        self.write(".gitignore", "build/\n.dart_tool/\n")
        self.write("packages/core/lib/scene.dart", "class Scene {}\n")
        run_check.git("add", ".")
        run_check.git("-c", "user.name=Qualification test", "-c",
                      "user.email=qualification@example.invalid", "commit",
                      "-qm", "Create source fixture")

    def write(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def test_each_qualification_target_changes_the_digest(self):
        for name in ["examples/shader_lab/lib/physical.dart",
                     "examples/planet/integration_test/atmosphere_test.dart",
                     "tool/build_native.py"]:
            with self.subTest(source=name):
                self.write(name, "original\n")
                before = run_check.snapshot()
                self.write(name, "changed\n")
                after = run_check.snapshot()
                self.assertNotEqual(before["source_digest"],
                                    after["source_digest"])
                self.assertNotEqual(before["files"][name], after["files"][name])

    def test_generated_outputs_do_not_change_source_digest(self):
        before = run_check.snapshot()
        self.write("examples/shader_lab/build/app.bin", "generated")
        self.write("examples/planet/.dart_tool/kernel", "generated")
        after = run_check.snapshot()
        self.assertEqual(before["source_digest"], after["source_digest"])


if __name__ == "__main__":
    unittest.main()
