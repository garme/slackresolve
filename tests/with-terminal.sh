#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
stty rows 24 cols 80 || exit 1
exec "$@"
