#!/usr/bin/env python3
"""Build and smoke-test a project-local, non-final LatticeLens 2.0 candidate.

The script accepts only a manifest-bound PARTIAL_NOT_FINAL verifier receipt.
It never writes to /Applications, Application Support, Keychain, or a user library.
"""

import argparse
import atexit
import datetime
import hashlib
import json
import os
import plistlib
import pwd
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path, PurePosixPath


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "release-assets" / "Release-2.0.0-local"
G09_ARTIFACT_CHECKS = (
    "dmg_verify",
    "readonly_mount",
    "mounted_signature",
    "isolated_install_executable_hash_match",
    "fixture_no_network_launch_smoke",
    "system_temporary_write_denied",
)
G09_COMPLETION_CHECKS = G09_ARTIFACT_CHECKS + (
    "full_user_workflow",
    "app_data_rollback",
)
PACKAGE_MANIFEST_SCHEMA = "latticelens-package-manifest-v2.1-local-candidate"
PACKAGE_RELOCATION_INDEX_SCHEMA = "latticelens-package-relocation-index-v1"
HISTORICAL_CONTEXT_PATHS = (
    "evidence/Continuation-20261003-F05-DerivationChain.md",
    "evidence/Continuation-20261003-G08-V11FormulaPerformance.md",
)
SYSTEM_TEMPORARY_PATHS = (
    "/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp",
    "/var/folders", "/private/var/folders",
)
ACTIVE_PROCESS_GROUPS = set()


def fail(message):
    raise RuntimeError(message)


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _path_has_symlink_component(path, root):
    root_path = Path(root)
    path = Path(path)
    try:
        relative = path.relative_to(root_path)
    except ValueError:
        return True
    if root_path.is_symlink() or any(part in ("", ".", "..") for part in relative.parts):
        return True
    current = root_path
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            return True
    return False


def _safe_package_relative_path(value):
    if not isinstance(value, str) or not value or "\\" in value:
        return None
    relative = PurePosixPath(value)
    if (relative.is_absolute() or relative.as_posix() != value or
            any(part in ("", ".", "..") for part in relative.parts)):
        return None
    return relative


def project_file(argument):
    if not isinstance(argument, (str, os.PathLike)):
        fail("input must be a regular, non-symlink project file")
    argument_text = os.fspath(argument)
    if "\\" in argument_text:
        fail("input path must use canonical project-relative separators")
    root = Path(ROOT)
    if root.is_symlink():
        fail("project root must not be a symlink")
    root = root.resolve(strict=True)
    path = Path(argument_text)
    if not path.is_absolute():
        path = root / path
    try:
        relative = path.relative_to(root)
    except ValueError:
        fail("input path is outside the project root")
    if (any(part in ("", ".", "..") for part in relative.parts) or
            _path_has_symlink_component(path, root) or not path.is_file()):
        fail("input must be a regular, non-symlink project file: " + str(path))
    resolved = path.resolve(strict=True)
    if not resolved.is_relative_to(root):
        fail("input path is outside the project root")
    return resolved


def controlled_environment(overrides):
    """Keep unrelated host settings while dropping every inherited app opt-in."""
    environment = {
        key: value for key, value in os.environ.items()
        if not key.startswith("LATTICELENS_")
    }
    environment.update(overrides)
    return environment


def validate_output_target(root, output):
    root_path = Path(root)
    if root_path.is_symlink():
        fail("project root must not be a symlink")
    root_path = root_path.resolve(strict=True)
    output_path = Path(os.path.abspath(Path(output)))
    if (output_path == root_path or not output_path.is_relative_to(root_path) or
            output_path.is_symlink()):
        fail("package output must remain inside the project and not be a symlink")

    parent = output_path.parent
    while parent != root_path:
        if parent.is_symlink():
            fail("package output parent must not be a symlink: " + str(parent))
        if not parent.is_dir():
            fail("package output parent must be an existing project directory: " + str(parent))
        parent = parent.parent
    return output_path


def package_output_target(root, output):
    path = Path(output)
    if not path.is_absolute():
        path = Path(root) / path
    return validate_output_target(root, path)


def require_new_output_directory(output):
    if output.exists() or output.is_symlink():
        fail("refusing to overwrite an existing 2.0 package directory")


def load_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail("unreadable JSON input " + path.name + ": " + str(error))


def validation_summary_path(validation_path):
    canonical_report = ROOT / "evidence" / "Validation-2.0-final-local.json"
    if validation_path == canonical_report:
        return ROOT / "VALIDATION_2.0_FINAL.md"
    return validation_path.with_suffix(".md")


def checked_run(command, *, cwd=ROOT, env=None, log=None, timeout=1800):
    log_stream = Path(log).open("wb") if log is not None else None
    process = None
    try:
        process = subprocess.Popen(command, cwd=cwd, env=env,
                                   stdout=log_stream if log_stream is not None else subprocess.PIPE,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        ACTIVE_PROCESS_GROUPS.add(process.pid)
        try:
            if log_stream is None:
                output_bytes, _ = process.communicate(timeout=timeout)
            else:
                process.wait(timeout=timeout)
                output_bytes = Path(log).read_bytes()
        except subprocess.TimeoutExpired:
            stopped = terminate_process(process)
            if log_stream is None:
                try:
                    output_bytes, _ = process.communicate(timeout=2)
                except subprocess.TimeoutExpired:
                    output_bytes = b""
            else:
                output_bytes = Path(log).read_bytes() if Path(log).is_file() else b""
            if not stopped:
                output = (output_bytes or b"").decode("utf-8", errors="replace")
                fail("timed-out command process group could not be stopped: " +
                     " ".join(map(str, command)) + "\n" + output[-4000:])
            fail("command timed out after " + str(timeout) + " seconds: " +
                 " ".join(map(str, command)))
        if process_group_exists(process.pid):
            stopped = terminate_process(process)
            if not stopped:
                fail("command left an unstoppable task-owned process group after exit: " +
                     " ".join(map(str, command)))
            fail("command left a task-owned process group after exit: " +
                 " ".join(map(str, command)))
        ACTIVE_PROCESS_GROUPS.discard(process.pid)
        output = (output_bytes or b"").decode("utf-8", errors="replace")
    finally:
        if log_stream is not None:
            log_stream.close()
    if process is not None and process.returncode != 0:
        tail = "\n".join(output.splitlines()[-30:])
        fail("command failed (" + str(process.returncode) + "): " +
             " ".join(map(str, command)) + "\n" + tail)
    return output


def process_group_exists(process_group):
    try:
        os.killpg(process_group, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def orca_environment():
    """Use the signed-in Orca runtime without changing the fixture app's HOME."""
    environment = dict(os.environ)
    host_home = Path(pwd.getpwuid(os.getuid()).pw_dir).expanduser().resolve(strict=True)
    environment["HOME"] = str(host_home)
    environment["CFFIXED_USER_HOME"] = str(host_home)
    return environment


def orca_result(command, *, log, timeout=30):
    try:
        response = json.loads(checked_run(command, env=orca_environment(), log=log,
                                          timeout=timeout))
    except json.JSONDecodeError as error:
        fail("Orca returned invalid JSON: " + str(error))
    if response.get("ok") is not True or not isinstance(response.get("result"), dict):
        fail("Orca could not inspect the isolated fixture app")
    return response["result"]


def fixture_app_window_arguments(orca, process_id, scratch, phase):
    apps = orca_result(
        [orca, "computer", "list-apps", "--json"],
        log=scratch / ("orca-apps-before-" + phase + ".json"),
    ).get("apps", [])
    if not any(item.get("pid") == process_id and item.get("bundleId") == "org.latticelens.app"
               and item.get("isRunning") is True for item in apps):
        fail("fixture app PID is no longer running; refusing bundle-ID fallback")
    windows = orca_result(
        [orca, "computer", "list-windows", "--app", "pid:" + str(process_id), "--json"],
        log=scratch / ("orca-windows-" + phase + ".json"),
    ).get("windows", [])
    matching = [window for window in windows
                if window.get("app", {}).get("pid") == process_id]
    if len(matching) != 1:
        fail("fixture app must have exactly one identifiable window")
    window = matching[0]
    window_id = window.get("id")
    if window_id is not None and str(window_id).lower() != "none":
        return ["--window-id", str(window_id)]
    return ["--window-index", str(window.get("index", 0))]


def request_fixture_app_quit(orca, process_id, scratch):
    app_selector = "pid:" + str(process_id)
    window_arguments = fixture_app_window_arguments(orca, process_id, scratch, "quit")
    quit_command = [orca, "computer", "hotkey", "--app", app_selector,
                    *window_arguments, "--key", "CmdOrCtrl+Q"]
    try:
        orca_result(
            [*quit_command, "--no-screenshot", "--json"],
            log=scratch / "orca-fixture-app-quit.json",
        )
    except RuntimeError as error:
        if "window_not_focused" not in str(error):
            raise
        orca_result(
            [*quit_command, "--restore-window", "--no-screenshot", "--json"],
            log=scratch / "orca-fixture-app-quit-restore-window.json",
        )
    deadline = time.monotonic() + 15
    attempt = 0
    while time.monotonic() < deadline:
        apps = orca_result(
            [orca, "computer", "list-apps", "--json"],
            log=scratch / ("orca-apps-after-fixture-quit-" + str(attempt) + ".json"),
        ).get("apps", [])
        if not any(item.get("pid") == process_id and item.get("bundleId") == "org.latticelens.app"
                   and item.get("isRunning") is True for item in apps):
            return
        attempt += 1
        time.sleep(0.5)
    fail("Orca did not observe the task-owned fixture app exit after Cmd+Q")


def fixture_app_ui_quit_result(orca, process_id, scratch, *, skip=False):
    if skip:
        return (
            "NOT_RUN",
            "Skipped by --skip-fixture-ui-quit; the identified sandbox process group is still stopped.",
        )
    try:
        request_fixture_app_quit(orca, process_id, scratch)
    except RuntimeError as error:
        if "window_not_focused" not in str(error):
            raise
        return (
            "NOT_RUN",
            "Orca could not focus the isolated fixture window, including after one --restore-window attempt; "
            "GUI quit remains unverified and the identified sandbox process group will be stopped.",
        )
    return "PASS", "Orca observed the isolated fixture app exit after Cmd+Q."


def stop_process_group(process_group, process=None):
    ACTIVE_PROCESS_GROUPS.add(process_group)
    try:
        os.killpg(process_group, signal.SIGTERM)
    except ProcessLookupError:
        pass
    except PermissionError:
        return False

    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if process is not None:
            process.poll()
        if not process_group_exists(process_group):
            if process is not None:
                try:
                    process.wait(timeout=0)
                except subprocess.TimeoutExpired:
                    pass
            ACTIVE_PROCESS_GROUPS.discard(process_group)
            return True
        time.sleep(0.1)

    try:
        os.killpg(process_group, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except PermissionError:
        return False
    if process is not None:
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        if not process_group_exists(process_group):
            ACTIVE_PROCESS_GROUPS.discard(process_group)
            return True
        time.sleep(0.1)
    return False


def terminate_process(process):
    if process is None:
        return True
    return stop_process_group(process.pid, process)


def cleanup_active_process_groups():
    stopped = True
    for process_group in tuple(ACTIVE_PROCESS_GROUPS):
        if not stop_process_group(process_group):
            stopped = False
    return stopped


atexit.register(cleanup_active_process_groups)


def sandbox_profile_text(host_home):
    home = Path(host_home).expanduser().resolve(strict=True)
    library = (home / "Library").resolve()
    library_rules = (
        "(deny file-read* (subpath " + json.dumps(str(library)) + "))\n"
        "(deny file-write* (subpath " + json.dumps(str(library)) + "))\n"
    )
    temporary_rules = "".join(
        "(deny file-write* (subpath " + json.dumps(path) + "))\n"
        for path in SYSTEM_TEMPORARY_PATHS
    )
    return (
        "(version 1)\n"
        "(allow default)\n"
        "(deny network*)\n"
        + library_rules
        + '(deny mach-lookup (global-name "com.apple.securityd"))\n'
        + temporary_rules
    )


def system_temporary_writes_denied(profile_text):
    return all(
        "(deny file-write* (subpath " + json.dumps(path) + "))" in profile_text
        for path in SYSTEM_TEMPORARY_PATHS
    )


def mounted_at(mount_path, hdiutil="hdiutil"):
    try:
        state = plistlib.loads(checked_run([hdiutil, "info", "-plist"]).encode("utf-8"))
    except (plistlib.InvalidFileException, ValueError) as error:
        fail("could not decode disk-image mount state: " + str(error))
    expected = str(mount_path)
    return any(entity.get("mount-point") == expected
               for image in state.get("images", [])
               for entity in image.get("system-entities", []))


def lipo_verify_arch_commands(binary):
    return [["lipo", str(binary), "-verify_arch", architecture]
            for architecture in ("arm64", "x86_64")]


def candidate_unpassed_gates(validation, package_checks):
    """Reconcile package evidence with pre-package gate results, without editing the receipt."""
    gate_results = validation.get("gate_results", [])
    g09_items = [item for item in gate_results if item.get("gate") == "G09"]
    if len(g09_items) != 1:
        fail("the verifier report must contain exactly one G09 gate")

    package_artifacts_passed = all(
        package_checks.get(check) == "PASS" for check in G09_ARTIFACT_CHECKS
    )
    g09_complete = all(
        package_checks.get(check) == "PASS" for check in G09_COMPLETION_CHECKS
    )
    partial_summary = (
        "The manifest-bound candidate DMG passed hash verification, read-only mount and signature checks; "
        "its project-local executable hash matched and the synthetic fixture launch smoke passed under "
        "a network-, user-Library-, Keychain-, and system-temporary-write-denying sandbox. "
        "Full offline user workflow, quit/relaunch and app/data rollback remain NOT_RUN."
    )
    complete_summary = (
        "The manifest-bound candidate DMG passed hash verification, read-only mount and signature checks; "
        "its project-local executable hash matched, the sandboxed synthetic fixture launch smoke passed, and the "
        "full offline user workflow, quit/relaunch and app/data rollback were accepted."
    )
    unpassed = []
    for item in gate_results:
        gate = item.get("gate")
        status = item.get("status")
        summary = item.get("summary") or ""
        if gate == "G09":
            if g09_complete and status not in ("FAIL", "BLOCKED"):
                status = "PASS"
                summary = complete_summary
            elif (status == "BLOCKED" and package_artifacts_passed and
                  "rebuild it before accepting G09" in str(summary)):
                status = "PARTIAL"
                summary = (partial_summary +
                           " The stale candidate was replaced; full offline workflow and app/data rollback remain NOT_RUN.")
            elif status not in ("FAIL", "BLOCKED"):
                status = "PARTIAL"
                if package_artifacts_passed:
                    summary = partial_summary
                else:
                    missing = [check for check in G09_ARTIFACT_CHECKS
                               if package_checks.get(check) != "PASS"]
                    summary = "G09 package evidence is incomplete: " + ", ".join(missing) + "."
            elif package_artifacts_passed:
                summary = (str(summary).rstrip() + " " + partial_summary +
                           " The pre-package failure/blocker remains uncleared.").strip()
        if status != "PASS":
            unpassed.append({"gate": gate, "status": status, "summary": summary})
    return unpassed


def build_input_manifest(run_id, output_path, explicit_inputs):
    roots = ["Sources", "Tests", "Scripts", "Assets", "Assets.xcassets",
             "LatticeLens.xcodeproj"]
    root_files = [
        "Package.swift", "README.md", "CHANGELOG.md", "VALIDATION_2.0.md",
        "VALIDATION_2.0_FINAL.md", "CleanupManifest-2.0.json",
        "CleanupManifest-2.0-final.json",
        "INSPIRE文献管理器2.0_開工方案_v5.md",
        "INSPIRE文獻管理器2.0_開工方案_final.md",
    ]
    paths = set(explicit_inputs)
    for relative in roots:
        base = ROOT / relative
        if not base.exists():
            continue
        for current, directories, files in os.walk(base, followlinks=False):
            current_path = Path(current)
            for name in list(directories):
                candidate = current_path / name
                if candidate.is_symlink():
                    paths.add(candidate)
                    directories.remove(name)
            for name in files:
                paths.add(current_path / name)
    for relative in root_files:
        path = ROOT / relative
        if path.is_file() or path.is_symlink():
            paths.add(path)

    entries = []
    for path in sorted(paths, key=lambda item: item.relative_to(ROOT).as_posix()):
        if not path.is_relative_to(ROOT):
            fail("build input escaped the project root")
        if path.is_symlink():
            resolved = path.resolve(strict=True)
            if not resolved.is_relative_to(ROOT):
                fail("build input symlink escaped the project root")
            target = os.readlink(path)
            entries.append({"path": path.relative_to(ROOT).as_posix(), "kind": "symlink",
                            "target": target,
                            "sha256": hashlib.sha256(target.encode("utf-8")).hexdigest()})
        elif path.is_file():
            entries.append({"path": path.relative_to(ROOT).as_posix(), "kind": "file",
                            "bytes": path.stat().st_size, "sha256": sha256(path)})
        else:
            fail("build input is not a regular file")

    present = {entry["path"] for entry in entries}
    if not {"Package.swift", "README.md", "CHANGELOG.md"}.issubset(present):
        fail("build input manifest is missing a required root document")
    if not any(path.startswith("Sources/") for path in present):
        fail("build input manifest contains no production sources")
    manifest = {"schema_version": "latticelens-build-input-manifest-v2.0",
                "run_id": run_id, "files": entries}
    output_path.write_text(json.dumps(manifest, ensure_ascii=False, sort_keys=True,
                                      indent=2) + "\n", encoding="utf-8")
    return sha256(output_path)


def package_checksum_map(package_directory):
    project_root = Path(ROOT).resolve(strict=True)
    package_path = Path(package_directory)
    if not package_path.is_absolute():
        package_path = project_root / package_path
    if (_path_has_symlink_component(package_path, project_root) or
            not package_path.is_dir()):
        fail("historical package path is missing, symlinked, or outside the project")
    package = package_path.resolve(strict=True)
    sums_path = package / "SHA256SUMS.txt"
    if (_path_has_symlink_component(sums_path, package) or
            not sums_path.is_file()):
        fail("historical package has no regular SHA256SUMS.txt")
    listed = {}
    for line_number, line in enumerate(sums_path.read_text(encoding="utf-8").splitlines(), 1):
        fields = line.split(maxsplit=1)
        if len(fields) != 2 or len(fields[0]) != 64 or any(ch not in "0123456789abcdef" for ch in fields[0]):
            fail("historical package checksum line is malformed: " + str(line_number))
        raw_path = fields[1].lstrip("*")
        relative = _safe_package_relative_path(raw_path)
        if relative is None or raw_path in listed:
            fail("historical package checksum path is unsafe or duplicated")
        target = package.joinpath(*relative.parts)
        if _path_has_symlink_component(target, package):
            fail("historical package checksum target is symlinked or outside its package")
        try:
            resolved = target.resolve(strict=True)
        except (OSError, RuntimeError, ValueError):
            fail("historical package checksum target is missing")
        if not resolved.is_relative_to(package) or not target.is_file():
            fail("historical package checksum target is symlinked or outside its package")
        actual = sha256(target)
        if actual != fields[0]:
            fail("historical package checksum mismatch: " + raw_path)
        listed[raw_path] = actual
    return listed


def historical_context_sources(validation):
    """Copy named history records from the exact candidate manifest bound by this verifier run."""
    artifacts = validation.get("artifacts")
    if not isinstance(artifacts, list):
        artifacts = []
    manifest_records = {
        (item.get("path"), item.get("sha256"))
        for item in artifacts if isinstance(item, dict) and
        item.get("kind") == "current_release_candidate_manifest"
    }
    if len(manifest_records) > 1:
        fail("validation receipt identifies more than one current candidate manifest")

    if not manifest_records:
        sources = []
        for source_path in HISTORICAL_CONTEXT_PATHS:
            source = ROOT / source_path
            if (_path_has_symlink_component(source, ROOT) or not source.is_file()):
                fail("no bound candidate package or regular historical context source exists: " + source_path)
            sources.append({"source_path": source_path, "source": source,
                            "sha256": sha256(source)})
        return sources

    manifest_relative, manifest_digest = next(iter(manifest_records))
    manifest_path = project_file(manifest_relative)
    if sha256(manifest_path) != manifest_digest or manifest_path.name != "manifest-v2.0-local-candidate.json":
        fail("validation receipt's current candidate manifest hash or filename is inconsistent")
    source_package = manifest_path.parent
    listed = package_checksum_map(source_package)
    manifest_relative_in_package = manifest_path.relative_to(source_package).as_posix()
    if listed.get(manifest_relative_in_package) != manifest_digest:
        fail("bound historical package manifest is not covered by its checksum list")
    manifest = load_json(manifest_path)
    if manifest.get("schema_version") not in (
            "latticelens-package-manifest-v2.0-local-candidate",
            PACKAGE_MANIFEST_SCHEMA):
        fail("bound historical package has an unsupported manifest schema")

    build_record = manifest.get("build_input_manifest")
    if not isinstance(build_record, dict) or build_record.get("file") != "build-inputs-v2.0.json":
        fail("bound historical package has no valid build-input manifest reference")
    build_path = source_package / "build-inputs-v2.0.json"
    if (build_path.is_symlink() or not build_path.is_file() or
            sha256(build_path) != build_record.get("sha256") or
            listed.get("build-inputs-v2.0.json") != build_record.get("sha256")):
        fail("bound historical package build-input manifest is missing or changed")
    build_inputs = load_json(build_path)
    if (build_inputs.get("schema_version") != "latticelens-build-input-manifest-v2.0" or
            build_inputs.get("run_id") != manifest.get("run_id")):
        fail("bound historical package build-input manifest has a mismatched run identity")
    build_entries = {item.get("path"): item for item in build_inputs.get("files", [])
                     if isinstance(item, dict)}

    relocation_by_source = {}
    if manifest.get("schema_version") == PACKAGE_MANIFEST_SCHEMA:
        validation_record = manifest.get("validation", {})
        index_record = validation_record.get("relocation_index") if isinstance(validation_record, dict) else None
        if not isinstance(index_record, dict):
            fail("bound v2.1 package has no relocation index")
        index_relative = _safe_package_relative_path(index_record.get("path"))
        if index_relative is None:
            fail("bound historical package relocation-index path is unsafe")
        index_path = source_package.joinpath(*index_relative.parts)
        if (_path_has_symlink_component(index_path, source_package) or not index_path.is_file() or
                sha256(index_path) != index_record.get("sha256") or
                listed.get(index_relative.as_posix()) != index_record.get("sha256")):
            fail("bound historical package relocation index is missing or changed")
        index_value = load_json(index_path)
        if (index_value.get("schema_version") != PACKAGE_RELOCATION_INDEX_SCHEMA or
                index_value.get("package_run_id") != manifest.get("run_id")):
            fail("bound historical package relocation index has a mismatched identity")
        relocation_by_source = {
            item.get("source_path"): item for item in index_value.get("files", [])
            if isinstance(item, dict) and item.get("role") == "historical_context"
        }

    result = []
    for source_path in HISTORICAL_CONTEXT_PATHS:
        if manifest.get("schema_version") == PACKAGE_MANIFEST_SCHEMA:
            record = relocation_by_source.get(source_path)
            if not isinstance(record, dict):
                fail("bound candidate omits a historical context mapping: " + source_path)
            package_relative = PurePosixPath(record.get("package_path", ""))
            expected_digest = record.get("sha256")
        else:
            input_entry = build_entries.get(source_path)
            if not isinstance(input_entry, dict) or input_entry.get("kind") != "file":
                fail("bound legacy candidate omits a historical build-input record: " + source_path)
            package_relative = PurePosixPath("compact-validation") / PurePosixPath(source_path).name
            expected_digest = input_entry.get("sha256")
        raw_package_path = package_relative.as_posix()
        if (_safe_package_relative_path(raw_package_path) is None or
                not raw_package_path.startswith("compact-validation/")):
            fail("bound candidate historical context path is unsafe")
        packaged_source = source_package.joinpath(*package_relative.parts)
        if _path_has_symlink_component(packaged_source, source_package):
            fail("bound candidate historical context failed its package hash check: " + source_path)
        try:
            resolved_source = packaged_source.resolve(strict=True)
        except (OSError, RuntimeError, ValueError):
            fail("bound candidate historical context file is missing: " + source_path)
        actual_digest = sha256(packaged_source)
        if (not resolved_source.is_relative_to(source_package) or not packaged_source.is_file() or
                actual_digest != expected_digest or
                listed.get(raw_package_path) != actual_digest):
            fail("bound candidate historical context failed its package hash check: " + source_path)
        if source_path in build_entries:
            input_entry = build_entries[source_path]
            if (input_entry.get("sha256") != actual_digest or
                    input_entry.get("bytes") != packaged_source.stat().st_size):
                fail("historical context differs from its preserved build-input identity: " + source_path)
        result.append({"source_path": source_path, "source": packaged_source,
                       "package_path": raw_package_path, "sha256": actual_digest})
    return result


def app_identity(app):
    info_path = app / "Contents" / "Info.plist"
    icon_path = app / "Contents" / "Resources" / "AppIcon.icns"
    if not app.is_dir() or not info_path.is_file() or not icon_path.is_file():
        fail("app bundle is missing its Info.plist or AppIcon")
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    if (info.get("CFBundleShortVersionString") != "2.0.0" or
            info.get("CFBundleVersion") != "201" or
            info.get("CFBundleIdentifier") != "org.latticelens.app"):
        fail("app identity does not match LatticeLens 2.0.0 (201)")
    executable = info.get("CFBundleExecutable")
    binary = app / "Contents" / "MacOS" / str(executable)
    if not binary.is_file():
        fail("app executable is missing")
    for command in lipo_verify_arch_commands(binary):
        checked_run(command)
    return binary, icon_path


def sorted_uuids(binary):
    values = []
    for line in checked_run(["dwarfdump", "--uuid", str(binary)]).splitlines():
        fields = line.split()
        if len(fields) >= 2:
            values.append(" ".join(fields[1:3]))
    return "\n".join(sorted(values))


def parse_arguments(arguments=None):
    parser = argparse.ArgumentParser(
        description=("Build and smoke-test a project-local 2.0 candidate from "
                     "manifest-bound PARTIAL_NOT_FINAL evidence."),
    )
    parser.add_argument("partial_validation", metavar="partial-validation.json",
                        help="current project-local verifier JSON")
    parser.add_argument("input_manifest", metavar="input-manifest.json",
                        help="verifier input manifest matching that receipt")
    parser.add_argument("v11_performance", metavar="v11-performance.json",
                        help="manifest-bound V11 performance receipt")
    parser.add_argument("v10_migration", metavar="v10-migration.json",
                        help="manifest-bound V10 migration receipt")
    parser.add_argument("--output-directory", default=str(OUTPUT),
                        help="new project-local package directory (default: %(default)s); existing targets are never overwritten")
    parser.add_argument("--skip-fixture-ui-quit", action="store_true",
                        help="leave GUI quit NOT_RUN and stop only the identified sandbox process group")
    return parser.parse_args(arguments)


def main(arguments=None):
    args = parse_arguments(arguments)
    validation_path, input_manifest_path, performance_path, migration_path = [
        project_file(argument) for argument in (
            args.partial_validation, args.input_manifest,
            args.v11_performance, args.v10_migration,
        )
    ]
    validation = load_json(validation_path)
    input_manifest = load_json(input_manifest_path)
    performance = load_json(performance_path)
    migration = load_json(migration_path)

    if (validation.get("schema_version") != "latticelens-verify-2.0-final-local" or
            validation.get("product_version") != "2.0.0" or
            validation.get("build_number") != 201 or
            validation.get("verdict") != "PARTIAL_NOT_FINAL"):
        fail("this packager requires a current 2.0.0 (201) PARTIAL_NOT_FINAL receipt")
    manifest_hash = validation.get("input_manifest_sha256")
    if (input_manifest_path.relative_to(ROOT).as_posix() != validation.get("input_manifest_path") or
            sha256(input_manifest_path) != manifest_hash):
        fail("the verifier report and supplied frozen input manifest do not match")
    if input_manifest.get("run_id") != validation.get("run_id"):
        fail("the supplied input manifest has a different verifier run ID")
    if (validation.get("performance_benchmark", {}).get("status") != "PASS" or
            validation.get("migration_drill", {}).get("status") != "PASS"):
        fail("current synthetic V11 performance and V10 migration receipts must both pass")
    if (performance.get("input_manifest_sha256") != manifest_hash or
            migration.get("inputManifestSHA256") != manifest_hash):
        fail("performance or migration evidence is stale for the verifier manifest")
    if (validation.get("performance_benchmark", {}).get("report_path") !=
            performance_path.relative_to(ROOT).as_posix() or
            validation.get("migration_drill", {}).get("receipt_path") !=
            migration_path.relative_to(ROOT).as_posix()):
        fail("supplied performance or migration path does not match the validation report")
    if (sha256(performance_path) != validation["performance_benchmark"].get("report_sha256") or
            sha256(migration_path) != validation["migration_drill"].get("receipt_sha256")):
        fail("performance or migration evidence hash does not match the validation report")
    output_path = package_output_target(ROOT, args.output_directory)
    require_new_output_directory(output_path)

    run_id = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
    scratch = Path(tempfile.mkdtemp(prefix=".codex-task-tmp-2.0-package-" + run_id + "-",
                                    dir=str(ROOT))).resolve()
    if scratch.parent != ROOT or scratch.is_symlink():
        fail("unsafe package scratch directory")
    pending = scratch / "Release-2.0.0-local"
    mount = scratch / "mounted-dmg"
    install_root = scratch / "isolated-install"
    build_log = scratch / "xcodebuild.log"
    smoke_log = scratch / "fixture-launch-smoke.log"
    process = None
    smoke_launcher_pid = None
    smoke_app_process_id = None
    fixture_app_ui_quit_status = "NOT_RUN"
    fixture_app_ui_quit_summary = "Fixture app launch has not yet been observed."
    mounted = False
    mount_attempted = False
    completed = False

    try:
        for directory in (scratch / "tmp", scratch / "home", scratch / "isolated-home",
                          scratch / "isolated-tmp", scratch / "isolated-store",
                          scratch / "isolated-fixture-cache", scratch / "stage",
                          mount, install_root, pending / "compact-validation"):
            directory.mkdir(parents=True, exist_ok=True)

        summary_path = validation_summary_path(validation_path)
        if not summary_path.is_file() or summary_path.is_symlink():
            fail("run-specific validation summary is missing")
        explicit_inputs = {validation_path, summary_path, input_manifest_path,
                           performance_path, migration_path}
        build_inputs_path = scratch / "build-inputs-v2.0.json"
        build_inputs_hash = build_input_manifest(run_id, build_inputs_path, explicit_inputs)

        build_environment = controlled_environment({
            "HOME": str(scratch / "home"),
            "CFFIXED_USER_HOME": str(scratch / "home"),
            "TMPDIR": str(scratch / "tmp"),
        })
        build_command = [
            "xcodebuild", "-project", "LatticeLens.xcodeproj", "-scheme", "LatticeLens",
            "-configuration", "Release", "-destination", "generic/platform=macOS",
            "-derivedDataPath", str(scratch / "DerivedData"), "ARCHS=arm64 x86_64",
            "ONLY_ACTIVE_ARCH=NO", "CODE_SIGNING_ALLOWED=NO",
            "DEBUG_INFORMATION_FORMAT=dwarf-with-dsym", "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES",
            "SWIFT_STRICT_CONCURRENCY=complete", "build", "-quiet",
        ]
        checked_run(build_command, env=build_environment, log=build_log)

        app = scratch / "DerivedData" / "Build" / "Products" / "Release" / "LatticeLens.app"
        binary, icon = app_identity(app)
        dsym = scratch / "DerivedData" / "Build" / "Products" / "Release" / "LatticeLens.app.dSYM"
        dsym_binary = dsym / "Contents" / "Resources" / "DWARF" / "LatticeLens"
        if not dsym.is_dir() or not dsym_binary.is_file():
            fail("universal Release dSYM is missing")
        app_uuids = sorted_uuids(binary)
        if not app_uuids or app_uuids != sorted_uuids(dsym_binary):
            fail("dSYM UUIDs do not match the universal Release executable")

        checked_run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(app)])
        checked_run(["codesign", "--verify", "--deep", "--strict", str(app)])
        signature = checked_run(["codesign", "--display", "--verbose=4", str(app)])
        signature_path = pending / "signature-inspection.log"
        signature_path.write_text(signature, encoding="utf-8")
        if "Signature=adhoc" not in signature:
            fail("app signature is not the declared ad-hoc local signature")

        shutil.copytree(app, scratch / "stage" / "LatticeLens.app", symlinks=True)
        os.symlink("/Applications", scratch / "stage" / "Applications")
        dmg = pending / "LatticeLens-2.0.0-local.dmg"
        checked_run(["hdiutil", "create", "-volname", "LatticeLens 2.0.0",
                     "-srcfolder", str(scratch / "stage"), "-ov", "-format", "UDZO",
                     str(dmg)], log=pending / "dmg-create.log")
        checked_run(["hdiutil", "verify", str(dmg)], log=pending / "dmg-verify.log")
        mount.mkdir(exist_ok=True)
        mount_attempted = True
        checked_run(["hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint",
                     str(mount), str(dmg)], log=pending / "dmg-mount.log")
        mounted = mounted_at(mount)
        if not mounted:
            fail("verified DMG did not mount at the task-owned project path")
        mounted_app = mount / "LatticeLens.app"
        mounted_binary, _ = app_identity(mounted_app)
        checked_run(["codesign", "--verify", "--deep", "--strict", str(mounted_app)])

        installed_app = install_root / "LatticeLens.app"
        shutil.copytree(mounted_app, installed_app, symlinks=True)
        installed_binary, _ = app_identity(installed_app)
        binary_hash = sha256(binary)
        if sha256(installed_binary) != binary_hash:
            fail("isolated installed executable differs from the mounted DMG")

        smoke_home = scratch / "isolated-home"
        smoke_tmp = scratch / "isolated-tmp"
        smoke_store = scratch / "isolated-store"
        smoke_cache = scratch / "isolated-fixture-cache"
        smoke_environment = controlled_environment({
            "LATTICELENS_USE_FIXTURES": "1",
            "LATTICELENS_TEST_STORE_ROOT": str(smoke_store),
            "LATTICELENS_TEST_TMP_ROOT": str(smoke_tmp),
            "LATTICELENS_FIXTURE_CACHE_ROOT": str(smoke_cache),
            "LATTICELENS_REQUIRE_PROJECT_LOCAL_TEST_ROOTS": "1",
            "HOME": str(smoke_home),
            "CFFIXED_USER_HOME": str(smoke_home),
            "TMPDIR": str(smoke_tmp),
        })
        host_home = Path(pwd.getpwuid(os.getuid()).pw_dir).expanduser().resolve(strict=True)
        host_library = (host_home / "Library").resolve()
        if scratch == host_library or scratch.is_relative_to(host_library):
            fail("package scratch unexpectedly resolves inside the real user Library")
        sandbox_profile = scratch / "fixture-app-sandbox.sb"
        sandbox_text = sandbox_profile_text(host_home)
        if not system_temporary_writes_denied(sandbox_text):
            fail("fixture sandbox profile does not deny every system temporary directory")
        sandbox_profile.write_text(sandbox_text, encoding="utf-8")
        sandbox_exec = shutil.which("sandbox-exec", path=smoke_environment.get("PATH"))
        if not sandbox_exec:
            fail("sandbox-exec is unavailable; refusing an unsandboxed fixture-app launch")
        orca = shutil.which("orca", path=smoke_environment.get("PATH"))
        if not orca:
            fail("Orca computer-use is unavailable; refusing an unverified fixture-app shutdown")
        apps_before = orca_result(
            [orca, "computer", "list-apps", "--json"],
            log=scratch / "orca-apps-before-fixture-launch.json",
        ).get("apps", [])
        if any(item.get("bundleId") == "org.latticelens.app" and item.get("isRunning") is True
               for item in apps_before):
            fail("an existing LatticeLens process is running; refusing an ambiguous fixture-app smoke")
        smoke_process_stopped = False
        with smoke_log.open("wb") as output:
            process = subprocess.Popen([sandbox_exec, "-f", str(sandbox_profile),
                                        str(installed_binary), "-LatticeLensUseFixtures", "YES"],
                                       cwd=str(ROOT), env=smoke_environment,
                                       stdin=subprocess.DEVNULL,
                                       stdout=output, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            ACTIVE_PROCESS_GROUPS.add(process.pid)
            smoke_launcher_pid = process.pid
            for _ in range(3):
                time.sleep(1)
                if process.poll() is not None:
                    fail("fixture/no-network app exited before the three-second launch smoke")
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                apps_after = orca_result(
                    [orca, "computer", "list-apps", "--json"],
                    log=scratch / "orca-apps-after-fixture-launch.json",
                ).get("apps", [])
                matching_apps = [item for item in apps_after
                                 if item.get("bundleId") == "org.latticelens.app"
                                 and item.get("isRunning") is True]
                if len(matching_apps) == 1 and isinstance(matching_apps[0].get("pid"), int):
                    smoke_app_process_id = matching_apps[0]["pid"]
                    if smoke_app_process_id != process.pid:
                        fail("Orca identified a different process than the task-owned sandbox launch")
                    break
                time.sleep(0.5)
            if smoke_app_process_id is None:
                fail("Orca did not identify exactly one task-owned fixture app process")
            fixture_app_ui_quit_status, fixture_app_ui_quit_summary = fixture_app_ui_quit_result(
                orca, smoke_app_process_id, scratch, skip=args.skip_fixture_ui_quit)
            smoke_process_stopped = terminate_process(process)
            if not smoke_process_stopped:
                fail("sandboxed fixture app process group could not be stopped")
            process = None

        checked_run(["hdiutil", "detach", str(mount)], log=pending / "dmg-unmount.log")
        if mounted_at(mount):
            fail("candidate DMG remained mounted after detach")
        mounted = False
        mount_attempted = False

        dsym_zip = pending / "LatticeLens-2.0.0.dSYM.zip"
        checked_run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent",
                     str(dsym), str(dsym_zip)])
        shutil.copy2(build_log, pending / "build.log")
        build_text = (pending / "build.log").read_text(encoding="utf-8", errors="replace")
        build_text = build_text.replace(str(ROOT), "<Reference_manager>").replace(str(scratch), "<package-scratch>")
        (pending / "build.log").write_text(build_text, encoding="utf-8")
        shutil.copy2(smoke_log, pending / "fixture-launch-smoke.log")
        smoke_text = (pending / "fixture-launch-smoke.log").read_text(encoding="utf-8", errors="replace")
        smoke_text = smoke_text.replace(str(ROOT), "<Reference_manager>").replace(str(scratch), "<package-scratch>")
        (pending / "fixture-launch-smoke.log").write_text(smoke_text, encoding="utf-8")
        shutil.copy2(build_inputs_path, pending / "build-inputs-v2.0.json")

        compact = pending / "compact-validation"
        core_sources = (
            ("validation_report", validation_path),
            ("validation_summary", summary_path),
            ("input_manifest", input_manifest_path),
            ("performance", performance_path),
            ("migration", migration_path),
        )
        relocation_files = []
        for role, source in core_sources:
            package_relative = "compact-validation/" + source.name
            destination = pending / package_relative
            if destination.exists() or destination.is_symlink():
                fail("two validation inputs map to the same package path: " + package_relative)
            shutil.copy2(source, destination)
            relocation_files.append({
                "role": role,
                "source_path": source.relative_to(ROOT).as_posix(),
                "package_path": package_relative,
                "sha256": sha256(source),
            })

        history_sources = historical_context_sources(validation)
        for item in history_sources:
            package_relative = "compact-validation/" + Path(item["source_path"]).name
            destination = pending / package_relative
            if destination.exists() or destination.is_symlink():
                fail("historical context collides with another package input: " + package_relative)
            shutil.copy2(item["source"], destination)
            copied_hash = sha256(destination)
            if copied_hash != item["sha256"]:
                fail("historical context changed while copying: " + item["source_path"])
            relocation_files.append({
                "role": "historical_context",
                "source_path": item["source_path"],
                "package_path": package_relative,
                "sha256": copied_hash,
            })
        shutil.copy2(ROOT / "VALIDATION_2.0.md", compact / "VALIDATION_2.0.md")
        relocation_index = {
            "schema_version": PACKAGE_RELOCATION_INDEX_SCHEMA,
            "package_run_id": run_id,
            "validation_run_id": validation.get("run_id"),
            "source_path_base": "project-relative-v1",
            "package_path_base": "package-relative-v1",
            "files": sorted(relocation_files, key=lambda item: (item["role"], item["source_path"])),
        }
        relocation_index_path = compact / "relocation-index.json"
        relocation_index_path.write_text(
            json.dumps(relocation_index, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
            encoding="utf-8")
        relocation_index_hash = sha256(relocation_index_path)

        dmg_hash = sha256(dmg)
        dsym_hash = sha256(dsym_zip)
        icon_hash = sha256(icon)
        validation_hash = sha256(validation_path)
        performance_hash = sha256(performance_path)
        migration_hash = sha256(migration_path)
        package_checks = {
            "dmg_verify": "PASS",
            "readonly_mount": "PASS",
            "mounted_signature": "PASS",
            "isolated_install_executable_hash_match": "PASS",
            "fixture_no_network_launch_smoke": "PASS",
            "system_temporary_write_denied": "PASS",
            "fixture_app_ui_quit": fixture_app_ui_quit_status,
            "ui_runner": validation.get("xcode_actions", {}).get("ui_tests", {}).get("status"),
            "full_user_workflow": "NOT_RUN",
            "voiceover": "NOT_RUN",
            "three_paper_lqcd_physics_review": "NOT_RUN",
            "applications_install": "NOT_RUN",
            "app_data_rollback": "NOT_RUN",
        }
        unpassed_gates = candidate_unpassed_gates(validation, package_checks)
        manifest = {
            "schema_version": PACKAGE_MANIFEST_SCHEMA,
            "run_id": run_id,
            "generated_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "artifact_class": "same_mac_local_ad_hoc_candidate",
            "product_version": "2.0.0",
            "build_number": 201,
            "minimum_macos": "14.0",
            "bundle_id": "org.latticelens.app",
            "signature_class": "ad_hoc_local",
            "developer_id": False,
            "notarized": False,
            "release_status": "PARTIAL_NOT_FINAL",
            "build_input_manifest": {
                "file": "build-inputs-v2.0.json", "sha256": build_inputs_hash,
                "input_verifier_manifest_sha256": manifest_hash,
            },
            "validation": {
                "path_base": "package-relative-v1",
                "report": "compact-validation/" + validation_path.name,
                "report_sha256": validation_hash,
                "summary": {
                    "path": "compact-validation/" + summary_path.name,
                    "source_path": summary_path.relative_to(ROOT).as_posix(),
                    "sha256": sha256(summary_path),
                },
                "input_manifest": {
                    "path": "compact-validation/" + input_manifest_path.name,
                    "source_path": input_manifest_path.relative_to(ROOT).as_posix(),
                    "sha256": sha256(input_manifest_path),
                },
                "performance": {
                    "path": "compact-validation/" + performance_path.name,
                    "source_path": performance_path.relative_to(ROOT).as_posix(),
                    "sha256": performance_hash,
                },
                "migration": {
                    "path": "compact-validation/" + migration_path.name,
                    "source_path": migration_path.relative_to(ROOT).as_posix(),
                    "sha256": migration_hash,
                },
                "relocation_index": {
                    "path": "compact-validation/relocation-index.json",
                    "sha256": relocation_index_hash,
                },
                "unpassed_gates": unpassed_gates,
            },
            "app": {
                "bundle": "LatticeLens.app",
                "architectures": checked_run(["lipo", "-archs", str(binary)]).strip(),
                "native_architecture_smoke": "arm64",
                "executable_sha256": binary_hash,
                "app_icon_sha256": icon_hash,
                "dsym_uuids": app_uuids.splitlines(),
            },
            "artifacts": {
                "dmg": {"file": "LatticeLens-2.0.0-local.dmg", "sha256": dmg_hash},
                "dsym": {"file": "LatticeLens-2.0.0.dSYM.zip", "sha256": dsym_hash},
            },
            "checks": package_checks,
            "fixture_sandbox": {
                "mechanism": "macOS sandbox-exec",
                "profile_sha256": sha256(sandbox_profile),
                "network_denied": True,
                "user_library_read_write_denied": True,
                "keychain_service_denied": True,
                "system_temporary_paths_write_denied": True,
                "system_temporary_write_probe": "not attempted outside Reference_manager",
                "fixture_app_ui_quit_summary": fixture_app_ui_quit_summary,
                "task_process_pid_matched_orca_app_pid": (smoke_app_process_id == smoke_launcher_pid),
                "process_group_stopped": smoke_process_stopped,
            },
            "install_boundary": (
                "The app was mounted read-only, copied, and launched only from a project-local "
                "isolated install with synthetic fixture roots under macOS sandbox-exec. Network, "
                "the real user's Library and Keychain service, and system temporary paths were "
                "denied; no /Applications installation or user PDF access was performed."
            ),
        }
        manifest_path = pending / "manifest-v2.0-local-candidate.json"
        manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, sort_keys=True,
                                            indent=2) + "\n", encoding="utf-8")
        (pending / "CHANGELOG.md").write_bytes((ROOT / "CHANGELOG.md").read_bytes())
        install_doc = """# LatticeLens 2.0.0 local candidate

This is a same-Mac, ad-hoc-signed candidate, not a final or public release.
It is not Developer ID signed or notarized. The manifest lists every gate
that remains incomplete; do not infer successful UI, VoiceOver, physics, or
installed-user-data acceptance from the mounted fixture launch smoke.

## Inspect and install

1. Verify SHA256SUMS.txt and manifest-v2.0-local-candidate.json before use.
2. This project-local package was mounted read-only and copied only into a
   disposable in-project install directory. No /Applications installation
   was performed. If manually installing later, inspect any existing app and
   choose rename, replace after backup, or cancel; never silently overwrite.
3. The automated launch smoke used synthetic fixture roots and no live INSPIRE,
   provider, Keychain, Application Support library, or user PDF. Interactive
   browsing, note persistence, VoiceOver, and quit/relaunch acceptance remain
   separate.

## Rollback and uninstall boundary

- Quit the app and remove only the exact isolated app copy used for testing.
- Keep the synthetic store and migration backup until checksums and semantic
  counts have been reconciled. This candidate did not migrate a real library.
- A future real-store rollback must restore a verified pre-migration backup to
  a new target and only then let the user select the active library.
- Default uninstall removes only the app. Keep Application Support, PDFs,
  Keychain entries, libraries, and Research Bundles unless the user separately
  requests a verified full purge.
"""
        (pending / "INSTALL_AND_ROLLBACK.md").write_text(install_doc, encoding="utf-8")

        checksum_lines = []
        for path in sorted(item for item in pending.rglob("*") if item.is_file()
                           and item.name != "SHA256SUMS.txt"):
            checksum_lines.append(sha256(path) + "  " + path.relative_to(pending).as_posix())
        (pending / "SHA256SUMS.txt").write_text("\n".join(checksum_lines) + "\n",
                                               encoding="utf-8")
        checked_run(["shasum", "-a", "256", "-c", "SHA256SUMS.txt"], cwd=pending)
        reloaded = load_json(manifest_path)
        if (reloaded.get("release_status") != "PARTIAL_NOT_FINAL" or
                not reloaded.get("validation", {}).get("unpassed_gates")):
            fail("candidate manifest failed its non-final status invariant")
        output_path = package_output_target(ROOT, args.output_directory)
        require_new_output_directory(output_path)
        os.rename(pending, output_path)
        completed = True
        print("candidate=" + str(output_path))
        print("dmg_sha256=" + dmg_hash)
        print("build_input_manifest_sha256=" + build_inputs_hash)
        print("release_status=PARTIAL_NOT_FINAL")
        return 0
    finally:
        cleanup_errors = []
        if process is not None and not terminate_process(process):
            cleanup_errors.append("fixture app process group could not be stopped")
        if mount_attempted or mounted:
            try:
                still_mounted = mounted_at(mount)
                if still_mounted:
                    checked_run(["hdiutil", "detach", str(mount)], timeout=120)
                if mounted_at(mount):
                    cleanup_errors.append("candidate DMG remains mounted at " + str(mount))
                else:
                    mounted = False
                    mount_attempted = False
            except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                cleanup_errors.append("could not verify or detach candidate DMG: " + str(error))
        if not cleanup_active_process_groups():
            cleanup_errors.append("task-owned process groups remain: " +
                                  ",".join(map(str, sorted(ACTIVE_PROCESS_GROUPS))))
        if scratch.exists():
            if scratch.resolve().parent != ROOT:
                fail("refusing to remove package scratch outside project root")
            if not completed:
                evidence = ROOT / "evidence"
                evidence.mkdir(exist_ok=True)
                for log in (build_log, smoke_log):
                    if log.is_file():
                        destination = evidence / ("PackageCandidate-" + run_id + "-" + log.name)
                        if not destination.exists():
                            text = log.read_text(encoding="utf-8", errors="replace")
                            text = text.replace(str(ROOT), "<Reference_manager>").replace(str(scratch), "<package-scratch>")
                            destination.write_text(text, encoding="utf-8")
            if cleanup_errors:
                print("package cleanup incomplete; retained scratch=" + str(scratch), file=sys.stderr)
                for error in cleanup_errors:
                    print("package cleanup issue=" + error, file=sys.stderr)
            else:
                shutil.rmtree(scratch)
        if cleanup_errors:
            raise RuntimeError("package cleanup incomplete: " + "; ".join(cleanup_errors))


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print("package candidate failed: " + str(error), file=sys.stderr)
        raise SystemExit(1)
