#!/usr/bin/env python3
"""Send a command to the BQ268 via USB serial and print the output."""
import serial
import sys
import time

PORT = '/dev/ttyACM0'
BAUD = 115200
TIMEOUT = int(sys.argv[2]) if len(sys.argv) > 2 else 5
CMD = sys.argv[1] if len(sys.argv) > 1 else 'echo ok'

try:
    s = serial.Serial(PORT, BAUD, timeout=2)
except serial.SerialException as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)

# Drain any buffered output and get a clean prompt
s.reset_input_buffer()
s.write(b'\n')
time.sleep(0.2)
s.read(s.in_waiting)

# Send the command
s.write((CMD + '\n').encode())

# Read output until timeout
output = b''
deadline = time.time() + TIMEOUT
while time.time() < deadline:
    chunk = s.read(s.in_waiting or 1)
    if chunk:
        output += chunk
    else:
        time.sleep(0.1)

s.close()

# Decode and strip command echo + trailing prompt
lines = output.decode('utf-8', errors='replace').splitlines()
# Skip first line (command echo) and last line (prompt)
if lines and CMD in lines[0]:
    lines = lines[1:]
if lines and lines[-1].startswith('bq268#'):
    lines = lines[:-1]

print('\n'.join(lines))
