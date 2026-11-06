#!/usr/bin/env bash
# Kept so the old command keeps working. The report generator is now
# tools/report.py, which writes report.md, report.json and report.txt.
exec python3 "$(dirname "${BASH_SOURCE[0]}")/report.py" ${1:+--session "$1"}
