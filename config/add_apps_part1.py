#!/usr/bin/env python3
"""Add 171 new Chinese apps to applications.json"""
import json, sys, os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
JSON_PATH = os.path.join(SCRIPT_DIR, "applications.json")

# Load existing
with open(JSON_PATH, 'r', encoding='utf-8') as f:
    apps = json.load(f)

existing_keys = set(apps.keys())
print(f"Existing app count before: {len(existing_keys)}")

# New apps data: list of (key, {fields})
# scoop is the minimum; winget/choco optional
NEW = [
