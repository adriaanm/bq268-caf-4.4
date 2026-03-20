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
    s = serial.Serial(PORT, BAUD, timeout=1)
except serial.SerialException as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)

# Drain any buffered output
s.reset_input_buffer()

# Send newline to get a clean prompt, then the command
s.write(b'\n')
time.sleep(0.2)
s.reset_input_buffer()  # Discard prompt

# Send command with end marker
marker = '__END_CMD__'
s.write(f'{CMD}; echo {marker}\n'.encode())

# Read until we see the marker or timeout
output = []
deadline = time.time() + TIMEOUT
while time.time() < deadline:
    line = s.readline().decode('utf-8', errors='replace').rstrip('\r\n')
    if marker in line:
        break
    output.append(line)

s.close()

# Skip the first line (command echo) if present
if output and CMD in output[0]:
    output = output[1:]

print('\n'.join(output))
