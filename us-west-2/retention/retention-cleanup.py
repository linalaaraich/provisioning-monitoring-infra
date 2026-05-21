#!/usr/bin/env python3
# =============================================================================
# rca_history.db retention cleanup — daily systemd-timer-fired
#
# Rules:
#   1. Backup the DB to /opt/triage/backups/rca_history.YYYY-MM-DDTHH-MM-SS.db
#      (keep last 7 daily backups; older ones deleted)
#   2. Delete rows where:
#        timestamp < (now - RETENTION_DAYS days) AND rca_quality != 'actionable'
#      Rationale: 'actionable' rows are the exemplar pool — never expire them.
#      Everything else (needs_review, data_starved, NULL) is debug noise older
#      than 90 days that has no operational value.
#   3. VACUUM the DB so the on-disk file actually shrinks.
#   4. Append a one-line summary to /var/log/rca-retention.log.
#
# Use --dry-run to preview without modifying.
# =============================================================================
from __future__ import annotations

import argparse
import logging
import os
import shutil
import sqlite3
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

DB_PATH = Path("/var/lib/docker/volumes/ai-stack_triage_data/_data/rca_history.db")
BACKUP_DIR = Path("/opt/triage/backups")
LOG_PATH = Path("/var/log/rca-retention.log")
RETENTION_DAYS = 90
BACKUPS_TO_KEEP = 7


def setup_logging(verbose: bool) -> logging.Logger:
    log = logging.getLogger("rca-retention")
    log.setLevel(logging.DEBUG if verbose else logging.INFO)
    fmt = logging.Formatter("%(asctime)s %(levelname)s %(message)s")
    # File handler
    fh = logging.FileHandler(LOG_PATH)
    fh.setFormatter(fmt)
    log.addHandler(fh)
    # Stdout handler (visible in `journalctl -u retention-cleanup.service`)
    sh = logging.StreamHandler(sys.stdout)
    sh.setFormatter(fmt)
    log.addHandler(sh)
    return log


def take_backup(log: logging.Logger, dry_run: bool) -> Path:
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H-%M-%S")
    dest = BACKUP_DIR / f"rca_history.{ts}.db"
    if dry_run:
        log.info("[DRY] would back up %s -> %s", DB_PATH, dest)
        return dest
    shutil.copy2(DB_PATH, dest)
    log.info("backed up %s -> %s (%d bytes)", DB_PATH, dest, dest.stat().st_size)
    return dest


def rotate_backups(log: logging.Logger, dry_run: bool) -> None:
    existing = sorted(BACKUP_DIR.glob("rca_history.*.db"))
    # Keep the newest BACKUPS_TO_KEEP; delete the rest.
    excess = existing[: max(0, len(existing) - BACKUPS_TO_KEEP)]
    for p in excess:
        if dry_run:
            log.info("[DRY] would delete old backup %s", p)
        else:
            p.unlink()
            log.info("deleted old backup %s", p)


def clean_history(log: logging.Logger, dry_run: bool) -> tuple[int, int]:
    cutoff = (datetime.now(timezone.utc) - timedelta(days=RETENTION_DAYS)).isoformat()
    db = sqlite3.connect(str(DB_PATH))

    # How many before?
    before = db.execute("SELECT COUNT(*) FROM rca_history").fetchone()[0]

    # How many candidates for deletion?
    candidates_q = """
        SELECT COUNT(*) FROM rca_history
        WHERE timestamp < ? AND (rca_quality IS NULL OR rca_quality != 'actionable')
    """
    candidates = db.execute(candidates_q, (cutoff,)).fetchone()[0]

    log.info(
        "retention check: total=%d cutoff=%s (RETENTION_DAYS=%d) candidates=%d",
        before, cutoff, RETENTION_DAYS, candidates,
    )

    if dry_run:
        # Show the qualities being removed for visibility
        for r in db.execute("""
            SELECT rca_quality, COUNT(*) c FROM rca_history
            WHERE timestamp < ? AND (rca_quality IS NULL OR rca_quality != 'actionable')
            GROUP BY rca_quality ORDER BY c DESC
        """, (cutoff,)):
            log.info("[DRY]   would delete %d rows with quality=%r", r[1], r[0])
        db.close()
        return before, candidates

    deleted = db.execute("""
        DELETE FROM rca_history
        WHERE timestamp < ? AND (rca_quality IS NULL OR rca_quality != 'actionable')
    """, (cutoff,)).rowcount
    db.commit()
    db.execute("VACUUM")
    db.commit()
    db.close()

    log.info("deleted %d rows; total now %d", deleted, before - deleted)
    return before, deleted


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dry-run", action="store_true", help="show what would happen, don't modify")
    ap.add_argument("--verbose", "-v", action="store_true")
    args = ap.parse_args()

    log = setup_logging(args.verbose)

    if not DB_PATH.exists():
        log.error("DB not found at %s — is the triage stack running?", DB_PATH)
        return 1

    try:
        take_backup(log, args.dry_run)
        rotate_backups(log, args.dry_run)
        clean_history(log, args.dry_run)
    except Exception:
        log.exception("retention cleanup failed")
        return 2

    log.info("retention cleanup complete (dry_run=%s)", args.dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main())
