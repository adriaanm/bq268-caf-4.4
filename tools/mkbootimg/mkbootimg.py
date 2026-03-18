#!/usr/bin/env python3
"""
Simple boot image packer for Android boot images (header version 0)
Based on boot_img_hdr structure from AOSP
"""
import struct
import sys
import hashlib

BOOT_MAGIC = b'ANDROID!'
BOOT_MAGIC_SIZE = 8
BOOT_NAME_SIZE = 16
BOOT_ARGS_SIZE = 512
BOOT_EXTRA_ARGS_SIZE = 1024

def pad_to_page(data, page_size=2048):
    """Pad data to page size boundary"""
    remainder = len(data) % page_size
    if remainder:
        data += b'\x00' * (page_size - remainder)
    return data

def create_boot_image(kernel, ramdisk, dtb, cmdline, board, page_size=2048,
                      kernel_addr=0x80008000, ramdisk_addr=0x81000000,
                      tags_addr=0x80000100):
    """
    Create an Android boot image (header version 0)

    Header format (1632 bytes before id):
    - magic[8]: "ANDROID!"
    - kernel_size[4]
    - kernel_addr[4]
    - ramdisk_size[4]
    - ramdisk_addr[4]
    - second_size[4]
    - second_addr[4]
    - tags_addr[4]
    - page_size[4]
    - dtb_size (unused in v0, but often used) [4]
    - os_version[4]
    - name[16]
    - cmdline[512]
    - id[32] (SHA hash)
    - extra_cmdline[1024]
    Total header: 1632 bytes, then padded to page_size
    """

    # Pad components
    kernel_padded = pad_to_page(kernel, page_size)
    ramdisk_padded = pad_to_page(ramdisk, page_size)
    dtb_padded = pad_to_page(dtb, page_size) if dtb else b''

    # OS version encoding: (major << 25) | (minor << 18) | (micro << 11) | patch_level
    # Android 8.1.0, patch 2019-03 = (8 << 25) | (1 << 18) | (0 << 11) | (2019 << 0) would overflow
    # Actually: os_patch_level = ((year - 2000) << 4) | month
    # For 2019-03: (19 << 4) | 3 = 307
    # os_version = (major << 14) | (minor << 7) | micro
    # For 8.1.0: (8 << 14) | (1 << 7) | 0 = 131200
    os_version = (8 << 14) | (1 << 7) | 0  # 8.1.0
    os_patch = (19 << 4) | 3  # 2019-03
    os_version_patch = (os_version << 11) | os_patch

    # Board name (16 bytes, null-padded)
    board_bytes = board.encode('utf-8')[:BOOT_NAME_SIZE].ljust(BOOT_NAME_SIZE, b'\x00')

    # Command line (512 bytes, null-padded)
    cmdline_bytes = cmdline.encode('utf-8')[:BOOT_ARGS_SIZE]
    cmdline_bytes = cmdline_bytes.ljust(BOOT_ARGS_SIZE, b'\x00')

    # Extra cmdline (1024 bytes) - unused
    extra_cmdline = b'\x00' * BOOT_EXTRA_ARGS_SIZE

    # Construct header without id
    header_base = (
        BOOT_MAGIC +
        struct.pack('<I', len(kernel)) +           # kernel_size
        struct.pack('<I', kernel_addr) +           # kernel_addr
        struct.pack('<I', len(ramdisk)) +          # ramdisk_size
        struct.pack('<I', ramdisk_addr) +          # ramdisk_addr
        struct.pack('<I', 0) +                     # second_size
        struct.pack('<I', 0) +                     # second_addr
        struct.pack('<I', tags_addr) +             # tags_addr
        struct.pack('<I', page_size) +             # page_size
        struct.pack('<I', len(dtb) if dtb else 0) +# dtb_size (header_version field in v0)
        struct.pack('<I', os_version_patch) +      # os_version
        board_bytes +                              # name[16]
        cmdline_bytes                              # cmdline[512]
    )

    # Calculate SHA1 hash for id (hash of kernel, ramdisk, and optionally second/dtb)
    sha = hashlib.sha1()
    sha.update(kernel)
    sha.update(ramdisk)
    if dtb:
        sha.update(dtb)
    img_id = sha.digest() + b'\x00' * 12  # Pad to 32 bytes

    # Complete header
    header = header_base + img_id + extra_cmdline

    # Pad header to page size
    header = pad_to_page(header, page_size)

    # Combine all parts: header + kernel + ramdisk + dtb
    boot_img = header + kernel_padded + ramdisk_padded + dtb_padded

    return boot_img

def main():
    if len(sys.argv) < 5:
        print("Usage: mkbootimg.py <kernel> <ramdisk> <dtb> <output> [cmdline]")
        sys.exit(1)

    kernel_path = sys.argv[1]
    ramdisk_path = sys.argv[2]
    dtb_path = sys.argv[3]
    output_path = sys.argv[4]
    cmdline = sys.argv[5] if len(sys.argv) > 5 else "androidboot.hardware=qcom"

    with open(kernel_path, 'rb') as f:
        kernel = f.read()

    with open(ramdisk_path, 'rb') as f:
        ramdisk = f.read()

    with open(dtb_path, 'rb') as f:
        dtb = f.read()

    boot_img = create_boot_image(kernel, ramdisk, dtb, cmdline, "")

    with open(output_path, 'wb') as f:
        f.write(boot_img)

    print(f"Created boot image: {output_path} ({len(boot_img)} bytes)")

if __name__ == '__main__':
    main()
