#!/usr/bin/env python3
"""Thin repository entry point for Cuttlefish build inventory."""

from __future__ import annotations

import sys

from apkrun_image.inventory import main

if __name__ == "__main__":
    sys.exit(main())
