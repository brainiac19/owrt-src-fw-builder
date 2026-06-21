#!/usr/bin/env python3
import os
import sys
import re

DEBUG = os.environ.get('DEBUG_LOG') == '1'
BUILD_LOG_FILE = os.environ.get('BUILD_LOG_FILE')

# Regex to match: make[d] -C <first_segment>/<rest_of_path> <action>
# e.g., make[2] -C package/libs/zlib download
# Group 1: 'make[2] -C ' (or with spaces)
# Group 2: 'package'
# Group 3: '/libs/zlib'
# Group 4: ' download'
pattern = re.compile(r'^(\s*make\[\d+\] -C )([^/\s]+)(/[^\s]+)?(\s+.*)$')

log_f = None
if BUILD_LOG_FILE:
    # Ensure directory exists
    log_dir = os.path.dirname(BUILD_LOG_FILE)
    if log_dir:
        os.makedirs(log_dir, exist_ok=True)
    log_f = open(BUILD_LOG_FILE, 'a')

try:
    for line in sys.stdin:
        # Write un-obfuscated to log file
        if log_f:
            log_f.write(line)
            log_f.flush()

        if DEBUG:
            sys.stdout.write(line)
            sys.stdout.flush()
            continue

        match = pattern.match(line)
        if match:
            prefix = match.group(1)
            first_segment = match.group(2)
            suffix = match.group(4)
            
            # Print obfuscated line
            sys.stdout.write(f"{prefix}{first_segment}/***{(suffix)}\n")
            sys.stdout.flush()
finally:
    if log_f:
        log_f.close()
