#!/usr/bin/env python3
"""Exercise the 1.0.11 downgrade path against a verified V8 restore and V12 clone."""

import argparse
import datetime as dt
import hashlib
import json
import os
import plistlib
import pwd
import re
import shutil
import signal
import subprocess
import tempfile
import time
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
OLD_RELEASE = ROOT / "release-assets" / "Release-1.0.11-local"
OLD_DMG = OLD_RELEASE / "LatticeLens-1.0.11-local.dmg"
OLD_MANIFEST = OLD_RELEASE / "manifest-v1.0.11.json"
FIXTURE_TEST = "testDefaultFactoryMigratesV9ThroughStagingToV12AndPreservesSourceFamily"
INPUTS = (
    "Scripts/g02_old_app_rollback_drill.py",
    "Scripts/verify_2_0_final.py",
    "Tests/LatticeLensTests/Support/TestSupport.swift",
    "Tests/LatticeLensTests/V4LocalTests.swift",
    "Sources/LatticeLens/Core/Persistence/SwiftDataLibraryStore.swift",
    "Sources/LatticeLens/Core/Persistence/V4NormalizedStore.swift",
)
OLD_APP_BUNDLE_ID = "org.latticelens.app"


def darwin_user_temp_paths():
    configured = (os.environ.get("LATTICELENS_HOST_SYSTEM_TMPDIR") or
                  os.environ.get("TMPDIR", ""))
    candidate = Path(configured) if configured else None
    if candidate is None or not candidate.is_absolute() or candidate.name != "T":
        return ()
    try:
        canonical = candidate.resolve(strict=True)
    except OSError:
        return ()
    if not any(canonical.is_relative_to(root) for root in
               (Path("/var/folders"), Path("/private/var/folders"))):
        return ()
    return tuple(dict.fromkeys((str(candidate), str(canonical))))


SYSTEM_TEMPORARY_PATHS = tuple(dict.fromkeys((
    "/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp",
    *darwin_user_temp_paths(),
)))
UNSTOPPED_PROCESS_GROUPS = set()
PROCESS_TERMINATION_ERRORS = []


class DrillError(RuntimeError):
    pass


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def tail(path, limit=80):
    if not path.is_file():
        return []
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()[-limit:]
    try:
        host_home = str(Path(pwd.getpwuid(os.getuid()).pw_dir).resolve())
    except (KeyError, OSError):
        host_home = ""
    replacements = [(str(ROOT), "<project>")]
    if host_home:
        replacements.append((host_home, "<host-home>"))
    for source, replacement in sorted(replacements, key=lambda item: len(item[0]), reverse=True):
        lines = [line.replace(source, replacement) for line in lines]
    return lines


def run_logged(command, log_path, *, environment=None, timeout=120, cwd=ROOT):
    try:
        process = subprocess.Popen(command, cwd=str(cwd), env=environment,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   start_new_session=True)
    except OSError as error:
        log_path.write_text(str(error) + "\n", encoding="utf-8")
        raise DrillError("could not start command: " + str(error))
    try:
        output, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        stopped = terminate_process(process)
        try:
            output, _ = process.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            output = b""
            stopped = False
        log_path.write_bytes((output or b"") + b"\nCOMMAND_TIMEOUT\n")
        if not stopped:
            UNSTOPPED_PROCESS_GROUPS.add(process.pid)
        raise DrillError("command timed out: " + " ".join(map(str, command)))
    if process_group_exists(process.pid):
        stopped = terminate_process(process)
        if not stopped:
            UNSTOPPED_PROCESS_GROUPS.add(process.pid)
        log_path.write_bytes((output or b"") + b"\nCOMMAND_LEFT_PROCESS_GROUP\n")
        raise DrillError("command left a task-owned process group after exit: " +
                         " ".join(map(str, command)))
    log_path.write_bytes(output or b"")
    if process.returncode != 0:
        raise DrillError("command exited " + str(process.returncode) + ": " +
                         " ".join(map(str, command)))
    return (output or b"").decode("utf-8", errors="replace")


def require_project_path(path, *, must_exist=False):
    absolute = path if path.is_absolute() else ROOT / path
    canonical = absolute.resolve(strict=must_exist)
    if canonical != absolute.absolute():
        raise DrillError("path resolves through a symlink: " + str(path))
    if canonical == ROOT or not canonical.is_relative_to(ROOT):
        raise DrillError("path escapes Reference_manager: " + str(path))
    if must_exist and (not canonical.exists() or canonical.is_symlink()):
        raise DrillError("required project file is missing or a symlink: " + str(path))
    return canonical


def sqlite_integrity(sqlite3, path, log_path):
    result = run_logged([sqlite3, "-readonly", str(path), "PRAGMA integrity_check;"],
                        log_path, timeout=30)
    if result.strip() != "ok":
        raise DrillError("SQLite integrity_check failed for " + str(path))
    return result.strip()


def terminate_process(process):
    if process is None:
        return True
    process_group = process.pid
    try:
        os.killpg(process_group, signal.SIGTERM)
    except ProcessLookupError:
        stopped = process.poll() is not None
        if stopped:
            UNSTOPPED_PROCESS_GROUPS.discard(process_group)
        return stopped
    except PermissionError as error:
        PROCESS_TERMINATION_ERRORS.append(
            "process-group SIGTERM denied for pid " + str(process_group) + ": " + str(error))
        try:
            # The group can contain a sandboxed app helper that the parent may
            # not signal as a group. Fall back only to the exact Popen child.
            process.terminate()
        except ProcessLookupError:
            pass
        except OSError as direct_error:
            PROCESS_TERMINATION_ERRORS.append(
                "direct-child SIGTERM denied for pid " + str(process_group) + ": " + str(direct_error))
            UNSTOPPED_PROCESS_GROUPS.add(process_group)
            return False
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        process.poll()
        try:
            os.killpg(process_group, 0)
        except ProcessLookupError:
            stopped = process.poll() is not None
            if stopped:
                UNSTOPPED_PROCESS_GROUPS.discard(process_group)
            return stopped
        except PermissionError as error:
            PROCESS_TERMINATION_ERRORS.append(
                "process-group state is not inspectable for pid " + str(process_group) + ": " + str(error))
            UNSTOPPED_PROCESS_GROUPS.add(process_group)
            return False
        time.sleep(0.1)
    try:
        os.killpg(process_group, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except PermissionError as error:
        PROCESS_TERMINATION_ERRORS.append(
            "process-group SIGKILL denied for pid " + str(process_group) + ": " + str(error))
        try:
            process.kill()
        except ProcessLookupError:
            pass
        except OSError as direct_error:
            PROCESS_TERMINATION_ERRORS.append(
                "direct-child SIGKILL denied for pid " + str(process_group) + ": " + str(direct_error))
            UNSTOPPED_PROCESS_GROUPS.add(process_group)
            return False
    try:
        process.wait(timeout=8)
    except subprocess.TimeoutExpired:
        UNSTOPPED_PROCESS_GROUPS.add(process_group)
        return False
    try:
        os.killpg(process_group, 0)
    except ProcessLookupError:
        UNSTOPPED_PROCESS_GROUPS.discard(process_group)
        return True
    except PermissionError as error:
        PROCESS_TERMINATION_ERRORS.append(
            "process-group state is not inspectable after shutdown for pid " + str(process_group) + ": " + str(error))
        UNSTOPPED_PROCESS_GROUPS.add(process_group)
        return False
    UNSTOPPED_PROCESS_GROUPS.add(process_group)
    return False


def process_group_exists(process_group):
    try:
        os.killpg(process_group, 0)
    except ProcessLookupError:
        return False
    return True


def sandbox_file_access_denials(paths):
    return "".join(
        "(deny file-read* (subpath " + json.dumps(str(path)) + "))\n"
        "(deny file-write* (subpath " + json.dumps(str(path)) + "))\n"
        for path in paths
    )


def path_is_under(path, roots):
    return any(path == str(root) or path.startswith(str(root).rstrip("/") + "/")
               for root in roots)


def parse_lsof_descriptors(output):
    descriptors = []
    descriptor = "unknown"
    lines = output.splitlines() if isinstance(output, str) else output
    for line in lines:
        if line.startswith("f"):
            descriptor = line[1:]
        elif line.startswith("n"):
            descriptors.append({"descriptor": descriptor, "path": line[1:]})
    return descriptors


def system_temporary_descriptor_summary(descriptors):
    summary = []
    for item in descriptors:
        path = item.get("path", "")
        matched_root = next((str(root) for root in SYSTEM_TEMPORARY_PATHS
                             if path_is_under(path, (root,))), None)
        if matched_root is None:
            continue
        descriptor = str(item.get("descriptor", "unknown"))
        access_mode = descriptor[-1] if descriptor.endswith(("r", "w", "u")) else "unknown"
        summary.append({
            "path_root": ("darwin_user_temp" if Path(matched_root).name == "T"
                          else matched_root),
            "basename": Path(path).name,
            "descriptor": descriptor,
            "access_mode": {"r": "read", "w": "write", "u": "read_write"}.get(
                access_mode, "unknown"),
        })
    return summary


def require_running_fixture_process(apps, process_id):
    if not isinstance(process_id, int) or process_id <= 0:
        raise DrillError("the task-owned old-app PID must be a positive integer")
    matches = [item for item in apps
               if item.get("pid") == process_id and
               item.get("bundleId") == OLD_APP_BUNDLE_ID and
               item.get("isRunning") is True]
    if len(matches) != 1:
        raise DrillError("the task-owned old-app PID is not uniquely running under its expected bundle ID")
    return matches[0]


def task_group_fixture_processes(apps, process_group_id):
    if not isinstance(process_group_id, int) or process_group_id <= 0:
        raise DrillError("the task-owned old-app process group must be a positive integer")
    matches = []
    for item in apps:
        if (item.get("bundleId") != OLD_APP_BUNDLE_ID or
                item.get("isRunning") is not True):
            continue
        process_id = item.get("pid")
        if not isinstance(process_id, int) or process_id <= 0:
            continue
        try:
            if os.getpgid(process_id) == process_group_id:
                matches.append(item)
        except OSError:
            continue
    return matches


def graceful_termination_source(process_id):
    if not isinstance(process_id, int) or process_id <= 0:
        raise DrillError("the graceful quit target PID must be a positive integer")
    return "\n".join((
        "import AppKit",
        "import Darwin",
        "import Foundation",
        "let targetPID: pid_t = " + str(process_id),
        "guard let target = NSRunningApplication(processIdentifier: targetPID) else {",
        "    fputs(\"task-owned app PID is not registered\\n\", stderr); exit(2)",
        "}",
        "guard target.bundleIdentifier == " + json.dumps(OLD_APP_BUNDLE_ID) +
        " && !target.isTerminated else {",
        "    fputs(\"task-owned app identity changed before quit request\\n\", stderr); exit(3)",
        "}",
        "guard target.terminate() else {",
        "    fputs(\"NSRunningApplication refused the graceful quit request\\n\", stderr); exit(4)",
        "}",
        "print(\"graceful quit request accepted for PID \\(targetPID)\")",
    ))


def mounted_at(hdiutil, mount_path):
    completed = subprocess.run([hdiutil, "info", "-plist"],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               timeout=30, check=False)
    if completed.returncode != 0:
        raise DrillError("could not inspect disk-image mount state")
    try:
        state = plistlib.loads(completed.stdout)
    except Exception as error:  # noqa: BLE001 - malformed system output is a fail-closed condition.
        raise DrillError("could not decode disk-image mount state: " + str(error))
    expected = str(mount_path)
    for image in state.get("images", []):
        for entity in image.get("system-entities", []):
            if entity.get("mount-point") == expected:
                return True
    return False


def orca_environment():
    """Connect the Orca CLI to the user's runtime while keeping the app isolated."""
    environment = dict(os.environ)
    host_home = Path(pwd.getpwuid(os.getuid()).pw_dir).expanduser().resolve(strict=True)
    environment["HOME"] = str(host_home)
    environment["CFFIXED_USER_HOME"] = str(host_home)
    return environment


def orca_result(command, log_path, *, timeout=30):
    output = run_logged(command, log_path, environment=orca_environment(), timeout=timeout)
    try:
        response = json.loads(output)
    except json.JSONDecodeError as error:
        raise DrillError("Orca returned invalid JSON: " + str(error)) from error
    if response.get("ok") is not True or not isinstance(response.get("result"), dict):
        raise DrillError("Orca could not inspect the isolated old-app window")
    return response["result"]


def fixture_app_window_arguments(orca, process_id, scratch, phase):
    apps = orca_result(
        [orca, "computer", "list-apps", "--json"],
        scratch / ("orca-apps-before-" + phase + ".json"),
    ).get("apps", [])
    require_running_fixture_process(apps, process_id)
    windows = orca_result(
        [orca, "computer", "list-windows", "--app", "pid:" + str(process_id), "--json"],
        scratch / ("orca-windows-" + phase + ".json"),
    ).get("windows", [])
    matching = [window for window in windows
                if window.get("app", {}).get("pid") == process_id]
    if len(matching) != 1:
        raise DrillError("fixture app must have exactly one identifiable window")
    window = matching[0]
    window_id = window.get("id")
    if window_id is not None and str(window_id).lower() != "none":
        return ["--window-id", str(window_id)]
    return ["--window-index", str(window.get("index", 0))]


def request_fixture_app_quit(orca, process_id, scratch):
    apps = orca_result(
        [orca, "computer", "list-apps", "--json"],
        scratch / "orca-apps-before-quit.json",
    ).get("apps", [])
    require_running_fixture_process(apps, process_id)

    swift = shutil.which("swift", path=os.environ.get("PATH", os.defpath))
    if not swift:
        raise DrillError("Swift is unavailable for an exact-PID graceful app termination request")
    module_cache = scratch / "swift-module-cache"
    module_cache.mkdir(parents=True, exist_ok=True)
    swift_source = graceful_termination_source(process_id)
    environment = {
        "PATH": os.environ.get("PATH", os.defpath),
        "HOME": str(scratch / "old-app-home"),
        "CFFIXED_USER_HOME": str(scratch / "old-app-home"),
        "TMPDIR": str(scratch / "old-app-tmp"),
        "LANG": "en_US.UTF-8",
    }
    for key in ("DEVELOPER_DIR", "SDKROOT"):
        if os.environ.get(key):
            environment[key] = os.environ[key]
    termination_output = run_logged(
        [swift, "-module-cache-path", str(module_cache), "-e", swift_source],
        scratch / "old-app-graceful-quit.log",
        environment=environment,
        timeout=45,
    )
    deadline = time.monotonic() + 15
    attempt = 0
    while time.monotonic() < deadline:
        apps = orca_result(
            [orca, "computer", "list-apps", "--json"],
            scratch / ("orca-apps-after-quit-" + str(attempt) + ".json"),
        ).get("apps", [])
        if not any(item.get("pid") == process_id and item.get("bundleId") == OLD_APP_BUNDLE_ID
                   and item.get("isRunning") is True for item in apps):
            return termination_output.strip()
        attempt += 1
        time.sleep(0.5)
    raise DrillError("the task-owned 1.0.11 app remained running after the graceful quit request")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-manifest-sha256", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{64}", args.input_manifest_sha256):
        parser.error("--input-manifest-sha256 must be a lowercase SHA-256")

    output_path = require_project_path(args.output)
    if output_path.exists() or output_path.is_symlink():
        parser.error("refusing to overwrite output: " + str(output_path))
    output_path.parent.mkdir(parents=True, exist_ok=True)

    scratch = Path(tempfile.mkdtemp(prefix=".codex-task-g02-old-app-", dir=str(ROOT)))
    if scratch.is_symlink() or scratch.resolve().parent != ROOT:
        raise DrillError("unsafe task scratch directory")
    process = None
    old_app_process_id = None
    old_app_ui_semantic_read = None
    graceful_quit_output = None
    mount = scratch / "mount"
    hdiutil = shutil.which("hdiutil", path=os.environ.get("PATH", os.defpath))
    mount_attempted = False
    mount_safe_to_remove = True
    cleanup_complete = False
    started = time.monotonic()
    report = {
        "schema_version": "latticelens-g02-old-app-rollback-v1",
        "run_id": dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8],
        "recorded_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "input_manifest_sha256": args.input_manifest_sha256,
        "status": "FAIL",
        "summary": "The older-app compatibility drill did not complete.",
        "checks": {},
        "errors": [],
        "source_sha256": {},
    }
    app_log = scratch / "old-app.log"
    swift_log = scratch / "fixture-test.log"
    app_output = None
    system_temporary_open_descriptors = []
    old_app_process_discovery = None

    try:
        if not any(Path(path).name == "T" for path in SYSTEM_TEMPORARY_PATHS):
            raise DrillError(
                "could not resolve the exact Darwin user temporary directory; refusing old-app launch")
        for name in ("tmp", "home", "fixture-stores", "fixture-tmp", "old-app-home", "old-app-tmp"):
            (scratch / name).mkdir()
        swiftpm_scratch = scratch / "swiftpm"
        swiftpm_scratch.mkdir()
        swiftpm_cache = swiftpm_scratch / "cache"
        swiftpm_config = swiftpm_scratch / "config"
        swiftpm_security = swiftpm_scratch / "security"
        for directory in (swiftpm_cache, swiftpm_config, swiftpm_security):
            directory.mkdir()
        fixture_root = scratch / "fixture-root"

        source_hashes = {}
        for relative in INPUTS:
            source = require_project_path(ROOT / relative, must_exist=True)
            source_hashes[relative] = sha256(source)
        report["source_sha256"] = source_hashes

        base_environment = {
            "PATH": os.environ.get("PATH", os.defpath),
            "HOME": str(scratch / "home"),
            "CFFIXED_USER_HOME": str(scratch / "home"),
            "TMPDIR": str(scratch / "tmp"),
            "LANG": "en_US.UTF-8",
            "LATTICELENS_TEST_STORE_ROOT": str(scratch / "fixture-stores"),
            "LATTICELENS_TEST_TMP_ROOT": str(scratch / "fixture-tmp"),
            "LATTICELENS_REQUIRE_PROJECT_LOCAL_TEST_ROOTS": "1",
            "LATTICELENS_ALLOW_PRODUCTION_ISOLATION": "0",
            "LATTICELENS_PRODUCTION_STORE_ROOT": "",
            "LATTICELENS_LIVE_INSPIRE_SMOKE": "0",
            "LATTICELENS_RUN_V4_BENCHMARK": "0",
            "LATTICELENS_RUN_V12_FORMULA_BENCHMARK": "0",
            "LATTICELENS_V10_PHYSICAL_ENOSPC_DRILL": "0",
            "LATTICELENS_G02_OLD_APP_ROLLBACK_FIXTURE_ROOT": str(fixture_root),
            "LATTICELENS_G02_INPUT_MANIFEST_SHA256": args.input_manifest_sha256,
        }
        for key in ("DEVELOPER_DIR", "SDKROOT"):
            if os.environ.get(key):
                base_environment[key] = os.environ[key]
        swift = shutil.which("swift", path=base_environment["PATH"])
        if not swift:
            raise DrillError("Swift toolchain is unavailable")
        test_command = [
            swift, "test", "--scratch-path", str(swiftpm_scratch),
            "--cache-path", str(swiftpm_cache),
            "--config-path", str(swiftpm_config),
            "--security-path", str(swiftpm_security),
            "--manifest-cache", "local", "--disable-dependency-cache",
            "--filter", FIXTURE_TEST, "-q",
        ]
        test_output = run_logged(test_command, swift_log, environment=base_environment,
                                 timeout=900)
        passed = re.findall(r"Test Case '-\[[^\]]+ " + re.escape(FIXTURE_TEST) +
                            r"\]' passed ", test_output)
        if len(passed) != 1 or re.search(r"Test Case '-\[[^\]]+ " + re.escape(FIXTURE_TEST) +
                                         r"\]' (?:failed|skipped)", test_output):
            raise DrillError("the fixture XCTest did not produce exactly one passing result")
        fixture_manifest_path = fixture_root / "old-app-rollback-fixture.json"
        if not fixture_manifest_path.is_file() or fixture_manifest_path.is_symlink():
            raise DrillError("the XCTest did not produce its rollback fixture manifest")
        fixture = json.loads(fixture_manifest_path.read_text(encoding="utf-8"))
        if (fixture.get("schema_version") != "latticelens-g02-old-app-rollback-fixture-v1" or
                fixture.get("input_manifest_sha256") != args.input_manifest_sha256 or
                fixture.get("source_schema_version") != 9 or fixture.get("target_schema_version") != 12 or
                not isinstance(fixture.get("paper_id"), int) or
                not isinstance(fixture.get("paper_title"), str) or not fixture["paper_title"].strip() or
                fixture.get("author_recid") != 2010363 or
                fixture.get("backup_verified") is not True or fixture.get("source_family_unchanged") is not True):
            raise DrillError("the migration XCTest fixture is not a verified manifest-bound V9/V12 pair")

        rollback_root = require_project_path(
            fixture_root / fixture["rollback_root_relative"], must_exist=True)
        legacy_store = require_project_path(
            rollback_root / "swiftdata" / Path(fixture["legacy_store_relative"]).name, must_exist=True)
        active_v12_store = require_project_path(
            rollback_root / "swiftdata" / Path(fixture["active_v12_store_relative"]).name, must_exist=True)
        if not legacy_store.is_file() or not active_v12_store.is_file():
            raise DrillError("rollback fixture database paths are not regular files")

        store_directory = legacy_store.parent
        backup_root = store_directory / Path(fixture["backup_root_relative"]).name
        backup_id = fixture["backup_id"]
        backup_manifest_path = backup_root / backup_id / "migration-manifest.json"
        migration_manifest = json.loads(backup_manifest_path.read_text(encoding="utf-8"))
        family_manifest = migration_manifest.get("storeFamilyManifest", {})
        family_files = fixture.get("backup_entries", [])
        if not family_files or migration_manifest.get("sourceSchemaVersion") != 9:
            raise DrillError("restored rollback backup is not recorded as a V9 family")

        backup_hashes_before = {}
        for entry in family_files:
            backup_file = backup_root / backup_id / entry["relative_path"]
            backup_file = require_project_path(backup_file, must_exist=True)
            if backup_file.stat().st_size != entry["byte_count"] or sha256(backup_file) != entry["sha256"]:
                raise DrillError("verified pre-upgrade backup entry does not match its receipt")
            backup_hashes_before[entry["relative_path"]] = entry["sha256"]
        if family_manifest.get("schemaVersion") != 9:
            raise DrillError("the V4 backup manifest does not identify schema 9")

        v12_hashes_before = {}
        for suffix in ("", "-wal", "-shm"):
            member = Path(str(active_v12_store) + suffix)
            if member.exists():
                if member.is_symlink() or not member.is_file():
                    raise DrillError("active V12 family contains a non-regular member")
                v12_hashes_before["main" if not suffix else suffix[1:]] = sha256(member)
        fixture_hashes = fixture.get("active_v12_family_sha256", {})
        if fixture_hashes != v12_hashes_before:
            raise DrillError("the V12 SQLite family changed after the isolated rollback target was built")

        old_manifest_path = require_project_path(OLD_MANIFEST, must_exist=True)
        old_dmg_path = require_project_path(OLD_DMG, must_exist=True)
        old_manifest = json.loads(old_manifest_path.read_text(encoding="utf-8"))
        dmg_artifact = old_manifest.get("artifacts", {}).get("dmg", {})
        if (old_manifest.get("product_version") != "1.0.11" or
                old_manifest.get("build_number") != 111 or
                old_manifest.get("bundle_id") != "org.latticelens.app" or
                old_manifest.get("app", {}).get("bundle") != "LatticeLens.app" or
                dmg_artifact.get("file") != OLD_DMG.name or
                not re.fullmatch(r"[0-9a-f]{64}", str(dmg_artifact.get("sha256", ""))) or
                dmg_artifact.get("bytes") != old_dmg_path.stat().st_size or
                sha256(old_dmg_path) != dmg_artifact.get("sha256")):
            raise DrillError("the 1.0.11 DMG differs from its preserved release manifest")
        dmg_verify_log = scratch / "dmg-verify.log"
        if not hdiutil:
            raise DrillError("hdiutil is unavailable")
        run_logged([hdiutil, "verify", str(old_dmg_path)], dmg_verify_log, timeout=120)
        mount.mkdir()
        mount_log = scratch / "dmg-mount.log"
        mount_attempted = True
        run_logged([hdiutil, "attach", "-nobrowse", "-readonly", "-mountpoint",
                    str(mount), str(old_dmg_path)], mount_log, timeout=120)
        if not mounted_at(hdiutil, mount):
            raise DrillError("the verified read-only DMG did not mount at the task-owned path")
        app = mount / old_manifest["app"]["bundle"]
        if not app.is_dir() or app.is_symlink():
            raise DrillError("the verified 1.0.11 DMG has no regular LatticeLens.app bundle")
        app_copy = scratch / "LatticeLens-1.0.11.app"
        shutil.copytree(app, app_copy, symlinks=True)
        info = plistlib.loads((app_copy / "Contents" / "Info.plist").read_bytes())
        executable = app_copy / "Contents" / "MacOS" / info["CFBundleExecutable"]
        app_identity = {
            "product_version": info.get("CFBundleShortVersionString"),
            "build_number": str(info.get("CFBundleVersion")),
            "bundle_id": info.get("CFBundleIdentifier"),
            "executable_sha256": sha256(executable),
            "architectures": run_logged(["lipo", "-archs", str(executable)],
                                         scratch / "architectures.log").strip(),
        }
        expected_app = old_manifest["app"]
        if (app_identity["product_version"] != "1.0.11" or
                app_identity["build_number"] != "111" or
                app_identity["bundle_id"] != old_manifest["bundle_id"] or
                app_identity["executable_sha256"] != expected_app["executable_sha256"] or
                set(app_identity["architectures"].split()) != {"arm64", "x86_64"}):
            raise DrillError("the mounted app does not match the declared 1.0.11 universal executable")
        run_logged(["codesign", "--verify", "--deep", "--strict", str(app_copy)],
                   scratch / "codesign-verify.log", timeout=120)

        account_home = Path(pwd.getpwuid(os.getuid()).pw_dir).expanduser()
        if not account_home.is_absolute() or not account_home.is_dir():
            raise DrillError("could not resolve the actual host user's home directory")
        user_library_paths = sorted({account_home / "Library", account_home.resolve() / "Library"},
                                    key=str)
        if any(scratch == path or scratch.is_relative_to(path) for path in user_library_paths):
            raise DrillError("task scratch unexpectedly resolves inside the host user's Library")
        profile = scratch / "old-app-sandbox.sb"
        protected_paths = [Path(str(active_v12_store) + suffix)
                           for suffix in ("", "-wal", "-shm")]
        protected_paths.append(
            store_directory / Path(fixture["active_v12_descriptor_relative"]).name)
        protected_path_rules = sandbox_file_access_denials(protected_paths)
        user_library_rules = sandbox_file_access_denials(user_library_paths)
        temporary_path_rules = sandbox_file_access_denials(SYSTEM_TEMPORARY_PATHS)
        profile.write_text(
            "(version 1)\n"
            "(allow default)\n"
            "(deny network*)\n"
            + user_library_rules +
            "(deny mach-lookup (global-name \"com.apple.securityd\"))\n" +
            temporary_path_rules +
            protected_path_rules,
            encoding="utf-8")
        sandbox_exec = shutil.which("sandbox-exec", path=base_environment["PATH"])
        if not sandbox_exec:
            raise DrillError("sandbox-exec is unavailable; refusing an unsandboxed old-app launch")
        orca = shutil.which("orca", path=base_environment["PATH"])
        if not orca:
            raise DrillError("Orca computer-use is unavailable; refusing to infer semantic readability from lsof")
        before_apps = orca_result([orca, "computer", "list-apps", "--json"],
                                  scratch / "orca-apps-before.json")
        before_matches = [item for item in before_apps.get("apps", [])
                          if item.get("bundleId") == OLD_APP_BUNDLE_ID and item.get("isRunning") is True]
        preexisting_same_bundle_process_count = len(before_matches)
        old_environment = [
            "/usr/bin/env", "-i",
            "HOME=" + str(scratch / "old-app-home"),
            "CFFIXED_USER_HOME=" + str(scratch / "old-app-home"),
            "TMPDIR=" + str(scratch / "old-app-tmp"),
            "LANG=en_US.UTF-8",
            "LATTICELENS_ALLOW_PRODUCTION_ISOLATION=1",
            "LATTICELENS_PRODUCTION_STORE_ROOT=" + str(rollback_root),
            str(executable), "-ApplePersistenceIgnoreState", "YES",
        ]
        app_output = app_log.open("wb")
        process = subprocess.Popen([sandbox_exec, "-f", str(profile), *old_environment],
                                   cwd=str(ROOT), stdin=subprocess.DEVNULL,
                                   stdout=app_output, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        opened_files = []
        lsof = shutil.which("lsof", path=base_environment["PATH"])
        if not lsof:
            raise DrillError("lsof is unavailable; refusing to infer which SQLite file the old app opened")
        for _ in range(60):
            if process.poll() is not None and not process_group_exists(process.pid):
                raise DrillError("1.0.11 exited before opening the restored V9 store")
            probe = subprocess.run([lsof, "-FfPn", "-g", str(process.pid)],
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   timeout=15, check=False)
            descriptors = parse_lsof_descriptors(probe.stdout.decode(
                "utf-8", errors="replace").splitlines())
            opened_files = [item["path"] for item in descriptors]
            system_temporary_open_descriptors = system_temporary_descriptor_summary(descriptors)
            if system_temporary_open_descriptors:
                raise DrillError("old-app process opened a sandbox-denied system temporary path")
            opened_legacy = any(name == str(legacy_store) or name.startswith(str(legacy_store) + "-")
                                for name in opened_files)
            opened_v12 = any(name == str(active_v12_store) or name.startswith(str(active_v12_store) + "-")
                             for name in opened_files)
            if opened_legacy and not opened_v12:
                break
            time.sleep(1)
        else:
            raise DrillError("1.0.11 did not open the restored V9 path without opening the V12 active store")

        time.sleep(2)
        app_log_text = app_log.read_text(encoding="utf-8", errors="replace")
        if re.search(r"Cannot use staged migration with an unknown model version|Store failed to load|"
                     r"NSCocoaErrorDomain\s*\(134504\)|addPersistentStoreWithType:.*returned error",
                     app_log_text, re.IGNORECASE):
            raise DrillError("1.0.11 reported a persistent-store load failure for the restored rollback fixture")

        expected_paper_id = fixture["paper_id"]
        expected_paper_title = fixture["paper_title"]
        running_apps = orca_result([orca, "computer", "list-apps", "--json"],
                                   scratch / "orca-apps-after-launch.json").get("apps", [])
        if not isinstance(process.pid, int):
            raise DrillError("the task-owned sandbox launch has no usable PID")
        same_bundle_running = [item for item in running_apps
                               if item.get("bundleId") == OLD_APP_BUNDLE_ID and
                               item.get("isRunning") is True]
        group_matches = task_group_fixture_processes(running_apps, process.pid)
        old_app_process_discovery = {
            "launch_process_id": process.pid,
            "launch_process_return_code": process.poll(),
            "preexisting_same_bundle_process_count": preexisting_same_bundle_process_count,
            "same_bundle_running_count": len(same_bundle_running),
            "task_group_match_count": len(group_matches),
            "selected_process_id": (group_matches[0].get("pid")
                                     if len(group_matches) == 1 else None),
        }
        if len(group_matches) != 1:
            raise DrillError(
                "the task-owned old-app process group did not contain exactly one running app "
                "with the expected bundle ID (same-bundle running=" +
                str(len(same_bundle_running)) + ", task-group matches=" + str(len(group_matches)) + ")")
        old_app_process_id = group_matches[0]["pid"]
        window_arguments = fixture_app_window_arguments(
            orca, old_app_process_id, scratch, "paper-read")
        tree_text = ""
        for attempt in range(10):
            state = orca_result(
                [orca, "computer", "get-app-state", "--app", "pid:" + str(old_app_process_id),
                 *window_arguments, "--json", "--no-screenshot"],
                scratch / ("orca-old-app-state-" + str(attempt) + ".json"), timeout=30)
            snapshot = state.get("snapshot", {})
            tree_text = snapshot.get("treeText", "") if isinstance(snapshot, dict) else ""
            if isinstance(tree_text, str) and expected_paper_title in tree_text:
                break
            time.sleep(1)
        if not isinstance(tree_text, str) or expected_paper_title not in tree_text:
            raise DrillError("1.0.11 UI did not expose the exact fixture paper title")
        visible_match_lines = [line.strip() for line in tree_text.splitlines()
                               if expected_paper_title in line]
        old_app_ui_semantic_read = {
            "provider": "orca-computer-use",
            "bundle_id": OLD_APP_BUNDLE_ID,
            "process_id": old_app_process_id,
            "paper_id": expected_paper_id,
            "paper_title": expected_paper_title,
            "title_visible": True,
            "visible_match_lines": visible_match_lines,
            "accessibility_tree_sha256": hashlib.sha256(tree_text.encode("utf-8")).hexdigest(),
        }
        final_probe = subprocess.run([lsof, "-FfPn", "-g", str(process.pid)],
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    timeout=15, check=False)
        if final_probe.returncode not in (0, 1):
            raise DrillError("could not recheck the isolated old-app process group before shutdown")
        descriptors = parse_lsof_descriptors(final_probe.stdout.decode(
            "utf-8", errors="replace").splitlines())
        opened_files = [item["path"] for item in descriptors]
        system_temporary_open_descriptors = system_temporary_descriptor_summary(descriptors)
        if system_temporary_open_descriptors:
            raise DrillError("old-app process opened a sandbox-denied system temporary path")
        if any(name == str(active_v12_store) or name.startswith(str(active_v12_store) + "-")
               for name in opened_files):
            raise DrillError("the older app opened the sandbox-denied active V12 SQLite family")
        forbidden_open = [name for name in opened_files
                          if any(name.startswith(str(path) + "/") for path in user_library_paths) or
                          "/Keychains/" in name or name.endswith("/login.keychain-db")]
        if forbidden_open:
            raise DrillError("old-app process exposed a user Library or Keychain file descriptor")
        app_was_running = process_group_exists(process.pid)
        graceful_quit_output = request_fixture_app_quit(orca, old_app_process_id, scratch)
        process_stopped = terminate_process(process)
        if process_stopped:
            process = None
        if app_output:
            app_output.close()
            app_output = None
        if not app_was_running or not process_stopped:
            raise DrillError("the isolated 1.0.11 process did not stay up or could not be stopped")

        sqlite3 = shutil.which("sqlite3", path=base_environment["PATH"])
        if not sqlite3:
            raise DrillError("sqlite3 CLI is unavailable for read-only integrity checks")
        legacy_integrity = sqlite_integrity(sqlite3, legacy_store, scratch / "legacy-integrity.log")
        active_integrity = sqlite_integrity(sqlite3, active_v12_store,
                                            scratch / "active-v12-integrity.log")
        v12_hashes_after = {}
        for suffix in ("", "-wal", "-shm"):
            member = Path(str(active_v12_store) + suffix)
            if member.exists():
                if member.is_symlink() or not member.is_file():
                    raise DrillError("active V12 family contains a non-regular member after rollback")
                v12_hashes_after["main" if not suffix else suffix[1:]] = sha256(member)
        if v12_hashes_after != v12_hashes_before:
            raise DrillError("the older app changed the active V12 SQLite family")

        backup_hashes_after = {}
        for entry in family_files:
            backup_file = backup_root / backup_id / entry["relative_path"]
            digest = sha256(backup_file)
            backup_hashes_after[entry["relative_path"]] = digest
            if digest != backup_hashes_before[entry["relative_path"]]:
                raise DrillError("the verified pre-upgrade backup changed while the old app ran")

        report["status"] = "PASS"
        report["summary"] = (
            "The manifest-bound 1.0.11 executable opened the restored V9-compatible store and displayed the exact "
            "fixture paper, did not open the active V12 SQLite family, and left that V12 family and the verified "
            "pre-upgrade backup byte-identical."
        )
        report["app"] = dict(app_identity, process_id=old_app_process_id)
        report["fixture"] = {
            "source_schema_version": 9,
            "active_schema_version": 12,
            "paper_id": fixture["paper_id"],
            "paper_title": fixture["paper_title"],
            "author_recid": fixture["author_recid"],
            "legacy_store_relative": str(legacy_store.relative_to(ROOT)),
            "active_v12_store_relative": str(active_v12_store.relative_to(ROOT)),
            "active_v12_descriptor_relative": str(
                (store_directory / Path(fixture["active_v12_descriptor_relative"]).name).relative_to(ROOT)),
            "backup_manifest_relative": str(backup_manifest_path.relative_to(ROOT)),
            "backup_verified_before_and_after": True,
        }
        report["checks"] = {
            "fixture_xctest": "PASS",
            "backup_manifest_and_family": "PASS",
            "old_app_dmg_and_executable_identity": "PASS",
            "old_app_launch": "PASS",
            "old_app_opened_restored_v9": "PASS",
            "old_app_did_not_open_v12": "PASS",
            "old_app_read_fixture_paper": "PASS",
            "v8_integrity_check": legacy_integrity,
            "v12_integrity_check": active_integrity,
            "v12_family_byte_stable": True,
            "verified_backup_byte_stable": True,
            "network_denied": True,
            "real_user_library_denied": True,
            "securityd_keychain_access_denied": True,
            "v12_path_denied_by_sandbox": True,
            "system_temporary_paths_denied": True,
            "task_process_stopped": True,
            "dmg_detached": False,
            "scratch_removed": False,
        }
        report["evidence"] = {
            "fixture_xctest_log_sha256": sha256(swift_log),
            "old_app_log_sha256": sha256(app_log),
            "dmg_sha256": sha256(old_dmg_path),
            "old_app_manifest_sha256": sha256(old_manifest_path),
            "old_app_ui_semantic_read": old_app_ui_semantic_read,
            "old_app_process_discovery": old_app_process_discovery,
            "preexisting_same_bundle_process_count": preexisting_same_bundle_process_count,
            "old_app_termination_mode": "NSRunningApplication.terminate with exact task-owned PID and bundle-ID checks",
            "old_app_termination_output": graceful_quit_output,
            "opened_project_files": [
                str(Path(name).relative_to(ROOT)) for name in opened_files
                if Path(name).is_relative_to(ROOT)
            ],
            "v12_family_sha256_before": v12_hashes_before,
            "v12_family_sha256_after": v12_hashes_after,
            "backup_family_sha256_before": backup_hashes_before,
            "backup_family_sha256_after": backup_hashes_after,
            "app_log_tail": tail(app_log, 40),
            "fixture_test_log_tail": tail(swift_log, 30),
        }
    except Exception as error:  # noqa: BLE001 - write a compact failure receipt for every stage outcome.
        report["status"] = "FAIL"
        report["summary"] = str(error)
        report["errors"].append(str(error))
        report["evidence"] = {
            "system_temporary_open_descriptors": system_temporary_open_descriptors,
            "old_app_process_discovery": old_app_process_discovery,
            "old_app_ui_semantic_read": old_app_ui_semantic_read,
            "fixture_xctest_log_tail": tail(swift_log, 40),
            "old_app_log_tail": tail(app_log, 40),
        }
    finally:
        process_stopped = process is None
        if process is not None:
            try:
                process_stopped = terminate_process(process)
            except OSError as error:
                PROCESS_TERMINATION_ERRORS.append(
                    "old-app process cleanup raised for pid " + str(process.pid) + ": " + str(error))
                process_stopped = False
                UNSTOPPED_PROCESS_GROUPS.add(process.pid)
        if app_output:
            try:
                app_output.close()
            except OSError as error:
                report["errors"].append("could not close old-app output log: " + str(error))
                report["status"] = "FAIL"
            app_output = None
        if "checks" in report:
            report["checks"]["task_process_stopped"] = (process is None or process_stopped)
        if process is not None and not process_stopped:
            report["status"] = "FAIL"
            report["errors"].append("could not stop the exact old-app process group")
        if UNSTOPPED_PROCESS_GROUPS:
            report["status"] = "FAIL"
            report["errors"].append(
                "task-owned command process groups remain: " +
                ",".join(str(value) for value in sorted(UNSTOPPED_PROCESS_GROUPS)))
        if mount_attempted:
            try:
                mounted = mounted_at(hdiutil, mount)
                if mounted:
                    run_logged([hdiutil, "detach", str(mount)],
                               scratch / "dmg-detach.log", timeout=60)
                    if mounted_at(hdiutil, mount):
                        raise DrillError("could not detach the exact read-only 1.0.11 DMG mount")
                if "checks" in report:
                    report["checks"]["dmg_detached"] = True
            except (OSError, subprocess.TimeoutExpired, DrillError) as error:
                mount_safe_to_remove = False
                report["status"] = "FAIL"
                report["errors"].append(str(error))
        if (mount_safe_to_remove and (process is None or process_stopped) and
                not UNSTOPPED_PROCESS_GROUPS):
            try:
                if scratch.is_dir() and not scratch.is_symlink() and scratch.resolve().parent == ROOT:
                    shutil.rmtree(scratch)
                    cleanup_complete = True
            except OSError as error:
                report["errors"].append("task scratch cleanup failed: " + str(error))
        report.setdefault("checks", {})["scratch_removed"] = cleanup_complete
        if PROCESS_TERMINATION_ERRORS:
            report.setdefault("evidence", {})["process_termination_diagnostics"] = list(
                PROCESS_TERMINATION_ERRORS)
        if not cleanup_complete:
            report["status"] = "FAIL"
            report["errors"].append("task scratch or a task-owned process/mount remains")
        report["elapsed_seconds"] = round(time.monotonic() - started, 3)
        report["errors"] = list(dict.fromkeys(report["errors"]))
        output_path.parent.mkdir(parents=True, exist_ok=True)
        if output_path.exists() or output_path.is_symlink():
            report["status"] = "FAIL"
            report["errors"].append("refusing to overwrite the requested receipt path")
        else:
            output_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print("G02_OLD_APP_ROLLBACK_STATUS=" + report["status"])
    print("G02_OLD_APP_ROLLBACK_RECEIPT=" + str(output_path.relative_to(ROOT)))
    print("G02_OLD_APP_ROLLBACK_SUMMARY=" + report["summary"])
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
