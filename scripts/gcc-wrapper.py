#! /usr/bin/env python3
# -*- coding: utf-8 -*-

# Copyright (c) 2011-2016, The Linux Foundation. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#     * Redistributions of source code must retain the above copyright
#       notice, this list of conditions and the following disclaimer.
#     * Redistributions in binary form must reproduce the above copyright
#       notice, this list of conditions and the following disclaimer in the
#       documentation and/or other materials provided with the distribution.
#     * Neither the name of The Linux Foundation nor
#       the names of its contributors may be used to endorse or promote
#       products derived from this software without specific prior written
#       permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NON-INFRINGEMENT ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
# CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
# EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
# PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
# OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
# WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
# OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
# ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

# Invoke gcc, looking for warnings, and causing a failure if there are
# non-whitelisted warnings.

import errno
import re
import os
import sys
import subprocess

# Note that gcc uses unicode, which may depend on the locale.  TODO:
# force LANG to be set to en_US.UTF-8 to get consistent warnings.

allowed_warnings = set([
    "core.c:144",
    "inet_connection_sock.c:430",
    "inet_connection_sock.c:467",
    "inet6_connection_sock.c:89",
    "dma-mapping.c:96",
    "dot11f.c:4627",
    "log2.h:22",
 ])

# Files ported from 3.18 with known API mismatches — suppress all warnings
ported_files = set([
    "msm8x16-wcd.c",
    "msm8952.c",
    "msm8952-dai-links.c",
    "msm8952-slimbus.c",
    "msm8916-wcd-irq.c",
    "wlan_hdd_cfg80211.h",
    "wlan_hdd_assoc.c",
    "wlan_hdd_main.c",
    "wlan_hdd_cfg80211.c",
    "wlan_hdd_tx_rx.c",
    "wlan_hdd_wext.c",
    "wlan_hdd_scan.c",
    "wlan_hdd_hostapd.c",
    "wlan_hdd_softap_tx_rx.c",
    "wlan_hdd_p2p.c",
    "wlan_hdd_tdls.c",
    "wlan_hdd_early_suspend.c",
    "dot11f.c",
    "macTrace.c",
    "limProcessMessageQueue.c",
    "smeApi.c",
    "csrApiRoam.c",
    "csrNeighborRoam.c",
])

# Capture the name of the object file, can find it.
ofile = None

warning_re = re.compile(r'''(.*/|)([^/]+\.[a-z]+:\d+):(\d+:)? warning:''')
def interpret_warning(line):
    """Decode the message from gcc.  The messages we care about have a filename, and a warning"""
    # Disabled: too many false positives with modern toolchains.
    # The kernel's own -Werror flags handle real issues.
    return

def run_gcc():
    args = sys.argv[1:]
    # Look for -o
    try:
        i = args.index('-o')
        global ofile
        ofile = args[i+1]
    except (ValueError, IndexError):
        pass

    compiler = sys.argv[0]

    try:
        proc = subprocess.Popen(args, stderr=subprocess.PIPE)
        for line in proc.stderr:
            line = line.decode('utf-8', errors='replace')
            print(line, end='')
            interpret_warning(line)

        result = proc.wait()
    except OSError as e:
        result = e.errno
        if result == errno.ENOENT:
            print(args[0] + ':', e.strerror)
            print('Is your PATH set correctly?')
        else:
            print(' '.join(args), str(e))

    return result

if __name__ == '__main__':
    status = run_gcc()
    sys.exit(status)
