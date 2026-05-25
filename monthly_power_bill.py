#!/usr/bin/env python3
"""Monthly power billing for Moltentech LLC.

Pulls per-host kWh from InfluxDB for a calendar month, writes CSV, and
prints a formatted report. Panel reconciliation uses stored cumulative
meter readings (two breakers, summed) with linear interpolation to
month boundaries, so you don't have to read the meters on the 1st.

Modes:
  (default)                     Generate bill for prior month → stdout
  --email TO                    Generate bill → email TO
  --add-reading DATE M1 [M2]    Record a panel meter reading (kWh, cumulative)
  --list-readings               Show stored panel readings

Options:
  --fill-gaps                   Extrapolate collector gaps in NUT data
  --panel KWH                   Override file-based panel reconciliation
                                with a manual kWh value (one-shot bypass)

Examples:
  monthly_power_bill.py --add-reading 2026-06-15 12450.3 8230.1
  monthly_power_bill.py --list-readings
  monthly_power_bill.py 2026-04 --fill-gaps
  monthly_power_bill.py --fill-gaps --email tom@moltentech.us

Cron on w2vy (1st of month, 00:30 UTC):
  30 0 1 * * /home/tom/monitoring-stack/monthly_power_bill.py \\
      --fill-gaps --email tom@moltentech.us
"""

import csv
import io
import os
import subprocess
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

_SCRIPT_DIR = Path(__file__).resolve().parent
_ENV_FILE = Path(os.environ.get("ENV_FILE", _SCRIPT_DIR / ".env"))
if _ENV_FILE.is_file():
    for _line in _ENV_FILE.read_text().splitlines():
        _line = _line.strip()
        if not _line or _line.startswith("#") or "=" not in _line:
            continue
        _k, _v = _line.split("=", 1)
        os.environ.setdefault(_k.strip(), _v.strip())

INFLUX_URL = os.environ.get("INFLUX_URL", "http://localhost:8086")
INFLUX_ORG = "moltentech"
INFLUX_BUCKET = "monitoring"
try:
    INFLUX_TOKEN = os.environ["INFLUX_TOKEN"]
except KeyError:
    sys.exit(f"INFLUX_TOKEN not set (export it or put it in {_ENV_FILE})")
OUTDIR = Path(os.environ.get("BILL_OUTDIR", "/home/tom/monitoring-stack/bills"))
PANEL_FILE = OUTDIR / "panel_readings.csv"
FROM_ADDR = "tom@moltentech.us"
FROM_NAME = "Moltentech Billing"


# ---------- date helpers ----------

def prior_month_utc():
    today = datetime.now(timezone.utc)
    y, m = (today.year - 1, 12) if today.month == 1 else (today.year, today.month - 1)
    return f"{y:04d}-{m:02d}"


def month_bounds(yyyymm):
    y, m = map(int, yyyymm.split("-"))
    start = datetime(y, m, 1, tzinfo=timezone.utc)
    stop = datetime(y + 1, 1, 1, tzinfo=timezone.utc) if m == 12 \
        else datetime(y, m + 1, 1, tzinfo=timezone.utc)
    return start, stop


def rfc3339(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------- InfluxDB queries ----------

def query_flux(flux):
    req = urllib.request.Request(
        f"{INFLUX_URL}/api/v2/query?org={INFLUX_ORG}",
        data=flux.encode(),
        headers={
            "Authorization": f"Token {INFLUX_TOKEN}",
            "Content-Type": "application/vnd.flux",
            "Accept": "application/csv",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read().decode()


def per_host_kwh(start, stop):
    flux = f"""
from(bucket: "{INFLUX_BUCKET}")
  |> range(start: {rfc3339(start)}, stop: {rfc3339(stop)})
  |> filter(fn: (r) => r._measurement == "ups" and r._field == "watts")
  |> aggregateWindow(every: 1h, fn: mean, createEmpty: false)
  |> group(columns: ["host"])
  |> sum()
  |> keep(columns: ["host", "_value"])
"""
    out = {}
    for row in csv.DictReader(io.StringIO(query_flux(flux))):
        host = (row.get("host") or "").strip()
        val = (row.get("_value") or "").strip()
        if host and val:
            out[host] = float(val) / 1000.0
    return out


def coverage_hours(start, stop):
    flux = f"""
from(bucket: "{INFLUX_BUCKET}")
  |> range(start: {rfc3339(start)}, stop: {rfc3339(stop)})
  |> filter(fn: (r) => r._measurement == "ups" and r._field == "watts")
  |> aggregateWindow(every: 1h, fn: count, createEmpty: false)
  |> filter(fn: (r) => r._value > 0)
  |> group(columns: ["host"])
  |> count()
  |> keep(columns: ["host", "_value"])
"""
    out = {}
    for row in csv.DictReader(io.StringIO(query_flux(flux))):
        host = (row.get("host") or "").strip()
        val = (row.get("_value") or "").strip()
        if host and val:
            out[host] = int(float(val))
    return out


# ---------- panel meter readings ----------

def load_panel_readings():
    """Returns [(datetime_utc, meter1, meter2, total), ...] sorted by date.

    Dates in CSV are YYYY-MM-DD, interpreted as 00:00 UTC. Meter2 may be
    blank for single-meter setups.
    """
    if not PANEL_FILE.exists():
        return []
    out = []
    with PANEL_FILE.open() as f:
        for row in csv.DictReader(f):
            try:
                d = datetime.strptime(row["date"], "%Y-%m-%d").replace(tzinfo=timezone.utc)
                m1 = float(row["meter1_kwh"])
                m2_raw = (row.get("meter2_kwh") or "").strip()
                m2 = float(m2_raw) if m2_raw else 0.0
                out.append((d, m1, m2, m1 + m2))
            except (ValueError, KeyError):
                continue
    out.sort(key=lambda r: r[0])
    return out


def add_reading(date_str, m1, m2):
    PANEL_FILE.parent.mkdir(parents=True, exist_ok=True)
    is_new = not PANEL_FILE.exists()
    with PANEL_FILE.open("a", newline="") as f:
        w = csv.writer(f)
        if is_new:
            w.writerow(["date", "meter1_kwh", "meter2_kwh", "notes"])
        w.writerow([date_str, f"{m1:.1f}", f"{m2:.1f}" if m2 is not None else "", ""])


def interpolate_total(target_dt, readings):
    """Linear interpolation of total kWh at target_dt. None if out of range."""
    if not readings:
        return None
    if target_dt < readings[0][0] or target_dt > readings[-1][0]:
        return None
    for i in range(len(readings) - 1):
        d0, _, _, t0 = readings[i]
        d1, _, _, t1 = readings[i + 1]
        if d0 <= target_dt <= d1:
            if d0 == d1:
                return t0
            frac = (target_dt - d0).total_seconds() / (d1 - d0).total_seconds()
            return t0 + (t1 - t0) * frac
    return None


def panel_kwh_for_month(month):
    """Returns (panel_kwh, status_note) where panel_kwh may be None."""
    start, stop = month_bounds(month)
    readings = load_panel_readings()
    if not readings:
        return None, "no panel readings on file"
    earliest, latest = readings[0][0], readings[-1][0]
    if start < earliest:
        return None, f"earliest reading {earliest:%Y-%m-%d} is after month start {start:%Y-%m-%d}"
    if stop > latest:
        return None, f"latest reading {latest:%Y-%m-%d} is before month end {stop:%Y-%m-%d}"
    start_total = interpolate_total(start, readings)
    end_total = interpolate_total(stop, readings)
    if start_total is None or end_total is None:
        return None, "interpolation failed (gap in readings)"
    return end_total - start_total, f"interpolated from {len(readings)} readings"


# ---------- args ----------

def parse_args(argv):
    month = None
    panel = None
    fill = False
    email = None
    add = None
    list_readings = False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--fill-gaps":
            fill = True
        elif a == "--panel":
            i += 1
            panel = float(argv[i])
        elif a == "--email":
            i += 1
            email = argv[i]
        elif a == "--add-reading":
            date_str = argv[i + 1]
            m1 = float(argv[i + 2])
            m2 = None
            # m2 is optional — only consume it if it looks like a number
            if i + 3 < len(argv) and not argv[i + 3].startswith("-"):
                try:
                    m2 = float(argv[i + 3])
                    i += 3
                except ValueError:
                    i += 2
            else:
                i += 2
            add = (date_str, m1, m2 if m2 is not None else 0.0)
        elif a == "--list-readings":
            list_readings = True
        elif a in ("-h", "--help"):
            print(__doc__)
            sys.exit(0)
        elif not a.startswith("--") and month is None:
            month = a
        else:
            sys.exit(f"unexpected arg: {a}")
        i += 1
    return {
        "month": month or prior_month_utc(),
        "panel": panel,
        "fill": fill,
        "email": email,
        "add": add,
        "list_readings": list_readings,
    }


# ---------- output ----------

def build_csv(outpath, rows, fill, total_raw, total_filled, panel_kwh):
    """NUT (120V compute) and panel (220V other) measure disjoint equipment;
    the LLC bill is their sum."""
    nut_kwh = total_filled if fill else total_raw
    header = ["host", "kwh", "coverage_hours", "coverage_pct"]
    if fill:
        header.append("filled_kwh")
    extra = [""] if fill else []
    with outpath.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        for r in rows:
            w.writerow(r)
        w.writerow([])
        nut_row = ["SUBTOTAL_NUT_120V", f"{total_raw:.2f}", "", ""]
        if fill:
            nut_row.append(f"{total_filled:.2f}")
        w.writerow(nut_row)
        if panel_kwh is not None:
            w.writerow(["SUBTOTAL_PANEL_220V", f"{panel_kwh:.2f}", "", ""] + extra)
            w.writerow(["TOTAL_BILLABLE", f"{nut_kwh + panel_kwh:.2f}", "", ""] + extra)


def build_report(month, month_hours, rows, fill, total_raw, total_filled,
                 panel_kwh, panel_note, csv_path):
    nut_kwh = total_filled if fill else total_raw
    status = "FINAL" if panel_kwh is not None else "DRAFT (220V panel reading pending)"

    lines = []
    lines.append(f"Moltentech LLC — Monthly Power Bill")
    lines.append(f"Billing period:  {month}  ({month_hours} hours UTC)")
    lines.append(f"Status:          {status}")
    lines.append(f"Method:          NUT watts integrated hourly"
                 + (", missing hours extrapolated" if fill else ""))
    lines.append("")
    lines.append(f"120V (NUT, compute):  {nut_kwh:>10.2f} kWh")
    if panel_kwh is not None:
        grand_total = nut_kwh + panel_kwh
        lines.append(f"220V (panel meters):  {panel_kwh:>10.2f} kWh"
                     f"   ({panel_note})")
        lines.append(f"                      {'-'*10}")
        lines.append(f"TOTAL BILLABLE:       {grand_total:>10.2f} kWh")
    else:
        lines.append(f"220V (panel meters):  pending — see ACTION REQUIRED below")
        lines.append(f"                      {'-'*10}")
        lines.append(f"DRAFT TOTAL (120V only): {nut_kwh:>10.2f} kWh")
    lines.append("")
    lines.append("Per-host breakdown:")
    if fill:
        lines.append(f"  {'Host':<8} {'Raw kWh':>10} {'Coverage':>10} {'Filled kWh':>12}")
        lines.append(f"  {'-'*8} {'-'*10} {'-'*10} {'-'*12}")
        for r in rows:
            lines.append(f"  {r[0]:<8} {r[1]:>10} {r[3]:>9}% {r[4]:>12}")
    else:
        lines.append(f"  {'Host':<8} {'kWh':>10} {'Coverage':>10}")
        lines.append(f"  {'-'*8} {'-'*10} {'-'*10}")
        for r in rows:
            lines.append(f"  {r[0]:<8} {r[1]:>10} {r[3]:>9}%")
    lines.append("")
    lines.append(f"CSV saved:  w2vy:{csv_path}")
    lines.append("")

    if panel_kwh is None:
        lines.append("=" * 60)
        lines.append("ACTION REQUIRED — DRAFT bill (no panel reconciliation).")
        lines.append(f"Reason: {panel_note}")
        lines.append("")
        lines.append("Read both 220V meters and record the cumulative kWh:")
        lines.append(f"  ssh w2vy '/home/tom/monitoring-stack/monthly_power_bill.py \\")
        lines.append(f"      --add-reading YYYY-MM-DD METER1_KWH METER2_KWH'")
        lines.append("")
        lines.append("Then re-run for this month to regenerate the FINAL bill:")
        lines.append(f"  ssh w2vy '/home/tom/monitoring-stack/monthly_power_bill.py \\")
        lines.append(f"      {month}"
                     + (" --fill-gaps" if fill else "") + "'")
        lines.append("")
        lines.append("Readings only need to bracket the month (any dates before "
                     "and after).")
        lines.append("=" * 60)
        lines.append("")
        lines.append("=" * 60)
        lines.append("BATTERY HEALTH CHECK (Tripp Lite UPS)")
        lines.append("")
        lines.append("While you're at the panel, press the front-panel TEST button on")
        lines.append("the Tripp Lite UPS. From any terminal, before walking over:")
        lines.append("")
        lines.append("  ssh w2vy '~/monitoring-stack/tripplite_battery_test.sh tripplite'")
        lines.append("")
        lines.append("It watches NUT for up to 5 minutes, captures the voltage sag,")
        lines.append("and logs to InfluxDB. Compare to the baseline; widening sag = aging battery.")
        lines.append("")
        lines.append("After a battery replacement, set a new baseline:")
        lines.append("  ssh w2vy '~/monitoring-stack/tripplite_battery_test.sh tripplite \\")
        lines.append("      --set-baseline --note \"replaced battery YYYY-MM-DD\"'")
        lines.append("=" * 60)

    return "\n".join(lines) + "\n"


def send_email(to_addr, subject, body):
    msg = (
        f"From: {FROM_NAME} <{FROM_ADDR}>\n"
        f"To: {to_addr}\n"
        f"Subject: {subject}\n"
        f"Content-Type: text/plain; charset=utf-8\n"
        f"MIME-Version: 1.0\n"
        f"\n"
        f"{body}"
    )
    proc = subprocess.run(
        ["/usr/sbin/sendmail", "-F", FROM_NAME, "-f", FROM_ADDR, "-t"],
        input=msg, text=True, capture_output=True,
    )
    if proc.returncode != 0:
        sys.stderr.write(f"sendmail failed (rc={proc.returncode}): {proc.stderr}\n")
        sys.exit(proc.returncode)


def print_readings():
    readings = load_panel_readings()
    if not readings:
        print(f"No readings recorded yet ({PANEL_FILE} does not exist).")
        return
    print(f"Panel readings ({len(readings)} on file):")
    print(f"  {'Date':<12} {'Meter1':>10} {'Meter2':>10} {'Total':>10}")
    print(f"  {'-'*12} {'-'*10} {'-'*10} {'-'*10}")
    for d, m1, m2, t in readings:
        m2s = f"{m2:.1f}" if m2 else "—"
        print(f"  {d:%Y-%m-%d}  {m1:>9.1f}  {m2s:>10}  {t:>9.1f}")


# ---------- main ----------

def main():
    args = parse_args(sys.argv[1:])

    if args["add"]:
        date_str, m1, m2 = args["add"]
        add_reading(date_str, m1, m2)
        total = m1 + m2
        print(f"Recorded reading: {date_str}  meter1={m1:.1f}  "
              f"meter2={m2:.1f}  total={total:.1f} kWh")
        readings = load_panel_readings()
        print(f"({len(readings)} reading(s) on file at {PANEL_FILE})")
        return

    if args["list_readings"]:
        print_readings()
        return

    month = args["month"]
    fill = args["fill"]
    email = args["email"]

    start, stop = month_bounds(month)
    month_hours = int((stop - start).total_seconds() / 3600)

    raw_kwh = per_host_kwh(start, stop)
    cov = coverage_hours(start, stop)

    rows = []
    total_raw = 0.0
    total_filled = 0.0
    for host in sorted(raw_kwh):
        ch = cov.get(host, 0)
        kwh = raw_kwh[host]
        total_raw += kwh
        row = [host, f"{kwh:.2f}", ch, f"{100.0 * ch / month_hours:.1f}"]
        if fill:
            filled = kwh * (month_hours / ch) if ch > 0 else 0.0
            total_filled += filled
            row.append(f"{filled:.2f}")
        rows.append(row)

    # Determine panel kWh: explicit override > readings file > none
    if args["panel"] is not None:
        panel_kwh = args["panel"]
        panel_note = "manual override"
    else:
        panel_kwh, panel_note = panel_kwh_for_month(month)

    OUTDIR.mkdir(parents=True, exist_ok=True)
    csv_path = OUTDIR / f"{month}.csv"
    build_csv(csv_path, rows, fill, total_raw, total_filled, panel_kwh)

    report = build_report(month, month_hours, rows, fill, total_raw,
                          total_filled, panel_kwh, panel_note, csv_path)

    if email:
        nut_kwh = total_filled if fill else total_raw
        grand_total = nut_kwh + panel_kwh if panel_kwh is not None else nut_kwh
        status_tag = "FINAL" if panel_kwh is not None else "DRAFT"
        subject = (f"Moltentech power bill {month} — {status_tag} — "
                   f"{grand_total:.0f} kWh")
        send_email(email, subject, report)
    else:
        sys.stdout.write(report)


if __name__ == "__main__":
    main()
