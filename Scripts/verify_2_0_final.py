#!/usr/bin/env python3
"""Fail-closed, project-local LatticeLens 2.0 verification receipt generator."""

import argparse
import datetime
import hashlib
import json
import math
import os
import plistlib
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path, PurePosixPath


ROOT = Path(__file__).resolve().parent.parent
REPORT_PATH = ROOT / "evidence" / "Validation-2.0-final-local.json"
SUMMARY_PATH = ROOT / "VALIDATION_2.0_FINAL.md"
MANUAL_ACCEPTANCE_PATH = ROOT / "evidence" / "ManualAcceptance-2.0-final-local.json"
XCODE_PROJECT = "LatticeLens.xcodeproj"
SKIP_ALLOWLIST = {
    "testOptInLiveInspireFreshPersistentStoreLoadsPinnedAuthorAndPapers":
        "Live INSPIRE is optional and was not enabled.",
    "testActualSwiftDataLargeStoreBenchmark":
        "The benchmark is a separate mandatory performance gate, not a unit-test pass.",
    "testActualSwiftDataV12FormulaStoreBenchmark":
        "The V12 disk benchmark is run as a separate mandatory performance stage.",
    "testAuthorizedDisposableV7MigrationDrill":
        "This legacy-store drill requires an explicitly authorized disposable path.",
    "testAuthorizedDisposableV10ToV12MigrationDrill":
        "The V10-to-V12 reconciliation/rollback drill is run as its own manifest-bound mandatory stage.",
    "testV10MigrationPhysicalDiskExhaustionOnDisposableImage":
        "The bounded HFS+ physical-disk drill is run as a separate project-local stage.",
}
V10_MIGRATION_DRILL_TEST = "V4LocalTests/testAuthorizedDisposableV10ToV12MigrationDrill"
CURRENT_CANONICAL_LIBRARY_HASH_FORMAT_VERSION = 3
G02_PHYSICAL_DISK_TEST = "testV10MigrationPhysicalDiskExhaustionOnDisposableImage"
G02_OLD_APP_FIXTURE_TEST = "testDefaultFactoryMigratesV9ThroughStagingToV12AndPreservesSourceFamily"
G02_OLD_APP_DRILL_SCRIPT = "Scripts/g02_old_app_rollback_drill.py"
G02_OLD_APP_SOURCE_INPUTS = (
    G02_OLD_APP_DRILL_SCRIPT,
    "Scripts/verify_2_0_final.py",
    "Tests/LatticeLensTests/Support/TestSupport.swift",
    "Tests/LatticeLensTests/V4LocalTests.swift",
    "Sources/LatticeLens/Core/Persistence/SwiftDataLibraryStore.swift",
    "Sources/LatticeLens/Core/Persistence/V4NormalizedStore.swift",
)
G10_RETAINED_PATHS = (
    "Sources", "Tests", "Scripts", "Assets", "Assets.xcassets",
    "LatticeLens.xcodeproj", "Package.swift", "DisposableMigrationV7Source",
    "Tests/LatticeLensTests/Fixtures", "AppIcon-master.svg", "AppIcon-contact-sheet.png",
    "INSPIRE文献管理器_开工方案_v1.md", "INSPIRE文献管理器_开工方案_v2.md",
    "INSPIRE文献管理器_开工方案_v3.md", "INSPIRE文献管理器_开工方案_v4.md",
    "INSPIRE文献管理器_开工方案_v5.md", "INSPIRE文献管理器2.0_開工方案_v5.md",
    "INSPIRE文獻管理器2.0_開工方案_final.md", "README.md", "CHANGELOG.md",
    "VALIDATION_2.0.md", "VALIDATION_2.0_FINAL.md",
)
G10_PACKAGE_CHECKS = (
    "dmg_verify", "readonly_mount", "mounted_signature",
    "isolated_install_executable_hash_match", "fixture_no_network_launch_smoke",
    "system_temporary_write_denied",
)
G09_COMPLETION_CHECKS = G10_PACKAGE_CHECKS + (
    "full_user_workflow", "app_data_rollback",
)
G09_ACCEPTANCE_RECEIPT_SCHEMA = "latticelens-g09-candidate-acceptance-v1"
PACKAGE_MANIFEST_V2_0 = "latticelens-package-manifest-v2.0-local-candidate"
PACKAGE_MANIFEST_V2_1 = "latticelens-package-manifest-v2.1-local-candidate"
PACKAGE_MANIFEST_SCHEMAS = frozenset({PACKAGE_MANIFEST_V2_0, PACKAGE_MANIFEST_V2_1})
PACKAGE_RELOCATION_INDEX_SCHEMA = "latticelens-package-relocation-index-v1"
PACKAGE_RELOCATION_ROLES = frozenset({
    "validation_report", "validation_summary", "input_manifest", "performance", "migration",
    "historical_context",
})
G10_HISTORICAL_CONTEXT_PATHS = frozenset({
    "evidence/Continuation-20261003-F05-DerivationChain.md",
    "evidence/Continuation-20261003-G08-V11FormulaPerformance.md",
})
G09_ACCEPTANCE_STEPS = {
    "full_user_workflow": frozenset({
        "offline_browse", "local_search", "cached_chinese_insight",
        "cached_numbered_formula", "cached_pdf", "note_persistence",
        "compare", "bundle_round_trip", "quit_relaunch",
    }),
    "app_data_rollback": frozenset({
        "verified_preupgrade_backup", "new_app_data_state", "restore_preupgrade_backup",
        "previous_app_launch", "semantic_reconciliation",
    }),
}
G10_BUILD_INPUT_PREFIXES = (
    "Sources/", "Tests/", "Scripts/", "Assets/", "Assets.xcassets/",
    "LatticeLens.xcodeproj/",
)
G10_BUILD_INPUT_ROOT_FILES = {
    "Package.swift", "README.md", "CHANGELOG.md", "VALIDATION_2.0.md",
    "VALIDATION_2.0_FINAL.md",
    "CleanupManifest-2.0.json", "CleanupManifest-2.0-final.json",
    "INSPIRE文献管理器2.0_開工方案_v5.md",
    "INSPIRE文獻管理器2.0_開工方案_final.md",
}


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _safe_relative_path(value):
    if not isinstance(value, str) or not value or "\\" in value:
        return None
    relative = PurePosixPath(value)
    if relative.is_absolute() or any(part in ("", ".", "..") for part in relative.parts):
        return None
    return relative


def canonical_input_entries(entries):
    if not isinstance(entries, list):
        raise ValueError("input manifest files must be an array")
    normalized = []
    for entry in entries:
        if not isinstance(entry, dict):
            raise ValueError("input manifest contains a non-object file entry")
        raw_path = entry.get("path")
        relative = _safe_relative_path(raw_path)
        kind = entry.get("kind")
        digest = entry.get("sha256")
        if (relative is None or str(relative) != raw_path or kind not in ("file", "symlink") or
                not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest)):
            raise ValueError("input manifest contains an unsafe or malformed file entry")
        item = {"path": str(relative), "kind": kind, "sha256": digest}
        if kind == "file":
            size = entry.get("bytes")
            if isinstance(size, bool) or not isinstance(size, int) or size < 0:
                raise ValueError("input manifest file entry has no byte count")
            item["bytes"] = size
        else:
            target = entry.get("target")
            if not isinstance(target, str):
                raise ValueError("input manifest symlink entry has no target")
            if sha256_bytes(target.encode("utf-8")) != digest:
                raise ValueError("input manifest symlink target hash is inconsistent")
            item["target"] = target
        normalized.append(item)
    normalized.sort(key=lambda item: item["path"])
    if len({item["path"] for item in normalized}) != len(normalized):
        raise ValueError("input manifest contains duplicate paths")
    return normalized


def input_entries_sha256(entries):
    canonical = canonical_input_entries(entries)
    payload = json.dumps(canonical, ensure_ascii=False, sort_keys=True,
                         separators=(",", ":")).encode("utf-8")
    return sha256_bytes(payload)


def _is_release_build_source(relative_path):
    return (relative_path in G10_BUILD_INPUT_ROOT_FILES or
            any(relative_path.startswith(prefix) for prefix in G10_BUILD_INPUT_PREFIXES))


def build_input_source_entries(root=ROOT):
    """Recompute the packager's source-only manifest, excluding run-specific receipts."""
    root = Path(root).resolve()
    source_paths = set()
    errors = []
    for prefix in G10_BUILD_INPUT_PREFIXES:
        base = root / prefix.rstrip("/")
        if base.is_symlink():
            errors.append("Release build input root is symlinked: " + prefix.rstrip("/"))
            continue
        if not base.exists():
            continue
        if not base.is_dir():
            errors.append("Release build input root is not a directory: " + prefix.rstrip("/"))
            continue
        for current, directories, files in os.walk(str(base), topdown=True, followlinks=False):
            current_path = Path(current)
            directories.sort()
            files.sort()
            for name in list(directories):
                candidate = current_path / name
                if candidate.is_symlink():
                    source_paths.add(candidate)
                    directories.remove(name)
            source_paths.update(current_path / name for name in files)

    for relative in G10_BUILD_INPUT_ROOT_FILES:
        path = root / relative
        if path.is_file() or path.is_symlink():
            source_paths.add(path)
        elif path.exists():
            errors.append("Release build root input is not a regular file: " + relative)

    entries = []
    for path in sorted(source_paths, key=lambda item: item.relative_to(root).as_posix()):
        relative = path.relative_to(root).as_posix()
        try:
            if path.is_symlink():
                resolved = path.resolve(strict=True)
                if not resolved.is_relative_to(root):
                    errors.append("Release build input symlink escapes the project: " + relative)
                    continue
                target = os.readlink(str(path))
                entries.append({"path": relative, "kind": "symlink", "target": target,
                                "sha256": sha256_bytes(target.encode("utf-8"))})
            elif path.is_file():
                entries.append({"path": relative, "kind": "file", "bytes": path.stat().st_size,
                                "sha256": sha256_file(path)})
            else:
                errors.append("Release build input is not a regular file: " + relative)
        except OSError as error:
            errors.append("Release build input could not be read: " + relative + ": " + str(error))
    return entries, errors


def _path_has_symlink_component(path, root):
    try:
        relative = Path(path).relative_to(Path(root))
    except ValueError:
        return True
    current = Path(root)
    if current.is_symlink():
        return True
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            return True
    return False


def verify_frozen_inputs(entries, root=ROOT):
    """Re-hash the exact frozen source set after tests and cleanup."""
    root = Path(root).resolve()
    errors = []
    for entry in entries:
        relative = _safe_relative_path(entry.get("path")) if isinstance(entry, dict) else None
        if relative is None:
            errors.append("Frozen input has an unsafe project-relative path.")
            continue
        path = root / Path(*relative.parts)
        parent_has_symlink = _path_has_symlink_component(path.parent, root)
        if not path.is_relative_to(root) or parent_has_symlink:
            errors.append("Frozen input path escaped through a symlink: " + str(relative))
            continue
        try:
            if entry.get("kind") == "symlink":
                if (not path.is_symlink() or
                        not path.resolve(strict=True).is_relative_to(root) or
                        os.readlink(str(path)) != entry.get("target")):
                    errors.append("Frozen input symlink changed: " + str(relative))
                elif sha256_bytes(os.readlink(str(path)).encode("utf-8")) != entry.get("sha256"):
                    errors.append("Frozen input symlink hash changed: " + str(relative))
            elif entry.get("kind") == "file":
                if path.is_symlink() or not path.is_file():
                    errors.append("Frozen input file is missing or changed type: " + str(relative))
                elif (path.stat().st_size != entry.get("bytes") or
                      sha256_file(path) != entry.get("sha256")):
                    errors.append("Frozen input file bytes or hash changed: " + str(relative))
            else:
                errors.append("Frozen input has an unknown file kind: " + str(relative))
        except OSError as error:
            errors.append("Frozen input could not be re-read: " + str(relative) + ": " + str(error))
    return errors


def cleanup_directory_metadata(path, root=ROOT):
    """Capture a non-following metadata identity for one exact project-local scratch tree."""
    path = Path(path)
    root = Path(root).resolve()
    if path.is_symlink() or not path.is_dir():
        raise RuntimeError("cleanup target must be an existing non-symlink directory")
    resolved = path.resolve(strict=True)
    if (not resolved.is_relative_to(root) or resolved.parent != root or
            not path.name.startswith(".codex-task-audit-2-final.")):
        raise RuntimeError("cleanup target is not the verifier-owned project-local scratch")

    records = []
    logical_bytes = 0
    file_count = 0
    directory_count = 0
    symlink_count = 0
    links_confined = True
    for current, directories, files in os.walk(str(path), topdown=True, followlinks=False):
        current_path = Path(current)
        directories.sort()
        files.sort()
        names = sorted(directories) + sorted(files)
        for name in names:
            item = current_path / name
            info = item.lstat()
            relative = item.relative_to(path).as_posix()
            if stat.S_ISLNK(info.st_mode):
                kind = "symlink"
                symlink_count += 1
                target = os.readlink(str(item))
                resolved_target = (item.parent / target).resolve(strict=False)
                if not resolved_target.is_relative_to(resolved):
                    links_confined = False
            elif stat.S_ISDIR(info.st_mode):
                kind = "directory"
                directory_count += 1
                target = None
            elif stat.S_ISREG(info.st_mode):
                kind = "file"
                file_count += 1
                logical_bytes += info.st_size
                target = None
            else:
                kind = "other"
                target = None
            records.append({"path": relative, "kind": kind, "bytes": info.st_size,
                            "mode": stat.S_IMODE(info.st_mode), "mtime_ns": info.st_mtime_ns,
                            "link_target": target})
        directories[:] = [name for name in directories
                          if not (current_path / name).is_symlink()]

    payload = json.dumps(records, ensure_ascii=False, sort_keys=True,
                         separators=(",", ":")).encode("utf-8")
    return {
        "path": path.relative_to(root).as_posix(),
        "canonical_path_verified": True,
        "directory_symlink": False,
        "logical_bytes": logical_bytes,
        "file_count": file_count,
        "subdirectory_count": directory_count,
        "symlink_count": symlink_count,
        "metadata_tree_sha256": sha256_bytes(payload),
        "symlink_targets_confined_to_scratch": links_confined,
    }


def apply_exact_cleanup_target(target_record, expected_path, remaining_process_count, root=ROOT):
    """Apply only the unchanged, exact scratch target recorded in the current run manifest."""
    root = Path(root).resolve()
    relative = _safe_relative_path(target_record.get("path"))
    if relative is None or str(relative) != str(expected_path):
        raise RuntimeError("cleanup manifest target does not match this run's exact scratch path")
    path = root / Path(*relative.parts)
    if (path.is_symlink() or not path.is_dir() or
            not path.resolve(strict=True).is_relative_to(root) or
            path.resolve(strict=True).parent != root or
            not path.name.startswith(".codex-task-audit-2-final.")):
        raise RuntimeError("cleanup manifest target is not the verifier-owned project-local scratch")
    if remaining_process_count or target_record.get("open_process_count") != 0:
        raise RuntimeError("cleanup target still has verifier-owned processes")
    if target_record.get("symlink_targets_confined_to_scratch") is not True:
        raise RuntimeError("cleanup scratch contains a symlink escaping its exact directory")
    current = cleanup_directory_metadata(path, root)
    identity_keys = ("path", "logical_bytes", "file_count", "subdirectory_count",
                     "symlink_count", "metadata_tree_sha256")
    if any(current.get(key) != target_record.get(key) for key in identity_keys):
        raise RuntimeError("cleanup target changed after its manifest preflight")
    shutil.rmtree(str(path))
    if path.exists() or path.is_symlink():
        raise RuntimeError("cleanup target remains after exact-path removal")
    return True


def _read_project_json(root, relative_value, description, errors):
    relative = _safe_relative_path(relative_value)
    if relative is None:
        errors.append(description + " path is not a safe project-relative path.")
        return None, None
    path = Path(root) / Path(*relative.parts)
    if (not path.is_relative_to(Path(root)) or _path_has_symlink_component(path, root) or
            not path.is_file()):
        errors.append(description + " is missing, symlinked, or outside the project.")
        return None, None
    try:
        return json.loads(path.read_text(encoding="utf-8")), sha256_file(path)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        errors.append(description + " is unreadable: " + str(error))
        return None, None


def _read_package_file(package_directory, relative_value, description, errors,
                       listed=None, expected_sha256=None):
    """Read only a canonical regular file contained in this package directory."""
    relative = _safe_relative_path(relative_value)
    if relative is None:
        errors.append(description + " path is not a safe package-relative path.")
        return None, None
    package = Path(package_directory).resolve(strict=True)
    path = package.joinpath(*relative.parts)
    try:
        resolved = path.resolve(strict=True)
        mode = path.lstat().st_mode
    except (OSError, RuntimeError, ValueError) as error:
        errors.append(description + " is missing or cannot be resolved: " + str(error))
        return None, None
    if (not resolved.is_relative_to(package) or stat.S_ISLNK(mode) or
            not stat.S_ISREG(mode) or _path_has_symlink_component(path, package)):
        errors.append(description + " is symlinked, non-regular, or outside the package.")
        return None, None
    digest = sha256_file(path)
    if expected_sha256 is not None and (
            not isinstance(expected_sha256, str) or
            not re.fullmatch(r"[0-9a-f]{64}", expected_sha256) or
            digest != expected_sha256):
        errors.append(description + " hash mismatch.")
    if listed is not None and listed.get(str(relative)) != digest:
        errors.append(description + " is not covered by the package checksum manifest.")
    return path, digest


def _read_package_json(package_directory, relative_value, description, errors,
                       listed=None, expected_sha256=None):
    path, digest = _read_package_file(
        package_directory, relative_value, description, errors, listed, expected_sha256)
    if path is None:
        return None, None
    try:
        return json.loads(path.read_text(encoding="utf-8")), digest
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        errors.append(description + " is unreadable: " + str(error))
        return None, digest


def _legacy_package_reference(package_directory, source_path, description,
                              errors, listed, expected_sha256):
    """Resolve only the documented v2.0 compact-validation basename layout."""
    source = _safe_relative_path(source_path)
    if source is None or not source.parts or source.parts[0] != "evidence":
        errors.append(description + " legacy source path is not a canonical evidence/ path.")
        return None, None
    packaged = PurePosixPath("compact-validation") / source.name
    path, digest = _read_package_file(
        package_directory, packaged.as_posix(), description, errors,
        listed=listed, expected_sha256=expected_sha256)
    return (path, digest, source.as_posix(), packaged.as_posix()) if path else (None, None, None, None)


def _load_package_relocation_index(validation, manifest, package_directory,
                                   listed, errors):
    """Validate explicit source-to-package mappings for v2.1 candidates."""
    if manifest.get("schema_version") == PACKAGE_MANIFEST_V2_0:
        return None, {}, []
    if (manifest.get("schema_version") != PACKAGE_MANIFEST_V2_1 or
            validation.get("path_base") != "package-relative-v1"):
        errors.append("Candidate validation references have an unsupported path base or schema.")
        return None, {}, []

    index_record = validation.get("relocation_index")
    if not isinstance(index_record, dict):
        errors.append("Candidate relocation index record is missing or malformed.")
        return None, {}, []
    index, index_hash = _read_package_json(
        package_directory, index_record.get("path"), "Candidate relocation index",
        errors, listed=listed, expected_sha256=index_record.get("sha256"))
    if not isinstance(index, dict):
        return None, {}, []
    if index.get("schema_version") != PACKAGE_RELOCATION_INDEX_SCHEMA:
        errors.append("Candidate relocation index has an unexpected schema.")
    if index.get("package_run_id") != manifest.get("run_id"):
        errors.append("Candidate relocation index belongs to a different package run.")
    records = index.get("files")
    if not isinstance(records, list):
        errors.append("Candidate relocation index files must be an array.")
        return index, {}, []

    by_role = {}
    seen_sources = set()
    seen_package_paths = set()
    history = []
    for item in records:
        if not isinstance(item, dict):
            errors.append("Candidate relocation index contains a malformed file record.")
            continue
        role = item.get("role")
        source = _safe_relative_path(item.get("source_path"))
        packaged = _safe_relative_path(item.get("package_path"))
        digest = item.get("sha256")
        if (role not in PACKAGE_RELOCATION_ROLES or source is None or packaged is None or
                not str(packaged).startswith("compact-validation/") or
                not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest)):
            errors.append("Candidate relocation index contains an unsafe or malformed path/hash record.")
            continue
        source_text, packaged_text = str(source), str(packaged)
        if source_text in seen_sources or packaged_text in seen_package_paths:
            errors.append("Candidate relocation index contains a duplicate source or package path.")
            continue
        seen_sources.add(source_text)
        seen_package_paths.add(packaged_text)
        _read_package_file(package_directory, packaged_text,
                           "Candidate relocated " + role, errors,
                           listed=listed, expected_sha256=digest)
        normalized = {"role": role, "source_path": source_text,
                      "package_path": packaged_text, "sha256": digest}
        if role == "historical_context":
            if source_text not in G10_HISTORICAL_CONTEXT_PATHS:
                errors.append("Candidate relocation index contains an unrecognized historical source path.")
            history.append(normalized)
        elif role in by_role:
            errors.append("Candidate relocation index repeats required role " + role + ".")
        else:
            by_role[role] = normalized

    required_roles = {"validation_report", "validation_summary", "input_manifest",
                      "performance", "migration"}
    missing_roles = sorted(required_roles - set(by_role))
    if missing_roles:
        errors.append("Candidate relocation index omits required roles: " + ", ".join(missing_roles) + ".")
    return index, by_role, history


def validate_g09_acceptance_receipts(manifest, candidate_directory, listed,
                                     input_manifest_binding):
    """Require checksum-bound, candidate-bound evidence before G09 completion can PASS."""
    errors = []
    checks = manifest.get("checks") if isinstance(manifest.get("checks"), dict) else {}
    receipts = manifest.get("acceptance_receipts")
    if receipts is None:
        receipts = {}
    if not isinstance(receipts, dict):
        return ["Candidate acceptance_receipts must be an object."]

    artifacts = manifest.get("artifacts") if isinstance(manifest.get("artifacts"), dict) else {}
    dmg = artifacts.get("dmg") if isinstance(artifacts.get("dmg"), dict) else {}
    app = manifest.get("app") if isinstance(manifest.get("app"), dict) else {}
    expected_candidate = {
        "run_id": manifest.get("run_id"),
        "input_manifest_sha256": input_manifest_binding,
        "dmg_sha256": dmg.get("sha256"),
        "executable_sha256": app.get("executable_sha256"),
    }

    for check_name, required_steps in G09_ACCEPTANCE_STEPS.items():
        status = checks.get(check_name)
        binding = receipts.get(check_name)
        if status != "PASS":
            if binding is not None:
                errors.append("Candidate " + check_name + " has a receipt but is not marked PASS.")
            continue
        if not isinstance(binding, dict):
            errors.append("Candidate " + check_name + " is PASS without a bound acceptance receipt.")
            continue

        receipt_relative = _safe_relative_path(binding.get("file"))
        if receipt_relative is None:
            errors.append("Candidate " + check_name + " receipt path is unsafe.")
            continue
        receipt_path = candidate_directory / Path(*receipt_relative.parts)
        receipt_digest = binding.get("sha256")
        if (not receipt_path.is_relative_to(candidate_directory) or
                _path_has_symlink_component(receipt_path, candidate_directory) or
                not receipt_path.is_file()):
            errors.append("Candidate " + check_name + " receipt is missing, symlinked, or outside the package.")
            continue
        actual_receipt_digest = sha256_file(receipt_path)
        if (not isinstance(receipt_digest, str) or
                not re.fullmatch(r"[0-9a-f]{64}", receipt_digest) or
                actual_receipt_digest != receipt_digest or
                listed.get(str(receipt_relative)) != actual_receipt_digest):
            errors.append("Candidate " + check_name + " receipt hash is missing or not covered by SHA256SUMS.txt.")
            continue
        try:
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            errors.append("Candidate " + check_name + " receipt is unreadable: " + str(error))
            continue

        if not isinstance(receipt, dict):
            errors.append("Candidate " + check_name + " receipt is not an object.")
            continue
        if (receipt.get("schema_version") != G09_ACCEPTANCE_RECEIPT_SCHEMA or
                receipt.get("check") != check_name or receipt.get("status") != "PASS"):
            errors.append("Candidate " + check_name + " receipt schema, check, or status is invalid.")
        if receipt.get("candidate") != expected_candidate:
            errors.append("Candidate " + check_name + " receipt is not bound to this exact app, DMG, and input manifest.")
        if not isinstance(receipt.get("scope"), str) or not receipt.get("scope", "").strip():
            errors.append("Candidate " + check_name + " receipt has no acceptance scope.")
        completed_at = receipt.get("completed_at_utc")
        try:
            if not isinstance(completed_at, str) or not completed_at.strip():
                raise ValueError("timestamp is empty")
            datetime.datetime.fromisoformat(completed_at.replace("Z", "+00:00"))
        except ValueError:
            errors.append("Candidate " + check_name + " receipt timestamp is not ISO-8601.")

        steps = receipt.get("steps")
        if not isinstance(steps, list):
            errors.append("Candidate " + check_name + " receipt steps must be an array.")
            continue
        observed_steps = set()
        for step in steps:
            if not isinstance(step, dict):
                errors.append("Candidate " + check_name + " receipt contains a malformed step.")
                continue
            step_id = step.get("id")
            if not isinstance(step_id, str) or not step_id.strip() or step_id in observed_steps:
                errors.append("Candidate " + check_name + " receipt step IDs must be non-empty and unique.")
                continue
            observed_steps.add(step_id)
            if step.get("status") != "PASS":
                errors.append("Candidate " + check_name + " receipt step is not PASS: " + step_id)
            evidence = step.get("evidence")
            if not isinstance(evidence, dict):
                errors.append("Candidate " + check_name + " receipt step has no hash-bound evidence: " + step_id)
                continue
            evidence_relative = _safe_relative_path(evidence.get("file"))
            if evidence_relative is None:
                errors.append("Candidate " + check_name + " evidence path is unsafe: " + step_id)
                continue
            evidence_path = candidate_directory / Path(*evidence_relative.parts)
            if (not evidence_path.is_relative_to(candidate_directory) or
                    _path_has_symlink_component(evidence_path, candidate_directory) or
                    not evidence_path.is_file()):
                errors.append("Candidate " + check_name + " evidence is missing, symlinked, or outside the package: " + step_id)
                continue
            actual_evidence_digest = sha256_file(evidence_path)
            if (evidence.get("sha256") != actual_evidence_digest or
                    listed.get(str(evidence_relative)) != actual_evidence_digest):
                errors.append("Candidate " + check_name + " evidence hash is invalid or not covered by SHA256SUMS.txt: " + step_id)
        missing_steps = sorted(required_steps - observed_steps)
        if missing_steps:
            errors.append("Candidate " + check_name + " receipt omits required steps: " + ", ".join(missing_steps) + ".")
    return errors


def candidate_package_snapshot(expected_input_manifest_sha256, expected_input_entries,
                              root=ROOT, manifest_path_override=None):
    """Validate one explicit manifest or discover the newest manifest timestamp, never mtime."""
    root = Path(root).resolve()
    release_root = root / "release-assets"
    errors = []
    if release_root.is_symlink() or not release_root.is_dir():
        return None, []

    manifest_paths = []
    selection_method = "generated_at_utc"
    if manifest_path_override is not None:
        relative = _safe_relative_path(manifest_path_override)
        if (relative is None or not relative.parts or relative.parts[0] != "release-assets" or
                relative.name != "manifest-v2.0-local-candidate.json"):
            return None, ["Explicit candidate manifest must be a safe release-assets-relative manifest path."]
        selected = root.joinpath(*relative.parts)
        if (not selected.is_relative_to(release_root) or
                _path_has_symlink_component(selected, root) or
                not selected.is_file()):
            return None, ["Explicit candidate manifest is missing, symlinked, or outside release-assets/."]
        manifest_paths = [selected]
        selection_method = "explicit_manifest"
    else:
        for directory in release_root.iterdir():
            if directory.is_symlink():
                if directory.name.startswith("Release-2.0.0-"):
                    errors.append("A named 2.0 release directory is symlinked: " + directory.name)
                continue
            if not directory.is_dir():
                continue
            selected = directory / "manifest-v2.0-local-candidate.json"
            if selected.is_symlink():
                errors.append("A 2.0 package manifest is symlinked: " + selected.relative_to(root).as_posix())
            elif selected.is_file():
                manifest_paths.append(selected)

    candidates = []
    for selected in manifest_paths:
        directory = selected.parent
        if directory.is_symlink() or not directory.is_dir():
            errors.append("A 2.0 release package is not a real directory: " + directory.name)
            continue
        try:
            value = json.loads(selected.read_text(encoding="utf-8"))
            generated = datetime.datetime.fromisoformat(value["generated_at_utc"].replace("Z", "+00:00"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
            errors.append("A 2.0 package has an invalid manifest: " + directory.name + ": " + str(error))
            continue
        if generated.tzinfo is None:
            errors.append("A 2.0 package manifest timestamp must include a timezone: " + directory.name)
            continue
        if value.get("schema_version") not in PACKAGE_MANIFEST_SCHEMAS:
            errors.append("A 2.0 package has an unsupported manifest schema: " + directory.name)
            continue
        candidates.append((generated, str(value.get("run_id") or ""),
                           selected.relative_to(root).as_posix(), directory, value))

    if not candidates:
        return None, errors

    _, _, _, directory, manifest = max(candidates, key=lambda item: (item[0], item[1], item[2]))
    package_errors = []
    manifest_path = directory / "manifest-v2.0-local-candidate.json"
    sums_path = directory / "SHA256SUMS.txt"
    if sums_path.is_symlink() or not sums_path.is_file():
        package_errors.append("Candidate SHA256SUMS.txt is missing or symlinked.")
        sums_text = ""
    else:
        try:
            sums_text = sums_path.read_text(encoding="utf-8", errors="strict")
        except (OSError, UnicodeDecodeError) as error:
            package_errors.append("Candidate SHA256SUMS.txt is unreadable: " + str(error))
            sums_text = ""

    listed = {}
    for line_number, line in enumerate(sums_text.splitlines(), 1):
        fields = line.split(maxsplit=1)
        if len(fields) != 2 or not re.fullmatch(r"[0-9a-f]{64}", fields[0]):
            package_errors.append("Candidate checksum line " + str(line_number) + " is malformed.")
            continue
        relative = _safe_relative_path(fields[1].lstrip("*"))
        if relative is None or str(relative) in listed:
            package_errors.append("Candidate checksum path is unsafe or duplicated on line " + str(line_number) + ".")
            continue
        file_path = directory / Path(*relative.parts)
        if (not file_path.is_relative_to(directory) or _path_has_symlink_component(file_path, directory) or
                not file_path.is_file()):
            package_errors.append("Candidate checksum target is missing or symlinked: " + str(relative))
            continue
        actual = sha256_file(file_path)
        if actual != fields[0]:
            package_errors.append("Candidate checksum mismatch: " + str(relative))
        listed[str(relative)] = actual

    for package_path in directory.rglob("*"):
        if package_path == sums_path:
            continue
        if package_path.is_symlink():
            package_errors.append("Candidate package contains an untrusted symbolic link: " +
                                  package_path.relative_to(directory).as_posix())
        elif package_path.is_file() and package_path.relative_to(directory).as_posix() not in listed:
            package_errors.append("Candidate package contains a file omitted from SHA256SUMS.txt: " +
                                  package_path.relative_to(directory).as_posix())

    artifacts = manifest.get("artifacts") if isinstance(manifest.get("artifacts"), dict) else {}
    required_paths = {"manifest-v2.0-local-candidate.json", "build-inputs-v2.0.json"}
    for artifact_name in ("dmg", "dsym"):
        artifact = artifacts.get(artifact_name)
        if not isinstance(artifact, dict):
            package_errors.append("Candidate manifest is missing its " + artifact_name + " artifact record.")
            continue
        relative = _safe_relative_path(artifact.get("file"))
        if relative is None or len(relative.parts) != 1:
            package_errors.append("Candidate " + artifact_name + " filename is unsafe.")
            continue
        required_paths.add(str(relative))
        actual = listed.get(str(relative))
        if actual is None or actual != artifact.get("sha256"):
            package_errors.append("Candidate " + artifact_name + " hash does not match its package manifest.")

    package_manifest_hash = sha256_file(manifest_path)
    if listed.get("manifest-v2.0-local-candidate.json") != package_manifest_hash:
        package_errors.append("Candidate package manifest is not covered by SHA256SUMS.txt.")
    build_input = manifest.get("build_input_manifest")
    build_input_value = None
    if not isinstance(build_input, dict) or build_input.get("file") != "build-inputs-v2.0.json":
        package_errors.append("Candidate build-input manifest record is missing or malformed.")
        input_manifest_binding = None
    else:
        input_manifest_binding = build_input.get("input_verifier_manifest_sha256")
        if listed.get("build-inputs-v2.0.json") != build_input.get("sha256"):
            package_errors.append("Candidate build-input manifest hash mismatch.")
        build_input_path = directory / "build-inputs-v2.0.json"
        if (build_input_path.is_symlink() or not build_input_path.is_file() or
                _path_has_symlink_component(build_input_path, directory)):
            package_errors.append("Candidate build-input manifest is missing, symlinked, or unsafe.")
        else:
            try:
                build_input_value = json.loads(build_input_path.read_text(encoding="utf-8"))
            except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
                package_errors.append("Candidate build-input manifest is unreadable: " + str(error))
            if (not isinstance(build_input_value, dict) or
                    build_input_value.get("schema_version") != "latticelens-build-input-manifest-v2.0"):
                package_errors.append("Candidate build-input manifest has an unexpected schema.")
            elif build_input_value.get("run_id") != manifest.get("run_id"):
                package_errors.append("Candidate build-input manifest belongs to a different package run.")

    if not required_paths.issubset(set(listed)):
        package_errors.append("Candidate checksum manifest omits a required release artifact.")

    validation = manifest.get("validation") if isinstance(manifest.get("validation"), dict) else {}
    manifest_schema = manifest.get("schema_version")
    relocation_index, relocation_by_role, history_relocations = _load_package_relocation_index(
        validation, manifest, directory, listed, package_errors)

    if manifest_schema == PACKAGE_MANIFEST_V2_1:
        report_record = relocation_by_role.get("validation_report")
        if (not isinstance(validation.get("report"), str) or not report_record or
                validation.get("report") != report_record.get("package_path") or
                validation.get("report_sha256") != report_record.get("sha256")):
            package_errors.append("Candidate validation report does not match its relocation-index entry.")
            report_path_value = validation.get("report")
        else:
            report_path_value = report_record["package_path"]
        report_value, report_hash = _read_package_json(
            directory, report_path_value, "Candidate validation report", package_errors,
            listed=listed, expected_sha256=validation.get("report_sha256"))
        report_source_path = report_record.get("source_path") if report_record else None
    else:
        report_path_value = validation.get("report")
        report_path, report_hash, report_source_path, report_package_path = _legacy_package_reference(
            directory, report_path_value, "Candidate validation report", package_errors,
            listed, validation.get("report_sha256"))
        report_value = None
        if report_path is not None:
            try:
                report_value = json.loads(report_path.read_text(encoding="utf-8"))
            except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
                package_errors.append("Candidate validation report is unreadable: " + str(error))
        report_record = {"role": "validation_report", "source_path": report_source_path,
                         "package_path": report_package_path, "sha256": report_hash}

    if (not isinstance(report_value, dict) or
            report_value.get("schema_version") != "latticelens-verify-2.0-final-local"):
        package_errors.append("Candidate validation report has an unexpected schema.")
    elif report_value.get("input_manifest_sha256") != input_manifest_binding:
        package_errors.append("Candidate validation report and build-input manifest disagree.")
    if (isinstance(report_value, dict) and report_record and
            report_record.get("source_path") != report_value.get("report_path")):
        package_errors.append("Candidate validation report source path disagrees with its relocation record.")

    candidate_input_manifest = None
    candidate_input_manifest_hash = None
    candidate_input_entries = None
    validation_reference_records = {"validation_report": report_record}
    if isinstance(report_value, dict):
        input_source_path = report_value.get("input_manifest_path")
        if manifest_schema == PACKAGE_MANIFEST_V2_1:
            input_record = relocation_by_role.get("input_manifest")
            input_manifest_entry = validation.get("input_manifest")
            if (not isinstance(input_manifest_entry, dict) or not input_record or
                    input_manifest_entry.get("path") != input_record.get("package_path") or
                    input_manifest_entry.get("source_path") != input_record.get("source_path") or
                    input_manifest_entry.get("sha256") != input_record.get("sha256") or
                    input_source_path != input_record.get("source_path")):
                package_errors.append("Candidate frozen input manifest does not match its relocation-index entry.")
                input_package_path = input_manifest_entry.get("path") if isinstance(input_manifest_entry, dict) else None
            else:
                input_package_path = input_record["package_path"]
            input_manifest_value, candidate_input_manifest_hash = _read_package_json(
                directory, input_package_path, "Candidate frozen input manifest", package_errors,
                listed=listed, expected_sha256=input_record.get("sha256") if input_record else None)
            validation_reference_records["input_manifest"] = input_record
        else:
            input_manifest_hash = report_value.get("input_manifest_sha256")
            input_path, candidate_input_manifest_hash, input_source_path, input_package_path = _legacy_package_reference(
                directory, input_source_path, "Candidate frozen input manifest", package_errors,
                listed, input_manifest_hash)
            input_manifest_value = None
            if input_path is not None:
                try:
                    input_manifest_value = json.loads(input_path.read_text(encoding="utf-8"))
                except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
                    package_errors.append("Candidate frozen input manifest is unreadable: " + str(error))
            validation_reference_records["input_manifest"] = {
                "role": "input_manifest", "source_path": input_source_path,
                "package_path": input_package_path, "sha256": candidate_input_manifest_hash,
            }
        candidate_input_manifest = input_manifest_value
        if candidate_input_manifest_hash != report_value.get("input_manifest_sha256"):
            package_errors.append("Candidate validation report and frozen input manifest hash disagree.")
        if candidate_input_manifest_hash != input_manifest_binding:
            package_errors.append("Candidate frozen input manifest is not the package's verifier input.")
        if (not isinstance(input_manifest_value, dict) or
                input_manifest_value.get("schema_version") != "latticelens-input-manifest-v1"):
            package_errors.append("Candidate frozen input manifest has an unexpected schema.")
        elif input_manifest_value.get("run_id") != report_value.get("run_id"):
            package_errors.append("Candidate validation report and frozen input manifest run IDs disagree.")
        else:
            try:
                candidate_input_entries = canonical_input_entries(input_manifest_value.get("files"))
            except (TypeError, ValueError) as error:
                package_errors.append("Candidate frozen input entries are invalid: " + str(error))

        summary_source_path = report_value.get("summary_path")
        if manifest_schema == PACKAGE_MANIFEST_V2_1:
            summary_record = relocation_by_role.get("validation_summary")
            summary_entry = validation.get("summary")
            if (not isinstance(summary_entry, dict) or not summary_record or
                    summary_entry.get("path") != summary_record.get("package_path") or
                    summary_entry.get("source_path") != summary_record.get("source_path") or
                    summary_entry.get("sha256") != summary_record.get("sha256") or
                    summary_source_path != summary_record.get("source_path")):
                package_errors.append("Candidate validation summary does not match its relocation-index entry.")
                summary_package_path = summary_entry.get("path") if isinstance(summary_entry, dict) else None
            else:
                summary_package_path = summary_record["package_path"]
            _read_package_file(directory, summary_package_path, "Candidate validation summary",
                               package_errors, listed=listed,
                               expected_sha256=summary_record.get("sha256") if summary_record else None)
            validation_reference_records["validation_summary"] = summary_record
        else:
            _, summary_hash, summary_source_path, summary_package_path = _legacy_package_reference(
                directory, summary_source_path, "Candidate validation summary", package_errors,
                listed, None)
            validation_reference_records["validation_summary"] = {
                "role": "validation_summary", "source_path": summary_source_path,
                "package_path": summary_package_path, "sha256": summary_hash,
            }

    expected_entries = None
    try:
        expected_entries = canonical_input_entries(expected_input_entries)
    except (TypeError, ValueError) as error:
        package_errors.append("Current frozen input entries are invalid: " + str(error))

    candidate_input_entries_sha256 = (
        input_entries_sha256(candidate_input_entries) if candidate_input_entries is not None else None)
    expected_input_entries_sha256 = (
        input_entries_sha256(expected_entries) if expected_entries is not None else None)
    input_manifest_entries_match_current = bool(
        candidate_input_entries_sha256 and expected_input_entries_sha256 and
        candidate_input_entries_sha256 == expected_input_entries_sha256)

    candidate_build_entries = None
    candidate_build_source_entries = None
    if isinstance(build_input_value, dict):
        try:
            candidate_build_entries = canonical_input_entries(build_input_value.get("files"))
            candidate_build_source_entries = [entry for entry in candidate_build_entries
                                              if _is_release_build_source(entry["path"])]
        except (TypeError, ValueError) as error:
            package_errors.append("Candidate build-input entries are invalid: " + str(error))

    current_build_source_entries, current_build_source_errors = build_input_source_entries(root)
    package_errors.extend(current_build_source_errors)
    candidate_build_source_entries_sha256 = (
        input_entries_sha256(candidate_build_source_entries)
        if candidate_build_source_entries is not None else None)
    current_build_source_entries_sha256 = input_entries_sha256(current_build_source_entries)
    build_input_sources_match_current = bool(
        candidate_build_source_entries_sha256 and
        candidate_build_source_entries_sha256 == current_build_source_entries_sha256)

    if candidate_input_entries is not None and candidate_build_source_entries is not None:
        candidate_build_by_path = {entry["path"]: entry for entry in candidate_build_source_entries}
        for entry in candidate_input_entries:
            if _is_release_build_source(entry["path"]) and candidate_build_by_path.get(entry["path"]) != entry:
                package_errors.append(
                    "Candidate frozen inputs disagree with its package build-input entry: " + entry["path"])

    if isinstance(report_value, dict) and candidate_build_entries is not None:
        explicit_records = dict(validation_reference_records)
        for role in ("performance", "migration"):
            if manifest_schema == PACKAGE_MANIFEST_V2_1:
                explicit_records[role] = relocation_by_role.get(role)
            else:
                legacy_value = validation.get(role)
                explicit_records[role] = ({"source_path": legacy_value.get("path")}
                                          if isinstance(legacy_value, dict) else None)
        required_explicit_paths = {
            record.get("source_path") for record in explicit_records.values()
            if isinstance(record, dict) and isinstance(record.get("source_path"), str)
        }
        candidate_history_entries = [entry for entry in candidate_build_entries
                                     if entry["path"] in G10_HISTORICAL_CONTEXT_PATHS]
        candidate_explicit_entries = [entry for entry in candidate_build_entries
                                      if not _is_release_build_source(entry["path"]) and
                                      entry["path"] not in G10_HISTORICAL_CONTEXT_PATHS]
        candidate_explicit_paths = {entry["path"] for entry in candidate_explicit_entries}
        if candidate_explicit_paths != required_explicit_paths:
            package_errors.append("Candidate build-input manifest does not list exactly its bound reports and receipts.")
        explicit_by_path = {entry["path"]: entry for entry in candidate_explicit_entries}
        for role, record in explicit_records.items():
            if not isinstance(record, dict) or not isinstance(record.get("source_path"), str):
                package_errors.append("Candidate build-input relocation record is missing for " + role + ".")
                continue
            entry = explicit_by_path.get(record["source_path"])
            if role in ("performance", "migration") and manifest_schema == PACKAGE_MANIFEST_V2_0:
                source_relative = _safe_relative_path(record.get("source_path"))
                package_relative = (PurePosixPath("compact-validation") / source_relative.name
                                    if source_relative else None)
                record = dict(record, sha256=(validation.get(role, {}).get("sha256")
                                               if isinstance(validation.get(role), dict) else None),
                              package_path=package_relative.as_posix() if package_relative else None)
            packaged_path = directory / (record.get("package_path") or "")
            if (not isinstance(entry, dict) or entry.get("kind") != "file" or
                    entry.get("sha256") != record.get("sha256") or
                    not packaged_path.is_file() or entry.get("bytes") != packaged_path.stat().st_size):
                package_errors.append("Candidate build-input entry does not match packaged " + role + ".")

        if manifest_schema == PACKAGE_MANIFEST_V2_1:
            if candidate_history_entries:
                package_errors.append("Historical context was incorrectly classified as a current build input.")
            if {item["source_path"] for item in history_relocations} != G10_HISTORICAL_CONTEXT_PATHS:
                package_errors.append("Candidate relocation index does not preserve both historical context files.")
        else:
            legacy_history = []
            for entry in candidate_history_entries:
                _, digest, source_path, package_path = _legacy_package_reference(
                    directory, entry["path"], "Candidate historical context", package_errors,
                    listed, entry.get("sha256"))
                if digest != entry.get("sha256"):
                    package_errors.append("Candidate historical context hash differs from its build-input record.")
                legacy_history.append({"role": "historical_context", "source_path": source_path,
                                       "package_path": package_path, "sha256": digest})
            if {item.get("source_path") for item in legacy_history} != G10_HISTORICAL_CONTEXT_PATHS:
                package_errors.append("Legacy candidate does not preserve both historical context files.")

    for evidence_name in ("performance", "migration"):
        evidence = validation.get(evidence_name)
        if not isinstance(evidence, dict):
            package_errors.append("Candidate " + evidence_name + " receipt is missing.")
            continue
        nested = (report_value.get("performance_benchmark") if evidence_name == "performance"
                  else report_value.get("migration_drill")) if isinstance(report_value, dict) else None
        nested_path_key = "report_path" if evidence_name == "performance" else "receipt_path"
        nested_hash_key = "report_sha256" if evidence_name == "performance" else "receipt_sha256"
        if not isinstance(nested, dict):
            package_errors.append("Candidate validation report has no " + evidence_name + " reference.")
            nested = {}
        if manifest_schema == PACKAGE_MANIFEST_V2_1:
            record = relocation_by_role.get(evidence_name)
            if (not record or evidence.get("path") != record.get("package_path") or
                    evidence.get("source_path") != record.get("source_path") or
                    evidence.get("sha256") != record.get("sha256") or
                    nested.get(nested_path_key) != record.get("source_path")):
                package_errors.append("Candidate " + evidence_name + " receipt does not match its relocation-index entry.")
                package_path = evidence.get("path")
            else:
                package_path = record["package_path"]
            receipt, receipt_hash = _read_package_json(
                directory, package_path, "Candidate " + evidence_name + " receipt", package_errors,
                listed=listed, expected_sha256=record.get("sha256") if record else None)
            validation_reference_records[evidence_name] = record
        else:
            if nested.get(nested_path_key) != evidence.get("path"):
                package_errors.append("Candidate " + evidence_name + " receipt path disagrees with its validation report.")
            receipt_path, receipt_hash, source_path, package_path = _legacy_package_reference(
                directory, evidence.get("path"), "Candidate " + evidence_name + " receipt",
                package_errors, listed, evidence.get("sha256"))
            receipt = None
            if receipt_path is not None:
                try:
                    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
                except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
                    package_errors.append("Candidate " + evidence_name + " receipt is unreadable: " + str(error))
            validation_reference_records[evidence_name] = {
                "role": evidence_name, "source_path": source_path,
                "package_path": package_path, "sha256": receipt_hash,
            }
        if receipt_hash != evidence.get("sha256"):
            package_errors.append("Candidate " + evidence_name + " receipt hash mismatch.")
        if nested.get(nested_hash_key) != receipt_hash:
            package_errors.append("Candidate validation report and " + evidence_name + " receipt hashes disagree.")
        if isinstance(receipt, dict):
            recorded_input = (receipt.get("input_manifest_sha256") if evidence_name == "performance"
                              else receipt.get("inputManifestSHA256"))
            if recorded_input != input_manifest_binding:
                package_errors.append("Candidate " + evidence_name + " receipt is stale for its input manifest.")

    if isinstance(report_value, dict) and isinstance(relocation_index, dict):
        if relocation_index.get("validation_run_id") != report_value.get("run_id"):
            package_errors.append("Candidate relocation index belongs to a different validation run.")

    checks = manifest.get("checks") if isinstance(manifest.get("checks"), dict) else {}
    acceptance_errors = validate_g09_acceptance_receipts(
        manifest, directory, listed, input_manifest_binding)
    package_errors.extend(acceptance_errors)
    source_identity_matches_current = bool(
        input_manifest_entries_match_current and build_input_sources_match_current and
        not package_errors)
    missing_package_checks = [check for check in G10_PACKAGE_CHECKS
                              if checks.get(check) != "PASS"]
    if source_identity_matches_current:
        package_errors.extend("Candidate package check is not PASS: " + check
                              for check in missing_package_checks)

    checksum_identity = [{"path": name, "sha256": digest}
                         for name, digest in sorted(listed.items())]
    integrity_sha256 = sha256_bytes(json.dumps(
        checksum_identity, sort_keys=True, separators=(",", ":")).encode("utf-8"))
    snapshot = {
        "directory": directory.relative_to(root).as_posix(),
        "manifest_path": manifest_path.relative_to(root).as_posix(),
        "manifest_sha256": package_manifest_hash,
        "manifest_selection": selection_method,
        "dmg_path": (directory / artifacts.get("dmg", {}).get("file", "")).relative_to(root).as_posix()
        if isinstance(artifacts.get("dmg"), dict) and artifacts["dmg"].get("file") else None,
        "dmg_sha256": artifacts.get("dmg", {}).get("sha256") if isinstance(artifacts.get("dmg"), dict) else None,
        "checksums_path": sums_path.relative_to(root).as_posix(),
        "checksums_sha256": sha256_file(sums_path) if sums_path.is_file() and not sums_path.is_symlink() else None,
        "integrity_sha256": integrity_sha256,
        "input_manifest_sha256": input_manifest_binding,
        "input_manifest_matches_current": input_manifest_binding == expected_input_manifest_sha256,
        "input_manifest_entries_sha256": candidate_input_entries_sha256,
        "current_input_manifest_entries_sha256": expected_input_entries_sha256,
        "input_manifest_entries_match_current": input_manifest_entries_match_current,
        "build_input_source_entries_sha256": candidate_build_source_entries_sha256,
        "current_build_input_source_entries_sha256": current_build_source_entries_sha256,
        "build_input_sources_match_current": build_input_sources_match_current,
        "source_identity_matches_current": source_identity_matches_current,
        "release_status": manifest.get("release_status"),
        "checks": dict(checks),
        "acceptance_receipts_valid": not acceptance_errors,
        "missing_package_checks": missing_package_checks,
        "errors": errors + package_errors,
    }
    return snapshot, errors + package_errors


def evaluate_g09_package(candidate, discovery_errors=(), pre_package_validation=False):
    """Derive G09 only from a checksum-valid candidate bound to current source inputs."""
    discovery_errors = list(discovery_errors)
    if pre_package_validation:
        return ("NOT_RUN",
                "G09 candidate acceptance is deferred until the current-source package is built; the exact manifest must be supplied in a post-package verification.",
                [])
    if candidate is None:
        if discovery_errors:
            return "FAIL", "G09 candidate discovery failed: " + " ".join(discovery_errors), discovery_errors
        return "NOT_RUN", "No manifest-backed 2.0 package is available for G09 verification.", []

    errors = discovery_errors + list(candidate.get("errors") or [])
    if errors:
        return "FAIL", "G09 candidate integrity or provenance validation failed: " + " ".join(errors), errors
    if not candidate.get("source_identity_matches_current"):
        issue = "The candidate build-input source entries do not match the current source snapshot; rebuild it before accepting G09."
        stale_checks = candidate.get("missing_package_checks") or []
        if stale_checks:
            issue += " The stale candidate does not attest current package checks: " + ", ".join(stale_checks) + "."
        return "BLOCKED", issue, [issue]

    checks = candidate.get("checks")
    if not isinstance(checks, dict):
        issue = "The validated candidate manifest has no checks object."
        return "FAIL", issue, [issue]

    missing_artifacts = [name for name in G10_PACKAGE_CHECKS if checks.get(name) != "PASS"]
    if missing_artifacts:
        issue = "G09 artifact checks are incomplete or non-passing: " + ", ".join(missing_artifacts) + "."
        return "FAIL", issue, missing_artifacts

    completion = {name: checks.get(name) for name in G09_COMPLETION_CHECKS
                  if name not in G10_PACKAGE_CHECKS}
    invalid = [name for name, status in completion.items()
               if status not in (None, "PASS", "NOT_RUN", "BLOCKED", "FAIL")]
    if invalid:
        issue = "G09 completion checks have unsupported statuses: " + ", ".join(invalid) + "."
        return "FAIL", issue, invalid
    failed = [name for name, status in completion.items() if status == "FAIL"]
    if failed:
        issue = "G09 full-workflow or rollback checks failed: " + ", ".join(failed) + "."
        return "FAIL", issue, failed
    blocked = [name for name, status in completion.items() if status == "BLOCKED"]
    if blocked:
        issue = "G09 completion checks are blocked: " + ", ".join(blocked) + "."
        return "BLOCKED", issue, blocked
    if any(status == "PASS" for status in completion.values()) and candidate.get("acceptance_receipts_valid") is not True:
        issue = "G09 completion checks lack validated candidate-bound acceptance receipts."
        return "FAIL", issue, [issue]
    outstanding = [name + "=" + str(status or "NOT_RECORDED")
                   for name, status in completion.items() if status != "PASS"]
    if outstanding:
        issue = ("The manifest-bound candidate passed DMG, signature, isolated executable-hash, and fixture-launch checks; "
                 "G09 still requires " + ", ".join(outstanding) + ".")
        return "PARTIAL", issue, outstanding

    summary = ("The exact candidate is checksum-valid and source-bound; DMG, signature, isolated executable hash, "
               "fixture launch, full offline workflow, and app/data rollback checks all passed.")
    return "PASS", summary, []


def candidate_dmg_mount_status(dmg_relative_path, root=ROOT):
    relative = _safe_relative_path(dmg_relative_path)
    if relative is None:
        return {"status": "NOT_RUN", "mounted": None, "reason": "No safe candidate DMG path is available."}
    path = Path(root) / Path(*relative.parts)
    if (not path.is_file() or _path_has_symlink_component(path, root)):
        return {"status": "NOT_RUN", "mounted": None, "reason": "Candidate DMG is missing or symlinked."}
    try:
        result = subprocess.run(["hdiutil", "info"], stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, check=False,
                                timeout=20)
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"status": "BLOCKED", "mounted": None, "reason": "Could not inspect disk-image mounts: " + str(error)}
    if result.returncode != 0:
        return {"status": "BLOCKED", "mounted": None,
                "reason": "hdiutil info returned " + str(result.returncode) + "."}
    mounted = str(path.resolve()) in result.stdout
    return {"status": "FAIL" if mounted else "PASS", "mounted": mounted,
            "reason": "Candidate DMG is mounted." if mounted else "Candidate DMG is not mounted."}


def retained_asset_snapshot(candidate_directory, root=ROOT):
    root = Path(root).resolve()
    paths = list(G10_RETAINED_PATHS)
    if candidate_directory:
        paths.append(candidate_directory)
    assets = []
    errors = []
    for relative_value in paths:
        relative = _safe_relative_path(relative_value)
        if relative is None:
            errors.append("Retained asset path is unsafe: " + str(relative_value))
            continue
        path = root / Path(*relative.parts)
        exists = path.exists() or path.is_symlink()
        symlink = path.is_symlink()
        regular = path.is_file() and not symlink
        directory = path.is_dir() and not symlink
        item = {"path": str(relative), "exists": exists, "symlink": symlink,
                "regular_file": regular, "directory": directory}
        if (not exists or symlink or not path.is_relative_to(root) or
                _path_has_symlink_component(path, root)):
            errors.append("Required retained asset is missing, symlinked, or outside the project: " + str(relative))
        elif str(relative) == "DisposableMigrationV7Source" and not any(path.iterdir()):
            errors.append("The retained disposable migration source archive is empty.")
        elif regular:
            item["sha256"] = sha256_file(path)
        assets.append(item)
    return assets, errors


def validate_cleanup_manifest_record(value, expected_run_id, expected_input_manifest_sha256,
                                     expected_scratch_relative, root=ROOT):
    """Validate the post-cleanup receipt without trusting its status label."""
    root = Path(root).resolve()
    errors = []
    if not isinstance(value, dict) or value.get("schema_version") != "latticelens-cleanup-2.0-final-local-v1":
        return ["Cleanup manifest has an unsupported schema."]
    if value.get("run_id") != expected_run_id:
        errors.append("Cleanup manifest belongs to a different verifier run.")
    if value.get("input_manifest_sha256") != expected_input_manifest_sha256:
        errors.append("Cleanup manifest is not bound to the frozen verifier input manifest.")
    if value.get("status") != "applied_postcleanup_verified":
        errors.append("Cleanup manifest does not record a completed post-cleanup verification.")
    targets = value.get("targets")
    if not isinstance(targets, list) or len(targets) != 1:
        errors.append("Cleanup manifest must contain exactly the current verifier-owned scratch target.")
        targets = []
    expected = str(expected_scratch_relative)
    for target in targets:
        if not isinstance(target, dict) or target.get("path") != expected:
            errors.append("Cleanup manifest target is not the exact current run scratch path.")
            continue
        relative = _safe_relative_path(target.get("path"))
        path = root / Path(*relative.parts) if relative else root
        if (relative is None or path.exists() or path.is_symlink() or
                target.get("canonical_path_verified") is not True or
                target.get("directory_symlink") is not False or
                target.get("symlink_targets_confined_to_scratch") is not True or
                target.get("removed") is not True or
                target.get("post_action_check") != "path absent" or
                target.get("open_process_count") != 0):
            errors.append("Cleanup manifest does not prove safe removal of its exact scratch target.")
    checks = value.get("post_cleanup_verification")
    if not isinstance(checks, dict):
        errors.append("Cleanup manifest is missing post-cleanup verification details.")
    else:
        required_passes = (
            "frozen_input_manifest", "retained_core_assets", "release_package_integrity",
            "release_package_unchanged", "candidate_source_binding",
            "candidate_dmg_unmounted", "owned_processes_stopped",
        )
        for name in required_passes:
            if checks.get(name) != "PASS":
                errors.append("Post-cleanup verification is not PASS for " + name + ".")
    if value.get("unapproved_deletions") != []:
        errors.append("Cleanup manifest records or fails to exclude unapproved deletions.")
    return errors


def evaluate_g10_cleanup(cleanup_removed, cleanup_errors, remaining_process_count,
                          frozen_input_errors, retained_before, retained_after,
                          candidate_before, candidate_after, mount_status):
    """Fail closed on cleanup/provenance violations; stale or unavailable package evidence stays partial."""
    fatal = list(cleanup_errors) + list(frozen_input_errors)
    if not cleanup_removed:
        fatal.append("Verifier-owned scratch was not removed.")
    if remaining_process_count:
        fatal.append("Verifier-owned test processes remain.")
    if retained_before != retained_after:
        fatal.append("Retained core asset inventory changed during the run.")
    if candidate_before and candidate_after:
        if candidate_before.get("directory") != candidate_after.get("directory"):
            fatal.append("The selected release candidate changed during cleanup verification.")
        if candidate_before.get("integrity_sha256") != candidate_after.get("integrity_sha256"):
            fatal.append("Release package hashes changed during cleanup verification.")
        if candidate_after.get("errors"):
            fatal.extend(candidate_after["errors"])
    elif candidate_before or candidate_after:
        fatal.append("Release candidate appeared or disappeared during cleanup verification.")
    if mount_status.get("status") == "FAIL":
        fatal.append(mount_status.get("reason", "Candidate DMG is mounted."))
    if fatal:
        return "FAIL", "G10 cleanup/provenance verification failed: " + " ".join(fatal), fatal

    partial = []
    if not candidate_after:
        partial.append("No current manifest-backed 2.0 package is available.")
    else:
        if candidate_after.get("errors"):
            partial.extend(candidate_after["errors"])
        if not candidate_after.get("source_identity_matches_current"):
            partial.append("The latest candidate build inputs do not match the current canonical source entries; rebuild it from this run.")
    if mount_status.get("status") == "BLOCKED":
        partial.append(mount_status.get("reason", "Candidate mount status could not be checked."))
    if mount_status.get("status") == "NOT_RUN":
        partial.append(mount_status.get("reason", "Candidate mount status was not checked."))
    if partial:
        status = "BLOCKED" if mount_status.get("status") == "BLOCKED" and not candidate_after else "PARTIAL"
        return status, "Scratch removal and retained project inputs were checked, but G10 cannot pass: " + " ".join(partial), partial

    summary = ("The exact verifier-owned scratch was removed; frozen input hashes and required fixtures/rollback sources "
               "remain unchanged; no verifier-owned test process or candidate DMG mount remains; and the latest "
               "manifest-bound candidate package checksums are unchanged.")
    return "PASS", summary, []


def input_paths():
    paths = set()
    roots = ["Sources", "Tests", "Scripts", "Assets", "Assets.xcassets"]
    for relative_root in roots:
        base = ROOT / relative_root
        if not base.exists():
            continue
        for current, directories, files in os.walk(base, followlinks=False):
            directories[:] = sorted(name for name in directories
                                    if not name.startswith(".codex-task-") and name != ".build")
            for name in files:
                path = Path(current) / name
                if path.is_symlink():
                    paths.add(path)
                elif path.is_file():
                    paths.add(path)

    root_files = [
        "Package.swift", "README.md", "CHANGELOG.md", "GITHUB_EXPORT.md",
        "VALIDATION_2.0.md", "CleanupManifest-2.0.json", "CleanupManifest-2.0-final.json",
        "INSPIRE文献管理器2.0_開工方案_v5.md",
        "INSPIRE文獻管理器2.0_開工方案_final.md",
        "evidence/Validation-2.0-local-20261001.json",
        "LatticeLens.xcodeproj/project.pbxproj",
        "LatticeLens.xcodeproj/xcshareddata/xcschemes/LatticeLens.xcscheme",
        "LatticeLens.xcodeproj/xcshareddata/xcschemes/LatticeLens-Unit.xcscheme",
        "LatticeLens.xcodeproj/xcshareddata/xcschemes/LatticeLens-UIFixture.xcscheme",
    ]
    for relative in root_files:
        path = ROOT / relative
        if path.is_file() or path.is_symlink():
            paths.add(path)
    return sorted(paths, key=lambda path: path.relative_to(ROOT).as_posix())


def freeze_manifest(run_id):
    entries = []
    for path in input_paths():
        relative = path.relative_to(ROOT).as_posix()
        if path.is_symlink():
            target = os.readlink(str(path))
            entries.append({"path": relative, "kind": "symlink", "target": target,
                            "sha256": sha256_bytes(target.encode("utf-8"))})
        else:
            entries.append({"path": relative, "kind": "file", "bytes": path.stat().st_size,
                            "sha256": sha256_file(path)})
    manifest = {
        "schema_version": "latticelens-input-manifest-v1",
        "run_id": run_id,
        "created_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "files": entries,
    }
    encoded = (json.dumps(manifest, ensure_ascii=False, sort_keys=True,
                          separators=(",", ":")) + "\n").encode("utf-8")
    destination = ROOT / "evidence" / ("Validation-2.0-final-local-" + run_id + "-inputs.json")
    destination.write_bytes(encoded)
    return destination, sha256_bytes(encoded), entries


def isolated_environment(scratch, base_environment=None):
    environment = dict(os.environ if base_environment is None else base_environment)
    host_system_temp = (environment.get("LATTICELENS_HOST_SYSTEM_TMPDIR") or
                        environment.get("TMPDIR", ""))
    for variable in ("LATTICELENS_LIVE_INSPIRE_SMOKE", "LATTICELENS_RUN_V4_BENCHMARK",
                     "LATTICELENS_RUN_V11_FORMULA_BENCHMARK",
                     "LATTICELENS_V11_FORMULA_BENCHMARK_ROOT",
                     "LATTICELENS_V11_FORMULA_BENCHMARK_OUTPUT",
                     "LATTICELENS_RUN_V12_FORMULA_BENCHMARK",
                     "LATTICELENS_V12_FORMULA_BENCHMARK_ROOT",
                     "LATTICELENS_V12_FORMULA_BENCHMARK_OUTPUT",
                     "LATTICELENS_V5_DISPOSABLE_V7_STORE", "LATTICELENS_V5_DISPOSABLE_DRILL_ROOT",
                     "LATTICELENS_V5_DISPOSABLE_SOURCE_ORIGIN",
                     "LATTICELENS_V10_DISPOSABLE_DRILL_ROOT",
                     "LATTICELENS_V10_DISPOSABLE_INPUT_MANIFEST_SHA256",
                     "LATTICELENS_ALLOW_PRODUCTION_ISOLATION",
                     "LATTICELENS_PRODUCTION_STORE_ROOT"):
        environment.pop(variable, None)
    # TMPDIR is provided for child tools that honor it; app-owned stores and
    # caches use explicit roots because Foundation/XCTest may ignore TMPDIR.
    # Isolate both the POSIX and CoreFoundation home-directory lookups so
    # AppKit/XCTest saved state cannot escape the task-local project scratch.
    # Keep the original Darwin T path separately for the G02 sandbox denylist;
    # child TMPDIR itself still points only into this verifier's scratch.
    if host_system_temp:
        environment["LATTICELENS_HOST_SYSTEM_TMPDIR"] = host_system_temp
    environment["TMPDIR"] = str(scratch / "tmp")
    environment["HOME"] = str(scratch / "home")
    environment["CFFIXED_USER_HOME"] = str(scratch / "home")
    environment["LATTICELENS_TEST_STORE_ROOT"] = str(scratch / "test-stores")
    environment["LATTICELENS_TEST_TMP_ROOT"] = str(scratch / "tmp" / "test-host")
    environment["LATTICELENS_REQUIRE_PROJECT_LOCAL_TEST_ROOTS"] = "1"
    return environment


def swiftpm_options(scratch, scratch_name="swiftpm"):
    """Keep SwiftPM's build and shared state inside this verifier run."""
    return [
        "--scratch-path", str(scratch / scratch_name),
        "--cache-path", str(scratch / "swiftpm-cache"),
        "--config-path", str(scratch / "swiftpm-config"),
        "--security-path", str(scratch / "swiftpm-security"),
        "--manifest-cache", "local",
        "--disable-dependency-cache",
    ]


def run_stage(name, command, scratch, environment, timeout_seconds):
    log_path = scratch / (name + ".log")
    started = time.monotonic()
    return_code = None
    timed_out = False
    launch_error = None
    with log_path.open("wb") as output:
        try:
            process = subprocess.Popen(command, cwd=str(ROOT), env=environment,
                                       stdout=output, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            try:
                return_code = process.wait(timeout=timeout_seconds)
            except subprocess.TimeoutExpired:
                timed_out = True
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                except ProcessLookupError:
                    process.wait()
        except OSError as error:
            launch_error = str(error)
            output.write((launch_error + "\n").encode("utf-8", errors="replace"))
    status = "TIMEOUT" if timed_out else ("PASS" if return_code == 0 else "FAIL")
    return {
        "name": name,
        "status": status,
        "command": command,
        "exit_code": return_code,
        "timed_out": timed_out,
        "timeout_seconds": timeout_seconds,
        "elapsed_seconds": round(time.monotonic() - started, 3),
        "log_path_scratch": log_path,
        "log_sha256": sha256_file(log_path),
        "launch_error": launch_error,
    }


def not_run_stage(name, command, scratch, reason):
    log_path = scratch / (name + ".log")
    log_path.write_text(reason + "\n", encoding="utf-8")
    return {
        "name": name,
        "status": "NOT_RUN",
        "command": command,
        "exit_code": None,
        "timed_out": False,
        "timeout_seconds": None,
        "elapsed_seconds": 0.0,
        "log_path_scratch": log_path,
        "log_sha256": sha256_file(log_path),
        "launch_error": None,
        "not_run_reason": reason,
    }


def run_old_app_rollback_stage(scratch, environment, input_manifest_hash, host_free_only):
    command = [sys.executable, "-B", G02_OLD_APP_DRILL_SCRIPT,
               "--input-manifest-sha256", input_manifest_hash,
               "--output", str(scratch / "g02-old-app-rollback-receipt.json")]
    if host_free_only:
        return not_run_stage(
            "g02-old-app-rollback-compatibility", command, scratch,
            "NOT_RUN by --host-free-only; no application, GUI, or rollback automation was started.")
    return run_stage("g02-old-app-rollback-compatibility", command, scratch, environment, 1500)


def run_xcode_stage(name, command, scratch, environment, timeout_seconds, host_free_only):
    if host_free_only:
        return not_run_stage(
            name, command, scratch,
            "NOT_RUN by --host-free-only; no Xcode build or test command was started.")
    return run_stage(name, command, scratch, environment, timeout_seconds)


def collect_xcode_summary(result_bundle, scratch, environment, name, host_free_only):
    if host_free_only:
        stage = not_run_stage(
            name, ["xcresult-summary", str(result_bundle)], scratch,
            "NOT_RUN by --host-free-only; no Xcode result bundle was produced or inspected.")
        return stage, None
    return collect_xcresult_summary(result_bundle, scratch, environment, name)


def xcode_test_commands(xcode_base, scheme, derived_data, result_bundle, test_store_root,
                       fixture_cache_root=None, test_tmp_root=None):
    """Return separate compile and runner actions sharing one isolated DerivedData root."""
    common = list(xcode_base) + [
        "-scheme", scheme,
        "-derivedDataPath", str(derived_data),
        "CODE_SIGNING_ALLOWED=YES",
        "CODE_SIGNING_REQUIRED=YES",
        "CODE_SIGN_IDENTITY=-",
    ]
    build = common + ["build-for-testing"]
    test = common + [
        "-resultBundlePath", str(result_bundle),
        "-parallel-testing-enabled", "NO",
        "-maximum-parallel-testing-workers", "1",
        "LATTICELENS_TEST_STORE_ROOT=" + str(test_store_root),
        "LATTICELENS_REQUIRE_PROJECT_LOCAL_TEST_ROOTS=1",
    ]
    if fixture_cache_root is not None:
        test.append("LATTICELENS_FIXTURE_CACHE_ROOT=" + str(fixture_cache_root))
    if test_tmp_root is not None:
        test.append("LATTICELENS_TEST_TMP_ROOT=" + str(test_tmp_root))
    test.append("test-without-building")
    return build, test


def match_owned_test_processes(ps_output, executable_paths):
    exact_executables = {str(Path(path).resolve()) for path in executable_paths}
    matches = {}
    for line in ps_output.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2 or not parts[0].isdigit():
            continue
        pid = int(parts[0])
        command = parts[1]
        for executable in exact_executables:
            if command == executable or command.startswith(executable + " "):
                matches[pid] = executable
                break
    return matches


def task_test_executable_paths(derived_data):
    derived_root = Path(derived_data).resolve()
    products = derived_root / "Build" / "Products"
    if not products.is_dir():
        return []
    executables = []
    bundles = list(products.rglob("*.app")) + list(products.rglob("*.xctest"))
    for bundle in bundles:
        info_path = bundle / "Contents" / "Info.plist"
        if not info_path.is_file():
            continue
        try:
            with info_path.open("rb") as stream:
                info = plistlib.load(stream)
        except (OSError, plistlib.InvalidFileException):
            continue
        name = info.get("CFBundleExecutable") if isinstance(info, dict) else None
        if not isinstance(name, str) or not name:
            continue
        executable = bundle / "Contents" / "MacOS" / name
        if executable.is_file() and executable.resolve().is_relative_to(derived_root):
            executables.append(executable.resolve())
    return sorted(set(executables), key=str)


def cleanup_task_test_processes(derived_data, grace_seconds=5):
    """Stop only app/test executables built under this run's unique DerivedData."""
    executable_paths = task_test_executable_paths(derived_data)
    if not executable_paths:
        return {"status": "PASS", "matched": [], "terminated": [], "remaining": [], "error": None}
    listing = subprocess.run(["ps", "-Ao", "pid=,command="], cwd=str(ROOT),
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             text=True, check=False)
    if listing.returncode != 0:
        return {"status": "FAIL", "matched": [], "terminated": [], "remaining": [],
                "error": listing.stderr.strip() or "Could not inspect task-owned Xcode processes."}
    matches = match_owned_test_processes(listing.stdout, executable_paths)
    terminated, remaining, cleanup_errors = [], [], []
    for pid, executable in matches.items():
        try:
            os.kill(pid, signal.SIGTERM)
            terminated.append({"pid": pid, "executable": executable, "signal": "SIGTERM"})
        except ProcessLookupError:
            continue
        except OSError as error:
            cleanup_errors.append({"pid": pid, "executable": executable, "error": str(error)})

    deadline = time.monotonic() + grace_seconds
    while matches and time.monotonic() < deadline:
        refreshed = subprocess.run(["ps", "-Ao", "pid=,command="], cwd=str(ROOT),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, check=False)
        if refreshed.returncode != 0:
            cleanup_errors.append({"error": refreshed.stderr.strip() or
                                   "Could not confirm task-owned process termination."})
            break
        live = match_owned_test_processes(refreshed.stdout, executable_paths)
        remaining = [{"pid": pid, "executable": executable}
                     for pid, executable in live.items() if pid in matches]
        if not remaining:
            break
        time.sleep(0.1)
    if remaining:
        for process in remaining:
            try:
                os.kill(process["pid"], signal.SIGKILL)
                for record in terminated:
                    if record["pid"] == process["pid"]:
                        record["signal"] = "SIGKILL"
            except ProcessLookupError:
                continue
            except OSError as error:
                process["error"] = str(error)
        refreshed = subprocess.run(["ps", "-Ao", "pid=,command="], cwd=str(ROOT),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, check=False)
        if refreshed.returncode == 0:
            live = match_owned_test_processes(refreshed.stdout, executable_paths)
            remaining = [{"pid": pid, "executable": executable}
                         for pid, executable in live.items() if pid in matches]
        else:
            cleanup_errors.append({"error": refreshed.stderr.strip() or
                                   "Could not confirm SIGKILL of task-owned Xcode processes."})
    return {"status": "PASS" if not remaining and not cleanup_errors else "FAIL",
            "matched": [{"pid": pid, "executable": executable} for pid, executable in matches.items()],
            "terminated": terminated, "remaining": remaining, "errors": cleanup_errors,
            "error": None}


XCODE_TEST_INFRASTRUCTURE_PATTERNS = (
    re.compile(r"The test runner hung before establishing connection", re.I),
    re.compile(r"Timed out after [0-9.]+s while initiating control session with daemon", re.I),
    re.compile(r"Timed out while enabling automation mode", re.I),
    re.compile(r"failed to initialize for UI testing", re.I),
)


def classify_xcode_test_stage(stage, log_text, xcresult_summary):
    """Distinguish a runner that never starts from an XCTest assertion failure."""
    failures = (xcresult_summary or {}).get("testFailures", [])
    if not isinstance(failures, list):
        failures = []
    failure_details = "\n".join(
        str(item.get("testName", "")) + " " + str(item.get("failureText", ""))
        for item in failures if isinstance(item, dict))
    infrastructure = any(pattern.search(log_text + "\n" + failure_details)
                         for pattern in XCODE_TEST_INFRASTRUCTURE_PATTERNS)
    has_assertion_failure = bool(re.search(r"Test Case '[^\n]+' failed", log_text))
    if not has_assertion_failure:
        has_assertion_failure = any(
            isinstance(item, dict) and
            "encountered an error" not in str(item.get("testName", "")).lower() and
            not any(pattern.search(str(item.get("failureText", "")))
                    for pattern in XCODE_TEST_INFRASTRUCTURE_PATTERNS)
            for item in failures)
    if has_assertion_failure:
        return "FAIL", "XCTest reported a test-case failure; see the runner log and xcresult details."
    if infrastructure:
        return "BLOCKED", "XCTest runner infrastructure failed before a complete test run; no assertion failure is inferred."

    total = (xcresult_summary or {}).get("totalTestCount")
    result = (xcresult_summary or {}).get("result")
    runner_restart_count = len(re.findall(
        r"Restarting after unexpected exit, crash, or test timeout", log_text, re.I))
    completed_case_event = bool(re.search(
        r"Test Case '[^\n]+' (?:passed|failed|skipped)", log_text, re.I))
    summary_missing_or_empty = not isinstance(total, int) or total == 0
    if (stage.get("timed_out") and runner_restart_count >= 2 and
            not completed_case_event and summary_missing_or_empty):
        return "BLOCKED", (
            "The XCTest runner restarted repeatedly and timed out before any test case completed; "
            "no product assertion result is inferred.")
    if stage.get("timed_out") and not re.search(r"Test Case '[^\n]+' started", log_text):
        return "BLOCKED", "The runner stage timed out before any test case started."
    if stage.get("status") == "PASS" and result == "Passed" and isinstance(total, int) and total > 0:
        return "PASS", "XCTest completed with a readable non-empty passing result bundle."
    if stage.get("status") == "PASS":
        return "FAIL", "The test command exited successfully but did not produce a readable non-empty passing XCTest result."
    return "FAIL", "The test runner failed without a recognized pre-test infrastructure blocker."


def classify_xcode_test_if_run(stage, log_text, xcresult_summary):
    if stage.get("status") == "NOT_RUN":
        return "NOT_RUN", stage.get("not_run_reason", "The Xcode test action was not run.")
    return classify_xcode_test_stage(stage, log_text, xcresult_summary)


def parse_test_summary(log_text):
    main_pattern = re.compile(
        r"Test Suite 'LatticeLensTests\.xctest' (?:passed|failed)[^\n]*\n"
        r"\s+Executed (\d+) tests?(?:, with (?:(\d+) tests? skipped and )?(\d+) failures?)"
    )
    fixture_pattern = re.compile(
        r"Test Suite 'LatticeLensUITests\.xctest' (?:passed|failed)[^\n]*\n"
        r"\s+Executed (\d+) tests?(?:, with (?:(\d+) tests? skipped and )?(\d+) failures?)"
    )
    main = main_pattern.search(log_text)
    fixture = fixture_pattern.search(log_text)
    summaries = [match for match in re.finditer(
        r"Executed (\d+) tests?(?:, with (?:(\d+) tests? skipped and )?(\d+) failures?)", log_text)]
    fallback = max(summaries, key=lambda match: int(match.group(1))) if summaries else None
    main_values = main.groups() if main else (fallback.groups() if fallback else ("0", None, "0"))
    main_total, main_skipped, main_failed = int(main_values[0]), int(main_values[1] or 0), int(main_values[2] or 0)
    fixture_values = fixture.groups() if fixture else ("0", None, "0")
    fixture_total, fixture_skipped, fixture_failed = int(fixture_values[0]), int(fixture_values[1] or 0), int(fixture_values[2] or 0)

    skip_pattern = re.compile(r"Test Case '-\[[^\]]+ (test[A-Za-z0-9_]+)\]' skipped(?: - ([^\n]+?))? \(")
    skips = []
    for match in skip_pattern.finditer(log_text):
        name = match.group(1)
        skips.append({"test": name, "reason": SKIP_ALLOWLIST.get(name, match.group(2) or "No skip reason recorded."),
                      "allowlisted": name in SKIP_ALLOWLIST})

    total = main_total + fixture_total
    skipped = main_skipped + fixture_skipped
    failed = main_failed + fixture_failed
    return {
        "enumerated": total,
        "passed": max(0, total - skipped - failed),
        "failed": failed,
        "skipped": skipped,
        "skip_reasons": skips,
        "summary_found": bool(main or fallback),
        "accessibility_fixture_tests": fixture_total,
        "unknown_skips": [item["test"] for item in skips if not item["allowlisted"]],
    }


G02_MIGRATION_TEST_CASES = (
    "testLegacyV9SchemaRejectsV12StoreWithoutChangingMainOrWAL",
    "testDefaultFactoryMigratesV8ThroughStagingToV12AndPreservesSourceFamily",
    "testDefaultFactoryMigratesV9ThroughStagingToV12AndPreservesSourceFamily",
    "testDefaultFactoryMigratesV9ThroughV12StagingAndPreservesSourceFamily",
    "testV10MigrationCrashRecoveryNeverPublishesUnverifiedStaging",
    "testV10MigrationCategoryBootstrapCrashOnRealV9StoreRollsBackStaging",
    "testV10BackupRefusesSymlinkedSQLiteSidecar",
    "testStoreBackupTreatsAbsentSidecarsAsOptionalButRejectsMissingRecordedSidecars",
    "testV10MigrationRejectsSemanticMismatchAndCancellationBeforeActivation",
    "testV10MigrationRejectsDuplicateFormulaEquationIdentityBeforeActivation",
    "testV10MigrationRecoveryRejectsTamperedBackupWithoutChangingActiveDescriptor",
    "testV10MigrationInvalidSchemaAndBackupFailureFailClosed",
    "testV10RecoveryUpgradesLegacySetOrderFingerprintAfterActivationCrash",
)


def physical_disk_enospc_evidence(root=ROOT):
    required_sources = (
        "Sources/LatticeLens/Core/Persistence/V4NormalizedStore.swift",
        "Tests/LatticeLensTests/V4LocalTests.swift",
        "Scripts/v10_physical_enospc_drill.sh",
    )
    evidence_dir = root / "evidence"
    candidates = sorted(evidence_dir.glob("G02-PhysicalDiskExhaustion-*.log"),
                        key=lambda path: path.stat().st_mtime, reverse=True)
    for path in candidates:
        if path.is_symlink() or not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        observed_hashes = dict(re.findall(r"^G02_SOURCE_SHA256 (\S+) ([0-9a-f]{64})$", text, re.MULTILINE))
        expected_hashes = {}
        hashes_match = True
        for relative in required_sources:
            source = root / relative
            if not source.is_file() or source.is_symlink():
                hashes_match = False
                break
            expected_hashes[relative] = sha256_file(source)
            if observed_hashes.get(relative) != expected_hashes[relative]:
                hashes_match = False
                break
        test_passed = re.search(
            r"Test Case '-\[[^\]]+ " + re.escape(G02_PHYSICAL_DISK_TEST) + r"\]' passed ", text
        ) is not None
        required_markers = (
            "G02_PHYSICAL_ENOSPC observed_error=",
            "G02_PHYSICAL_RECOVERY phase=rolledBack descriptor=absent source_family=unchanged",
            "TEST_STATUS=0",
        )
        if not hashes_match or not test_passed or any(marker not in text for marker in required_markers):
            continue
        return {
            "status": "PASS",
            "reason": "A source-bound, project-local HFS+ image run observed a real ENOSPC during staging-copy and recovered to rolledBack without changing the source family or publishing a descriptor.",
            "log_path": path.relative_to(root).as_posix(),
            "log_sha256": sha256_file(path),
            "source_sha256": expected_hashes,
        }
    return {
        "status": "NOT_RUN",
        "reason": "No successful physical-disk log matching the current migration source, XCTest, and drill-script hashes was found.",
        "log_path": None,
        "log_sha256": None,
        "source_sha256": {},
    }


def g02_migration_case_evidence(log_text, v10_drill_status, physical_disk_status="NOT_RUN",
                                old_app_rollback_status="NOT_RUN"):
    observed = {name: [] for name in G02_MIGRATION_TEST_CASES}
    pattern = re.compile(r"Test Case '-\[[^\]]+ (test[A-Za-z0-9_]+)\]' (passed|failed|skipped)")
    for match in pattern.finditer(log_text):
        name, result = match.groups()
        if name in observed:
            observed[name].append(result)

    cases = []
    for name in G02_MIGRATION_TEST_CASES:
        results = observed[name]
        if len(results) == 1 and results[0] == "passed":
            status = "PASS"
        elif not results:
            status = "NOT_RUN"
        elif "failed" in results:
            status = "FAIL"
        elif "skipped" in results:
            status = "SKIPPED"
        else:
            status = "DUPLICATE_OR_INCONSISTENT"
        cases.append({"test": name, "status": status, "observed_results": results})

    all_required_passed = all(case["status"] == "PASS" for case in cases)
    if all_required_passed and v10_drill_status == "PASS":
        summary = (
            "The current SwiftPM run passed a host-free synthetic V9-schema refusal check against a V12 store; "
            "its main database and WAL bytes remained unchanged, while transient SHM bytes changed, so this does "
            "not claim whole-family byte preservation or older-app UI behavior. It also passed V8-to-V12 and "
            "V9-to-V12 staged factory migrations with "
            "source-family preservation, real V9 category-crash rollback, and a synthetic V8/V9/V10 matrix covering "
            "seven coordinator crash points, main/WAL/SHM byte preservation, corruption of each backed-up "
            "family member, semantic mismatch, cancellation, and an injected file-write-out-of-space error. "
            "WAL and SHM symlink refusal, optional source-sidecar handling, rejection of missing manifest-listed "
            "sidecars, and duplicate logical formula identity refusal before activation also passed. The "
            "manifest-bound V10-to-V12 activation/restore/rollback drill passed. "
        )
        missing = []
        if physical_disk_status == "PASS":
            summary += (
                "A source-bound disposable HFS+ image drill observed real ENOSPC during staging-copy and recovered "
                "to rolledBack with the source family unchanged and no active descriptor. "
            )
        else:
            missing.append("physical disk exhaustion=" + str(physical_disk_status))
        if old_app_rollback_status == "PASS":
            summary += (
                "The hash-verified 1.0.11 app opened a restored V9-compatible target and displayed the exact "
                "fixture paper without opening or changing the active V12 SQLite family; the verified "
                "pre-upgrade backup remained byte-stable."
            )
        else:
            missing.append("older-app compatible rollback=" + str(old_app_rollback_status))
        if missing:
            summary += "G02 remains PARTIAL: " + "; ".join(missing) + "."
    elif all_required_passed:
        summary = (
            "The current SwiftPM run passed the V8/V9 staged migration and coordinator regression "
            "cases, but the manifest-bound V10-to-V12 drill status is " + str(v10_drill_status) +
            ". G02 remains PARTIAL because the full per-source-version crash/error matrix for "
            "V8/V9/V10 is not yet certified."
        )
    else:
        summary = (
            "Required migration regressions are missing or non-passing in this SwiftPM run; see "
            "case_results. G02 cannot be accepted. The full V8/V9/V10 crash/error matrix also "
            "remains uncertified."
        )
    if not all_required_passed or v10_drill_status == "FAIL":
        status = "FAIL"
    elif v10_drill_status == "BLOCKED" or old_app_rollback_status == "BLOCKED":
        status = "BLOCKED"
    elif (all_required_passed and v10_drill_status == "PASS" and
          physical_disk_status == "PASS" and old_app_rollback_status == "PASS"):
        status = "PASS"
    elif old_app_rollback_status == "FAIL":
        status = "FAIL"
    else:
        status = "PARTIAL"
    return {"status": status, "all_required_passed": all_required_passed, "cases": cases,
            "v10_drill_status": v10_drill_status, "physical_disk_status": physical_disk_status,
            "old_app_rollback_status": old_app_rollback_status, "summary": summary}


def validate_old_app_rollback_receipt(receipt_path, input_manifest_hash, stage_status,
                                      root=ROOT):
    if stage_status == "NOT_RUN":
        return {"status": "NOT_RUN",
                "summary": "Old-app rollback compatibility was not run in host-free mode.",
                "receipt_path": None, "receipt_sha256": None, "validation_errors": []}
    if stage_status == "TIMEOUT":
        return {"status": "BLOCKED", "summary": "The old-app rollback compatibility stage timed out.",
                "receipt_path": None, "receipt_sha256": None, "validation_errors": []}
    if stage_status != "PASS":
        return {"status": "FAIL", "summary": "The old-app rollback compatibility stage failed to execute.",
                "receipt_path": None, "receipt_sha256": None,
                "validation_errors": ["stage_status=" + str(stage_status)]}
    try:
        path = Path(receipt_path)
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root.resolve()):
            raise ValueError("receipt is missing, symlinked, or outside the project")
        receipt_bytes = path.read_bytes()
        receipt = json.loads(receipt_bytes)
        if (receipt.get("schema_version") != "latticelens-g02-old-app-rollback-v1" or
                receipt.get("input_manifest_sha256") != input_manifest_hash or
                receipt.get("status") != "PASS"):
            raise ValueError("receipt schema, frozen input identity, or stage status is invalid")
        old_release = root / "release-assets/Release-1.0.11-local"
        old_manifest_path = old_release / "manifest-v1.0.11.json"
        old_dmg_path = old_release / "LatticeLens-1.0.11-local.dmg"
        root_real = root.resolve()
        if (old_release.is_symlink() or not old_release.is_dir() or
                old_manifest_path.is_symlink() or not old_manifest_path.is_file() or
                old_dmg_path.is_symlink() or not old_dmg_path.is_file() or
                not old_manifest_path.resolve().is_relative_to(root_real) or
                not old_dmg_path.resolve().is_relative_to(root_real)):
            raise ValueError("preserved 1.0.11 manifest or DMG is missing or symlinked")
        old_manifest = json.loads(old_manifest_path.read_text(encoding="utf-8"))
        dmg_manifest = old_manifest.get("artifacts", {}).get("dmg", {})
        dmg_hash = sha256_file(old_dmg_path)
        manifest_hash = sha256_file(old_manifest_path)
        if (old_manifest.get("product_version") != "1.0.11" or
                old_manifest.get("build_number") != 111 or
                old_manifest.get("bundle_id") != "org.latticelens.app" or
                old_manifest.get("app", {}).get("bundle") != "LatticeLens.app" or
                dmg_manifest.get("file") != old_dmg_path.name or
                not re.fullmatch(r"[0-9a-f]{64}", str(dmg_manifest.get("sha256", ""))) or
                dmg_manifest.get("bytes") != old_dmg_path.stat().st_size or
                dmg_manifest.get("sha256") != dmg_hash):
            raise ValueError("preserved 1.0.11 DMG does not match its manifest hash and size")
        app = receipt.get("app", {})
        if (app.get("product_version") != old_manifest.get("product_version") or
                app.get("build_number") != str(old_manifest.get("build_number")) or
                app.get("bundle_id") != old_manifest.get("bundle_id") or
                app.get("executable_sha256") != old_manifest.get("app", {}).get("executable_sha256")):
            raise ValueError("opened old-app identity does not match the preserved 1.0.11 manifest")

        checks = receipt.get("checks", {})
        required_checks = {
            "fixture_xctest": "PASS",
            "backup_manifest_and_family": "PASS",
            "old_app_dmg_and_executable_identity": "PASS",
            "old_app_launch": "PASS",
            "old_app_opened_restored_v9": "PASS",
            "old_app_did_not_open_v12": "PASS",
            "old_app_read_fixture_paper": "PASS",
            "v8_integrity_check": "ok",
            "v12_integrity_check": "ok",
            "v12_family_byte_stable": True,
            "verified_backup_byte_stable": True,
            "network_denied": True,
            "real_user_library_denied": True,
            "securityd_keychain_access_denied": True,
            "v12_path_denied_by_sandbox": True,
            "system_temporary_paths_denied": True,
            "task_process_stopped": True,
            "dmg_detached": True,
            "scratch_removed": True,
        }
        for key, expected in required_checks.items():
            if checks.get(key) != expected:
                raise ValueError("required receipt check is not passing: " + key)
        evidence = receipt.get("evidence", {})
        app_log_tail = evidence.get("app_log_tail")
        if not isinstance(app_log_tail, list) or any(not isinstance(line, str) for line in app_log_tail):
            raise ValueError("old-app log tail is missing or malformed")
        store_load_error_patterns = (
            r"Cannot use staged migration with an unknown model version",
            r"Store failed to load",
            r"NSCocoaErrorDomain\s*\(134504\)",
            r"addPersistentStoreWithType:.*returned error",
        )
        if any(re.search(pattern, line, re.IGNORECASE)
               for pattern in store_load_error_patterns for line in app_log_tail):
            raise ValueError("old-app log reports a persistent-store load failure")
        if not re.fullmatch(r"[0-9a-f]{64}", str(evidence.get("old_app_log_sha256", ""))):
            raise ValueError("old-app log hash is missing or malformed")
        if (evidence.get("dmg_sha256") != dmg_hash or
                evidence.get("old_app_manifest_sha256") != manifest_hash):
            raise ValueError("receipt does not bind the exact preserved 1.0.11 manifest and DMG")
        if (not isinstance(evidence.get("v12_family_sha256_before"), dict) or
                not evidence["v12_family_sha256_before"] or
                evidence.get("v12_family_sha256_before") != evidence.get("v12_family_sha256_after") or
                not isinstance(evidence.get("backup_family_sha256_before"), dict) or
                not evidence["backup_family_sha256_before"] or
                evidence.get("backup_family_sha256_before") != evidence.get("backup_family_sha256_after")):
            raise ValueError("V12/backup before-and-after family hashes do not match")
        for family_key in ("v12_family_sha256_before", "backup_family_sha256_before"):
            family_hashes = evidence[family_key]
            if any(not isinstance(name, str) or not name or
                   _safe_relative_path(name) is None or str(_safe_relative_path(name)) != name or
                   not re.fullmatch(r"[0-9a-f]{64}", str(digest))
                   for name, digest in family_hashes.items()):
                raise ValueError("SQLite family evidence contains an invalid member hash")
        fixture = receipt.get("fixture", {})
        ui_read = evidence.get("old_app_ui_semantic_read", {})
        expected_paper_id = fixture.get("paper_id")
        expected_paper_title = fixture.get("paper_title")
        visible_lines = ui_read.get("visible_match_lines") if isinstance(ui_read, dict) else None
        if (not isinstance(expected_paper_id, int) or isinstance(expected_paper_id, bool) or
                not isinstance(expected_paper_title, str) or not expected_paper_title.strip() or
                not isinstance(ui_read, dict) or
                ui_read.get("provider") != "orca-computer-use" or
                ui_read.get("bundle_id") != old_manifest.get("bundle_id") or
                ui_read.get("process_id") != app.get("process_id") or
                not isinstance(app.get("process_id"), int) or isinstance(app.get("process_id"), bool) or
                app.get("process_id") <= 0 or
                ui_read.get("paper_id") != expected_paper_id or
                ui_read.get("paper_title") != expected_paper_title or
                ui_read.get("title_visible") is not True or
                not re.fullmatch(r"[0-9a-f]{64}", str(ui_read.get("accessibility_tree_sha256", ""))) or
                not isinstance(visible_lines, list) or
                not any(isinstance(line, str) and expected_paper_title in line for line in visible_lines)):
            raise ValueError("old-app accessibility evidence does not prove the exact fixture paper was read")
        opened_values = evidence.get("opened_project_files", [])
        if not isinstance(opened_values, list):
            raise ValueError("process-opened path evidence is not an array")
        opened = set()
        for value in opened_values:
            relative = _safe_relative_path(value)
            if relative is None or str(relative) != value:
                raise ValueError("process-opened path evidence is not a normalized project-relative path")
            opened.add(value)
        legacy_path = fixture.get("legacy_store_relative")
        v12_path = fixture.get("active_v12_store_relative")
        legacy_relative = _safe_relative_path(legacy_path)
        v12_relative = _safe_relative_path(v12_path)
        v12_family_members = {v12_path, v12_path + "-wal", v12_path + "-shm"} if isinstance(v12_path, str) else set()
        opened_v12_members = {value for value in opened
                              if value in v12_family_members or
                              (isinstance(v12_path, str) and value.startswith(v12_path + "-"))}
        if (not isinstance(legacy_path, str) or not isinstance(v12_path, str) or
                legacy_relative is None or v12_relative is None or legacy_path == v12_path or
                legacy_path not in opened or v12_path in opened or
                opened_v12_members or
                fixture.get("source_schema_version") != 9 or
                fixture.get("active_schema_version") != 12 or
                fixture.get("backup_verified_before_and_after") is not True):
            raise ValueError("process-opened paths do not prove V9-only rollback compatibility")
        source_hashes = receipt.get("source_sha256")
        if (not isinstance(source_hashes, dict) or
                set(source_hashes) != set(G02_OLD_APP_SOURCE_INPUTS)):
            raise ValueError("receipt source hashes do not cover the exact G02 rollback inputs")
        for relative, expected_hash in source_hashes.items():
            source = root / relative
            if (not re.fullmatch(r"[0-9a-f]{64}", str(expected_hash)) or
                    not source.is_file() or source.is_symlink() or sha256_file(source) != expected_hash):
                raise ValueError("source input changed during old-app compatibility stage: " + relative)

        run_id = receipt.get("run_id")
        if not isinstance(run_id, str) or not re.fullmatch(r"[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}", run_id):
            raise ValueError("receipt run ID is not a generated UTC compatibility-drill identity")

        evidence_dir = root / "evidence"
        if evidence_dir.is_symlink() or not evidence_dir.is_dir():
            raise ValueError("project evidence directory is missing or symlinked")
        durable_path = evidence_dir / ("G02-OldAppRollback-" + run_id + ".json")
        if durable_path.exists() or durable_path.is_symlink():
            raise ValueError("refusing to overwrite an old-app rollback receipt")
        durable_path.write_bytes(receipt_bytes)
        return {"status": "PASS", "summary": receipt["summary"],
                "receipt_path": durable_path.relative_to(root).as_posix(),
                "receipt_sha256": sha256_file(durable_path), "validation_errors": []}
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        return {"status": "FAIL", "summary": "The old-app rollback receipt failed validation.",
                "receipt_path": None, "receipt_sha256": None,
                "validation_errors": [str(error)]}


G07_REQUIRED_CASES = (
    "testResearchBundleVerifyDryRunAndRestoreToNewTarget",
    "testResearchBundleTypedRestoreBuildsVerifiedV9StagingStoreWithoutActiveOverwrite",
    "testResearchBundleSchema5ImportsIntoV12TypedStagingStore",
    "testResearchBundleTypedRestoreHonorsPreCancelledImportWithoutCreatingTarget",
    "testResearchBundleTypedRestoreCancelsAfterStagingAndRemovesTargetFamily",
    "testResearchBundlePostStageFailuresRemoveNewStoreFamily",
    "testResearchBundleV10RoundTripsCategoryFormulaInventoryAndJobCheckpoint",
    "testResearchBundleSchema7OmitsEmptyAuditRecordCounts",
    "testV11WorkbenchRowsSurviveRelaunchAndRejectedCompareKeepsPriorMatrix",
)

G01_CATEGORY_REQUIRED_CASES = (
    "testFreshAuthorIndexAndClientDefaultsUseHepPhWithoutChangingLegacyProfile",
    "testCategoryProfileDefaultsLegacySelectionCanonicalIdentityAndCheckpointInvalidation",
    "testCategoryFacetsFilterWithoutMutatingEnabledProfile",
    "testEnabledAuthorFacetExcludesQualifiedAuthorsOnlyInDisabledCategories",
    "testDefaultFactoryKeepsLegacyCategorySelectionAndInvalidatesOnlyLegacyQuery",
    "testAuthorCandidatePaginationRefusesAnOverWindowPartitionInsteadOfSkippingItsRemainder",
    "testAuthorCandidatePaginationRejectsWrongCategoryCheckpointBeforeTransport",
    "testAuthorCandidateOpenEndedPartitionContinuesAboveLegacyRecidCeiling",
    "testAuthorCandidatePaginationRejectsAnOverWindowOpenEndedTail",
    "testAuthorCandidatePaginationStopsAtPartialLivePageAndAdvancesPartition",
    "testAuthorCandidatePaginationRejectsPersistedOverWindowPage41WithoutARequest",
    "testAuthorPaginationHTTP400RecoveryNeverDropsPartitionRange",
    "testHIndexThresholdIsStrictAndSelfIsAlwaysVisible",
    "testHIndexFallbackStopsBeforeINSPIREPage41HTTP400",
    "testHIndex429DoesNotTriggerExpensiveLocalFallback",
)
G01_UI_REQUIRED_CASES = (
    "testLargeFixtureAuthorAndPaperReachabilityKeepsSelectionAfterSearchReset",
    "testLargeFixtureCategoryFacetsSeparateHepPhMultiAndDisabledHepTh",
    "testLargeFixtureLaunchesAtAllThreeResponsiveAcceptanceSizes",
)

G03_FORMULA_REQUIRED_CASES = (
    "testFormulaInventoryParserFailsClosedForDuplicateLabelsMissingTexAndMalformedMarkup",
    "testFormulaInventoryParserRefusesMoreThanConfiguredEquationLimit",
    "testFormulaInventoryParserAcceptsZeroAndExactlyConfiguredEquationLimit",
    "testFormulaInventoryParserRejectsAmbiguousMathPairingAndHandlesQuotedGreaterThan",
    "testFormulaInventoryParserIgnoresRawTextMarkupAndHandlesVoidTags",
    "testFormulaInventoryParserPreservesMixedAnnotationOrderAndRejectsUnsupportedVisibleLabels",
    "testFormulaInventoryParserPairsNestedAlignRowsAndMultlineEquations",
    "testFormulaInventoryParserRequiresMathAndLabelToShareAnEquationRow",
    "testAllNumberedEquationWorkflowRejectsMissingOrAlteredFormulaWithoutSaving",
    "testNumberedFormulaRequiresTypedStepContractInsteadOfLegacyStrings",
    "testNumberedFormulaDerivationRequiresSourceBoundContinuousStepsAndConclusion",
    "testFormulaNumericProvenanceNormalizesTeXUnitCommandsAgainstSourceAnchor",
    "testFormulaCoverageValidatorRejectsDependencyCyclesAndAcceptsKnownAcyclicReferences",
    "testFormulaCoverageClaimHashBindsClaimTextStatusConclusionStepsAndAnchorPayload",
    "testV10FormulaInventoryReadRejectsTamperingAndKeepsIncompleteState",
)

G04_JOB_REQUIRED_CASES = (
    "testEvidenceAndVisionDeadlinesRejectOneRequestWithoutRetry",
    "testEvidenceProductionClientEnforcesConnectAndFirstContentDeadlines",
    "testEvidenceProductionClientCancelsActiveRequestWithoutRetryOrArtifact",
    "testEvidenceProductionFormulaRequestReceivesFiniteDeadlineAfterProseSucceeds",
    "testEvidenceProductionFormulaRequestCanBeCancelledWithoutRetryOrPublication",
    "testDeadlineReturnsBeforeSlowProviderTaskFinishes",
    "testEndpointPolicyAndSSEContract",
    "testAnalysisDeadlineEnforcerSeparatesConnectFirstContentIdleHardAndOversize",
    "testTransportHeartbeatCannotSatisfyFirstContentDeadline",
    "testTransportHeartbeatDoesNotRefreshDecodedContentIdleDeadline",
    "testAnalysisDeadlineEnforcerDropsLateCallbacksAndDoesNotRetry",
    "testFormulaBatchWorkflowPersistsSuccessfulBatchesAndResumesOnlyPending",
    "testFormulaJobCanOutlastFinitePerRequestDeadlineAcrossBatches",
    "testEvidenceArtifactSaveFailurePublishesCompletedFormulaJobWithoutProviderRetry",
    "testValidatedFormulaBatchesCanPublishAfterReceiptSaveFailureWithoutAnotherPOST",
    "testV10FormulaJobPersistsTypedRunAttemptsAndValidationReceiptAtomically",
    "testV10FormulaJobReadsMutableStateFromTypedRowsAndRejectsDamagedProjection",
)
G04_RELAUNCH_UI_REQUIRED_CASES = (
    "testDiskBackedFormulaJobResumesFromTypedCheckpointAfterQuitAndRelaunch",
)

G05_DERIVATION_REQUIRED_CASES = (
    "testFormulaStepStructureChecksBasicTeXGroupsAndMarksUnknownMacrosManual",
    "testNumberedFormulaRequiresTypedStepContractInsteadOfLegacyStrings",
    "testNumberedFormulaDerivationRequiresSourceBoundContinuousStepsAndConclusion",
    "testFormulaNumericProvenanceNormalizesTeXUnitCommandsAgainstSourceAnchor",
    "testFormulaCoverageValidatorRejectsDependencyCyclesAndAcceptsKnownAcyclicReferences",
    "testFormulaCoverageClaimHashBindsClaimTextStatusConclusionStepsAndAnchorPayload",
)

G06_UI_REQUIRED_CASES = (
    "testXCUITestOutputRootsAreExplicitlyProjectLocal",
    "testLargeFixtureAuthorAndPaperReachabilityKeepsSelectionAfterSearchReset",
    "testLargeFixtureCategoryFacetsSeparateHepPhMultiAndDisabledHepTh",
    "testLargeFixtureLaunchesAtAllThreeResponsiveAcceptanceSizes",
    "testDiskBackedLargeFixturePreservesSavedNoteAcrossQuitAndRelaunch",
    "testLargeFixtureSettingsKeepsModelsAndTerminologyReachableInDraft",
    "testLargeFixtureModelSelectorKeepsCurrentModelWhileSearching",
    "testLargeFixtureTagAndCollectionManagersSearchAndCancelWithoutWrite",
    "testSettingsWorkflowIsKeyboardDiscoverable",
    "testFixtureAuthorSearchPaperSelectionAndFiveTabs",
    "testFixtureAnalysisCancellationCacheAndFigureDegradation",
    "testFixtureReferenceManagerControlsAreKeyboardDiscoverable",
    "testFixtureFullTextScopeAndAnchorJumpStayLocal",
    "testFixtureCaptionOnlyAndVisionDisclosureRemainSeparate",
    "testFixtureVisionMaximumZeroDisablesPixelsAndFrozenDisclosureIsSpecific",
    "testFixtureResearchHomeUsesLocalSnapshotCounts",
    "testFixtureWorkbenchEntryShowsGraphPreview",
    "testFixtureSyncCenterExposesDurableLocalJobSummary",
    "testFixtureUnifiedLocalSearchShowsProvenanceWithoutProviderRequest",
    "testFixtureReadAndFavoriteControlsPerformVisibleLocalMutation",
    "testFixtureReferenceNoteAndTagControlsMutateOnlyFixtureStore",
    "testFixtureRadarQueryCanBeSavedAndPausedThroughOwnedJobPath",
    "testFixtureNotebookShowsExactAnchorAnnotationAfterLocalPDFExtraction",
    "testFixtureNotebookCreatesVisibleMultiAnchorEntryOnlyAfterExplicitSave",
    "testFixtureSharedPDFDeleteIsPaperScopedAndRemainingAnchorOpens",
    "testFixtureEvidenceInsightStartsOnlyAfterLocalPDFAnchorExists",
    "testFixtureEvidenceInsightCompletesWhenProviderUsesScalarResearchQuestion",
    "testFixtureArxivHTMLFormulaDerivationCompletesWithCurrentPayloadAnchors",
    "testFixtureCompareCreatesExtractsAndJumpsToExactSharedPDFAnchor",
    "testFixtureModelDiscoveryUsesInProcessSubstitute",
    "testFixtureGlobalSearchAndSmartFilterAreAccessibleControls",
)


def required_case_evidence(log_text, required_case_names):
    observed = {name: [] for name in required_case_names}
    pattern = re.compile(r"Test Case '-\[[^\]]+ (test[A-Za-z0-9_]+)\]' (passed|failed|skipped)")
    for match in pattern.finditer(log_text):
        name, result = match.groups()
        if name in observed:
            observed[name].append(result)

    cases = []
    for name in required_case_names:
        results = observed[name]
        if results == ["passed"]:
            status = "PASS"
        elif not results:
            status = "NOT_RUN"
        elif "failed" in results:
            status = "FAIL"
        elif "skipped" in results:
            status = "SKIPPED"
        else:
            status = "DUPLICATE_OR_INCONSISTENT"
        cases.append({"test": name, "status": status, "observed_results": results})
    return {
        "all_required_passed": all(item["status"] == "PASS" for item in cases),
        "has_failure_or_skip": any(item["status"] in (
            "FAIL", "SKIPPED", "DUPLICATE_OR_INCONSISTENT") for item in cases),
        "cases": cases,
    }


def combine_case_evidence(*evidence_groups):
    cases = [case for group in evidence_groups for case in group.get("cases", [])]
    return {
        "all_required_passed": bool(cases) and all(case.get("status") == "PASS" for case in cases),
        "has_failure_or_skip": any(case.get("status") in (
            "FAIL", "SKIPPED", "DUPLICATE_OR_INCONSISTENT") for case in cases),
        "cases": cases,
    }


def g01_gate_summary(category_evidence, ui_evidence):
    """Describe the required local G01 evidence without promoting optional live coverage."""
    category_status = "PASS" if category_evidence.get("all_required_passed") else "incomplete"
    ui_status = "PASS" if ui_evidence.get("all_required_passed") else "incomplete"
    return ("Category/pagination contract cases: " + category_status +
            "; responsive XCUITest cases: " + ui_status +
            ". Live INSPIRE completeness is optional and is not inferred from local fixtures.")


def required_case_gate_status(evidence, prerequisite_status="PASS"):
    """Map current-run case evidence to a fail-closed gate disposition."""
    if prerequisite_status == "FAIL" or evidence.get("has_failure_or_skip"):
        return "FAIL"
    if prerequisite_status == "BLOCKED":
        return "BLOCKED"
    if prerequisite_status != "PASS" or not evidence.get("all_required_passed"):
        return "PARTIAL"
    return "PASS"


def resolve_scoped_regular_file(relative_value, allowed_root, description):
    """Lexically allowlist and contain a project-relative file before reading it."""
    if (not isinstance(relative_value, str) or not relative_value or
            "\\" in relative_value or "\x00" in relative_value):
        return None, description + " path must be a non-empty POSIX relative path."
    relative = PurePosixPath(relative_value)
    if (relative.is_absolute() or relative.as_posix() != relative_value or
            any(part in ("", ".", "..") for part in relative.parts)):
        return None, description + " path is not a canonical project-relative path."

    try:
        candidate = ROOT.joinpath(*relative.parts)
        allowed = Path(allowed_root).resolve(strict=False)
        resolved = candidate.resolve(strict=False)
    except (OSError, RuntimeError, ValueError) as error:
        return None, description + " path could not be safely resolved: " + str(error)
    if resolved == allowed or not resolved.is_relative_to(allowed):
        return None, description + " path escapes its allowlisted project directory."

    current = ROOT
    for part in relative.parts:
        current = current / part
        try:
            mode = current.lstat().st_mode
        except OSError as error:
            return None, description + " file is unavailable: " + str(error)
        if stat.S_ISLNK(mode):
            return None, description + " path contains a symbolic link."
    try:
        mode = candidate.lstat().st_mode
    except OSError as error:
        return None, description + " file is unavailable: " + str(error)
    if not stat.S_ISREG(mode):
        return None, description + " path is not a regular file."
    return candidate, None


def g07_required_case_evidence(log_text):
    observed = {name: [] for name in G07_REQUIRED_CASES}
    pattern = re.compile(r"Test Case '-\[[^\]]+ (test[A-Za-z0-9_]+)\]' (passed|failed|skipped)")
    for match in pattern.finditer(log_text):
        name, result = match.groups()
        if name in observed:
            observed[name].append(result)

    cases = []
    for name in G07_REQUIRED_CASES:
        results = observed[name]
        if len(results) == 1 and results[0] == "passed":
            status = "PASS"
        elif not results:
            status = "NOT_RUN"
        elif "failed" in results:
            status = "FAIL"
        elif "skipped" in results:
            status = "SKIPPED"
        else:
            status = "DUPLICATE_OR_INCONSISTENT"
        cases.append({"test": name, "status": status, "observed_results": results})

    all_required_passed = all(case["status"] == "PASS" for case in cases)
    if all_required_passed:
        summary = (
            "The current SwiftPM run passed schema-7 typed inventory/job/claim/validation-report and "
            "analysis-run/attempt round-trip, schema-5 import into V12 staging, existing-target and "
            "tampered-report rejection before staging, and pre-stage and mid-stage cancellation checks. "
            "Injected post-stage failures at store-open, library-materialization, search-index, "
            "typed-state, and semantic-comparison checkpoints all removed the exact new SQLite family "
            "without changing Bundle bytes. "
            "The disk-backed V12 Radar/Compare/Notebook/Search regression also verifies row persistence "
            "across reopen and preservation of the prior Compare matrix after rejection. G07 remains "
            "PARTIAL: interactive Bundle UI/relaunch acceptance is not certified."
        )
    else:
        summary = (
            "Required Bundle/workbench regressions are missing or non-passing in this SwiftPM run; see "
            "case_results. G07 cannot be accepted. Full post-stage rollback fault coverage and "
            "interactive UI/relaunch acceptance also remain uncertified."
        )
    return {"all_required_passed": all_required_passed, "cases": cases, "summary": summary}


def validate_v10_to_v12_migration_receipt(path, expected_manifest_hash):
    if not path.is_file():
        return None, ["The V10-to-V12 disposable migration test did not write its receipt."]
    try:
        encoded = path.read_bytes()
        receipt = json.loads(encoded.decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        return None, ["The V10-to-V12 disposable migration receipt is unreadable: " + str(error)]

    errors = []
    if receipt.get("schemaVersion") != "latticelens-v10-disposable-migration-drill-v5":
        errors.append("Unexpected V10-to-V12 disposable migration receipt schema.")
    if receipt.get("sourceOrigin") != "synthetic_generated":
        errors.append("The V10 migration drill did not identify its source as generated synthetic data.")
    if receipt.get("inputManifestSHA256") != expected_manifest_hash:
        errors.append("The V10 migration receipt is not bound to the verifier's frozen input manifest.")
    if str(ROOT.resolve()) in encoded.decode("utf-8", errors="replace"):
        errors.append("The sanitized V10 migration receipt contains a project-absolute path.")

    success = receipt.get("successfulMigration")
    if not isinstance(success, dict):
        errors.append("The V10 migration receipt is missing its success leg.")
        success = {}
    for key in ("backupVerified", "semanticReconciliationPassed", "sourceFamilyUnchanged"):
        if success.get(key) is not True:
            errors.append("The V10 success leg did not confirm " + key + ".")
    if (success.get("sourceSchemaVersion") != 10 or success.get("targetSchemaVersion") != 12 or
            success.get("journalPhase") != "activated" or success.get("descriptorSchemaVersion") != 12):
        errors.append("The success leg did not activate a verified V10-to-V12 descriptor.")
    source_counts = success.get("sourceRecordCounts")
    target_counts = success.get("targetRecordCounts")
    def valid_record_counts(value):
        return (isinstance(value, dict) and
                all(isinstance(key, str) and isinstance(count, int) and not isinstance(count, bool) and count >= 0
                    for key, count in value.items()))

    if not valid_record_counts(source_counts) or not valid_record_counts(target_counts):
        errors.append("The V10/V12 semantic record counts are missing or malformed.")
        source_counts = {}
        target_counts = {}
    legacy_checkpoint_count = success.get("legacyCategoryCheckpointCount")
    source_invalidation_count = success.get("sourceLegacyCheckpointInvalidationCount")
    target_invalidation_count = success.get("targetLegacyCheckpointInvalidationCount")
    if (isinstance(legacy_checkpoint_count, bool) or not isinstance(legacy_checkpoint_count, int) or
            legacy_checkpoint_count < 0):
        errors.append("The V10 migration receipt has no valid legacy checkpoint count.")
        legacy_checkpoint_count = 0
    for field_name, value in (("source", source_invalidation_count), ("target", target_invalidation_count)):
        if value is not None and (isinstance(value, bool) or not isinstance(value, int) or value < 0):
            errors.append("The migration receipt has an invalid " + field_name + " checkpoint invalidation count.")
            if field_name == "source":
                source_invalidation_count = None
            else:
                target_invalidation_count = None
    expected_count_delta = {}
    if source_invalidation_count is not None:
        if (isinstance(source_invalidation_count, bool) or not isinstance(source_invalidation_count, int) or
                target_invalidation_count != source_invalidation_count):
            errors.append("The migration changed an existing legacy checkpoint invalidation marker.")
    elif legacy_checkpoint_count > 0:
        if target_invalidation_count != legacy_checkpoint_count:
            errors.append("The migration did not add the expected legacy checkpoint invalidation marker.")
        expected_count_delta = {"typed.searchIndexStates": 1}
    elif target_invalidation_count is not None:
        errors.append("The migration added a legacy checkpoint invalidation marker without legacy checkpoints.")
    actual_count_delta = {
        key: target_counts.get(key, 0) - source_counts.get(key, 0)
        for key in set(source_counts).union(target_counts)
        if target_counts.get(key, 0) != source_counts.get(key, 0)
    }
    if actual_count_delta != expected_count_delta:
        errors.append("V10/V12 record-count changes exceed the declared derived invalidation marker.")
    source_stable_hash = success.get("sourceStableIDHash")
    target_stable_hash = success.get("targetStableIDHash")
    descriptor_semantic_hash = success.get("descriptorSemanticHash")
    if (not isinstance(source_stable_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", source_stable_hash) or
            not isinstance(target_stable_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", target_stable_hash) or
            descriptor_semantic_hash != target_stable_hash):
        errors.append("The activated V12 descriptor hash does not match its reconciled target summary.")
    if not success.get("sourceFamilyHashes"):
        errors.append("The success leg did not record the original SQLite source-family hashes.")
    if (success.get("sourceLibraryHashFormatVersion") != CURRENT_CANONICAL_LIBRARY_HASH_FORMAT_VERSION or
            success.get("targetLibraryHashFormatVersion") != CURRENT_CANONICAL_LIBRARY_HASH_FORMAT_VERSION):
        errors.append("The V10 migration was not reconciled with the current canonical library-hash format.")

    post_activation_restore = receipt.get("postActivationRestore")
    if not isinstance(post_activation_restore, dict):
        errors.append("The V10 migration receipt is missing its post-activation restore leg.")
        post_activation_restore = {}
    for key in ("restoreTargetWasAbsent", "backupVerified", "restoredFamilyMatchesManifest",
                "semanticReconciliationPassed", "productionStoreOpenPassed"):
        if post_activation_restore.get(key) is not True:
            errors.append("The post-activation restore leg did not confirm " + key + ".")
    if (post_activation_restore.get("sourceSchemaVersion") != 10 or
            post_activation_restore.get("restoredSchemaVersion") != 10 or
            post_activation_restore.get("productionSchemaVersion") != 12 or
            post_activation_restore.get("productionMigrationPhase") != "activated"):
        errors.append("The post-activation restore did not reopen V10 and reactivate it through the production V12 path.")
    if post_activation_restore.get("backupManifestHash") != success.get("backupManifestHash"):
        errors.append("The post-activation restore did not use the verified pre-migration backup from the success leg.")
    if (post_activation_restore.get("sourceRecordCounts") != source_counts or
            post_activation_restore.get("restoredRecordCounts") != source_counts or
            post_activation_restore.get("productionRecordCounts") != target_counts):
        errors.append("The post-activation restore did not recover the V10 source and reconciled V12 target counts.")
    production_stable_hash = post_activation_restore.get("productionStableIDHash")
    production_descriptor_hash = post_activation_restore.get("productionDescriptorSemanticHash")
    if (post_activation_restore.get("sourceStableIDHash") != source_stable_hash or
            post_activation_restore.get("restoredStableIDHash") != source_stable_hash or
            not isinstance(production_stable_hash, str) or
            not re.fullmatch(r"[0-9a-f]{64}", production_stable_hash) or
            production_descriptor_hash != production_stable_hash):
        errors.append("The post-activation restore did not bind its V10 source and restored V12 descriptor hashes.")
    if (post_activation_restore.get("sourceLibraryHashFormatVersion") != CURRENT_CANONICAL_LIBRARY_HASH_FORMAT_VERSION or
            post_activation_restore.get("restoredLibraryHashFormatVersion") != CURRENT_CANONICAL_LIBRARY_HASH_FORMAT_VERSION or
            post_activation_restore.get("productionLibraryHashFormatVersion") != CURRENT_CANONICAL_LIBRARY_HASH_FORMAT_VERSION):
        errors.append("The post-activation restore lacks the current canonical semantic hash format.")
    if (not post_activation_restore.get("restoredFamilyHashes") or
            post_activation_restore.get("restoredFamilyHashes") != success.get("sourceFamilyHashes")):
        errors.append("The restored SQLite family does not match the original pre-migration family hashes.")

    rollback = receipt.get("rollback")
    if not isinstance(rollback, dict):
        errors.append("The V10 migration receipt is missing its rollback leg.")
        rollback = {}
    for key in ("backupVerified", "sourceFamilyUnchanged", "sourceSemanticUnchanged",
                "activeDescriptorAbsent", "stagingRemoved"):
        if rollback.get(key) is not True:
            errors.append("The V10 rollback leg did not confirm " + key + ".")
    if (rollback.get("sourceSchemaVersion") != 10 or rollback.get("targetSchemaVersion") != 12 or
            rollback.get("journalPhaseBeforeRecovery") != "verified" or
            rollback.get("recoveredJournalPhase") != "rolledBack"):
        errors.append("The V10 rollback leg did not recover a verified, pre-activation migration.")
    if (not isinstance(rollback.get("sourceStableIDHash"), str) or
            rollback.get("sourceStableIDHash") != rollback.get("recoveredSourceStableIDHash") or
            not rollback.get("sourceFamilyHashes")):
        errors.append("The V10 rollback source identity or family hashes changed.")
    if (rollback.get("sourceLibraryHashFormatVersion") != CURRENT_CANONICAL_LIBRARY_HASH_FORMAT_VERSION or
            rollback.get("recoveredLibraryHashFormatVersion") != CURRENT_CANONICAL_LIBRARY_HASH_FORMAT_VERSION):
        errors.append("The rollback leg did not preserve a canonical library semantic summary.")
    return receipt, errors


def validate_v12_performance_report(path, expected_manifest_hash):
    if not path.is_file():
        return None, ["The V12 benchmark did not write its machine-readable result."]
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return None, ["The V12 benchmark report is unreadable: " + str(error)]

    errors = []
    if value.get("schema_version") != "latticelens-benchmark-v12-formula":
        errors.append("Unexpected V12 benchmark report schema.")
    if value.get("persistence_schema_version") != 12:
        errors.append("The performance workload did not open the current V12 persistence schema.")
    if value.get("input_manifest_sha256") != expected_manifest_hash:
        errors.append("The benchmark report is not bound to this run's frozen input manifest.")
    build = value.get("build", {})
    if not isinstance(build, dict):
        build = {}
        errors.append("The benchmark build identity is missing or malformed.")
    if build.get("configuration") != "SwiftPM-debug-XCTest" or build.get("product_version") != "2.0.0" or build.get("build_number") != 201:
        errors.append("The benchmark build identity does not match the current 2.0.0 (201) fixture build.")
    machine = value.get("machine", {})
    if not isinstance(machine, dict) or not isinstance(machine.get("architecture"), str) or not machine.get("operating_system"):
        errors.append("The benchmark is missing its machine architecture or operating-system identity.")
    declared_thresholds = value.get("thresholds_ms", {})
    expected_thresholds = {"cold_reopen_p95": 5_000, "warm_search_p95": 250,
                           "read_mutation_p95": 100, "favorite_mutation_p95": 100,
                           "note_mutation_p95": 100}
    if declared_thresholds != expected_thresholds:
        errors.append("The benchmark's declared thresholds differ from the v5/final acceptance values.")

    dataset = value.get("dataset", {})
    if not isinstance(dataset, dict):
        dataset = {}
        errors.append("The benchmark dataset summary is missing or malformed.")
    required_dataset = {
        "authors": 2_000, "papers": 20_000, "paper_author_links": 100_000,
        "evidence_chunks": 10_000, "radar_events": 500,
        "formula_inventories": 20, "formulas": 5_000, "formulas_per_inventory": 250,
    }
    for key, expected in required_dataset.items():
        if dataset.get(key) != expected:
            errors.append("Dataset cardinality mismatch for " + key + ".")

    measurements = value.get("measurements", {})
    if not isinstance(measurements, dict):
        measurements = {}
        errors.append("The benchmark measurements section is missing or malformed.")
    requirements = {
        "cold_reopen": (20, 5_000),
        "warm_search": (100, 250),
        "read_mutation": (100, 100),
        "favorite_mutation": (100, 100),
        "note_mutation": (100, 100),
        "formula_inventory_read": (100, None),
        "formula_job_read": (100, None),
        "formula_job_checkpoint_commit": (100, None),
    }
    recomputed = {}
    for name, (required_count, threshold) in requirements.items():
        result = measurements.get(name)
        if not isinstance(result, dict):
            errors.append("Missing measurement series: " + name + ".")
            continue
        samples = result.get("samples_ms")
        if not isinstance(samples, list) or len(samples) != required_count or any(
                isinstance(sample, bool) or not isinstance(sample, int) or sample < 0 for sample in samples):
            errors.append("Invalid sample count or value for " + name + ".")
            continue
        p95 = sorted(samples)[min(len(samples) - 1, math.ceil((len(samples) - 1) * 0.95))]
        recomputed[name] = p95
        if result.get("p95_ms") != p95:
            errors.append("Reported p95 does not match raw samples for " + name + ".")
        if threshold is not None and p95 > threshold:
            errors.append(name + " p95 is " + str(p95) + " ms; threshold is " + str(threshold) + " ms.")
    warm_search = measurements.get("warm_search", {})
    if not isinstance(warm_search, dict) or warm_search.get("result_count") != 100:
        errors.append("Warm search did not return the required bounded 100-paper result set.")
    formula_inventory_read = measurements.get("formula_inventory_read", {})
    if not isinstance(formula_inventory_read, dict) or formula_inventory_read.get("items_per_result") != 250:
        errors.append("Formula inventory query did not validate all 250 items per result.")
    formula_job_read = measurements.get("formula_job_read", {})
    if (not isinstance(formula_job_read, dict) or formula_job_read.get("claims_per_result") != 8 or
            formula_job_read.get("structured_steps_per_result") != 8 or
            formula_job_read.get("segments_per_result") != 8 or
            formula_job_read.get("segment_steps_per_result") != 8):
        errors.append("Formula-job reads did not reconstruct the V12 typed claim, step, and segment rows.")

    formula = value.get("formula_work", {})
    if not isinstance(formula, dict):
        formula = {}
        errors.append("The formula-work summary is missing or malformed.")
    if formula.get("html_parse_sample_count") != 20 or formula.get("inventory_write_sample_count") != 20:
        errors.append("Expected one formula parse and inventory-write sample per synthetic paper.")
    if formula.get("batch_plan_sample_count") != 20 or formula.get("total_batch_plans") != 640 or formula.get("batches_per_inventory") != [32] * 20:
        errors.append("Formula batch-plan coverage does not match 20 inventories of 250 equations at batch size 8.")
    if formula.get("merge_validation_sample_count") != 20:
        errors.append("Synthetic source-coverage validation was not measured for each inventory.")
    for count_key, samples_key, required_count in (
            ("html_parse_sample_count", "html_parse_samples_ms", 20),
            ("inventory_write_sample_count", "inventory_write_samples_ms", 20),
            ("batch_plan_sample_count", "batch_plan_samples_ms", 20),
            ("merge_validation_sample_count", "merge_validation_samples_ms", 20)):
        samples = formula.get(samples_key)
        if formula.get(count_key) != required_count or not isinstance(samples, list) or len(samples) != required_count or any(
                isinstance(sample, bool) or not isinstance(sample, int) or sample < 0 for sample in samples):
            errors.append("Invalid formula-resource sample set: " + samples_key + ".")
            continue
        p95_key = {"html_parse_samples_ms": "html_parse_p95_ms",
                   "inventory_write_samples_ms": "inventory_write_p95_ms",
                   "batch_plan_samples_ms": "batch_plan_p95_ms",
                   "merge_validation_samples_ms": "merge_validation_p95_ms"}[samples_key]
        expected_p95 = sorted(samples)[min(required_count - 1, math.ceil((required_count - 1) * 0.95))]
        if formula.get(p95_key) != expected_p95:
            errors.append("Reported formula-resource p95 does not match raw samples for " + samples_key + ".")

    storage = value.get("storage", {})
    if not isinstance(storage, dict):
        storage = {}
        errors.append("The storage summary is missing or malformed.")
    if storage.get("disk_backed") is not True or storage.get("backup_verified") is not True:
        errors.append("The benchmark store is not confirmed disk-backed with a verified synthetic backup.")
    for key, expected in (("formula_inventory_rows", 20), ("formula_item_rows", 5_000),
                          ("formula_job_rows", 1), ("formula_claim_rows", 8),
                          ("formula_structured_step_rows", 8), ("formula_segment_rows", 8),
                          ("formula_segment_step_rows", 8), ("batch_checkpoint_rows", 32)):
        if storage.get(key) != expected:
            errors.append("Stored row count mismatch for " + key + ".")
    for key in ("store_family_bytes", "search_index_token_rows", "search_index_payload_bytes",
                "formula_inventory_payload_bytes", "formula_item_payload_bytes"):
        number = storage.get(key)
        if isinstance(number, bool) or not isinstance(number, int) or number <= 0:
            errors.append("Missing or invalid storage measurement: " + key + ".")

    work = value.get("row_commit_encode_work", {})
    if not isinstance(work, dict):
        work = {}
        errors.append("The row/commit/encode workload record is missing or malformed.")
    job_work = work.get("formula_job_checkpoint_mutation", {})
    if not isinstance(job_work, dict) or any(job_work.get(key) != expected for key, expected in (
            ("samples", 100), ("job_rows_visited_per_commit", 1),
            ("canonical_claim_rows_touched_per_commit", 8),
            ("canonical_structured_step_rows_touched_per_commit", 8),
            ("canonical_segment_rows_visited_per_commit", 8),
            ("canonical_segment_step_rows_visited_per_commit", 8),
            ("batch_checkpoint_rows_visited_per_commit", 32),
            ("context_save_calls_per_commit", 1))):
        errors.append("The formula-job mutation row-family workload does not match the exercised V12 repository path.")

    rss = value.get("rss", {})
    if not isinstance(rss, dict):
        rss = {}
        errors.append("The RSS summary is missing or malformed.")
    if not isinstance(rss.get("process_peak_bytes"), int) or rss["process_peak_bytes"] <= 0:
        errors.append("Dedicated-process RSS high-water mark is unavailable.")
    if not isinstance(value.get("total_wall_ms"), int) or value["total_wall_ms"] <= 0:
        errors.append("Total benchmark wall time is unavailable.")
    return {"report": value, "recomputed_p95_ms": recomputed, "errors": errors}, errors


PHYSICS_REVIEW_FIELDS = (
    "action", "ensemble_parameters", "lattice_spacing_and_volume", "pion_mass",
    "momentum", "source_sink", "operator", "euclidean_sign", "scheme_scale",
    "fourier_normalization", "matching", "statistical_systematic_errors",
    "formula_dependencies",
)
PHYSICS_REVIEW_STATUSES = {"direct", "inference", "missing", "needs_manual", "not_applicable"}
VOICEOVER_REVIEW_FIELDS = (
    "self_h_index_category", "formula_labels_and_coverage", "derivation_step_sources",
    "pdf_page", "compare_cell", "preflight_disclosure",
)
VOICEOVER_WINDOW_SIZES = {"820x640", "1280x820", "1440x900"}


def validate_manual_acceptance(expected_manifest_hash):
    """Accept only explicit human receipts tied to this frozen source manifest."""
    if not MANUAL_ACCEPTANCE_PATH.exists():
        return [
            {"scope": "three-paper physics review", "status": "NOT_RUN",
             "reason": "No human physics-review receipt was supplied.",
             "receipt_path": MANUAL_ACCEPTANCE_PATH.relative_to(ROOT).as_posix()},
            {"scope": "VoiceOver and responsive UI review", "status": "NOT_RUN",
             "reason": "No human VoiceOver receipt was supplied.",
             "receipt_path": MANUAL_ACCEPTANCE_PATH.relative_to(ROOT).as_posix()},
        ]
    if MANUAL_ACCEPTANCE_PATH.is_symlink() or not MANUAL_ACCEPTANCE_PATH.is_file():
        return [
            {"scope": "three-paper physics review", "status": "FAIL",
             "reason": "Manual receipt path is not a regular, non-symlink file."},
            {"scope": "VoiceOver and responsive UI review", "status": "FAIL",
             "reason": "Manual receipt path is not a regular, non-symlink file."},
        ]
    try:
        receipt = json.loads(MANUAL_ACCEPTANCE_PATH.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        return [
            {"scope": "three-paper physics review", "status": "FAIL",
             "reason": "Manual receipt is unreadable: " + str(error)},
            {"scope": "VoiceOver and responsive UI review", "status": "FAIL",
             "reason": "Manual receipt is unreadable: " + str(error)},
        ]

    receipt_hash = sha256_file(MANUAL_ACCEPTANCE_PATH)
    if (not isinstance(receipt, dict) or
            receipt.get("schema_version") != "latticelens-manual-acceptance-v1"):
        reason = "Manual receipt schema version is missing or unsupported."
        return [
            {"scope": "three-paper physics review", "status": "FAIL", "reason": reason,
             "receipt_path": MANUAL_ACCEPTANCE_PATH.relative_to(ROOT).as_posix(),
             "receipt_sha256": receipt_hash},
            {"scope": "VoiceOver and responsive UI review", "status": "FAIL", "reason": reason,
             "receipt_path": MANUAL_ACCEPTANCE_PATH.relative_to(ROOT).as_posix(),
             "receipt_sha256": receipt_hash},
        ]

    def valid_date(value):
        if not isinstance(value, str) or not value.strip():
            return False
        try:
            datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
            return True
        except ValueError:
            return False

    physics_errors = []
    physics_reviews = receipt.get("physics_reviews")
    if not isinstance(physics_reviews, list) or len(physics_reviews) != 3:
        physics_errors.append("Exactly three per-paper human review records are required.")
        physics_reviews = []
    categories = []
    paper_ids = set()
    for index, item in enumerate(physics_reviews, 1):
        if not isinstance(item, dict):
            physics_errors.append("Physics review record " + str(index) + " is malformed.")
            continue
        paper_id = item.get("paper_id")
        category = item.get("category")
        if not isinstance(paper_id, str) or not paper_id.strip() or paper_id in paper_ids:
            physics_errors.append("Physics review paper IDs must be non-empty and unique.")
        paper_ids.add(paper_id if isinstance(paper_id, str) else "")
        if category not in ("hep-lat", "hep-ph"):
            physics_errors.append("Physics review category must be hep-lat or hep-ph.")
        else:
            categories.append(category)
        allowed_source_root = ROOT / "Tests" / "LatticeLensTests" / "Fixtures" / "PhysicsReviews"
        source, source_error = resolve_scoped_regular_file(
            item.get("source_path"), allowed_source_root,
            "Physics review source")
        if source_error:
            physics_errors.append("Each reviewed paper must resolve to a regular project-local PhysicsReviews fixture: " + source_error)
        elif item.get("source_sha256") != sha256_file(source):
            physics_errors.append("Physics review source hash does not match its fixed fixture.")
        if (item.get("status") != "reviewed_with_receipt" or
                not isinstance(item.get("source_version"), str) or not item.get("source_version", "").strip()):
            physics_errors.append("Each paper review needs a fixed source version and reviewed_with_receipt status.")
        if not isinstance(item.get("reviewer"), str) or not item.get("reviewer", "").strip():
            physics_errors.append("Each paper review needs a named human reviewer.")
        if not valid_date(item.get("reviewed_at_utc")):
            physics_errors.append("Each paper review needs an ISO-8601 review timestamp.")
        if item.get("input_manifest_sha256") != expected_manifest_hash:
            physics_errors.append("A paper review is not bound to the current frozen input manifest.")
        rubric = item.get("rubric")
        if not isinstance(rubric, dict):
            physics_errors.append("Each paper review needs the complete physics convention rubric.")
        else:
            for field in PHYSICS_REVIEW_FIELDS:
                entry = rubric.get(field)
                if (not isinstance(entry, dict) or entry.get("status") not in PHYSICS_REVIEW_STATUSES or
                        not isinstance(entry.get("note"), str) or not entry.get("note", "").strip()):
                    physics_errors.append("Physics rubric field is missing a status/note: " + field)
    if categories.count("hep-lat") < 2 or categories.count("hep-ph") < 1:
        physics_errors.append("Human review scope must include at least two hep-lat and one hep-ph paper.")
    if receipt.get("input_manifest_sha256") != expected_manifest_hash:
        physics_errors.append("Manual receipt is not bound to the current frozen input manifest.")
    physics_status = "PASS" if not physics_errors else (
        "NOT_RUN" if not physics_reviews and not receipt.get("input_manifest_sha256") else "FAIL")

    voiceover_errors = []
    voiceover = receipt.get("voiceover_review")
    if not isinstance(voiceover, dict):
        voiceover_errors.append("VoiceOver review record is missing.")
        voiceover = {}
    if voiceover.get("input_manifest_sha256") != expected_manifest_hash:
        voiceover_errors.append("VoiceOver review is not bound to the current frozen input manifest.")
    if not isinstance(voiceover.get("reviewer"), str) or not voiceover.get("reviewer", "").strip():
        voiceover_errors.append("VoiceOver review needs a named human reviewer.")
    if not valid_date(voiceover.get("reviewed_at_utc")):
        voiceover_errors.append("VoiceOver review needs an ISO-8601 review timestamp.")
    checks = voiceover.get("checks")
    if not isinstance(checks, dict):
        voiceover_errors.append("VoiceOver review needs per-surface observations.")
    else:
        for field in VOICEOVER_REVIEW_FIELDS:
            item = checks.get(field)
            if (not isinstance(item, dict) or item.get("status") != "PASS" or
                    not isinstance(item.get("observation"), str) or not item.get("observation", "").strip()):
                voiceover_errors.append("VoiceOver observation is missing or non-passing: " + field)
    window_sizes = voiceover.get("window_sizes")
    if (not isinstance(window_sizes, list) or
            any(not isinstance(size, str) for size in window_sizes) or
            set(window_sizes) != VOICEOVER_WINDOW_SIZES):
        voiceover_errors.append("VoiceOver screenshots must cover 820x640, 1280x820, and 1440x900.")
    screenshots = voiceover.get("screenshots")
    if not isinstance(screenshots, list) or len(screenshots) != 3:
        voiceover_errors.append("Three hash-bound manual screenshots are required.")
    else:
        observed_sizes = set()
        for screenshot in screenshots:
            if not isinstance(screenshot, dict):
                voiceover_errors.append("A manual screenshot record is malformed.")
                continue
            size = screenshot.get("window_size")
            if not isinstance(size, str) or size not in VOICEOVER_WINDOW_SIZES:
                voiceover_errors.append("A manual screenshot has an unsupported or malformed window size.")
            screenshot_path, screenshot_error = resolve_scoped_regular_file(
                screenshot.get("path"), ROOT / "evidence", "Manual screenshot")
            if screenshot_error:
                voiceover_errors.append("Manual screenshots must be regular files under project evidence/: " + screenshot_error)
            elif screenshot.get("sha256") != sha256_file(screenshot_path):
                voiceover_errors.append("A manual screenshot hash does not match its file.")
            if isinstance(size, str) and size in VOICEOVER_WINDOW_SIZES:
                observed_sizes.add(size)
        if observed_sizes != VOICEOVER_WINDOW_SIZES:
            voiceover_errors.append("Manual screenshots do not cover the required three window sizes.")
    voiceover_status = "PASS" if not voiceover_errors else (
        "NOT_RUN" if not voiceover.get("input_manifest_sha256") and
        voiceover.get("status") == "NOT_RUN" else "FAIL")

    path_value = MANUAL_ACCEPTANCE_PATH.relative_to(ROOT).as_posix()
    return [
        {"scope": "three-paper physics review", "status": physics_status,
         "reason": "; ".join(physics_errors) if physics_errors else "Three source-bound human physics reviews passed.",
         "receipt_path": path_value, "receipt_sha256": receipt_hash,
         "review_count": len(physics_reviews),
         "paper_categories": categories},
        {"scope": "VoiceOver and responsive UI review", "status": voiceover_status,
         "reason": "; ".join(voiceover_errors) if voiceover_errors else "Manual VoiceOver and responsive UI checks passed.",
         "receipt_path": path_value, "receipt_sha256": receipt_hash},
    ]


def collect_xcresult_summary(result_bundle, scratch, environment, name):
    if not result_bundle.is_dir():
        return ({"name": name, "status": "NOT_RUN", "exit_code": None,
                 "error": "No xcresult bundle was produced by the test stage."}, None)
    developer_directory = subprocess.run(["xcode-select", "-p"], cwd=str(ROOT),
                                         stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                         text=True, check=False)
    if developer_directory.returncode != 0:
        return ({"name": name, "status": "FAIL", "exit_code": developer_directory.returncode,
                 "error": developer_directory.stderr.strip()}, None)
    tool = Path(developer_directory.stdout.strip()) / "usr" / "bin" / "xcresulttool"
    if not tool.is_file():
        return ({"name": name, "status": "FAIL", "exit_code": None,
                 "error": "xcresulttool is not present in the selected Xcode developer directory."}, None)
    stage = run_stage(name, [str(tool), "get", "test-results", "summary", "--path",
                             str(result_bundle), "--compact"], scratch, environment, 60)
    raw = stage["log_path_scratch"].read_text(encoding="utf-8", errors="replace")
    try:
        summary = json.loads(raw)
    except json.JSONDecodeError:
        summary = None
        stage["parse_error"] = "xcresulttool output was not valid JSON."
    return stage, summary


def compact_xcresult_summary(summary):
    if not isinstance(summary, dict):
        return None
    return {
        "result": summary.get("result"),
        "total": summary.get("totalTestCount"),
        "passed": summary.get("passedTests"),
        "failed": summary.get("failedTests"),
        "skipped": summary.get("skippedTests"),
        "test_failures": summary.get("testFailures", []),
        "runtime_warnings": summary.get("runtimeWarnings", []),
    }


def xcode_case_counts(log_text, xcresult_summary):
    counts = parse_test_summary(log_text)
    if counts["summary_found"] or not isinstance(xcresult_summary, dict):
        return counts
    total = xcresult_summary.get("totalTestCount")
    passed = xcresult_summary.get("passedTests")
    failed = xcresult_summary.get("failedTests")
    skipped = xcresult_summary.get("skippedTests")
    if not all(isinstance(value, int) for value in (total, passed, failed, skipped)):
        return counts
    counts.update({
        "enumerated": total,
        "passed": passed,
        "failed": failed,
        "skipped": skipped,
        "summary_found": total > 0,
        "unknown_skips": (["xcresult_skip_details_unavailable"] if skipped else []),
    })
    return counts


def git_dirty():
    result = subprocess.run(["git", "status", "--porcelain"], cwd=str(ROOT),
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    return result.returncode != 0 or bool(result.stdout.strip())


def write_report(path, value):
    data = (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_bytes(data)
    os.replace(str(temporary), str(path))
    return sha256_bytes(data)


def report_output_paths(run_id, run_specific):
    if not run_specific:
        return REPORT_PATH, SUMMARY_PATH
    stem = "Validation-2.0-final-local-" + run_id
    return ROOT / "evidence" / (stem + ".json"), ROOT / "evidence" / (stem + ".md")


def main():
    parser = argparse.ArgumentParser(description="Run isolated project-local SwiftPM and Xcode checks and write a fail-closed 2.0 receipt.")
    parser.add_argument("--local-only", action="store_true", help="run only local fixture-backed checks; no network or user-library access")
    parser.add_argument("--host-free-only", action="store_true",
                        help="run host-free SwiftPM/release/migration/performance/static checks; mark Xcode and old-app GUI rollback actions NOT_RUN without launching apps")
    parser.add_argument("--pre-package-validation", action="store_true",
                        help="freeze pre-package software evidence; record G09 as NOT_RUN while retaining the selected existing package's integrity in G10")
    parser.add_argument("--candidate-manifest", metavar="PROJECT_RELATIVE_PATH",
                        help="verify this exact release-assets package manifest instead of timestamp discovery")
    output_mode = parser.add_mutually_exclusive_group()
    output_mode.add_argument("--run-specific-outputs", action="store_true",
                             help="write run-ID-suffixed reports under evidence/ without replacing the canonical receipt")
    output_mode.add_argument("--replace-canonical", action="store_true",
                             help="explicitly replace the canonical report and summary after the run completes")
    arguments = parser.parse_args()
    if not arguments.local_only:
        parser.error("--local-only is required; this verifier never performs live or private-data checks")
    candidate_manifest_override = arguments.candidate_manifest
    if candidate_manifest_override is not None:
        candidate_manifest_relative = _safe_relative_path(candidate_manifest_override)
        if (candidate_manifest_relative is None or not candidate_manifest_relative.parts or
                candidate_manifest_relative.parts[0] != "release-assets" or
                candidate_manifest_relative.name != "manifest-v2.0-local-candidate.json"):
            parser.error("--candidate-manifest must name a safe project-relative package manifest under release-assets/")
        candidate_manifest_override = candidate_manifest_relative.as_posix()

    run_id = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
    report_path, summary_path = report_output_paths(run_id, arguments.run_specific_outputs)
    if ((report_path.exists() or report_path.is_symlink() or
         summary_path.exists() or summary_path.is_symlink()) and
            not arguments.replace_canonical):
        parser.error("refusing to overwrite an existing validation report or summary")
    scratch = Path(tempfile.mkdtemp(prefix=".codex-task-audit-2-final.", dir=str(ROOT)))
    if scratch.is_symlink() or scratch.resolve().parent != ROOT.resolve() or not scratch.name.startswith(".codex-task-audit-2-final."):
        raise RuntimeError("refusing unsafe task scratch path")
    (scratch / "test-stores").mkdir()
    (scratch / "tmp").mkdir()
    (scratch / "home").mkdir()
    (scratch / "tmp" / "test-host").mkdir()
    (scratch / "tmp" / "xcode-unit-host").mkdir()
    (scratch / "swiftpm").mkdir()
    (scratch / "swiftpm-release").mkdir()
    (scratch / "swiftpm-cache").mkdir()
    (scratch / "swiftpm-config").mkdir()
    (scratch / "swiftpm-security").mkdir()
    (scratch / "xcode" / "unit-derived").mkdir(parents=True)
    (scratch / "xcode" / "ui-derived").mkdir(parents=True)
    manifest_path, manifest_hash, manifest_entries = freeze_manifest(run_id)
    candidate_before, candidate_discovery_errors = candidate_package_snapshot(
        manifest_hash, manifest_entries, manifest_path_override=candidate_manifest_override)
    candidate_directory = candidate_before.get("directory") if candidate_before else None
    retained_before, retained_before_errors = retained_asset_snapshot(candidate_directory)
    candidate_mount_before = candidate_dmg_mount_status(
        candidate_before.get("dmg_path") if candidate_before else None)

    environment = isolated_environment(scratch)
    host_free_only = arguments.host_free_only

    stages = []
    swift_test = run_stage("swiftpm-tests", ["swift", "test"] + swiftpm_options(scratch) + ["-q"],
                           scratch, environment, 900)
    stages.append(swift_test)
    test_text = swift_test["log_path_scratch"].read_text(encoding="utf-8", errors="replace")
    test_counts = parse_test_summary(test_text)
    swift_test["case_counts"] = test_counts
    if swift_test["status"] == "PASS" and (not test_counts["summary_found"] or
                                              test_counts["accessibility_fixture_tests"] != 1 or
                                              test_counts["failed"] or test_counts["unknown_skips"]):
        swift_test["status"] = "FAIL"

    migration_drill_root = scratch / "v10-to-v12-disposable-migration-drill"
    migration_drill_root.mkdir()
    migration_environment = environment.copy()
    migration_environment["LATTICELENS_V10_DISPOSABLE_DRILL_ROOT"] = str(migration_drill_root)
    migration_environment["LATTICELENS_V10_DISPOSABLE_INPUT_MANIFEST_SHA256"] = manifest_hash
    migration_drill_stage = run_stage(
        "v10-to-v12-disposable-migration-drill",
        ["swift", "test"] + swiftpm_options(scratch) + ["--filter", V10_MIGRATION_DRILL_TEST, "-q"],
        scratch, migration_environment, 900)
    stages.append(migration_drill_stage)
    migration_drill_counts = parse_test_summary(
        migration_drill_stage["log_path_scratch"].read_text(encoding="utf-8", errors="replace"))
    migration_drill_stage["case_counts"] = migration_drill_counts
    migration_drill_receipt_path = migration_drill_root / "migration-v10-to-v12.json"
    migration_drill_receipt, migration_drill_errors = validate_v10_to_v12_migration_receipt(
        migration_drill_receipt_path, manifest_hash)
    if migration_drill_stage["status"] == "PASS" and (
            not migration_drill_counts["summary_found"] or migration_drill_counts["enumerated"] != 1 or
            migration_drill_counts["passed"] != 1 or migration_drill_counts["failed"] != 0 or
            migration_drill_counts["skipped"] != 0):
        migration_drill_errors.append("The dedicated V10 migration drill did not execute exactly one passing XCTest.")
    if migration_drill_stage["status"] == "TIMEOUT":
        migration_drill_status = "BLOCKED"
        migration_drill_summary = "The isolated V10-to-V12 migration/rollback test reached its 900-second timeout."
    elif migration_drill_stage["status"] != "PASS" or migration_drill_errors:
        migration_drill_status = "FAIL"
        migration_drill_summary = "The current-source disposable V10-to-V12 drill failed: " + " ".join(migration_drill_errors)
    else:
        migration_drill_status = "PASS"
        migration_drill_summary = "A generated V10 source was activated as V12, its verified pre-migration backup was restored to a fresh target after activation and reopened through the production factory, and a separate pre-activation crash recovered without publishing staging."

    migration_drill_evidence_path = None
    migration_drill_receipt_hash = None
    if migration_drill_status == "PASS":
        migration_drill_evidence_path = ROOT / "evidence" / ("migration-v10-disposable-drill-" + run_id + ".json")
        if migration_drill_evidence_path.exists():
            migration_drill_status = "FAIL"
            migration_drill_summary = "Refusing to overwrite an existing V10 migration receipt for this run ID."
            migration_drill_errors.append("The exact generated evidence path already exists.")
            migration_drill_evidence_path = None
        else:
            try:
                receipt_bytes = migration_drill_receipt_path.read_bytes()
                migration_drill_evidence_path.write_bytes(receipt_bytes)
                migration_drill_receipt_hash = sha256_bytes(receipt_bytes)
            except OSError as error:
                migration_drill_status = "FAIL"
                migration_drill_summary = "Could not preserve the verified V10 migration receipt: " + str(error)
                migration_drill_errors.append("Writing the current-run receipt to evidence failed.")
                migration_drill_evidence_path = None

    migration_drill_report = {
        "status": migration_drill_status,
        "summary": migration_drill_summary,
        "stage": migration_drill_stage["name"],
        "case_counts": migration_drill_counts,
        "receipt_path": migration_drill_evidence_path.relative_to(ROOT).as_posix()
            if migration_drill_evidence_path else None,
        "receipt_sha256": migration_drill_receipt_hash,
        "input_manifest_sha256": manifest_hash,
        "validation_errors": migration_drill_errors,
    }

    old_app_scratch_report = scratch / "g02-old-app-rollback-receipt.json"
    old_app_rollback_stage = run_old_app_rollback_stage(
        scratch, environment, manifest_hash, host_free_only)
    stages.append(old_app_rollback_stage)
    old_app_rollback = validate_old_app_rollback_receipt(
        old_app_scratch_report, manifest_hash, old_app_rollback_stage["status"])
    old_app_rollback["stage"] = old_app_rollback_stage["name"]
    old_app_rollback["stage_status"] = old_app_rollback_stage["status"]
    old_app_rollback["stage_log_sha256"] = old_app_rollback_stage["log_sha256"]

    swift_release = run_stage(
        "swiftpm-release",
        ["swift", "build", "-c", "release"] + swiftpm_options(scratch, "swiftpm-release") + [
         "-Xswiftc", "-warnings-as-errors"], scratch, environment, 900)
    stages.append(swift_release)

    xcode_derived = scratch / "xcode" / "unit-derived"
    xcode_ui_derived = scratch / "xcode" / "ui-derived"
    xcode_base = ["xcodebuild", "-project", XCODE_PROJECT, "-destination", "platform=macOS,arch=arm64",
                  "-jobs", "2", "ONLY_ACTIVE_ARCH=YES"]
    xcode_debug = run_xcode_stage(
        "xcode-debug-build",
        xcode_base + ["-scheme", "LatticeLens", "-configuration", "Debug",
                      "-derivedDataPath", str(xcode_derived), "CODE_SIGNING_ALLOWED=NO", "build"],
        scratch, environment, 900, host_free_only)
    stages.append(xcode_debug)

    xcode_release = run_xcode_stage(
        "xcode-release-build",
        xcode_base + ["-scheme", "LatticeLens", "-configuration", "Release",
                      "-derivedDataPath", str(xcode_derived), "CODE_SIGNING_ALLOWED=NO", "build"],
        scratch, environment, 900, host_free_only)
    stages.append(xcode_release)

    xcode_analyze = run_xcode_stage(
        "xcode-analyze",
        xcode_base + ["-scheme", "LatticeLens", "-configuration", "Debug",
                      "-derivedDataPath", str(xcode_derived), "CODE_SIGNING_ALLOWED=NO", "analyze"],
        scratch, environment, 900, host_free_only)
    stages.append(xcode_analyze)

    xcode_unit_result = scratch / "xcode" / "LatticeLens-Unit.xcresult"
    xcode_unit_store_root = scratch / "test-stores" / "xcode-unit"
    unit_build_command, unit_test_command = xcode_test_commands(
        xcode_base, "LatticeLens-Unit", xcode_derived, xcode_unit_result, xcode_unit_store_root,
        test_tmp_root=scratch / "tmp" / "xcode-unit-host")
    xcode_unit_build = run_xcode_stage(
        "xcode-unit-build-for-testing", unit_build_command, scratch, environment, 900,
        host_free_only)
    stages.append(xcode_unit_build)
    if xcode_unit_build["status"] == "PASS" or host_free_only:
        xcode_unit = run_xcode_stage(
            "xcode-unit-test-without-building", unit_test_command, scratch, environment, 600,
            host_free_only)
    else:
        xcode_unit = not_run_stage(
            "xcode-unit-test-without-building", unit_test_command, scratch,
            "The Xcode unit test products did not build successfully.")
    stages.append(xcode_unit)
    if host_free_only:
        xcode_unit_process_cleanup = {
            "status": "PASS", "matched": [], "terminated": [], "remaining": [],
            "error": None, "reason": "No Xcode unit process was started in host-free mode.",
        }
    else:
        xcode_unit_process_cleanup = cleanup_task_test_processes(xcode_derived)
    xcode_unit["task_process_cleanup"] = xcode_unit_process_cleanup
    unit_summary_stage, unit_xcresult = collect_xcode_summary(
        xcode_unit_result, scratch, environment, "xcode-unit-xcresult-summary", host_free_only)
    stages.append(unit_summary_stage)
    xcode_unit["xcresult_summary"] = compact_xcresult_summary(unit_xcresult)
    unit_log_text = xcode_unit["log_path_scratch"].read_text(encoding="utf-8", errors="replace")
    xcode_unit["case_counts"] = xcode_case_counts(unit_log_text, unit_xcresult)
    xcode_unit["status"], xcode_unit["runner_reason"] = classify_xcode_test_if_run(
        xcode_unit, unit_log_text, unit_xcresult)
    if (xcode_unit["status"] == "PASS" and
            (xcode_unit["case_counts"]["failed"] or xcode_unit["case_counts"]["unknown_skips"])):
        xcode_unit["status"] = "FAIL"
        xcode_unit["runner_reason"] = "XCTest reported failures or skips without an accepted skip classification."

    xcode_ui_result = scratch / "xcode" / "LatticeLens-UIFixture.xcresult"
    xcode_ui_store_root = scratch / "test-stores" / "xcode-ui"
    xcode_ui_cache_root = scratch / "fixture-cache" / "xcode-ui"
    xcode_ui_tmp_root = scratch / "tmp" / "xcode-ui-host"
    xcode_ui_base = ["xcodebuild", "-project", XCODE_PROJECT,
                     "-destination", "platform=macOS,arch=arm64", "-jobs", "2",
                     "ONLY_ACTIVE_ARCH=YES"]
    ui_build_command, ui_test_command = xcode_test_commands(
        xcode_ui_base, "LatticeLens-UIFixture", xcode_ui_derived, xcode_ui_result,
        xcode_ui_store_root, xcode_ui_cache_root, xcode_ui_tmp_root)
    xcode_ui_build = run_xcode_stage(
        "xcode-ui-build-for-testing", ui_build_command, scratch, environment, 900,
        host_free_only)
    stages.append(xcode_ui_build)
    if xcode_ui_build["status"] == "PASS" or host_free_only:
        xcode_ui = run_xcode_stage(
            "xcode-ui-test-without-building", ui_test_command, scratch, environment, 600,
            host_free_only)
    else:
        xcode_ui = not_run_stage(
            "xcode-ui-test-without-building", ui_test_command, scratch,
            "The Xcode UI fixture test products did not build successfully.")
    stages.append(xcode_ui)
    if host_free_only:
        xcode_ui_process_cleanup = {
            "status": "PASS", "matched": [], "terminated": [], "remaining": [],
            "error": None, "reason": "No Xcode UI process was started in host-free mode.",
        }
    else:
        xcode_ui_process_cleanup = cleanup_task_test_processes(xcode_ui_derived)
    xcode_ui["task_process_cleanup"] = xcode_ui_process_cleanup
    ui_summary_stage, ui_xcresult = collect_xcode_summary(
        xcode_ui_result, scratch, environment, "xcode-ui-xcresult-summary", host_free_only)
    stages.append(ui_summary_stage)
    xcode_ui["xcresult_summary"] = compact_xcresult_summary(ui_xcresult)
    ui_log_text = xcode_ui["log_path_scratch"].read_text(encoding="utf-8", errors="replace")
    xcode_ui["case_counts"] = xcode_case_counts(ui_log_text, ui_xcresult)
    xcode_ui["status"], xcode_ui["runner_reason"] = classify_xcode_test_if_run(
        xcode_ui, ui_log_text, ui_xcresult)
    if (xcode_ui["status"] == "PASS" and
            (xcode_ui["case_counts"]["failed"] or xcode_ui["case_counts"]["unknown_skips"])):
        xcode_ui["status"] = "FAIL"
        xcode_ui["runner_reason"] = "XCTest reported failures or skips without an accepted skip classification."
    if xcode_ui_build["status"] == "FAIL":
        xcode_ui_status = "FAIL"
        xcode_ui_reason = "The UI fixture target failed during build-for-testing; see the isolated build log."
    elif xcode_ui_build["status"] != "PASS" and not host_free_only:
        xcode_ui_status = "NOT_RUN"
        xcode_ui_reason = "The UI fixture test products were not built."
    elif xcode_ui["status"] == "BLOCKED":
        xcode_ui_status = "BLOCKED"
        xcode_ui_reason = xcode_ui["runner_reason"] or "The UI test runner did not complete."
    elif xcode_ui["status"] == "PASS" and isinstance(ui_xcresult, dict) and ui_xcresult.get("result") == "Passed":
        xcode_ui_status = "PASS"
        xcode_ui_reason = "The fixture-backed XCUIApplication suite completed; manual VoiceOver acceptance is still separate."
    elif xcode_ui["status"] == "FAIL":
        xcode_ui_status = "FAIL"
        xcode_ui_reason = xcode_ui["runner_reason"] or "The UI test build or runner failed."
    else:
        xcode_ui_status = "NOT_RUN"
        xcode_ui_reason = xcode_ui.get("not_run_reason", "No readable current UI test result was produced.")

    performance_output_path = ROOT / "evidence" / ("FormulaPerformance-2.0-final-local-" + run_id + ".json")
    performance_environment = environment.copy()
    performance_environment["LATTICELENS_RUN_V12_FORMULA_BENCHMARK"] = "1"
    performance_environment["LATTICELENS_V12_FORMULA_BENCHMARK_ROOT"] = str(scratch / "test-stores" / "v12-formula-benchmark")
    performance_environment["LATTICELENS_V12_FORMULA_BENCHMARK_OUTPUT"] = str(performance_output_path)
    performance_environment["LATTICELENS_BENCHMARK_INPUT_MANIFEST_SHA256"] = manifest_hash
    performance_stage = run_stage(
        "v12-formula-performance",
        ["swift", "test"] + swiftpm_options(scratch) +
        ["--filter", "V4BenchmarkTests/testActualSwiftDataV12FormulaStoreBenchmark", "-q"],
        scratch, performance_environment, 1_800)
    stages.append(performance_stage)
    performance_stage["case_counts"] = parse_test_summary(
        performance_stage["log_path_scratch"].read_text(encoding="utf-8", errors="replace"))
    performance_validation, performance_errors = validate_v12_performance_report(
        performance_output_path, manifest_hash)
    performance_counts = performance_stage["case_counts"]
    if (performance_stage["status"] == "PASS" and
            (performance_counts["enumerated"] != 1 or performance_counts["passed"] != 1 or
             performance_counts["failed"] != 0 or performance_counts["skipped"] != 0)):
        performance_errors.append("The dedicated benchmark XCTest did not execute exactly one passing case.")
    if performance_stage["status"] == "TIMEOUT":
        performance_status = "BLOCKED"
        performance_summary = "The dedicated V12 benchmark reached its declared 1,800-second timeout; no performance result is accepted."
    elif performance_stage["status"] != "PASS":
        performance_status = "FAIL"
        performance_summary = "The dedicated V12 benchmark test failed; see its current stage log and preserved partial report, if any."
    elif performance_errors:
        performance_status = "FAIL"
        performance_summary = "The V12 benchmark ran but failed provenance, workload, sample-count, or threshold checks: " + " ".join(performance_errors)
    else:
        performance_status = "PASS"
        measured = performance_validation["recomputed_p95_ms"]
        performance_summary = ("Current V12 disk benchmark met the checked gates: cold reopen p95=" +
                                str(measured["cold_reopen"]) + " ms, warm search p95=" +
                                str(measured["warm_search"]) + " ms; each 100-sample read/favorite/note mutation series met its 100 ms ceiling.")

    xcode_core_stages = [xcode_debug, xcode_release, xcode_analyze, xcode_unit_build,
                         xcode_unit, unit_summary_stage]
    xcode_core_ok = all(stage.get("status") == "PASS" for stage in xcode_core_stages)

    static_commands = [
        ["plutil", "-lint", "LatticeLens.xcodeproj/project.pbxproj"],
        ["xmllint", "--noout", "LatticeLens.xcodeproj/xcshareddata/xcschemes/LatticeLens.xcscheme"],
        ["xmllint", "--noout", "LatticeLens.xcodeproj/xcshareddata/xcschemes/LatticeLens-Unit.xcscheme"],
        ["xmllint", "--noout", "LatticeLens.xcodeproj/xcshareddata/xcschemes/LatticeLens-UIFixture.xcscheme"],
        [sys.executable, "-B", "Tests/VerifierContractTests.py"],
        [sys.executable, "-B", "Tests/PackageCandidateContractTests.py"],
        ["git", "diff", "--check"],
        [sys.executable, "-m", "json.tool", "CleanupManifest-2.0.json"],
        [sys.executable, "-m", "json.tool", "CleanupManifest-2.0-final.json"],
        [sys.executable, "-m", "json.tool", "evidence/Validation-2.0-local-20261001.json"],
    ]
    static_results = []
    for index, command in enumerate(static_commands, 1):
        stage = run_stage("static-check-" + str(index), command, scratch, environment, 120)
        stages.append(stage)
        static_results.append({"command": command, "status": stage["status"], "exit_code": stage["exit_code"],
                              "output_sha256": stage["log_sha256"]})

    swift_core_ok = swift_test["status"] == "PASS" and swift_release["status"] == "PASS"
    static_ok = all(stage["status"] == "PASS" for stage in stages if stage["name"].startswith("static-check-"))
    xcode_build_ok = all(stage.get("status") == "PASS" for stage in
                         (xcode_debug, xcode_release, xcode_analyze, xcode_unit_build, xcode_ui_build))
    xcode_assertion_failure = xcode_unit.get("status") == "FAIL" or xcode_ui.get("status") == "FAIL"
    xcode_runner_blocked = xcode_unit.get("status") == "BLOCKED" or xcode_ui.get("status") == "BLOCKED"
    physical_enospc = physical_disk_enospc_evidence()
    g02_migration_evidence = g02_migration_case_evidence(
        test_text, migration_drill_status, physical_enospc["status"],
        old_app_rollback["status"])
    g07_bundle_evidence = g07_required_case_evidence(test_text)

    g01_category_cases = required_case_evidence(test_text, G01_CATEGORY_REQUIRED_CASES)
    g01_ui_cases = required_case_evidence(ui_log_text, G01_UI_REQUIRED_CASES)
    g01_cases = combine_case_evidence(g01_category_cases, g01_ui_cases)
    g03_cases = required_case_evidence(test_text, G03_FORMULA_REQUIRED_CASES)
    g04_job_cases = required_case_evidence(test_text, G04_JOB_REQUIRED_CASES)
    g04_relaunch_cases = required_case_evidence(ui_log_text, G04_RELAUNCH_UI_REQUIRED_CASES)
    g04_cases = combine_case_evidence(g04_job_cases, g04_relaunch_cases)
    g05_cases = required_case_evidence(test_text, G05_DERIVATION_REQUIRED_CASES)
    g06_cases = required_case_evidence(ui_log_text, G06_UI_REQUIRED_CASES)
    manual_receipts = validate_manual_acceptance(manifest_hash)
    physics_manual = next(item for item in manual_receipts
                          if item["scope"] == "three-paper physics review")
    voiceover_manual = next(item for item in manual_receipts
                            if item["scope"] == "VoiceOver and responsive UI review")

    swift_prerequisite = ("PASS" if swift_core_ok and static_ok else
                          "FAIL" if swift_test["status"] == "FAIL" or
                          swift_release["status"] == "FAIL" or not static_ok else "PARTIAL")
    g01_prerequisite = ("FAIL" if swift_prerequisite == "FAIL" or
                        xcode_ui_status == "FAIL" else
                        xcode_ui_status if swift_prerequisite == "PASS" else swift_prerequisite)
    g01_status = required_case_gate_status(g01_cases, g01_prerequisite)
    g03_status = required_case_gate_status(g03_cases, swift_prerequisite)
    g04_prerequisite = ("FAIL" if swift_prerequisite == "FAIL" or xcode_ui_status == "FAIL" else
                        "BLOCKED" if xcode_ui_status == "BLOCKED" else
                        "PASS" if swift_prerequisite == "PASS" and xcode_ui_status == "PASS" else
                        "PARTIAL")
    g04_status = required_case_gate_status(g04_cases, g04_prerequisite)
    g05_status = required_case_gate_status(g05_cases, swift_prerequisite)
    if g05_status == "PASS" and physics_manual["status"] != "PASS":
        g05_status = "FAIL" if physics_manual["status"] == "FAIL" else "PARTIAL"
    xcode_build_prerequisite = ("FAIL" if not static_ok or any(stage.get("status") == "FAIL" for stage in
                                 (xcode_debug, xcode_release, xcode_analyze, xcode_ui_build)) else
                                "BLOCKED" if xcode_ui_status == "BLOCKED" else
                                "PASS" if xcode_ui_status == "PASS" else "PARTIAL")
    g06_status = required_case_gate_status(g06_cases, xcode_build_prerequisite)
    if g06_status == "PASS" and voiceover_manual["status"] != "PASS":
        g06_status = "FAIL" if voiceover_manual["status"] == "FAIL" else "PARTIAL"

    expected_gates = [
        ("G01", g01_status, g01_gate_summary(g01_category_cases, g01_ui_cases)),
        ("G02", g02_migration_evidence["status"], g02_migration_evidence["summary"]),
        ("G03", g03_status, "Current-run numbered-formula parser, coverage, tamper, and typed derivation regression results are listed below."),
        ("G04", g04_status, "Current-run finite-request, cancellation, checkpoint, and disk-backed quit/relaunch cases are listed below."),
        ("G05", g05_status, "Automated typed derivation cases and the three-paper human physics review are independently recorded below."),
        ("G06", g06_status, ("Host-free mode intentionally marked every Xcode build/test/result action NOT_RUN. "
                             if host_free_only else
                             "Xcode Debug/Release/Analyze and separate test builds ran. ") +
         xcode_ui_reason + " Manual VoiceOver status: " + voiceover_manual["status"] + "."),
        ("G07", "PARTIAL", g07_bundle_evidence["summary"]),
        ("G08", performance_status, performance_summary),
        ("G09", "NOT_RUN", "No provenance-bound 2.0 DMG, isolated install, or app/data rollback has been executed."),
        ("G10", "PARTIAL", "Final exact-path cleanup and post-cleanup provenance verification are recorded at the end of this run."),
    ]
    performance_receipt_hash = sha256_file(performance_output_path) if performance_output_path.is_file() else None
    gate_results = []
    for gate_id, status, summary in expected_gates:
        if gate_id in ("G01", "G03", "G04", "G05", "G07") and (not swift_core_ok or not static_ok):
            status = "FAIL"
        if gate_id == "G01":
            if (xcode_unit_build.get("status") == "FAIL" or
                    xcode_unit.get("status") == "FAIL" or
                    xcode_ui_status == "FAIL" or
                    any(stage.get("status") == "FAIL" for stage in
                        (xcode_debug, xcode_release, xcode_analyze))):
                status = "FAIL"
            elif xcode_unit.get("status") == "BLOCKED" or xcode_ui_status == "BLOCKED":
                status = "BLOCKED"
        if gate_id == "G02":
            if (migration_drill_status == "FAIL" or not swift_core_ok or not static_ok or
                    not g02_migration_evidence["all_required_passed"]):
                status = "FAIL"
            elif migration_drill_status == "BLOCKED" or old_app_rollback["status"] == "BLOCKED":
                status = "BLOCKED"
            elif old_app_rollback["status"] == "FAIL":
                status = "FAIL"
            elif (physical_enospc["status"] != "PASS" or
                  old_app_rollback["status"] != "PASS" or migration_drill_status != "PASS"):
                status = "PARTIAL"
            else:
                status = "PASS"
        if gate_id == "G06":
            if (not static_ok or any(stage.get("status") == "FAIL" for stage in
                                     (xcode_debug, xcode_release, xcode_analyze,
                                      xcode_unit_build, xcode_ui_build)) or
                    xcode_ui_status == "FAIL"):
                status = "FAIL"
            elif xcode_runner_blocked or xcode_ui_status == "BLOCKED":
                status = "BLOCKED"
        if gate_id == "G08":
            status = performance_status
        if gate_id == "G07" and not g07_bundle_evidence["all_required_passed"]:
            status = "FAIL"
        evidence_names = ["swiftpm-tests", "swiftpm-release", "xcode-debug-build",
                          "xcode-release-build", "xcode-analyze", "xcode-unit-build-for-testing",
                          "xcode-unit-test-without-building"]
        if gate_id == "G02":
            evidence_names.append("v10-to-v12-disposable-migration-drill")
            if physical_enospc["status"] == "PASS":
                evidence_names.append("physical-disk-enospc-drill")
            if old_app_rollback["status"] == "PASS":
                evidence_names.append("older-app-restored-v9-rollback-compatibility")
        if gate_id == "G06":
            evidence_names.extend(["xcode-ui-build-for-testing", "xcode-ui-test-without-building",
                                   "xcode-ui-xcresult-summary"])
        if gate_id == "G08":
            evidence_names.append("v12-formula-performance")
        gate_entry = {"gate": gate_id, "status": status, "summary": summary,
                      "evidence": evidence_names,
                      "blocker_evidence": {"stage": "xcode-ui-test-without-building",
                                            "stage_log_sha256": xcode_ui["log_sha256"],
                                            "reason": xcode_ui_reason}
                      if gate_id == "G06" and xcode_ui_status == "BLOCKED" else None}
        if gate_id == "G07":
            gate_entry["case_results"] = g07_bundle_evidence["cases"]
            gate_entry["all_required_cases_passed"] = g07_bundle_evidence["all_required_passed"]
        if gate_id == "G01":
            gate_entry["case_results"] = {
                "swiftpm_category_and_pagination": g01_category_cases["cases"],
                "xcuitest_responsive_ui": g01_ui_cases["cases"],
            }
            gate_entry["all_required_cases_passed"] = g01_cases["all_required_passed"]
        if gate_id == "G03":
            gate_entry["case_results"] = g03_cases["cases"]
            gate_entry["all_required_cases_passed"] = g03_cases["all_required_passed"]
        if gate_id == "G04":
            gate_entry["case_results"] = {
                "swiftpm_formula_jobs": g04_job_cases["cases"],
                "xcuitest_quit_relaunch": g04_relaunch_cases["cases"],
            }
            gate_entry["all_required_cases_passed"] = g04_cases["all_required_passed"]
        if gate_id == "G05":
            gate_entry["case_results"] = g05_cases["cases"]
            gate_entry["all_required_cases_passed"] = g05_cases["all_required_passed"]
            gate_entry["physics_review_status"] = physics_manual["status"]
        if gate_id == "G06":
            gate_entry["case_results"] = g06_cases["cases"]
            gate_entry["all_required_cases_passed"] = g06_cases["all_required_passed"]
            gate_entry["voiceover_status"] = voiceover_manual["status"]
        if gate_id == "G02":
            gate_entry["case_results"] = g02_migration_evidence["cases"]
            gate_entry["all_required_cases_passed"] = g02_migration_evidence["all_required_passed"]
            gate_entry["manifest_bound_v10_drill_status"] = g02_migration_evidence["v10_drill_status"]
            gate_entry["physical_disk_enospc_status"] = physical_enospc["status"]
            gate_entry["old_app_rollback_compatibility_status"] = old_app_rollback["status"]
            gate_entry["old_app_rollback_stage_status"] = old_app_rollback_stage["status"]
            gate_entry["old_app_rollback_validation_errors"] = old_app_rollback["validation_errors"]
        if gate_id == "G08" and performance_receipt_hash:
            gate_entry["evidence_artifacts"] = [{
                "path": performance_output_path.relative_to(ROOT).as_posix(),
                "sha256": performance_receipt_hash,
                "input_manifest_sha256": manifest_hash,
            }]
        if gate_id == "G02":
            gate_artifacts = []
            if migration_drill_receipt_hash and migration_drill_report["receipt_path"]:
                gate_artifacts.append({
                    "path": migration_drill_report["receipt_path"],
                    "sha256": migration_drill_receipt_hash,
                    "input_manifest_sha256": manifest_hash,
                })
            if physical_enospc["status"] == "PASS":
                gate_artifacts.append({
                    "path": physical_enospc["log_path"],
                    "sha256": physical_enospc["log_sha256"],
                    "source_sha256": physical_enospc["source_sha256"],
                })
            if old_app_rollback.get("receipt_path") and old_app_rollback.get("receipt_sha256"):
                gate_artifacts.append({
                    "path": old_app_rollback["receipt_path"],
                    "sha256": old_app_rollback["receipt_sha256"],
                    "input_manifest_sha256": manifest_hash,
                    "kind": "older_app_restored_v9_rollback_compatibility",
                })
            if gate_artifacts:
                gate_entry["evidence_artifacts"] = gate_artifacts
        gate_results.append(gate_entry)

    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    log_path = ROOT / "evidence" / ("Validation-2.0-final-local-" + run_id + ".log")
    with log_path.open("w", encoding="utf-8") as combined:
        for stage in stages:
            combined.write("\n=== " + stage["name"] + " | " + stage["status"] + " ===\n")
            combined.write("COMMAND: " + " ".join(stage["command"]) + "\n")
            output = stage["log_path_scratch"].read_text(encoding="utf-8", errors="replace")
            combined.write(output.replace(str(scratch), "<task-scratch>"))
            if not output.endswith("\n"):
                combined.write("\n")
    log_hash = sha256_file(log_path)

    task_test_processes = [
        {"stage": "xcode-unit-test-without-building", **xcode_unit_process_cleanup},
        {"stage": "xcode-ui-test-without-building", **xcode_ui_process_cleanup},
    ]
    remaining_process_count = sum(len(item.get("remaining", [])) for item in task_test_processes)
    process_cleanup_failed = any(item.get("status") != "PASS" for item in task_test_processes)
    cleanup = {"scratch": scratch.relative_to(ROOT).as_posix(), "removed": False,
               "processes_started_by_verifier_remaining": remaining_process_count,
               "task_test_processes": task_test_processes, "error": None,
               "manifest_path": None, "manifest_sha256": None}
    cleanup_manifest_path = ROOT / "evidence" / ("CleanupManifest-2.0-final-local-" + run_id + ".json")
    cleanup_manifest_errors = []
    try:
        target_record = cleanup_directory_metadata(scratch)
        target_record.update({
            "owner": "this verifier run",
            "open_process_count": remaining_process_count,
            "action": "remove exact verifier-owned project-local scratch",
            "removed": False,
            "post_action_check": "pending",
        })
    except (OSError, RuntimeError, ValueError) as error:
        target_record = {
            "path": scratch.relative_to(ROOT).as_posix(),
            "canonical_path_verified": False,
            "directory_symlink": scratch.is_symlink(),
            "logical_bytes": None,
            "file_count": None,
            "subdirectory_count": None,
            "symlink_count": None,
            "metadata_tree_sha256": None,
            "symlink_targets_confined_to_scratch": False,
            "owner": "this verifier run",
            "open_process_count": remaining_process_count,
            "action": "remove exact verifier-owned project-local scratch",
            "removed": False,
            "post_action_check": "pending",
        }
        cleanup_manifest_errors.append("Scratch preflight failed: " + str(error))
    cleanup_manifest = {
        "schema_version": "latticelens-cleanup-2.0-final-local-v1",
        "run_id": run_id,
        "input_manifest_sha256": manifest_hash,
        "scope": "Only this run's exact verifier-owned project-local scratch is eligible for removal.",
        "mode": "exact_manifest_whitelist_apply",
        "status": "preflight_reviewed",
        "targets": [target_record],
        "unapproved_deletions": [],
    }
    if cleanup_manifest_path.exists() or cleanup_manifest_path.is_symlink():
        cleanup_manifest_errors.append("Run-specific cleanup manifest path already exists; refusing to overwrite it.")
    else:
        try:
            write_report(cleanup_manifest_path, cleanup_manifest)
        except OSError as error:
            cleanup_manifest_errors.append("Could not persist cleanup preflight manifest: " + str(error))
    try:
        if cleanup_manifest_errors:
            raise RuntimeError("; ".join(cleanup_manifest_errors))
        if process_cleanup_failed:
            raise RuntimeError("task-owned Xcode app/test processes were not all confirmed stopped; preserving scratch for recovery")
        cleanup["removed"] = apply_exact_cleanup_target(
            target_record, scratch.relative_to(ROOT).as_posix(), remaining_process_count)
    except Exception as error:
        cleanup["error"] = str(error)

    target_record["removed"] = cleanup["removed"]
    target_record["post_action_check"] = "path absent" if cleanup["removed"] else "path remains or removal unverified"
    target_record["apply_error"] = cleanup["error"]

    frozen_input_errors = verify_frozen_inputs(manifest_entries)
    candidate_after, candidate_after_discovery_errors = candidate_package_snapshot(
        manifest_hash, manifest_entries, manifest_path_override=candidate_manifest_override)
    candidate_directory_after = candidate_after.get("directory") if candidate_after else candidate_directory
    retained_after, retained_after_errors = retained_asset_snapshot(candidate_directory_after)
    candidate_mount_after = candidate_dmg_mount_status(
        candidate_after.get("dmg_path") if candidate_after else None)
    if candidate_mount_before.get("status") == "FAIL" or candidate_mount_after.get("status") == "FAIL":
        candidate_mount_status = {"status": "FAIL", "mounted": True,
                                  "reason": "The candidate DMG was mounted during cleanup verification."}
    elif (candidate_mount_before.get("status") == "BLOCKED" or
          candidate_mount_after.get("status") == "BLOCKED"):
        candidate_mount_status = {"status": "BLOCKED", "mounted": None,
                                  "reason": "Could not prove that the candidate DMG was unmounted."}
    else:
        candidate_mount_status = candidate_mount_after

    cleanup_errors = list(cleanup_manifest_errors) + list(retained_before_errors) + list(retained_after_errors)
    if cleanup.get("error"):
        cleanup_errors.append(cleanup["error"])
    if candidate_before and candidate_before.get("errors"):
        cleanup_errors.extend(candidate_before["errors"])
    if candidate_after and candidate_after.get("errors"):
        cleanup_errors.extend(candidate_after["errors"])
    cleanup_errors.extend(candidate_discovery_errors)
    cleanup_errors.extend(candidate_after_discovery_errors)
    g10_status, g10_summary, g10_issues = evaluate_g10_cleanup(
        cleanup["removed"], cleanup_errors, remaining_process_count,
        frozen_input_errors, retained_before, retained_after,
        candidate_before, candidate_after, candidate_mount_status)

    retained_equal = retained_before == retained_after and not retained_before_errors and not retained_after_errors
    release_integrity_pass = bool(candidate_before and candidate_after and
                                   not candidate_before.get("errors") and not candidate_after.get("errors"))
    release_unchanged = bool(candidate_before and candidate_after and
                             candidate_before.get("directory") == candidate_after.get("directory") and
                             candidate_before.get("integrity_sha256") == candidate_after.get("integrity_sha256"))
    candidate_binding_pass = bool(candidate_after and candidate_after.get("source_identity_matches_current"))
    processes_stopped = (remaining_process_count == 0 and not process_cleanup_failed)
    cleanup_manifest["post_cleanup_verification"] = {
        "frozen_input_manifest": "PASS" if not frozen_input_errors else "FAIL",
        "frozen_input_errors": frozen_input_errors,
        "retained_core_assets": "PASS" if retained_equal else "FAIL",
        "retained_assets_before": retained_before,
        "retained_assets_after": retained_after,
        "release_package_integrity": "PASS" if release_integrity_pass else "FAIL",
        "release_package_unchanged": "PASS" if release_unchanged else "FAIL",
        "candidate_source_binding": "PASS" if candidate_binding_pass else "PARTIAL",
        "candidate_dmg_unmounted": candidate_mount_status.get("status"),
        "candidate_dmg_mount_evidence": candidate_mount_status,
        "owned_processes_stopped": "PASS" if processes_stopped else "FAIL",
        "release_package_before": candidate_before,
        "release_package_after": candidate_after,
        "unresolved_cleanup_errors": g10_issues,
    }
    cleanup_manifest["status"] = (
        "applied_postcleanup_verified" if g10_status == "PASS" else
        "applied_postcleanup_partial" if cleanup["removed"] else "apply_failed")
    if cleanup_manifest_path.exists() and not cleanup_manifest_path.is_symlink():
        try:
            write_report(cleanup_manifest_path, cleanup_manifest)
            cleanup_manifest_errors = validate_cleanup_manifest_record(
                json.loads(cleanup_manifest_path.read_text(encoding="utf-8")), run_id,
                manifest_hash, scratch.relative_to(ROOT).as_posix())
            if g10_status == "PASS" and cleanup_manifest_errors:
                g10_status = "FAIL"
                g10_issues.extend(cleanup_manifest_errors)
                g10_summary = "G10 cleanup manifest failed its independent post-write validation: " + " ".join(cleanup_manifest_errors)
                cleanup_manifest["status"] = "applied_postcleanup_partial"
                cleanup_manifest["post_cleanup_verification"]["unresolved_cleanup_errors"] = g10_issues
                write_report(cleanup_manifest_path, cleanup_manifest)
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            g10_status = "FAIL"
            g10_issues.append("Could not persist or re-read the final cleanup manifest: " + str(error))
            g10_summary = "G10 cleanup manifest could not be independently re-read after apply: " + str(error)
    else:
        g10_status = "FAIL"
        g10_issues.append("Final run-specific cleanup manifest is missing or symlinked.")
        g10_summary = "G10 cleanup manifest is missing or symlinked after apply."
    cleanup_manifest_hash = (sha256_file(cleanup_manifest_path)
                              if cleanup_manifest_path.is_file() and not cleanup_manifest_path.is_symlink()
                              else None)
    cleanup["manifest_path"] = cleanup_manifest_path.relative_to(ROOT).as_posix()
    cleanup["manifest_sha256"] = cleanup_manifest_hash
    cleanup["manifest_status"] = cleanup_manifest.get("status")

    performance_p95 = (performance_validation or {}).get("recomputed_p95_ms", {})
    performance_dataset = ((performance_validation or {}).get("report", {}).get("dataset", {})
                           if isinstance((performance_validation or {}).get("report"), dict) else {})
    artifacts = [
        {"path": log_path.relative_to(ROOT).as_posix(), "sha256": log_hash, "kind": "compact_raw_stage_log"},
        {"path": manifest_path.relative_to(ROOT).as_posix(), "sha256": manifest_hash, "kind": "frozen_input_manifest"},
    ]
    if performance_receipt_hash:
        artifacts.append({"path": performance_output_path.relative_to(ROOT).as_posix(),
                          "sha256": performance_receipt_hash, "kind": "v12_disk_performance_receipt"})
    if migration_drill_receipt_hash and migration_drill_report["receipt_path"]:
        artifacts.append({"path": migration_drill_report["receipt_path"],
                          "sha256": migration_drill_receipt_hash,
                          "kind": "v10_to_v12_disposable_migration_receipt",
                          "input_manifest_sha256": manifest_hash})
    if physical_enospc["status"] == "PASS":
        artifacts.append({"path": physical_enospc["log_path"],
                          "sha256": physical_enospc["log_sha256"],
                          "kind": "g02_physical_disk_enospc_drill",
                          "source_sha256": physical_enospc["source_sha256"]})
    if old_app_rollback.get("receipt_path") and old_app_rollback.get("receipt_sha256"):
        artifacts.append({"path": old_app_rollback["receipt_path"],
                          "sha256": old_app_rollback["receipt_sha256"],
                          "kind": "older_app_restored_v9_rollback_compatibility",
                          "input_manifest_sha256": manifest_hash})

    g09_status, g09_summary, g09_issues = evaluate_g09_package(
        candidate_after, candidate_after_discovery_errors,
        pre_package_validation=arguments.pre_package_validation)
    g09_gate = next(gate for gate in gate_results if gate["gate"] == "G09")
    g09_gate["status"] = g09_status
    g09_gate["summary"] = g09_summary
    g09_gate["package_verification"] = {
        "candidate_present": candidate_after is not None,
        "manifest_path": candidate_after.get("manifest_path") if candidate_after else None,
        "manifest_sha256": candidate_after.get("manifest_sha256") if candidate_after else None,
        "checksums_path": candidate_after.get("checksums_path") if candidate_after else None,
        "checksums_sha256": candidate_after.get("checksums_sha256") if candidate_after else None,
        "dmg_path": candidate_after.get("dmg_path") if candidate_after else None,
        "dmg_sha256": candidate_after.get("dmg_sha256") if candidate_after else None,
        "input_manifest_sha256": candidate_after.get("input_manifest_sha256") if candidate_after else None,
        "source_identity_matches_current": bool(
            candidate_after and candidate_after.get("source_identity_matches_current")),
        "checks": ({name: candidate_after.get("checks", {}).get(name)
                    for name in G09_COMPLETION_CHECKS}
                   if candidate_after and isinstance(candidate_after.get("checks"), dict) else {}),
        "issues": g09_issues,
    }
    g09_artifacts = []
    if candidate_after:
        for path_key, digest_key, kind in (
                ("manifest_path", "manifest_sha256", "current_release_candidate_manifest"),
                ("dmg_path", "dmg_sha256", "current_release_candidate_dmg")):
            artifact = {"path": candidate_after[path_key],
                        "sha256": candidate_after[digest_key], "kind": kind}
            g09_artifacts.append(artifact)
            artifacts.append(artifact)
    g09_gate["evidence_artifacts"] = g09_artifacts

    g10_gate = next(gate for gate in gate_results if gate["gate"] == "G10")
    g10_gate["status"] = g10_status
    g10_gate["summary"] = g10_summary
    g10_gate["cleanup_verification"] = {
        "manifest_path": cleanup["manifest_path"],
        "manifest_sha256": cleanup["manifest_sha256"],
        "input_manifest_reverified": not frozen_input_errors,
        "retained_core_assets_unchanged": retained_equal,
        "release_candidate_path": candidate_after.get("directory") if candidate_after else None,
        "release_candidate_input_manifest_matches": bool(
            candidate_after and candidate_after.get("input_manifest_matches_current")),
        "release_candidate_source_identity_matches": candidate_binding_pass,
        "release_candidate_integrity_unchanged": release_unchanged,
        "candidate_dmg_mount_status": candidate_mount_status,
        "verifier_owned_processes_remaining": remaining_process_count,
        "issues": g10_issues,
    }
    g10_artifacts = []
    if cleanup["manifest_sha256"]:
        g10_artifacts.append({
            "path": cleanup["manifest_path"],
            "sha256": cleanup["manifest_sha256"],
            "kind": "post_cleanup_whitelist_manifest",
            "input_manifest_sha256": manifest_hash,
        })
        artifacts.append({"path": cleanup["manifest_path"],
                          "sha256": cleanup["manifest_sha256"],
                          "kind": "post_cleanup_whitelist_manifest"})
    if candidate_after:
        g10_artifacts.extend([
            {"path": candidate_after["manifest_path"],
             "sha256": candidate_after["manifest_sha256"],
             "kind": "current_release_candidate_manifest"},
            {"path": candidate_after["dmg_path"],
             "sha256": candidate_after["dmg_sha256"],
             "kind": "current_release_candidate_dmg"},
        ])
    g10_gate["evidence_artifacts"] = g10_artifacts
    mandatory_gate_failed = any(gate["status"] == "FAIL" for gate in gate_results)
    if host_free_only:
        xcode_action_status = "NOT_RUN"
    elif any(stage.get("status") == "FAIL" for stage in
           (xcode_debug, xcode_release, xcode_analyze, xcode_unit_build, xcode_ui_build)):
        xcode_action_status = "FAIL"
    elif xcode_assertion_failure or xcode_ui_status == "FAIL":
        xcode_action_status = "FAIL"
    elif xcode_runner_blocked or xcode_ui_status == "BLOCKED":
        xcode_action_status = "BLOCKED"
    elif xcode_core_ok and xcode_ui_status == "PASS":
        xcode_action_status = "PASS"
    else:
        xcode_action_status = "PARTIAL"

    report = {
        "schema_version": "latticelens-verify-2.0-final-local",
        "run_id": run_id,
        "report_path": report_path.relative_to(ROOT).as_posix(),
        "summary_path": summary_path.relative_to(ROOT).as_posix(),
        "recorded_at_utc": now,
        "product_version": "2.0.0",
        "build_number": 201,
        "input_manifest_sha256": manifest_hash,
        "input_manifest_path": manifest_path.relative_to(ROOT).as_posix(),
        "input_file_count": len(manifest_entries),
        "working_tree_dirty": git_dirty(),
        "verification_mode": "host_free_only" if host_free_only else "full_local",
        "candidate_audit_mode": "pre_package_validation" if arguments.pre_package_validation else
            ("explicit_manifest" if candidate_manifest_override else "timestamp_discovery"),
        "scope": ("Host-free project-local SwiftPM synthetic stores only; the verifier did not invoke xcodebuild, xcode-select, xcresulttool, or Xcode test actions. No live service, Keychain, Application Support library, personal PDF, or installed production app was accessed."
                  if host_free_only else
                  "Synthetic, project-local SwiftPM/Xcode stores and fixture app only; no live service, Keychain, Application Support library, personal PDF, or installed production app was accessed."),
        "stages": [{key: value for key, value in stage.items() if key != "log_path_scratch"} for stage in stages],
        "static_checks": static_results,
        "swift_tests": test_counts,
        "performance_benchmark": {
            "status": performance_status,
            "summary": performance_summary,
            "report_path": performance_output_path.relative_to(ROOT).as_posix() if performance_receipt_hash else None,
            "report_sha256": performance_receipt_hash,
            "input_manifest_sha256": manifest_hash,
            "dataset": performance_dataset,
            "recomputed_p95_ms": performance_p95,
            "validation_errors": performance_errors,
            "timeout_seconds": performance_stage["timeout_seconds"],
        },
        "migration_drill": migration_drill_report,
        "old_app_rollback_compatibility": old_app_rollback,
        "physical_disk_enospc_drill": physical_enospc,
        "xcode_actions": {
            "status": xcode_action_status,
            "destination": "platform=macOS,arch=arm64",
            "debug_build": xcode_debug["status"],
            "release_build": xcode_release["status"],
            "analyze": xcode_analyze["status"],
            "unit_build_for_testing": xcode_unit_build["status"],
            "unit_tests": {"status": xcode_unit["status"],
                            "runner_reason": xcode_unit.get("runner_reason"),
                            "summary": xcode_unit.get("xcresult_summary"),
                            "case_counts": xcode_unit.get("case_counts"),
                            "xcresult_summary_stage": unit_summary_stage["status"]},
            "ui_build_for_testing": xcode_ui_build["status"],
            "ui_tests": {"status": xcode_ui_status, "reason": xcode_ui_reason,
                          "runner_status": xcode_ui.get("status"),
                          "summary": xcode_ui.get("xcresult_summary"),
                          "xcresult_summary_stage": ui_summary_stage["status"]},
            "voiceover_manual": "NOT_RUN",
            "environment_note": ("Host-free mode does not invoke Xcode tooling; Xcode build/test acceptance remains NOT_RUN."
                                  if host_free_only else
                                  "A prior xcrun simctl diagnostic spawned xcodebuild -runFirstLaunch; only that task-owned process group was terminated. Any partial Xcode first-launch state change is unverified."),
        },
        "gate_results": gate_results,
        "manual_receipts": manual_receipts,
        "artifacts": artifacts,
        "optional": {"live_inspire": "NOT_RUN", "live_ar5iv": "NOT_RUN",
                     "live_remote_llm": "NOT_REQUIRED", "developer_id": "OUT_OF_SCOPE",
                     "notarization": "OUT_OF_SCOPE"},
        "cleanup": cleanup,
        "verdict": ("FAIL_NOT_FINAL" if mandatory_gate_failed or not cleanup["removed"] else
                    "FINAL" if all(gate["status"] == "PASS" for gate in gate_results) else
                    "PARTIAL_NOT_FINAL"),
    }
    report_hash = write_report(report_path, report)

    passed = sum(1 for gate in gate_results if gate["status"] == "PASS")
    markdown = [
        "# LatticeLens 2.0 Final Local Validation",
        "",
        "**Verdict: " + report["verdict"] + "** — " +
        ("all mandatory gates passed for this frozen local input." if report["verdict"] == "FINAL" else
         "mandatory gates remain incomplete; this is not a release receipt."),
        "",
        "Run ID: `" + run_id + "`  ",
        "Verification mode: `" + report["verification_mode"] + "`  ",
        "Candidate audit mode: `" + report["candidate_audit_mode"] + "`  ",
        "Input manifest SHA-256: `" + manifest_hash + "`  ",
        "Machine-readable report SHA-256: `" + report_hash + "`  ",
        "Working tree dirty: `" + str(report["working_tree_dirty"]).lower() + "`.",
        "",
        "## Current automated evidence",
        "",
        "- `swift test --scratch-path <run-scratch>/swiftpm -q`: " +
        str(test_counts["passed"]) + " passed, " + str(test_counts["failed"]) + " failed, " +
        str(test_counts["skipped"]) + " skipped out of " + str(test_counts["enumerated"]) + ".",
        "- Warnings-as-errors SwiftPM Release build: `" + swift_release["status"] + "`.",
        "- Xcode actions: `NOT_RUN` by host-free mode; no Xcode build, test runner, or result inspection was started."
        if host_free_only else
        "- Xcode: Debug `" + xcode_debug["status"] + "`, Release `" + xcode_release["status"] +
        "`, Analyze `" + xcode_analyze["status"] + "`, unit build-for-testing `" +
        xcode_unit_build["status"] + "`, unit test-without-building `" + xcode_unit["status"] +
        "` (" + str((xcode_unit.get("xcresult_summary") or {}).get("passed", "unknown")) +
        " passed / " + str((xcode_unit.get("xcresult_summary") or {}).get("failed", "unknown")) +
        " failed / " + str((xcode_unit.get("xcresult_summary") or {}).get("skipped", "unknown")) +
        " skipped); UI build-for-testing `" + xcode_ui_build["status"] + "`, test-without-building `" +
        xcode_ui_status + "`.",
        "- Static checks: " + str(sum(1 for item in static_results if item["status"] == "PASS")) +
        "/" + str(len(static_results)) + " passed.",
        "- Host-free accessibility fixture is included in SwiftPM counts; it is not XCUITest or VoiceOver acceptance.",
        "",
        "Skip allowlist:",
        "",
    ]
    markdown.extend("- `" + item["test"] + "`: " + item["reason"] for item in test_counts["skip_reasons"])
    markdown.extend(["", "## Mandatory gates", "", "| Gate | Status | Evidence boundary |", "| --- | --- | --- |"])
    markdown.extend("| " + gate["gate"] + " | " + gate["status"] + " | " + gate["summary"] + " |" for gate in gate_results)
    markdown.extend([
        "", "## Blockers and limits", "",
        "- Xcode unit runner: `" + xcode_unit["status"] + "` — " +
        (xcode_unit.get("runner_reason") or "see separate build/run stage receipts."),
        "- XCUITest: `" + xcode_ui_status + "` — " + xcode_ui_reason,
        "- Three-paper human physics review: `" + physics_manual["status"] + "` — " + physics_manual["reason"],
        "- Manual VoiceOver/responsive UI review: `" + voiceover_manual["status"] + "` — " + voiceover_manual["reason"],
        "- G02 V10-to-V12 disposable migration: `" + migration_drill_status + "` — " + migration_drill_summary,
        "- G02 1.0.11 restored-V9 rollback compatibility: `" + old_app_rollback["status"] + "` — " +
        old_app_rollback["summary"] +
        (" Receipt: `" + old_app_rollback["receipt_path"] + "` (SHA-256 `" +
         old_app_rollback["receipt_sha256"] + "`)." if old_app_rollback.get("receipt_path") else ""),
        "- G08 V12 disk benchmark: `" + performance_status + "` — " + performance_summary,
        "- G07 injected post-stage rejection checkpoints now verify exact new-store-family removal and unchanged Bundle bytes; disk-backed Radar/Compare/Notebook/Search persistence and rejected Compare matrix preservation are also required SwiftPM cases. Interactive Bundle UI/relaunch acceptance remains NOT_RUN.",
        "- G09 package/install: `" + g09_gate["status"] + "` — " + g09_gate["summary"],
        "- A prior `xcrun simctl list devices available` diagnostic started `xcodebuild -runFirstLaunch`; its task-owned process group was terminated. Any partial global Xcode initialization effect is unverified; no global cleanup was attempted.",
        "- Live INSPIRE/ar5iv/provider checks were not run and are not substituted by fixtures.",
        "- The verifier writes a report when incomplete; `PARTIAL_NOT_FINAL` distinguishes unverified/blocked gates from explicit gate failures, and only `FINAL` returns zero.",
        "", "## Reproduction", "",
        "From the project directory run: `zsh Scripts/verify_2_0_final.sh --local-only" +
        (" --host-free-only" if host_free_only else "") +
        (" --run-specific-outputs" if arguments.run_specific_outputs else "") + "`.",
        "The run creates a unique project-local scratch, uses only synthetic stores, clears live opt-ins, freezes a source manifest before tests, runs the V12 performance opt-in as a separate manifest-bound stage, and removes only its own scratch after child processes exit."
        + (" Host-free mode records every Xcode stage as NOT_RUN and does not invoke Xcode tooling." if host_free_only else ""),
        "", "Raw stage log: `" + log_path.relative_to(ROOT).as_posix() + "`.",
    ])
    summary_path.write_text("\n".join(markdown) + "\n", encoding="utf-8")

    print("verdict=" + report["verdict"])
    print("swift_tests=" + str(test_counts["passed"]) + " passed / " + str(test_counts["failed"]) + " failed / " + str(test_counts["skipped"]) + " skipped")
    print("release_build=" + swift_release["status"])
    print("G08_performance=" + performance_status)
    print("mandatory_gates_passed=" + str(passed) + "/" + str(len(gate_results)))
    print("report=" + report_path.relative_to(ROOT).as_posix())
    print("summary=" + summary_path.relative_to(ROOT).as_posix())
    return 0 if report["verdict"] == "FINAL" else 1


if __name__ == "__main__":
    sys.exit(main())
