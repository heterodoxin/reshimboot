#!/usr/bin/env python3
# reshimboot: helpers for reading Chrome OS disk images and kernels.
#
# This replaces the old binwalk based extraction. Instead of scanning for
# magic bytes, it follows the actual on-disk structures:
#
#   GPT disk image -> KERN-A partition -> vboot keyblock + preamble
#   -> kernel body (x86 protected mode code) -> compressed payload
#   -> vmlinux ELF -> embedded initramfs (usually xz or uncompressed cpio)
#
# Only the python standard library is required. lz4 and zstd payloads are
# handed off to the lz4/zstd command line tools if they are installed.
#
# Copyright (C) 2026 reshimboot contributors
# Licensed under the GNU GPL v3, see the LICENSE file for details.

import argparse
import bz2
import gzip
import lzma
import re
import shutil
import struct
import subprocess
import sys
import uuid
import zlib

SECTOR = 512
GPT_SIGNATURE = b"EFI PART"
VBOOT_MAGIC = b"CHROMEOS"
BZIMAGE_MAGIC = b"HdrS"

GPT_TYPES = {
  "fe3a2a5d-4f32-41a7-b725-accc3285a309": "chromeos-kernel",
  "3cb8e202-3b7e-47dd-8a3c-7ff2a13cfcec": "chromeos-rootfs",
  "0fc63daf-8483-4772-8e79-3d69d8477de4": "linux-data",
  "ebd0a0a2-b9e5-4433-87c0-68b6b72699c7": "basic-data",
  "c12a7328-f81f-11d2-ba4b-00a0c93ec93b": "efi-system",
}

COMPRESSION_MAGICS = [
  (b"\x1f\x8b\x08", "gzip"),
  (b"\xfd7zXZ\x00", "xz"),
  (b"\x28\xb5\x2f\xfd", "zstd"),
  (b"\x02\x21\x4c\x18", "lz4"),
  (b"BZh", "bzip2"),
  (b"\x5d\x00\x00", "lzma"),
]


class ShimToolError(Exception):
  pass


# ---------------------------------------------------------------------------
# GPT parsing
# ---------------------------------------------------------------------------

class Partition:
  def __init__(self, number, type_guid, part_guid, first_lba, last_lba, attrs, name):
    self.number = number
    self.type_guid = type_guid
    self.part_guid = part_guid
    self.first_lba = first_lba
    self.last_lba = last_lba
    self.attrs = attrs
    self.name = name

  @property
  def offset(self):
    return self.first_lba * SECTOR

  @property
  def size(self):
    return (self.last_lba - self.first_lba + 1) * SECTOR

  @property
  def type_name(self):
    return GPT_TYPES.get(self.type_guid, self.type_guid)


def parse_gpt(header_and_entries):
  """Parse a GPT from a buffer that starts at LBA 0 of the disk."""
  header = header_and_entries[SECTOR:SECTOR * 2]
  if header[:8] != GPT_SIGNATURE:
    raise ShimToolError("no GPT signature found, this is not a Chrome OS disk image")
  entries_lba, = struct.unpack_from("<Q", header, 72)
  num_entries, entry_size = struct.unpack_from("<II", header, 80)
  table_start = entries_lba * SECTOR
  table_end = table_start + num_entries * entry_size
  if len(header_and_entries) < table_end:
    raise ShimToolError("GPT partition table is truncated")

  partitions = []
  for i in range(num_entries):
    entry = header_and_entries[table_start + i * entry_size:table_start + (i + 1) * entry_size]
    type_guid = str(uuid.UUID(bytes_le=entry[0:16]))
    if type_guid == "00000000-0000-0000-0000-000000000000":
      continue
    part_guid = str(uuid.UUID(bytes_le=entry[16:32]))
    first_lba, last_lba, attrs = struct.unpack_from("<QQQ", entry, 32)
    name = entry[56:128].decode("utf-16-le", errors="replace").split("\x00")[0]
    partitions.append(Partition(i + 1, type_guid, part_guid, first_lba, last_lba, attrs, name))
  return partitions


def gpt_table_size(header_bytes):
  header = header_bytes[SECTOR:SECTOR * 2]
  if header[:8] != GPT_SIGNATURE:
    raise ShimToolError("no GPT signature found, this is not a Chrome OS disk image")
  entries_lba, = struct.unpack_from("<Q", header, 72)
  num_entries, entry_size = struct.unpack_from("<II", header, 80)
  return entries_lba * SECTOR + num_entries * entry_size


def read_gpt_from_file(path):
  with open(path, "rb") as f:
    start = f.read(SECTOR * 2)
    table_size = gpt_table_size(start)
    f.seek(0)
    return parse_gpt(f.read(table_size))


def find_partition(partitions, number):
  for part in partitions:
    if part.number == number:
      return part
  raise ShimToolError(f"partition {number} does not exist")


def read_exact(stream, size):
  chunks = []
  remaining = size
  while remaining > 0:
    chunk = stream.read(min(remaining, 1 << 20))
    if not chunk:
      break
    chunks.append(chunk)
    remaining -= len(chunk)
  return b"".join(chunks)


def extract_partitions(source, requests):
  """Copy partitions out of a disk image.

  source is either a path or "-" for stdin. When reading from stdin, the
  image is streamed and reading stops as soon as every requested partition
  has been written, so the rest of a huge image never needs to be stored.
  """
  stream = sys.stdin.buffer if source == "-" else open(source, "rb")
  try:
    start = read_exact(stream, SECTOR * 2)
    table_size = gpt_table_size(start)
    table = start + read_exact(stream, table_size - len(start))
    partitions = parse_gpt(table)
    position = len(table)

    jobs = []
    for number, out_path in requests:
      part = find_partition(partitions, number)
      jobs.append((part, out_path))
    jobs.sort(key=lambda job: job[0].offset)

    for part, out_path in jobs:
      if part.offset < position:
        if source == "-":
          raise ShimToolError(f"partition {part.number} overlaps an earlier request, cannot stream it")
        stream.seek(part.offset)
        position = part.offset
      else:
        skip = part.offset - position
        if source == "-":
          while skip > 0:
            skipped = len(stream.read(min(skip, 1 << 20)))
            if skipped == 0:
              raise ShimToolError("image ended before the requested partition")
            skip -= skipped
        else:
          stream.seek(part.offset)
        position = part.offset

      remaining = part.size
      with open(out_path, "wb") as out:
        while remaining > 0:
          chunk = stream.read(min(remaining, 4 << 20))
          if not chunk:
            raise ShimToolError(f"image ended in the middle of partition {part.number}")
          out.write(chunk)
          remaining -= len(chunk)
      position += part.size
  finally:
    if stream is not sys.stdin.buffer:
      stream.close()


# ---------------------------------------------------------------------------
# streaming zip extraction
# ---------------------------------------------------------------------------

ZIP_LOCAL_HEADER = 0x04034b50
ZIP_DATA_DESCRIPTOR = 0x08074b50
ZIP64_EXTRA_ID = 0x0001
OUT_CHUNK = 16 << 20


class ImageWriter:
  """Write a disk image, optionally keeping only some of its partitions.

  When partitions are selected, everything else is left as a hole in a sparse
  file, and the writer reports when every selected byte has been written so
  the caller can stop reading the rest of the download.
  """

  def __init__(self, path, keep_parts):
    self.file = open(path, "wb")
    self.keep_parts = keep_parts
    self.position = 0
    self.header = b""
    self.ranges = None
    self.stop_at = None
    self.disk_size = None

  def _setup_ranges(self):
    table_size = gpt_table_size(self.header)
    if len(self.header) < table_size:
      return False
    partitions = parse_gpt(self.header[:table_size])
    alternate_lba, = struct.unpack_from("<Q", self.header, SECTOR + 32)
    self.disk_size = (alternate_lba + 1) * SECTOR
    self.ranges = [(0, table_size)]
    for number in self.keep_parts:
      part = find_partition(partitions, number)
      self.ranges.append((part.offset, part.offset + part.size))
    self.stop_at = max(end for _, end in self.ranges)
    return True

  def write(self, data):
    if not self.keep_parts:
      self.file.write(data)
      self.position += len(data)
      return

    start = self.position
    self.position += len(data)
    if self.ranges is None:
      needed = (1 << 20) - len(self.header)
      if needed > 0:
        self.header += data[:needed]
      if len(self.header) >= SECTOR * 2:
        self._setup_ranges()
    if self.ranges is None:
      #the gpt is always in the first few kilobytes, so just keep it for now
      self.file.seek(start)
      self.file.write(data)
      return

    end = self.position
    for range_start, range_end in self.ranges:
      lo = max(start, range_start)
      hi = min(end, range_end)
      if lo < hi:
        self.file.seek(lo)
        self.file.write(data[lo - start:hi - start])

  @property
  def done(self):
    return self.stop_at is not None and self.position >= self.stop_at

  def close(self):
    if self.disk_size is not None:
      #extend to the full size so partition offsets stay valid
      self.file.truncate(self.disk_size)
    self.file.close()


def parse_zip64_extra(extra, uncompressed, compressed):
  offset = 0
  while offset + 4 <= len(extra):
    header_id, size = struct.unpack_from("<HH", extra, offset)
    body = extra[offset + 4:offset + 4 + size]
    if header_id == ZIP64_EXTRA_ID:
      fields = [f[0] for f in struct.iter_unpack("<Q", body[:len(body) // 8 * 8])]
      if uncompressed == 0xffffffff and fields:
        uncompressed = fields.pop(0)
      if compressed == 0xffffffff and fields:
        compressed = fields.pop(0)
    offset += 4 + size
  return uncompressed, compressed


def stream_unzip(stream, out_path, keep_parts=None, verify=False):
  """Extract the first file of a zip archive that is read as a stream.

  Unlike funzip, this handles zip64 archives (anything over 4 GB, which
  includes the dedede shim and recovery images) and checks the CRC32.
  When keep_parts is given, only those partitions are written and reading
  stops as soon as they are complete, unless verify is set.
  Returns "verified" or "partial".
  """
  header = read_exact(stream, 30)
  if len(header) < 30:
    raise ShimToolError("the download is empty or not a zip file")
  (signature, _, flags, method, _, _, crc, compressed, uncompressed,
   name_length, extra_length) = struct.unpack("<IHHHHHIIIHH", header)
  if signature != ZIP_LOCAL_HEADER:
    raise ShimToolError("the download is not a zip file (it may be an error page)")
  if flags & 1:
    raise ShimToolError("encrypted zip files are not supported")
  name = read_exact(stream, name_length).decode(errors="replace")
  extra = read_exact(stream, extra_length)
  uncompressed, compressed = parse_zip64_extra(extra, uncompressed, compressed)
  print(f"shimtool: extracting {name}", file=sys.stderr)

  writer = ImageWriter(out_path, keep_parts or [])
  actual_crc = 0
  total = 0
  trailing = b""
  try:
    if method == 0:
      if flags & 8:
        raise ShimToolError("stored zip entries with data descriptors are not supported")
      remaining = compressed
      while remaining > 0:
        chunk = stream.read(min(remaining, 1 << 20))
        if not chunk:
          raise ShimToolError("the download ended early")
        remaining -= len(chunk)
        actual_crc = zlib.crc32(chunk, actual_crc)
        total += len(chunk)
        writer.write(chunk)
        if writer.done and not verify:
          return "partial"
    elif method == 8:
      decompressor = zlib.decompressobj(-zlib.MAX_WBITS)
      while not decompressor.eof:
        chunk = stream.read(1 << 20)
        if not chunk:
          raise ShimToolError("the download ended early, the file is incomplete")
        data = decompressor.decompress(chunk, OUT_CHUNK)
        while True:
          if data:
            actual_crc = zlib.crc32(data, actual_crc)
            total += len(data)
            writer.write(data)
            if writer.done and not verify:
              return "partial"
          if not decompressor.unconsumed_tail or decompressor.eof:
            break
          data = decompressor.decompress(decompressor.unconsumed_tail, OUT_CHUNK)
      trailing = decompressor.unused_data
    else:
      raise ShimToolError(f"unsupported zip compression method {method}")

    if flags & 8:
      #the crc is stored after the data, optionally with a signature
      trailing += read_exact(stream, max(0, 16 - len(trailing)))
      if struct.unpack_from("<I", trailing, 0)[0] == ZIP_DATA_DESCRIPTOR:
        trailing = trailing[4:]
      crc, = struct.unpack_from("<I", trailing, 0)
    if actual_crc != crc:
      raise ShimToolError(f"CRC mismatch ({actual_crc:08x} != {crc:08x}), the download is corrupted")
    if uncompressed not in (0, 0xffffffff) and total != uncompressed:
      raise ShimToolError(f"size mismatch ({total} != {uncompressed}), the download is corrupted")
    return "verified"
  finally:
    writer.close()


# ---------------------------------------------------------------------------
# kernel parsing
# ---------------------------------------------------------------------------

def locate_kernel_body(data):
  """Return (body_offset, setup_header_offset) for a vboot kernel or bzImage."""
  headers = [m.start() - 0x202 for m in re.finditer(re.escape(BZIMAGE_MAGIC), data)]
  headers = [h for h in headers if h >= 0]
  if not headers:
    raise ShimToolError("no x86 boot protocol header (HdrS) found in the kernel")

  if data[:8] == VBOOT_MAGIC:
    #chrome os kernel partition: keyblock, then preamble, then the kernel body
    #the bzImage setup header is stored separately in the params page
    keyblock_size, = struct.unpack_from("<I", data, 16)
    preamble_size, = struct.unpack_from("<I", data, keyblock_size)
    body = keyblock_size + preamble_size
    return [(body, h) for h in headers]

  #plain bzImage: protected mode code follows the real mode setup sectors
  candidates = []
  for h in headers:
    setup_sects = data[h + 0x1f1] or 4
    candidates.append((h + (setup_sects + 1) * SECTOR, h))
  return candidates


def detect_compression(blob):
  for magic, name in COMPRESSION_MAGICS:
    if blob.startswith(magic):
      return name
  return None


def run_decompressor(command, blob):
  if not shutil.which(command[0]):
    raise ShimToolError(f"{command[0]} is needed to decompress this kernel, please install it")
  result = subprocess.run(command, input=blob, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
  if not result.stdout:
    raise ShimToolError(f"{command[0]} failed to decompress the kernel")
  return result.stdout


def decompress(blob, kind):
  """Decompress one stream, ignoring any trailing data after it."""
  if kind == "gzip":
    d = zlib.decompressobj(16 + zlib.MAX_WBITS)
    return d.decompress(blob)
  if kind == "xz":
    d = lzma.LZMADecompressor(format=lzma.FORMAT_XZ)
    return d.decompress(blob)
  if kind == "lzma":
    d = lzma.LZMADecompressor(format=lzma.FORMAT_ALONE)
    return d.decompress(blob)
  if kind == "bzip2":
    d = bz2.BZ2Decompressor()
    return d.decompress(blob)
  if kind == "zstd":
    return run_decompressor(["zstd", "-dc"], blob)
  if kind == "lz4":
    return run_decompressor(["lz4", "-dc"], blob)
  raise ShimToolError(f"unknown compression {kind}")


def extract_vmlinux(data):
  errors = []
  for body, header in locate_kernel_body(data):
    try:
      payload_offset, payload_length = struct.unpack_from("<II", data, header + 0x248)
    except struct.error:
      continue
    start = body + payload_offset
    payload = data[start:start + payload_length]
    kind = detect_compression(payload)
    if not kind:
      errors.append(f"unknown payload format at {start:#x}")
      continue
    try:
      vmlinux = decompress(payload, kind)
    except (OSError, EOFError, lzma.LZMAError, zlib.error, ShimToolError) as e:
      errors.append(f"{kind} payload at {start:#x}: {e}")
      continue
    if vmlinux[:4] == b"\x7fELF":
      return vmlinux
    errors.append(f"{kind} payload at {start:#x} is not an ELF file")
  raise ShimToolError("could not extract vmlinux: " + "; ".join(errors or ["no candidates"]))


def elf_sections(vmlinux):
  """Yield (name, file_offset, size) for each section of a 64 bit ELF file."""
  if vmlinux[4] != 2:
    return
  shoff, = struct.unpack_from("<Q", vmlinux, 0x28)
  shentsize, shnum, shstrndx = struct.unpack_from("<HHH", vmlinux, 0x3a)
  if shoff == 0 or shoff + shnum * shentsize > len(vmlinux):
    return

  def header(i):
    return struct.unpack_from("<IIQQQQIIQQ", vmlinux, shoff + i * shentsize)

  strtab = header(shstrndx)
  names = vmlinux[strtab[4]:strtab[4] + strtab[5]]
  for i in range(shnum):
    sh = header(i)
    end = names.find(b"\x00", sh[0])
    yield names[sh[0]:end].decode(errors="replace"), sh[4], sh[5]


def looks_like_cpio(blob):
  return blob[:6] in (b"070701", b"070702") and b"TRAILER!!!" in blob


def find_initramfs(vmlinux):
  #limit the search to the sections that can hold the initramfs when possible
  regions = []
  for name, offset, size in elf_sections(vmlinux):
    if name in (".init.ramfs", ".init.data"):
      regions.append((offset, size))
  if not regions:
    regions = [(0, len(vmlinux))]

  for region_start, region_size in regions:
    region = vmlinux[region_start:region_start + region_size]

    #uncompressed initramfs
    for match in re.finditer(rb"07070[12]", region):
      candidate = region[match.start():]
      if looks_like_cpio(candidate):
        return candidate

    #compressed initramfs
    for magic, kind in COMPRESSION_MAGICS:
      for match in re.finditer(re.escape(magic), region):
        try:
          candidate = decompress(region[match.start():], kind)
        except (OSError, EOFError, lzma.LZMAError, zlib.error, ShimToolError):
          continue
        if looks_like_cpio(candidate):
          return candidate

  raise ShimToolError("could not find the initramfs inside the kernel")


def kernel_version(vmlinux):
  match = re.search(rb"Linux version (\S+)", vmlinux)
  if not match:
    raise ShimToolError("could not find the kernel version string")
  return match.group(1).decode()


def kernel_cmdline(data):
  if data[:8] != VBOOT_MAGIC:
    raise ShimToolError("not a Chrome OS kernel partition")
  for match in re.finditer(rb"[ -~]{32,}", data):
    text = match.group().decode()
    if "cros_" in text or "root=" in text:
      return text.strip()
  raise ShimToolError("could not find the kernel command line")


# ---------------------------------------------------------------------------
# command line interface
# ---------------------------------------------------------------------------

def read_file(path):
  if path == "-":
    return sys.stdin.buffer.read()
  with open(path, "rb") as f:
    return f.read()


def write_output(path, data):
  if path == "-":
    sys.stdout.buffer.write(data)
  else:
    with open(path, "wb") as f:
      f.write(data)


def cmd_gpt(args):
  partitions = read_gpt_from_file(args.image)
  if args.part is not None:
    part = find_partition(partitions, args.part)
    print(part.offset if args.field == "offset" else part.size if args.field == "size" else part.name)
    return
  for part in partitions:
    print(f"{part.number}\t{part.first_lba}\t{part.last_lba - part.first_lba + 1}\t{part.type_name}\t{part.name}")


def cmd_extract(args):
  requests = []
  for spec in args.parts:
    number, _, path = spec.partition(":")
    if not number.isdigit() or not path:
      raise ShimToolError(f"invalid partition request '{spec}', expected NUMBER:PATH")
    requests.append((int(number), path))
  extract_partitions(args.image, requests)


def cmd_unzip(args):
  keep_parts = []
  if args.parts:
    for number in args.parts.split(","):
      if not number.strip().isdigit():
        raise ShimToolError(f"invalid partition number '{number}'")
      keep_parts.append(int(number))
  stream = sys.stdin.buffer if args.zip == "-" else open(args.zip, "rb")
  try:
    result = stream_unzip(stream, args.output, keep_parts, args.verify)
  finally:
    if stream is not sys.stdin.buffer:
      stream.close()
  print(f"shimtool: {result}", file=sys.stderr)


def cmd_initramfs(args):
  vmlinux = extract_vmlinux(read_file(args.kernel))
  write_output(args.output, find_initramfs(vmlinux))


def cmd_version(args):
  print(kernel_version(extract_vmlinux(read_file(args.kernel))))


def cmd_cmdline(args):
  print(kernel_cmdline(read_file(args.kernel)))


def main(argv=None):
  parser = argparse.ArgumentParser(description="Read Chrome OS disk images and kernels.")
  sub = parser.add_subparsers(dest="command", required=True)

  p = sub.add_parser("gpt", help="list the partitions of a disk image")
  p.add_argument("image")
  p.add_argument("--part", type=int, help="only print information about this partition")
  p.add_argument("--field", choices=["offset", "size", "name"], default="offset")
  p.set_defaults(func=cmd_gpt)

  p = sub.add_parser("extract", help="copy partitions out of a disk image ('-' streams from stdin)")
  p.add_argument("image")
  p.add_argument("parts", nargs="+", metavar="NUMBER:PATH")
  p.set_defaults(func=cmd_extract)

  p = sub.add_parser("unzip", help="extract a zipped disk image as a stream, with zip64 and crc checks")
  p.add_argument("zip", help="the zip file, or '-' to read from stdin")
  p.add_argument("output")
  p.add_argument("--parts", help="only keep these partitions (comma separated) and stop reading once they are done")
  p.add_argument("--verify", action="store_true", help="with --parts, keep reading to the end to check the crc")
  p.set_defaults(func=cmd_unzip)

  p = sub.add_parser("initramfs", help="extract the initramfs cpio archive from a kernel")
  p.add_argument("kernel")
  p.add_argument("output", nargs="?", default="-")
  p.set_defaults(func=cmd_initramfs)

  p = sub.add_parser("kernel-version", help="print the version of a kernel")
  p.add_argument("kernel")
  p.set_defaults(func=cmd_version)

  p = sub.add_parser("cmdline", help="print the command line stored in a Chrome OS kernel partition")
  p.add_argument("kernel")
  p.set_defaults(func=cmd_cmdline)

  args = parser.parse_args(argv)
  try:
    args.func(args)
  except ShimToolError as e:
    print(f"shimtool: error: {e}", file=sys.stderr)
    return 1
  except BrokenPipeError:
    return 0
  return 0


if __name__ == "__main__":
  sys.exit(main())
