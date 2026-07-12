#!/usr/bin/env python3
import os
import sys
import re

DEBUG = os.environ.get('DEBUG_LOG') == '1'
OBFUSCATE = os.environ.get('OBFUSCATE_LOGS') == '1'
BUILD_LOG_FILE = os.environ.get('BUILD_LOG_FILE')

# Regex to match: make[d] -C <first_segment>/<rest_of_path> <action>
pattern = re.compile(r'^(\s*make\[\d+\] -C )([^/\s]+)(/[^\s]+)?(\s+.*)$')
feed_update_pattern = re.compile(r"^Updating feed '[^']+' from '[^']+'(.*)$")
feed_install_pattern = re.compile(r"^Installing package '[^']+'(.*)$")
feed_install_all_pattern = re.compile(r"^Installing all packages from feed '[^']+'(.*)$")

log_f = None
if BUILD_LOG_FILE:
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
            if OBFUSCATE:
                prefix = match.group(1)
                first_segment = match.group(2)
                suffix = match.group(4)
                sys.stdout.write(f"{prefix}{first_segment}/***{(suffix)}\n")
            else:
                sys.stdout.write(line)
            sys.stdout.flush()
            continue

        m_up = feed_update_pattern.match(line)
        if m_up:
            if OBFUSCATE:
                sys.stdout.write(f"Updating feed '***' from '***'{m_up.group(1)}\n")
            else:
                sys.stdout.write(line)
            sys.stdout.flush()
            continue

        m_inst = feed_install_pattern.match(line)
        if m_inst:
            if OBFUSCATE:
                sys.stdout.write(f"Installing package '***'{m_inst.group(1)}\n")
            else:
                sys.stdout.write(line)
            sys.stdout.flush()
            continue

        m_all = feed_install_all_pattern.match(line)
        if m_all:
            if OBFUSCATE:
                sys.stdout.write(f"Installing all packages from feed '***'{m_all.group(1)}\n")
            else:
                sys.stdout.write(line)
            sys.stdout.flush()
            continue
finally:
    if log_f:
        log_f.close()
