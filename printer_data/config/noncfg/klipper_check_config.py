#!/usr/bin/env python3
"""
klipper_check_config.py
A simple Klipper configuration file validator.

Usage:
    python klipper_check_config.py /path/to/printer.cfg
"""

import sys
import os
import re

# Known Klipper config sections (extend as needed)
KNOWN_SECTIONS = {
    "stepper_x", "stepper_y", "stepper_z",
    "extruder", "heater_bed", "mcu",
    "printer", "display", "fan", "heater_fan",
    "bed_screws", "safe_z_home", "probe",
    "bltouch", "filament_switch_sensor",
    "temperature_sensor", "output_pin",
    "input_shaper", "tmc2209", "tmc2130", "tmc5160"
}

def validate_config(file_path):
    if not os.path.isfile(file_path):
        print(f"❌ Error: File '{file_path}' not found.")
        return 1

    errors = []
    warnings = []
    current_section = None
    seen_keys = set()

    section_pattern = re.compile(r"^\s*\[([a-zA-Z0-9_]+)\]\s*$")
    key_value_pattern = re.compile(r"^\s*([a-zA-Z0-9_]+)\s*=\s*(.+)\s*$")

    with open(file_path, "r", encoding="utf-8") as f:
        for line_num, line in enumerate(f, start=1):
            stripped = line.strip()

            # Skip comments and empty lines
            if not stripped or stripped.startswith("#"):
                continue

            # Section header
            match_section = section_pattern.match(stripped)
            if match_section:
                section_name = match_section.group(1)
                current_section = section_name
                seen_keys.clear()

                if section_name not in KNOWN_SECTIONS:
                    warnings.append(f"Line {line_num}: Unknown section '[{section_name}]'")
                continue

            # Key-value pair
            match_kv = key_value_pattern.match(stripped)
            if match_kv:
                key = match_kv.group(1)
                if key in seen_keys:
                    warnings.append(f"Line {line_num}: Duplicate key '{key}' in section [{current_section}]")
                seen_keys.add(key)
                continue

            # If not section or key-value, it's invalid
            errors.append(f"Line {line_num}: Invalid syntax -> {stripped}")

    # Output results
    if errors:
        print("❌ Configuration Errors:")
        for e in errors:
            print("   " + e)
    else:
        print("✅ No syntax errors found.")

    if warnings:
        print("\n⚠ Warnings:")
        for w in warnings:
            print("   " + w)

    return 1 if errors else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python klipper_check_config.py /path/to/printer.cfg")
        sys.exit(1)

    sys.exit(validate_config(sys.argv[1]))
