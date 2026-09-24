#!/usr/bin/env python3
# Tests for tools/patch_systemd.py against a small copy of the code it edits.
# Run with: python3 -m unittest discover -s tests

import os
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "tools", "patch_systemd.py")

#mount_nofollow() as it looks in systemd 257 to 262
ORIGINAL = """int mount_fd(const char *source, int target_fd, const char *filesystemtype,
             unsigned long mountflags, const void *data) {
        return 0;
}

int mount_nofollow(
                const char *source,
                const char *target,
                const char *filesystemtype,
                unsigned long mountflags,
                const void *data) {

        _cleanup_close_ int fd = -EBADF;

        if (true) {
                fd = open(target, O_PATH|O_CLOEXEC|O_NOFOLLOW);
        }
        if (fd < 0)
                return -errno;

        return mount_fd(source, fd, filesystemtype, mountflags, data);
}

const char *mount_propagation_flag_to_string(unsigned long flags) {
        return NULL;
}
"""


class PatchSystemdTest(unittest.TestCase):
  def run_patch(self, source):
    with tempfile.TemporaryDirectory() as src_dir:
      path = os.path.join(src_dir, "src", "basic", "mountpoint-util.c")
      os.makedirs(os.path.dirname(path))
      with open(path, "w") as f:
        f.write(source)
      result = subprocess.run([sys.executable, SCRIPT, src_dir], capture_output=True, text=True)
      with open(path) as f:
        return result, f.read()

  def test_replaces_the_function_body(self):
    result, patched = self.run_patch(ORIGINAL)
    self.assertEqual(result.returncode, 0, result.stderr)
    body = patched[patched.index("int mount_nofollow("):patched.index("const char *mount_propagation")]
    self.assertIn("return RET_NERRNO(mount(source, target, filesystemtype, mountflags, data));", body)
    self.assertNotIn("O_NOFOLLOW", body)
    #the code around it is left alone
    self.assertIn("int mount_fd(const char *source", patched)
    self.assertIn("const char *mount_propagation_flag_to_string(unsigned long flags) {\n        return NULL;\n}", patched)

  def test_patching_twice_changes_nothing(self):
    _, patched = self.run_patch(ORIGINAL)
    result, patched_again = self.run_patch(patched)
    self.assertEqual(result.returncode, 0, result.stderr)
    self.assertEqual(patched, patched_again)

  def test_fails_when_the_function_is_missing(self):
    result, _ = self.run_patch("int something_else(void) {\n        return 0;\n}\n")
    self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
  unittest.main()
