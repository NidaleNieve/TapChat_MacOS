#!/usr/bin/env python3
"""Compares benchmark runs: the median of each figure over bench/<label>-N.json.

    Scripts/summarize.py before after          prints a Markdown table
"""
import glob
import json
import statistics
import sys

# (figure, path in the JSON, unit, lower is better)
FIGURES = [
    ("Stream 12k chars, short chat: CPU", "stream.cpuSeconds", "CPU s"),
    ("Stream 12k chars, short chat: wall time", "stream.wallSeconds", "s"),
    ("Stream 12k chars after 300 messages: CPU", "streamLong.cpuSeconds", "CPU s"),
    ("Stream 12k chars after 300 messages: wall time", "streamLong.wallSeconds", "s"),
    ("Stream after 300 messages: peak memory", "streamLong.peakFootprintMB", "MB"),
    ("Open 300-message chat from History (first time)", "chat.openColdMs", "ms"),
    ("Open 300-message chat from History (again), median", "chat.openWarm.p50", "ms"),
    ("Fast scroll, per frame, average", "chat.scrollStepMs.avg", "ms"),
    ("Fast scroll, per frame, p95", "chat.scrollStepMs.p95", "ms"),
    ("Fast scroll, per frame, worst", "chat.scrollStepMs.max", "ms"),
    ("Idle frame (floor)", "chat.idleFrameMs.p50", "ms"),
    ("Memory with 300-message chat open", "chat.footprintWithChatMB", "MB"),
    ("Add 8 screenshots", "attach.addAllMs", "ms"),
    ("Remove one attachment, average", "attach.removeMs.avg", "ms"),
    ("Memory held after removing them", "attach.heldAfterRemovingMB", "MB"),
    ("Idle, window open: TapChat + CLI memory", "idleVisible.totalFootprintMB", "MB"),
    ("Idle, window open: CLI processes", "idleVisible.childProcesses", ""),
    ("Idle, window open: CPU", "idleVisible.cpuPercent", "%"),
    ("Hidden, after use: memory", "idleHiddenAfterUse.footprintMB", "MB"),
    ("Hidden, after use: CPU", "idleHiddenAfterUse.cpuPercent", "%"),
    ("Hidden, a minute after use: memory", "idleHiddenMinuteAfterUse.footprintMB", "MB"),
    ("Hidden, a minute after use: CPU", "idleHiddenMinuteAfterUse.cpuPercent", "%"),
    ("Hidden, at launch: memory", "idleHidden.footprintMB", "MB"),
]


def get(r, path):
    if path == "attach.heldAfterRemovingMB":
        a = r.get("attach", {})
        if "footprintAfterRemovingMB" in a:
            return a["footprintAfterRemovingMB"] - a["footprintBeforeMB"]
        return None
    for k in path.split("."):
        if not isinstance(r, dict) or k not in r:
            return None
        r = r[k]
    return r


def median(label, path):
    xs = [get(json.load(open(f)), path) for f in sorted(glob.glob(f"bench/{label}-*.json"))]
    xs = [x for x in xs if x is not None]
    return (statistics.median(xs), len(xs)) if xs else (None, 0)


def fmt(x):
    return "–" if x is None else f"{x:,.1f}" if abs(x) < 100 else f"{x:,.0f}"


def main():
    a, b = sys.argv[1], sys.argv[2]
    print(f"| Figure | {a} | {b} | Change |")
    print("|---|---:|---:|---:|")
    for name, path, unit in FIGURES:
        x, n = median(a, path)
        y, m = median(b, path)
        change = "–"
        if x is not None and y is not None:
            if y > 0 and x / y >= 1.05:
                change = f"**{x / y:.1f}× less**" if unit in ("MB", "CPU s", "%", "") else f"**{x / y:.1f}× faster**"
            elif x > 0 and y / x >= 1.05:
                change = f"{y / x:.1f}× more" if unit in ("MB", "CPU s", "%", "") else f"{y / x:.1f}× slower"
            elif y == 0 and x > 0:
                change = "**gone**"
            else:
                change = "same"
        u = f" {unit}" if unit else ""
        print(f"| {name} | {fmt(x)}{u} | {fmt(y)}{u} | {change} |")
    print(f"\nMedians of {median(a, 'chat.messages')[1]} and {median(b, 'chat.messages')[1]} runs.")


if __name__ == "__main__":
    main()
