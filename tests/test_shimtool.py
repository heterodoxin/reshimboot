#!/usr/bin/env python3
# Tests for tools/shimtool.py using small synthetic images, so they run in CI
# without downloading the real multi-gigabyte shim and recovery images.
# Run with: python3 -m unittest discover -s tests

import gzip
import io
import lzma
import os
import struct
import subprocess
import sys
import tempfile
import unittest
import uuid
import zipfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
import shimtool  # noqa: E402

SECTOR = 512
KERNEL_TYPE = uuid.UUID("fe3a2a5d-4f32-41a7-b725-accc3285a309")
ROOTFS_TYPE = uuid.UUID("3cb8e202-3b7e-47dd-8a3c-7ff2a13cfcec")


def make_gpt_image(partitions, total_sectors):
  """Build a disk image. partitions is a list of (type, first_lba, sectors, name, fill_byte)."""
  image = bytearray(total_sectors * SECTOR)
  header = bytearray(SECTOR)
  header[0:8] = b"EFI PART"
  struct.pack_into("<Q", header, 32, total_sectors - 1)  #alternate lba
  struct.pack_into("<Q", header, 72, 2)  #entries lba
  struct.pack_into("<II", header, 80, 128, 128)
  image[SECTOR:SECTOR * 2] = header

  for i, (type_guid, first_lba, sectors, name, fill) in enumerate(partitions):
    entry = bytearray(128)
    entry[0:16] = type_guid.bytes_le
    entry[16:32] = uuid.uuid4().bytes_le
    struct.pack_into("<QQQ", entry, 32, first_lba, first_lba + sectors - 1, 0)
    encoded = name.encode("utf-16-le")
    entry[56:56 + len(encoded)] = encoded
    offset = 2 * SECTOR + i * 128
    image[offset:offset + 128] = entry
    image[first_lba * SECTOR:(first_lba + sectors) * SECTOR] = bytes([fill]) * (sectors * SECTOR)
  return bytes(image)


def make_cpio(files):
  """Build a newc cpio archive from a {name: bytes} dict."""
  out = bytearray()

  def add(name, data, mode):
    name_bytes = name.encode() + b"\x00"
    fields = [0, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(name_bytes), 0]
    out.extend(b"070701" + b"".join(b"%08X" % f for f in fields))
    out.extend(name_bytes)
    out.extend(b"\x00" * (-len(out) % 4))
    out.extend(data)
    out.extend(b"\x00" * (-len(out) % 4))

  for name, data in files.items():
    add(name, data, 0o100755)
  add("TRAILER!!!", b"", 0)
  return bytes(out)


def make_elf(init_data, version="5.4.85-test"):
  """Build a minimal 64 bit ELF with .text and .init.data sections."""
  text = b"\x90" * 64 + f"Linux version {version} (test@build)".encode() + b"\x00" * 16
  shstrtab = b"\x00.text\x00.init.data\x00.shstrtab\x00"
  body = bytearray(b"\x00" * 64)
  text_offset = len(body)
  body += text
  init_offset = len(body)
  body += init_data
  strtab_offset = len(body)
  body += shstrtab
  body += b"\x00" * (-len(body) % 8)
  shoff = len(body)

  def section(name_offset, offset, size):
    return struct.pack("<IIQQQQIIQQ", name_offset, 1, 0, 0, offset, size, 0, 0, 1, 0)

  body += b"\x00" * 64
  body += section(1, text_offset, len(text))
  body += section(7, init_offset, len(init_data))
  body += section(18, strtab_offset, len(shstrtab))

  body[0:4] = b"\x7fELF"
  body[4] = 2  #64 bit
  body[5] = 1  #little endian
  struct.pack_into("<Q", body, 0x28, shoff)
  struct.pack_into("<HHH", body, 0x3a, 64, 4, 3)
  return bytes(body)


def make_vboot_kernel(vmlinux):
  """Wrap a vmlinux the way a chrome os kernel partition does."""
  payload = gzip.compress(vmlinux)
  keyblock_size = 0x400
  preamble_size = 0x800
  body_offset = keyblock_size + preamble_size
  payload_offset = 0x200

  data = bytearray(body_offset + payload_offset + len(payload) + 0x2000)
  data[0:8] = b"CHROMEOS"
  struct.pack_into("<I", data, 16, keyblock_size)
  struct.pack_into("<I", data, keyblock_size, preamble_size)
  start = body_offset + payload_offset
  data[start:start + len(payload)] = payload

  #the setup header lives in a separate params page after the body
  header = len(data) - 0x1000
  data[header + 0x202:header + 0x206] = b"HdrS"
  struct.pack_into("<II", data, header + 0x248, payload_offset, len(payload))
  return bytes(data)


class GptTests(unittest.TestCase):
  def setUp(self):
    self.image = make_gpt_image([
      (KERNEL_TYPE, 64, 16, "KERN-A", 0x11),
      (ROOTFS_TYPE, 80, 32, "ROOT-A", 0x22),
    ], 200)

  def test_parse(self):
    parts = shimtool.parse_gpt(self.image)
    self.assertEqual([p.number for p in parts], [1, 2])
    self.assertEqual(parts[0].name, "KERN-A")
    self.assertEqual(parts[0].type_name, "chromeos-kernel")
    self.assertEqual(parts[1].offset, 80 * SECTOR)
    self.assertEqual(parts[1].size, 32 * SECTOR)

  def test_not_gpt(self):
    with self.assertRaises(shimtool.ShimToolError):
      shimtool.parse_gpt(b"\x00" * 4096)

  def test_extract_file_and_stream(self):
    with tempfile.TemporaryDirectory() as tmp:
      image_path = os.path.join(tmp, "disk.bin")
      with open(image_path, "wb") as f:
        f.write(self.image)
      out = os.path.join(tmp, "part2.bin")
      shimtool.extract_partitions(image_path, [(2, out)])
      with open(out, "rb") as f:
        self.assertEqual(f.read(), b"\x22" * 32 * SECTOR)

      #streaming from stdin
      out1 = os.path.join(tmp, "p1.bin")
      out2 = os.path.join(tmp, "p2.bin")
      result = subprocess.run(
        [sys.executable, shimtool.__file__, "extract", "-", f"1:{out1}", f"2:{out2}"],
        input=self.image, capture_output=True)
      self.assertEqual(result.returncode, 0, result.stderr)
      with open(out1, "rb") as f:
        self.assertEqual(f.read(), b"\x11" * 16 * SECTOR)


class KernelTests(unittest.TestCase):
  def setUp(self):
    self.cpio = make_cpio({"init": b"#!/bin/sh\necho hi\n", "bin/busybox": b"\x7fELF fake"})
    init_data = b"\x00" * 100 + lzma.compress(self.cpio, format=lzma.FORMAT_XZ) + b"\x00" * 100
    self.vmlinux = make_elf(init_data)
    self.kernel = make_vboot_kernel(self.vmlinux)

  def test_vmlinux(self):
    self.assertEqual(shimtool.extract_vmlinux(self.kernel), self.vmlinux)

  def test_version(self):
    self.assertEqual(shimtool.kernel_version(self.vmlinux), "5.4.85-test")

  def test_xz_initramfs(self):
    self.assertTrue(shimtool.find_initramfs(self.vmlinux).startswith(self.cpio))

  def test_uncompressed_initramfs(self):
    vmlinux = make_elf(b"\x00" * 64 + self.cpio)
    self.assertTrue(shimtool.find_initramfs(vmlinux).startswith(self.cpio))

  def test_cpio_unpacks(self):
    with tempfile.TemporaryDirectory() as tmp:
      kernel_path = os.path.join(tmp, "kernel.bin")
      with open(kernel_path, "wb") as f:
        f.write(self.kernel)
      cpio_data = subprocess.run([sys.executable, shimtool.__file__, "initramfs", kernel_path],
                                 capture_output=True, check=True).stdout
      out_dir = os.path.join(tmp, "out")
      os.mkdir(out_dir)
      subprocess.run(["cpio", "-imd", "--quiet"], input=cpio_data, cwd=out_dir, check=True)
      with open(os.path.join(out_dir, "init"), "rb") as f:
        self.assertEqual(f.read(), b"#!/bin/sh\necho hi\n")

  def test_corrupt_payload(self):
    kernel = bytearray(self.kernel)
    kernel[0xc00 + 0x200 + 40] ^= 0xff  #inside the gzip payload
    with self.assertRaises(shimtool.ShimToolError):
      shimtool.extract_vmlinux(bytes(kernel))


class NonSeekable(io.RawIOBase):
  """A write-only stream, which makes zipfile use zip64 data descriptors."""

  def __init__(self):
    self.data = bytearray()

  def writable(self):
    return True

  def write(self, b):
    self.data += b
    return len(b)


class UnzipTests(unittest.TestCase):
  def setUp(self):
    self.image = make_gpt_image([
      (KERNEL_TYPE, 64, 16, "KERN-A", 0x11),
      (ROOTFS_TYPE, 80, 32, "ROOT-A", 0x22),
      (ROOTFS_TYPE, 1000, 3000, "STATE", 0x33),
    ], 4100)
    self.tmp = tempfile.TemporaryDirectory()

  def tearDown(self):
    self.tmp.cleanup()

  def zipped(self, streamed):
    if streamed:
      raw = NonSeekable()
      with zipfile.ZipFile(raw, "w", zipfile.ZIP_DEFLATED) as z:
        with z.open("image.bin", "w", force_zip64=True) as f:
          f.write(self.image)
      return bytes(raw.data)
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as z:
      z.writestr("image.bin", self.image)
    return buffer.getvalue()

  def unzip(self, data, keep_parts=None, verify=False):
    out = os.path.join(self.tmp.name, "out.bin")
    result = shimtool.stream_unzip(io.BytesIO(data), out, keep_parts, verify)
    with open(out, "rb") as f:
      return result, f.read()

  def test_full_verified(self):
    for streamed in (False, True):
      result, data = self.unzip(self.zipped(streamed))
      self.assertEqual(result, "verified")
      self.assertEqual(data, self.image)

  def test_partial_stops_early(self):
    result, data = self.unzip(self.zipped(True), keep_parts=[1, 2])
    self.assertEqual(result, "partial")
    self.assertEqual(len(data), len(self.image))  #sparse, but full size
    self.assertEqual(data[64 * SECTOR:112 * SECTOR], self.image[64 * SECTOR:112 * SECTOR])
    self.assertEqual(data[1000 * SECTOR:1001 * SECTOR], b"\x00" * SECTOR)  #STATE was skipped

  def test_partial_verified(self):
    result, data = self.unzip(self.zipped(True), keep_parts=[2], verify=True)
    self.assertEqual(result, "verified")
    self.assertEqual(data[80 * SECTOR:112 * SECTOR], b"\x22" * 32 * SECTOR)

  def test_crc_mismatch(self):
    #change the stored crc so that the data no longer matches it
    data = bytearray(self.zipped(False))
    struct.pack_into("<I", data, 14, struct.unpack_from("<I", data, 14)[0] ^ 1)
    with self.assertRaises(shimtool.ShimToolError):
      self.unzip(bytes(data))

  def test_truncated(self):
    data = self.zipped(True)
    with self.assertRaises(shimtool.ShimToolError):
      self.unzip(data[:len(data) // 2])

  def test_not_a_zip(self):
    with self.assertRaises(shimtool.ShimToolError):
      self.unzip(b"<html><body>404 not found</body></html>")


if __name__ == "__main__":
  unittest.main()
