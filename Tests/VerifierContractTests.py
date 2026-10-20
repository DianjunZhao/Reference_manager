#!/usr/bin/env python3
"""Contract tests for the project-local final verification manifest."""

import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch


ROOT = Path(__file__).resolve().parent.parent
VERIFIER_PATH = ROOT / "Scripts" / "verify_2_0_final.py"
SPEC = importlib.util.spec_from_file_location("verify_2_0_final", VERIFIER_PATH)
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)
OLD_APP_DRILL_PATH = ROOT / "Scripts" / "g02_old_app_rollback_drill.py"
OLD_APP_DRILL_SPEC = importlib.util.spec_from_file_location(
    "g02_old_app_rollback_drill", OLD_APP_DRILL_PATH)
OLD_APP_DRILL = importlib.util.module_from_spec(OLD_APP_DRILL_SPEC)
OLD_APP_DRILL_SPEC.loader.exec_module(OLD_APP_DRILL)
PACKAGE_SCRIPT_PATH = ROOT / "Scripts" / "package_2_0_local_candidate.py"
PACKAGE_SCRIPT_SPEC = importlib.util.spec_from_file_location(
    "package_2_0_local_candidate", PACKAGE_SCRIPT_PATH)
PACKAGE_SCRIPT = importlib.util.module_from_spec(PACKAGE_SCRIPT_SPEC)
PACKAGE_SCRIPT_SPEC.loader.exec_module(PACKAGE_SCRIPT)


def write_candidate_checksums(candidate_directory):
    candidate_directory = Path(candidate_directory)
    files = sorted(path for path in candidate_directory.rglob("*")
                   if path.is_file() and path.name != "SHA256SUMS.txt")
    sums = "\n".join(
        VERIFIER.sha256_file(path) + "  " + path.relative_to(candidate_directory).as_posix()
        for path in files
    ) + "\n"
    (candidate_directory / "SHA256SUMS.txt").write_text(sums, encoding="utf-8")


def make_v2_1_candidate_fixture(temporary_root, directory_name, generated_at_utc):
    temporary_root = Path(temporary_root)
    candidate = temporary_root / "release-assets" / directory_name
    compact = candidate / "compact-validation"
    compact.mkdir(parents=True)
    evidence = temporary_root / "evidence"
    evidence.mkdir(exist_ok=True)

    for relative, contents in (
            ("Sources/Fixture.swift", "let fixtureValue = 1\n"),
            ("Package.swift", "// synthetic package input\n"),
            ("README.md", "Synthetic local candidate contract.\n"),
            ("CHANGELOG.md", "Synthetic candidate fixture.\n")):
        path = temporary_root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")

    source_entries, source_errors = VERIFIER.build_input_source_entries(temporary_root)
    if source_errors:
        raise AssertionError("invalid synthetic source entries: " + "; ".join(source_errors))
    verifier_run_id = "verifier-" + directory_name
    package_run_id = "package-" + directory_name

    def write_json(path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, ensure_ascii=False, sort_keys=True,
                                   separators=(",", ":")) + "\n", encoding="utf-8")

    def file_entry(path):
        return {
            "path": path.relative_to(temporary_root).as_posix(),
            "kind": "file",
            "bytes": path.stat().st_size,
            "sha256": VERIFIER.sha256_file(path),
        }

    input_manifest_path = evidence / "inputs.json"
    write_json(input_manifest_path, {
        "schema_version": "latticelens-input-manifest-v1",
        "run_id": verifier_run_id,
        "created_at_utc": "2026-10-16T00:00:00Z",
        "files": source_entries,
    })
    input_manifest_hash = VERIFIER.sha256_file(input_manifest_path)

    performance_path = evidence / "performance.json"
    migration_path = evidence / "migration.json"
    summary_path = evidence / "validation.md"
    validation_path = evidence / "validation.json"
    write_json(performance_path, {"input_manifest_sha256": input_manifest_hash})
    write_json(migration_path, {"inputManifestSHA256": input_manifest_hash})
    summary_path.write_text("Synthetic validation summary.\n", encoding="utf-8")
    write_json(validation_path, {
        "schema_version": "latticelens-verify-2.0-final-local",
        "run_id": verifier_run_id,
        "report_path": "evidence/validation.json",
        "input_manifest_path": "evidence/inputs.json",
        "input_manifest_sha256": input_manifest_hash,
        "summary_path": "evidence/validation.md",
        "performance_benchmark": {
            "report_path": "evidence/performance.json",
            "report_sha256": VERIFIER.sha256_file(performance_path),
        },
        "migration_drill": {
            "receipt_path": "evidence/migration.json",
            "receipt_sha256": VERIFIER.sha256_file(migration_path),
        },
    })

    roles = (
        ("validation_report", validation_path, "validation.json"),
        ("input_manifest", input_manifest_path, "inputs.json"),
        ("validation_summary", summary_path, "validation.md"),
        ("performance", performance_path, "performance.json"),
        ("migration", migration_path, "migration.json"),
    )
    relocation_records = []
    package_validation = {}
    for role, source, filename in roles:
        packaged = compact / filename
        packaged.write_bytes(source.read_bytes())
        record = {
            "role": role,
            "source_path": source.relative_to(temporary_root).as_posix(),
            "package_path": packaged.relative_to(candidate).as_posix(),
            "sha256": VERIFIER.sha256_file(packaged),
        }
        relocation_records.append(record)
        if role == "validation_report":
            package_validation["report"] = record["package_path"]
            package_validation["report_sha256"] = record["sha256"]
        elif role == "input_manifest":
            package_validation["input_manifest"] = {
                "path": record["package_path"], "source_path": record["source_path"],
                "sha256": record["sha256"],
            }
        elif role == "validation_summary":
            package_validation["summary"] = {
                "path": record["package_path"], "source_path": record["source_path"],
                "sha256": record["sha256"],
            }
        else:
            package_validation[role] = {
                "path": record["package_path"], "source_path": record["source_path"],
                "sha256": record["sha256"],
            }

    for source_path in sorted(VERIFIER.G10_HISTORICAL_CONTEXT_PATHS):
        source = temporary_root / source_path
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text("Synthetic preserved historical context.\n", encoding="utf-8")
        packaged = compact / source.name
        packaged.write_bytes(source.read_bytes())
        relocation_records.append({
            "role": "historical_context",
            "source_path": source_path,
            "package_path": packaged.relative_to(candidate).as_posix(),
            "sha256": VERIFIER.sha256_file(packaged),
        })

    relocation_records.sort(key=lambda item: (item["role"], item["source_path"]))
    relocation_index_path = compact / "relocation-index.json"
    write_json(relocation_index_path, {
        "schema_version": VERIFIER.PACKAGE_RELOCATION_INDEX_SCHEMA,
        "package_run_id": package_run_id,
        "validation_run_id": verifier_run_id,
        "files": relocation_records,
    })
    package_validation.update({
        "path_base": "package-relative-v1",
        "relocation_index": {
            "path": relocation_index_path.relative_to(candidate).as_posix(),
            "sha256": VERIFIER.sha256_file(relocation_index_path),
        },
    })

    build_entries = list(source_entries) + [
        file_entry(path) for path in
        (validation_path, summary_path, input_manifest_path, performance_path, migration_path)
    ]
    build_input_path = candidate / "build-inputs-v2.0.json"
    write_json(build_input_path, {
        "schema_version": "latticelens-build-input-manifest-v2.0",
        "run_id": package_run_id,
        "files": build_entries,
    })
    dmg_path = candidate / "LatticeLens-2.0.0-local.dmg"
    dsym_path = candidate / "LatticeLens-2.0.0.dSYM.zip"
    dmg_path.write_bytes(b"synthetic dmg")
    dsym_path.write_bytes(b"synthetic dsym")

    manifest = {
        "schema_version": VERIFIER.PACKAGE_MANIFEST_V2_1,
        "run_id": package_run_id,
        "generated_at_utc": generated_at_utc,
        "release_status": "PARTIAL_NOT_FINAL",
        "app": {"executable_sha256": "a" * 64},
        "artifacts": {
            "dmg": {"file": dmg_path.name, "sha256": VERIFIER.sha256_file(dmg_path)},
            "dsym": {"file": dsym_path.name, "sha256": VERIFIER.sha256_file(dsym_path)},
        },
        "build_input_manifest": {
            "file": build_input_path.name,
            "sha256": VERIFIER.sha256_file(build_input_path),
            "input_verifier_manifest_sha256": input_manifest_hash,
        },
        "validation": package_validation,
        "checks": {name: "PASS" for name in VERIFIER.G10_PACKAGE_CHECKS},
    }
    manifest_path = candidate / "manifest-v2.0-local-candidate.json"
    write_json(manifest_path, manifest)
    write_candidate_checksums(candidate)
    return {
        "candidate": candidate,
        "manifest_path": manifest_path,
        "manifest": manifest,
        "evidence": evidence,
        "input_manifest_hash": input_manifest_hash,
        "source_entries": source_entries,
    }


class OldAppRollbackProcessCleanupTests(unittest.TestCase):
    def setUp(self):
        OLD_APP_DRILL.UNSTOPPED_PROCESS_GROUPS.clear()
        OLD_APP_DRILL.PROCESS_TERMINATION_ERRORS.clear()

    def tearDown(self):
        OLD_APP_DRILL.UNSTOPPED_PROCESS_GROUPS.clear()
        OLD_APP_DRILL.PROCESS_TERMINATION_ERRORS.clear()

    def test_group_sigterm_permission_error_falls_back_to_the_owned_child(self):
        process = Mock()
        process.pid = 41234
        process.poll.return_value = 0
        with patch.object(OLD_APP_DRILL.os, "killpg",
                          side_effect=[PermissionError(1, "group signal denied"),
                                       ProcessLookupError()]), \
                patch.object(process, "terminate") as terminate:
            stopped = OLD_APP_DRILL.terminate_process(process)

        self.assertTrue(stopped)
        terminate.assert_called_once_with()
        self.assertNotIn(process.pid, OLD_APP_DRILL.UNSTOPPED_PROCESS_GROUPS)
        self.assertTrue(any("group SIGTERM denied" in item
                            for item in OLD_APP_DRILL.PROCESS_TERMINATION_ERRORS))

    def test_denied_group_and_child_signals_fail_closed_without_raising(self):
        process = Mock()
        process.pid = 41235
        process.poll.return_value = None
        with patch.object(OLD_APP_DRILL.os, "killpg",
                          side_effect=PermissionError(1, "group signal denied")), \
                patch.object(process, "terminate",
                             side_effect=PermissionError(1, "child signal denied")):
            stopped = OLD_APP_DRILL.terminate_process(process)

        self.assertFalse(stopped)
        self.assertIn(process.pid, OLD_APP_DRILL.UNSTOPPED_PROCESS_GROUPS)
        self.assertTrue(any("direct-child SIGTERM denied" in item
                            for item in OLD_APP_DRILL.PROCESS_TERMINATION_ERRORS))

    def test_orca_cli_uses_host_runtime_home_not_the_isolated_product_home(self):
        command = ["orca", "computer", "list-apps", "--json"]
        expected = {"ok": True, "result": {}}
        with patch.dict(OLD_APP_DRILL.os.environ, {
                "HOME": "/project/scratch/isolated-home",
                "CFFIXED_USER_HOME": "/project/scratch/isolated-home",
                "TMPDIR": "/project/scratch/tmp",
        }), patch.object(OLD_APP_DRILL, "run_logged", return_value=json.dumps(expected)) as run_logged:
            result = OLD_APP_DRILL.orca_result(command, ROOT / "unused-orca-log.json")

        host_home = str(Path(OLD_APP_DRILL.pwd.getpwuid(OLD_APP_DRILL.os.getuid()).pw_dir).resolve())
        self.assertEqual(result, {})
        self.assertEqual(run_logged.call_args.kwargs["environment"]["HOME"], host_home)
        self.assertEqual(run_logged.call_args.kwargs["environment"]["CFFIXED_USER_HOME"], host_home)
        self.assertEqual(run_logged.call_args.kwargs["environment"]["TMPDIR"], "/project/scratch/tmp")

    def test_same_bundle_app_selection_uses_the_task_owned_pid(self):
        user_app = {"pid": 12307, "bundleId": OLD_APP_DRILL.OLD_APP_BUNDLE_ID,
                    "isRunning": True}
        fixture_app = {"pid": 424242, "bundleId": OLD_APP_DRILL.OLD_APP_BUNDLE_ID,
                       "isRunning": True}

        selected = OLD_APP_DRILL.require_running_fixture_process(
            [user_app, fixture_app], 424242)

        self.assertIs(selected, fixture_app)

    def test_task_group_app_selection_excludes_the_preexisting_same_bundle_app(self):
        user_app = {"pid": 12307, "bundleId": OLD_APP_DRILL.OLD_APP_BUNDLE_ID,
                    "isRunning": True}
        fixture_app = {"pid": 424242, "bundleId": OLD_APP_DRILL.OLD_APP_BUNDLE_ID,
                       "isRunning": True}
        with patch.object(OLD_APP_DRILL.os, "getpgid",
                          side_effect=lambda process_id: {
                              12307: 12307, 424242: 41234,
                          }[process_id]):
            selected = OLD_APP_DRILL.task_group_fixture_processes(
                [user_app, fixture_app], 41234)

        self.assertEqual(selected, [fixture_app])

    def test_task_group_app_selection_fails_closed_when_same_bundle_is_not_owned(self):
        user_app = {"pid": 12307, "bundleId": OLD_APP_DRILL.OLD_APP_BUNDLE_ID,
                    "isRunning": True}
        with patch.object(OLD_APP_DRILL.os, "getpgid", return_value=12307):
            selected = OLD_APP_DRILL.task_group_fixture_processes([user_app], 41234)

        self.assertEqual(selected, [])

    def test_fixture_app_quit_targets_exact_pid_and_ignores_same_bundle_user_app(self):
        user_app = {"pid": 12307, "bundleId": OLD_APP_DRILL.OLD_APP_BUNDLE_ID,
                    "isRunning": True}
        fixture_app = {"pid": 424242, "bundleId": OLD_APP_DRILL.OLD_APP_BUNDLE_ID,
                       "isRunning": True}
        with tempfile.TemporaryDirectory(dir=ROOT, prefix=".codex-task-tmp-g02-contract-") as directory:
            scratch = Path(directory)
            with patch.object(OLD_APP_DRILL, "orca_result", side_effect=[
                    {"apps": [user_app, fixture_app]},
                    {"apps": [user_app]},
            ]) as orca_result, \
                    patch.object(OLD_APP_DRILL, "run_logged",
                                 return_value="graceful quit confirmed" ) as run_logged, \
                    patch.object(OLD_APP_DRILL.shutil, "which", return_value="/usr/bin/swift"), \
                    patch.object(OLD_APP_DRILL.time, "sleep") as sleep:
                OLD_APP_DRILL.request_fixture_app_quit("orca", 424242, scratch)

        self.assertEqual(orca_result.call_count, 2)
        self.assertTrue(all(call.args[0] == ["orca", "computer", "list-apps", "--json"]
                            for call in orca_result.call_args_list))
        quit_command = run_logged.call_args.args[0]
        swift_source = quit_command[quit_command.index("-e") + 1]
        self.assertIn("let targetPID: pid_t = 424242", swift_source)
        self.assertIn('target.bundleIdentifier == "org.latticelens.app"', swift_source)
        self.assertIn("target.terminate()", swift_source)
        self.assertNotIn("12307", swift_source)
        self.assertNotIn("CmdOrCtrl+Q", swift_source)
        self.assertEqual(run_logged.call_args.kwargs["environment"]["HOME"],
                         str(scratch / "old-app-home"))
        self.assertEqual(run_logged.call_args.kwargs["environment"]["TMPDIR"],
                         str(scratch / "old-app-tmp"))
        self.assertEqual(quit_command[1], "-module-cache-path")
        self.assertTrue(Path(quit_command[2]).is_relative_to(scratch))
        sleep.assert_not_called()

    def test_fixture_app_quit_refuses_a_stale_pid_before_requesting_termination(self):
        with patch.object(OLD_APP_DRILL, "orca_result", return_value={"apps": []}) as orca_result:
            with patch.object(OLD_APP_DRILL, "run_logged") as run_logged:
                with self.assertRaises(OLD_APP_DRILL.DrillError):
                    OLD_APP_DRILL.request_fixture_app_quit(
                        "orca", 424244, ROOT / ".codex-task-test")

        run_logged.assert_not_called()
        orca_result.assert_called_once()
        self.assertEqual(orca_result.call_args.args[0],
                         ["orca", "computer", "list-apps", "--json"])

    def test_old_app_sandbox_denies_reads_and_writes_to_system_temporary_paths(self):
        rules = OLD_APP_DRILL.sandbox_file_access_denials(
            OLD_APP_DRILL.SYSTEM_TEMPORARY_PATHS)
        darwin_temp_roots = [path for path in OLD_APP_DRILL.SYSTEM_TEMPORARY_PATHS
                             if Path(path).name == "T"]

        for path in OLD_APP_DRILL.SYSTEM_TEMPORARY_PATHS:
            quoted = json.dumps(path)
            self.assertIn("(deny file-read* (subpath " + quoted + "))", rules)
            self.assertIn("(deny file-write* (subpath " + quoted + "))", rules)
            self.assertTrue(OLD_APP_DRILL.path_is_under(path + "/fixture", (path,)))
        self.assertFalse(OLD_APP_DRILL.path_is_under(
            str(ROOT / ".codex-task-g02" / "fixture"),
            OLD_APP_DRILL.SYSTEM_TEMPORARY_PATHS))
        self.assertTrue(darwin_temp_roots)
        for path in darwin_temp_roots:
            self.assertTrue(OLD_APP_DRILL.path_is_under(
                str(Path(path) / "org.latticelens.app.savedState"),
                OLD_APP_DRILL.SYSTEM_TEMPORARY_PATHS))
            cache_sibling = str(Path(path).parent / "C" / "com.apple.LaunchServices-test.csstore")
            self.assertFalse(OLD_APP_DRILL.path_is_under(
                cache_sibling, OLD_APP_DRILL.SYSTEM_TEMPORARY_PATHS))

    def test_g02_temp_denylist_uses_preserved_host_T_after_child_tmpdir_is_isolated(self):
        host_temp = (OLD_APP_DRILL.os.environ.get("LATTICELENS_HOST_SYSTEM_TMPDIR") or
                     OLD_APP_DRILL.os.environ.get("TMPDIR", ""))
        with patch.dict(OLD_APP_DRILL.os.environ, {
                "TMPDIR": "/project/scratch/tmp",
                "LATTICELENS_HOST_SYSTEM_TMPDIR": host_temp,
        }):
            roots = OLD_APP_DRILL.darwin_user_temp_paths()

        self.assertIn(str(Path(host_temp)), roots)
        self.assertIn(str(Path(host_temp).resolve()), roots)
        self.assertNotIn("/project/scratch/tmp", roots)

    def test_lsof_failure_evidence_records_only_temp_basename_and_access_mode(self):
        lsof_lines = [
            "p424242", "f8w", "n/var/folders/host-specific/T/org.latticelens.app.savedState",
            "f9r", "n/project/scratch/fixture.store",
        ]
        temp_root = next(path for path in OLD_APP_DRILL.SYSTEM_TEMPORARY_PATHS
                         if Path(path).name == "T")
        lsof_lines[2] = "n" + str(Path(temp_root) / "org.latticelens.app.savedState")
        descriptors = OLD_APP_DRILL.parse_lsof_descriptors(lsof_lines)
        self.assertEqual(descriptors, OLD_APP_DRILL.parse_lsof_descriptors("\n".join(lsof_lines)))

        self.assertEqual(len(descriptors), 2)
        summary = OLD_APP_DRILL.system_temporary_descriptor_summary(descriptors)
        self.assertEqual(summary, [{
            "path_root": "darwin_user_temp",
            "basename": "org.latticelens.app.savedState",
            "descriptor": "8w",
            "access_mode": "write",
        }])
        self.assertNotIn("host-specific", json.dumps(summary))

    def test_old_app_saved_state_uses_isolated_home_without_relaxing_temp_denials(self):
        source = OLD_APP_DRILL_PATH.read_text(encoding="utf-8")

        self.assertIn('"-ApplePersistenceIgnoreState", "YES"', source)
        rules = OLD_APP_DRILL.sandbox_file_access_denials(
            OLD_APP_DRILL.SYSTEM_TEMPORARY_PATHS)
        self.assertNotIn('(deny file-write* (subpath "/var/folders"))', rules)
        self.assertNotIn('(deny file-read* (subpath "/var/folders"))', rules)
        for path in OLD_APP_DRILL.SYSTEM_TEMPORARY_PATHS:
            self.assertIn('(deny file-write* (subpath ' + json.dumps(path) + '))', rules)
            self.assertIn('(deny file-read* (subpath ' + json.dumps(path) + '))', rules)

    def test_package_orca_cli_uses_host_runtime_home_not_the_fixture_home(self):
        expected = {"ok": True, "result": {"apps": []}}
        with patch.dict(PACKAGE_SCRIPT.os.environ, {
                "HOME": "/project/scratch/isolated-home",
                "CFFIXED_USER_HOME": "/project/scratch/isolated-home",
                "TMPDIR": "/project/scratch/isolated-tmp",
        }), patch.object(PACKAGE_SCRIPT, "checked_run", return_value=json.dumps(expected)) as checked_run:
            result = PACKAGE_SCRIPT.orca_result(
                ["orca", "computer", "list-apps", "--json"],
                log=ROOT / "unused-package-orca-log.json",
            )

        host_home = str(Path(PACKAGE_SCRIPT.pwd.getpwuid(PACKAGE_SCRIPT.os.getuid()).pw_dir).resolve())
        self.assertEqual(result, {"apps": []})
        self.assertEqual(checked_run.call_args.kwargs["env"]["HOME"], host_home)
        self.assertEqual(checked_run.call_args.kwargs["env"]["CFFIXED_USER_HOME"], host_home)
        self.assertEqual(checked_run.call_args.kwargs["env"]["TMPDIR"], "/project/scratch/isolated-tmp")

    def test_package_quit_targets_exact_pid_and_confirms_app_disappearance(self):
        with patch.object(PACKAGE_SCRIPT, "orca_result", side_effect=[
                {"apps": [{"pid": 424243, "bundleId": "org.latticelens.app",
                           "isRunning": True}]},
                {"windows": [{"app": {"pid": 424243}, "id": 8, "index": 0}]},
                {},
                {"apps": []},
        ]) as orca_result, \
                patch.object(PACKAGE_SCRIPT.time, "sleep") as sleep:
            PACKAGE_SCRIPT.request_fixture_app_quit("orca", 424243, ROOT / ".codex-task-test")

        quit_command = orca_result.call_args_list[2].args[0]
        self.assertEqual(quit_command[:7], [
            "orca", "computer", "hotkey", "--app", "pid:424243", "--window-id", "8",
        ])
        self.assertEqual(quit_command[quit_command.index("--key") + 1], "CmdOrCtrl+Q")
        self.assertNotIn("--restore-window", quit_command)
        self.assertEqual(orca_result.call_args_list[3].args[0],
                         ["orca", "computer", "list-apps", "--json"])
        sleep.assert_not_called()

    def test_package_quit_refuses_a_stale_pid_before_sending_a_hotkey(self):
        with patch.object(PACKAGE_SCRIPT, "orca_result", return_value={"apps": []}) as orca_result:
            with self.assertRaises(RuntimeError):
                PACKAGE_SCRIPT.request_fixture_app_quit(
                    "orca", 424245, ROOT / ".codex-task-test")

        orca_result.assert_called_once()
        self.assertEqual(orca_result.call_args.args[0],
                         ["orca", "computer", "list-apps", "--json"])


class InputManifestContractTests(unittest.TestCase):
    def test_verifier_and_benchmark_fixture_share_the_project_release_identity(self):
        self.assertEqual((VERIFIER.PRODUCT_VERSION, VERIFIER.BUILD_NUMBER), ("2.0.0", 212))
        source = (ROOT / "Tests" / "LatticeLensTests" / "V4BenchmarkTests.swift").read_text(encoding="utf-8")
        match = re.search(r'"build_number":\s*(\d+)', source)
        self.assertIsNotNone(match)
        self.assertEqual(int(match.group(1)), VERIFIER.BUILD_NUMBER)

    def test_frozen_inputs_include_both_implementation_plans(self):
        inputs = {path.resolve() for path in VERIFIER.input_paths()}
        required = {
            ROOT / "INSPIRE文献管理器2.0_開工方案_v5.md",
            ROOT / "INSPIRE文獻管理器2.0_開工方案_final.md",
            ROOT / "Scripts/g02_old_app_rollback_drill.py",
            VERIFIER_PATH,
            Path(__file__),
        }

        self.assertTrue(required.issubset(inputs),
                        "The frozen input manifest must bind both the requested v5 plan "
                        "and its final closure plan.")

    def test_isolated_environment_keeps_host_temp_only_for_g02_denylist(self):
        host_temp = (VERIFIER.os.environ.get("LATTICELENS_HOST_SYSTEM_TMPDIR") or
                     VERIFIER.os.environ.get("TMPDIR", ""))
        with tempfile.TemporaryDirectory(dir=ROOT,
                                         prefix=".codex-task-tmp-host-temp-contract-") as directory:
            scratch = Path(directory)
            with patch.dict(VERIFIER.os.environ, {"TMPDIR": host_temp}, clear=False):
                environment = VERIFIER.isolated_environment(scratch)

        self.assertEqual(environment["TMPDIR"], str(scratch / "tmp"))
        self.assertEqual(environment["LATTICELENS_HOST_SYSTEM_TMPDIR"], host_temp)

    def test_run_specific_receipts_do_not_target_the_existing_canonical_files(self):
        run_id = "20261003T120000Z-a1b2c3d4"
        report, summary = VERIFIER.report_output_paths(run_id, True)

        self.assertEqual(report, ROOT / "evidence" / ("Validation-2.0-final-local-" + run_id + ".json"))
        self.assertEqual(summary, ROOT / "evidence" / ("Validation-2.0-final-local-" + run_id + ".md"))
        self.assertNotEqual(report, VERIFIER.REPORT_PATH)
        self.assertNotEqual(summary, VERIFIER.SUMMARY_PATH)
        self.assertTrue(report.is_relative_to(ROOT / "evidence"))
        self.assertTrue(summary.is_relative_to(ROOT / "evidence"))

    def test_host_free_xcode_dispatch_records_not_run_without_starting_xcode(self):
        with tempfile.TemporaryDirectory(dir=ROOT, prefix=".codex-task-tmp-host-free-contract-") as directory:
            scratch = Path(directory)
            with patch.object(VERIFIER, "run_stage") as run_stage:
                stage = VERIFIER.run_xcode_stage(
                    "xcode-debug-build", ["xcodebuild", "build"], scratch, {}, 900, True)

            run_stage.assert_not_called()
            self.assertEqual(stage["status"], "NOT_RUN")
            self.assertIn("no Xcode", stage["not_run_reason"])
            self.assertTrue(stage["log_path_scratch"].is_relative_to(scratch))

            with patch.object(VERIFIER, "collect_xcresult_summary") as collect:
                summary_stage, summary = VERIFIER.collect_xcode_summary(
                    scratch / "missing.xcresult", scratch, {}, "xcode-summary", True)

            collect.assert_not_called()
            self.assertEqual(summary_stage["status"], "NOT_RUN")
            self.assertIsNone(summary)

    def test_not_run_xcode_test_never_enters_failure_classifier(self):
        stage = {"status": "NOT_RUN", "not_run_reason": "host-free policy"}
        with patch.object(VERIFIER, "classify_xcode_test_stage") as classify:
            status, reason = VERIFIER.classify_xcode_test_if_run(stage, "", None)

        classify.assert_not_called()
        self.assertEqual(status, "NOT_RUN")
        self.assertEqual(reason, "host-free policy")

    def test_host_free_option_is_advertised_by_the_verifier_cli(self):
        result = subprocess.run(
            [sys.executable, "-B", str(VERIFIER_PATH), "--help"],
            cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, check=False,
        )

        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("--host-free-only", result.stdout)
        self.assertIn("old-app GUI rollback actions NOT_RUN", result.stdout)

    def test_host_free_mode_does_not_start_the_old_app_or_gui_rollback_drill(self):
        with tempfile.TemporaryDirectory(dir=ROOT, prefix=".codex-task-tmp-host-free-g02-") as directory:
            scratch = Path(directory)
            with patch.object(VERIFIER, "run_stage") as run_stage:
                stage = VERIFIER.run_old_app_rollback_stage(
                    scratch, {}, "a" * 64, True)

            run_stage.assert_not_called()
            self.assertEqual(stage["status"], "NOT_RUN")
            self.assertIn("no application, GUI", stage["not_run_reason"])
            self.assertTrue(stage["log_path_scratch"].is_relative_to(scratch))

    def test_not_run_old_app_rollback_is_not_reclassified_as_failure(self):
        with tempfile.TemporaryDirectory(dir=ROOT, prefix=".codex-task-tmp-host-free-g02-receipt-") as directory:
            receipt_path = Path(directory) / "missing-receipt.json"
            result = VERIFIER.validate_old_app_rollback_receipt(
                receipt_path, "b" * 64, "NOT_RUN")

        self.assertEqual(result["status"], "NOT_RUN")
        self.assertEqual(result["validation_errors"], [])

    def test_child_environment_uses_project_local_roots_and_drops_external_store_opt_ins(self):
        scratch = ROOT / ".codex-task-tmp-verifier-contract"
        environment = VERIFIER.isolated_environment(scratch, {
            "TMPDIR": "/var/tmp",
            "LATTICELENS_LIVE_INSPIRE_SMOKE": "1",
            "LATTICELENS_RUN_V11_FORMULA_BENCHMARK": "1",
            "LATTICELENS_RUN_V12_FORMULA_BENCHMARK": "1",
            "LATTICELENS_V12_FORMULA_BENCHMARK_ROOT": "/outside/benchmark",
            "LATTICELENS_V12_FORMULA_BENCHMARK_OUTPUT": "/outside/benchmark.json",
            "LATTICELENS_V5_DISPOSABLE_V7_STORE": "/outside/user-data.store",
            "LATTICELENS_V10_DISPOSABLE_DRILL_ROOT": "/outside/migration-output",
            "LATTICELENS_V10_DISPOSABLE_INPUT_MANIFEST_SHA256": "stale-manifest",
            "LATTICELENS_ALLOW_PRODUCTION_ISOLATION": "1",
            "LATTICELENS_PRODUCTION_STORE_ROOT": "/outside/production-store",
            "KEEP_UNRELATED_SETTING": "unchanged",
        })

        self.assertEqual(environment["TMPDIR"], str(scratch / "tmp"))
        self.assertEqual(environment["HOME"], str(scratch / "home"))
        self.assertEqual(environment["CFFIXED_USER_HOME"], str(scratch / "home"))
        self.assertEqual(environment["LATTICELENS_TEST_STORE_ROOT"], str(scratch / "test-stores"))
        self.assertEqual(environment["LATTICELENS_TEST_TMP_ROOT"], str(scratch / "tmp" / "test-host"))
        self.assertEqual(environment["LATTICELENS_REQUIRE_PROJECT_LOCAL_TEST_ROOTS"], "1")
        self.assertNotIn("LATTICELENS_LIVE_INSPIRE_SMOKE", environment)
        self.assertNotIn("LATTICELENS_RUN_V11_FORMULA_BENCHMARK", environment)
        self.assertNotIn("LATTICELENS_RUN_V12_FORMULA_BENCHMARK", environment)
        self.assertNotIn("LATTICELENS_V12_FORMULA_BENCHMARK_ROOT", environment)
        self.assertNotIn("LATTICELENS_V12_FORMULA_BENCHMARK_OUTPUT", environment)
        self.assertNotIn("LATTICELENS_V5_DISPOSABLE_V7_STORE", environment)
        self.assertNotIn("LATTICELENS_V10_DISPOSABLE_DRILL_ROOT", environment)
        self.assertNotIn("LATTICELENS_V10_DISPOSABLE_INPUT_MANIFEST_SHA256", environment)
        self.assertNotIn("LATTICELENS_ALLOW_PRODUCTION_ISOLATION", environment)
        self.assertNotIn("LATTICELENS_PRODUCTION_STORE_ROOT", environment)
        self.assertEqual(environment["KEEP_UNRELATED_SETTING"], "unchanged")

    def test_manifest_bound_v10_to_v12_drill_is_an_explicit_mandatory_stage(self):
        self.assertIn("testAuthorizedDisposableV10ToV12MigrationDrill", VERIFIER.SKIP_ALLOWLIST)
        self.assertEqual(VERIFIER.V10_MIGRATION_DRILL_TEST,
                         "V4LocalTests/testAuthorizedDisposableV10ToV12MigrationDrill")

    def test_optional_live_author_window_smoke_skip_is_allowlisted(self):
        test_name = "testOptInLiveAuthorPartitionCompletesAcrossINSPIREWindow"
        self.assertEqual(VERIFIER.SKIP_ALLOWLIST[test_name],
                         "Live INSPIRE author-window smoke is opt-in and was not enabled.")
        summary = VERIFIER.parse_test_summary(
            "Test Suite 'LatticeLensTests.xctest' passed at 2026-10-18 00:00:00.000.\n"
            "\t Executed 1 test, with 1 test skipped and 0 failures (0 unexpected) in 0.001 seconds.\n"
            f"Test Case '-[LatticeLensTests.CoreContractTests {test_name}]' skipped "
            "- requires explicit read-only INSPIRE author-window smoke opt-in (0.001 seconds)\n"
        )
        self.assertEqual(summary["unknown_skips"], [])
        self.assertTrue(summary["skip_reasons"][0]["allowlisted"])

    def test_verifier_hash_format_version_matches_swift_canonical_fingerprint(self):
        source = (ROOT / "Sources" / "LatticeLens" / "Core" / "Persistence" /
                 "V4NormalizedStore.swift").read_text(encoding="utf-8")
        self.assertIn(
            f"static let formatVersion = {VERIFIER.CURRENT_CANONICAL_LIBRARY_HASH_FORMAT_VERSION}",
            source)
        self.assertIn(
            f'latticelens-library-snapshot-v{VERIFIER.CURRENT_CANONICAL_LIBRARY_HASH_FORMAT_VERSION}\\n',
            source)

    def test_v10_to_v12_drill_receipt_validator_fails_closed_on_stale_manifest(self):
        digest = "a" * 64
        receipt = {
            "schemaVersion": "latticelens-v10-disposable-migration-drill-v5",
            "sourceOrigin": "synthetic_generated",
            "inputManifestSHA256": digest,
            "successfulMigration": {
                "sourceSchemaVersion": 10, "targetSchemaVersion": 12, "journalPhase": "activated",
                "sourceFamilyHashes": {"synthetic.store": digest},
                "sourceRecordCounts": {"papers": 1, "typed.searchIndexStates": 1},
                "targetRecordCounts": {"papers": 1, "typed.searchIndexStates": 2},
                "legacyCategoryCheckpointCount": 1,
                "sourceLegacyCheckpointInvalidationCount": None,
                "targetLegacyCheckpointInvalidationCount": 1,
                "sourceLibraryHashFormatVersion": VERIFIER.CURRENT_CANONICAL_LIBRARY_HASH_FORMAT_VERSION,
                "targetLibraryHashFormatVersion": VERIFIER.CURRENT_CANONICAL_LIBRARY_HASH_FORMAT_VERSION,
                "sourceStableIDHash": digest, "targetStableIDHash": "b" * 64,
                "backupManifestHash": digest,
                "backupVerified": True, "semanticReconciliationPassed": True,
                "sourceFamilyUnchanged": True, "descriptorSchemaVersion": 12,
                "descriptorSemanticHash": "b" * 64,
            },
            "postActivationRestore": {
                "sourceSchemaVersion": 10, "restoredSchemaVersion": 10,
                "productionSchemaVersion": 12, "productionMigrationPhase": "activated",
                "sourceRecordCounts": {"papers": 1, "typed.searchIndexStates": 1},
                "restoredRecordCounts": {"papers": 1, "typed.searchIndexStates": 1},
                "productionRecordCounts": {"papers": 1, "typed.searchIndexStates": 2},
                "sourceLibraryHashFormatVersion": VERIFIER.CURRENT_CANONICAL_LIBRARY_HASH_FORMAT_VERSION,
                "restoredLibraryHashFormatVersion": VERIFIER.CURRENT_CANONICAL_LIBRARY_HASH_FORMAT_VERSION,
                "productionLibraryHashFormatVersion": VERIFIER.CURRENT_CANONICAL_LIBRARY_HASH_FORMAT_VERSION,
                "sourceStableIDHash": digest, "restoredStableIDHash": digest,
                "productionStableIDHash": "b" * 64,
                "productionDescriptorSemanticHash": "b" * 64,
                "backupManifestHash": digest,
                "restoredFamilyHashes": {"synthetic.store": digest},
                "restoreTargetWasAbsent": True, "backupVerified": True,
                "restoredFamilyMatchesManifest": True, "semanticReconciliationPassed": True,
                "productionStoreOpenPassed": True,
            },
            "rollback": {
                "sourceSchemaVersion": 10, "targetSchemaVersion": 12,
                "journalPhaseBeforeRecovery": "verified", "recoveredJournalPhase": "rolledBack",
                "sourceFamilyHashes": {"synthetic.store": digest},
                "sourceLibraryHashFormatVersion": VERIFIER.CURRENT_CANONICAL_LIBRARY_HASH_FORMAT_VERSION,
                "recoveredLibraryHashFormatVersion": VERIFIER.CURRENT_CANONICAL_LIBRARY_HASH_FORMAT_VERSION,
                "sourceStableIDHash": digest, "recoveredSourceStableIDHash": digest,
                "backupVerified": True, "sourceFamilyUnchanged": True,
                "sourceSemanticUnchanged": True, "activeDescriptorAbsent": True,
                "stagingRemoved": True,
            },
        }
        path = Mock()
        path.is_file.return_value = True
        path.read_bytes.return_value = json.dumps(receipt).encode("utf-8")

        validated, errors = VERIFIER.validate_v10_to_v12_migration_receipt(path, digest)
        self.assertIsNotNone(validated)
        self.assertEqual(errors, [])

        receipt["successfulMigration"]["targetRecordCounts"]["typed.searchIndexStates"] = 3
        path.read_bytes.return_value = json.dumps(receipt).encode("utf-8")
        _, count_errors = VERIFIER.validate_v10_to_v12_migration_receipt(path, digest)
        self.assertTrue(any("record-count changes exceed" in error for error in count_errors))

        receipt["successfulMigration"]["targetRecordCounts"]["typed.searchIndexStates"] = 2
        receipt["successfulMigration"]["targetLegacyCheckpointInvalidationCount"] = 2
        path.read_bytes.return_value = json.dumps(receipt).encode("utf-8")
        _, marker_errors = VERIFIER.validate_v10_to_v12_migration_receipt(path, digest)
        self.assertTrue(any("expected legacy checkpoint invalidation marker" in error
                            for error in marker_errors))
        receipt["successfulMigration"]["targetLegacyCheckpointInvalidationCount"] = 1

        legacy_format_receipt = json.loads(json.dumps(receipt))
        for key in ("sourceLibraryHashFormatVersion", "targetLibraryHashFormatVersion"):
            legacy_format_receipt["successfulMigration"][key] = 2
        for key in ("sourceLibraryHashFormatVersion", "restoredLibraryHashFormatVersion",
                    "productionLibraryHashFormatVersion"):
            legacy_format_receipt["postActivationRestore"][key] = 2
        for key in ("sourceLibraryHashFormatVersion", "recoveredLibraryHashFormatVersion"):
            legacy_format_receipt["rollback"][key] = 2
        path.read_bytes.return_value = json.dumps(legacy_format_receipt).encode("utf-8")
        _, legacy_errors = VERIFIER.validate_v10_to_v12_migration_receipt(path, digest)
        self.assertTrue(any("current canonical library-hash format" in error
                            for error in legacy_errors))
        self.assertTrue(any("current canonical semantic hash format" in error
                            for error in legacy_errors))
        self.assertTrue(any("canonical library semantic summary" in error
                            for error in legacy_errors))

        path.read_bytes.return_value = json.dumps(receipt).encode("utf-8")
        receipt["postActivationRestore"]["restoreTargetWasAbsent"] = False
        path.read_bytes.return_value = json.dumps(receipt).encode("utf-8")
        _, restore_errors = VERIFIER.validate_v10_to_v12_migration_receipt(path, digest)
        self.assertTrue(any("restoreTargetWasAbsent" in error for error in restore_errors))

        receipt["postActivationRestore"]["restoreTargetWasAbsent"] = True
        path.read_bytes.return_value = json.dumps(receipt).encode("utf-8")
        _, stale_errors = VERIFIER.validate_v10_to_v12_migration_receipt(path, "b" * 64)
        self.assertTrue(any("frozen input manifest" in error for error in stale_errors))

    def test_v12_performance_validator_rejects_stale_v11_schema(self):
        path = Mock()
        path.is_file.return_value = True
        path.read_text.return_value = json.dumps({
            "schema_version": "latticelens-benchmark-v11-formula",
            "persistence_schema_version": 11,
        })

        validated, errors = VERIFIER.validate_v12_performance_report(path, "a" * 64)

        self.assertIsNotNone(validated)
        self.assertTrue(any("Unexpected V12 benchmark report schema" in error for error in errors))
        self.assertTrue(any("current V12 persistence schema" in error for error in errors))

    def test_swiftpm_build_and_shared_state_are_confined_to_run_scratch(self):
        scratch = ROOT / ".codex-task-tmp-verifier-contract"
        options = VERIFIER.swiftpm_options(scratch)
        for option in ("--scratch-path", "--cache-path", "--config-path", "--security-path"):
            path = Path(options[options.index(option) + 1]).resolve()
            self.assertTrue(path.is_relative_to(scratch.resolve()),
                            option + " must remain inside the verifier's project-local scratch")

        self.assertEqual(options[options.index("--manifest-cache") + 1], "local")
        self.assertIn("--disable-dependency-cache", options)

    def test_xcode_unit_and_ui_commands_split_build_from_test_runner(self):
        base = ["xcodebuild", "-project", "LatticeLens.xcodeproj",
                "-destination", "platform=macOS,arch=arm64", "-jobs", "2"]
        derived = ROOT / ".codex-task-audit-2-final.contract" / "xcode" / "unit-derived"
        result = ROOT / ".codex-task-audit-2-final.contract" / "xcode" / "unit.xcresult"
        store = ROOT / ".codex-task-audit-2-final.contract" / "test-stores" / "unit"
        test_tmp = ROOT / ".codex-task-audit-2-final.contract" / "tmp" / "ui-host"

        build_command, test_command = VERIFIER.xcode_test_commands(
            base, "LatticeLens-Unit", derived, result, store, test_tmp_root=test_tmp)

        self.assertEqual(build_command[-1], "build-for-testing")
        self.assertEqual(test_command[-1], "test-without-building")
        self.assertIn("CODE_SIGNING_REQUIRED=YES", build_command)
        self.assertIn("CODE_SIGNING_REQUIRED=YES", test_command)
        self.assertEqual(build_command[build_command.index("-derivedDataPath") + 1],
                         test_command[test_command.index("-derivedDataPath") + 1])
        self.assertIn("-parallel-testing-enabled", test_command)
        self.assertIn("-maximum-parallel-testing-workers", test_command)
        self.assertIn("LATTICELENS_TEST_STORE_ROOT=" + str(store), test_command)
        self.assertIn("LATTICELENS_TEST_TMP_ROOT=" + str(test_tmp), test_command)
        self.assertIn("LATTICELENS_REQUIRE_PROJECT_LOCAL_TEST_ROOTS=1", test_command)
        self.assertNotIn("-resultBundlePath", build_command)
        self.assertEqual(test_command[test_command.index("-resultBundlePath") + 1], str(result))

    def test_xcode_unit_scheme_host_is_the_production_app_and_not_the_ui_bundle(self):
        scheme = (ROOT / "LatticeLens.xcodeproj" / "xcshareddata" / "xcschemes" /
                  "LatticeLens-Unit.xcscheme").read_text(encoding="utf-8")
        project = (ROOT / "LatticeLens.xcodeproj" / "project.pbxproj").read_text(encoding="utf-8")

        self.assertIn("BlueprintName = \"LatticeLensTests\"", scheme)
        self.assertNotIn("BlueprintName = \"LatticeLensUITests\"", scheme)
        self.assertIn('TEST_HOST = "$(BUILT_PRODUCTS_DIR)/LatticeLens.app/Contents/MacOS/LatticeLens"', project)
        self.assertIn('BUNDLE_LOADER = "$(TEST_HOST)"', project)

    def test_xcode_test_hosts_use_explicit_project_local_output_roots(self):
        schemes = ROOT / "LatticeLens.xcodeproj" / "xcshareddata" / "xcschemes"
        unit_scheme = (schemes / "LatticeLens-Unit.xcscheme").read_text(encoding="utf-8")
        ui_scheme = (schemes / "LatticeLens-UIFixture.xcscheme").read_text(encoding="utf-8")
        ui_tests = (ROOT / "Tests" / "LatticeLensUITests" /
                    "LatticeLensUITests.swift").read_text(encoding="utf-8")
        core_tests = (ROOT / "Tests" / "LatticeLensTests" /
                      "CoreContractTests.swift").read_text(encoding="utf-8")

        unit_store_root = 'key = "LATTICELENS_TEST_STORE_ROOT"\n            value = "$(DERIVED_FILE_DIR)/LatticeLens-Unit-Test-Store"'
        unit_tmp_root = 'key = "LATTICELENS_TEST_TMP_ROOT"\n            value = "$(DERIVED_FILE_DIR)/LatticeLens-Unit-Test-TMP"'
        self.assertGreaterEqual(unit_scheme.count(unit_store_root), 1)
        self.assertGreaterEqual(unit_scheme.count(unit_tmp_root), 1)
        self.assertIn('key = "LATTICELENS_TEST_TMP_ROOT"', ui_scheme)
        self.assertIn('key = "LATTICELENS_REQUIRE_PROJECT_LOCAL_TEST_ROOTS"', unit_scheme)
        self.assertIn('key = "LATTICELENS_REQUIRE_PROJECT_LOCAL_TEST_ROOTS"', ui_scheme)
        unit_home = 'key = "HOME"\n            value = "$(DERIVED_FILE_DIR)"'
        unit_fixed_home = ('key = "CFFIXED_USER_HOME"\n'
                           '            value = "$(DERIVED_FILE_DIR)"')
        ui_home = 'key = "HOME"\n            value = "$(DERIVED_FILE_DIR)"'
        ui_fixed_home = ('key = "CFFIXED_USER_HOME"\n'
                         '            value = "$(DERIVED_FILE_DIR)"')
        self.assertIn(unit_home, unit_scheme)
        self.assertIn(unit_fixed_home, unit_scheme)
        self.assertIn(ui_home, ui_scheme)
        self.assertIn(ui_fixed_home, ui_scheme)
        self.assertIn('app.launchEnvironment["TMPDIR"] = appTemporaryDirectory', ui_tests)
        self.assertIn('app.launchEnvironment["HOME"] = appTemporaryDirectory', ui_tests)
        self.assertIn('app.launchEnvironment["CFFIXED_USER_HOME"] = appTemporaryDirectory', ui_tests)
        self.assertIn('environment["LATTICELENS_REQUIRE_PROJECT_LOCAL_TEST_ROOTS"] == "1"', core_tests)
        self.assertNotIn('FileManager.default.temporaryDirectory', core_tests + ui_tests)

    def test_process_cleanup_matches_only_executables_under_current_derived_data(self):
        derived = ROOT / ".codex-task-audit-2-final.contract" / "xcode" / "derived"
        host = derived / "Build" / "Products" / "Debug" / "LatticeLens.app" / "Contents" / "MacOS" / "LatticeLens"
        other = ROOT / ".codex-task-audit-2-final.other" / "LatticeLens.app" / "Contents" / "MacOS" / "LatticeLens"
        listing = ("410 " + str(host) + " -ApplePersistenceIgnoreState YES\n"
                   "411 " + str(other) + "\n"
                   "412 /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild "
                   "-derivedDataPath " + str(derived) + " test-without-building\n")

        matches = VERIFIER.match_owned_test_processes(listing, [host])

        self.assertEqual(matches, {410: str(host.resolve())})

    def test_xcode_runner_startup_error_is_blocked_not_zero_test_pass_or_assertion_fail(self):
        stage = {"status": "FAIL", "exit_code": 65, "timed_out": False}
        log = ('IDETestOperationsObserverDebug: Timed out after 120.0s while initiating '
               'control session with daemon.\nThe test runner hung before establishing connection.')
        summary = {
            "result": "Failed",
            "totalTestCount": 1,
            "passedTests": 0,
            "failedTests": 1,
            "skippedTests": 0,
            "testFailures": [{
                "testName": "LatticeLens (24755) encountered an error",
                "failureText": "The test runner hung before establishing connection.",
            }],
        }

        status, reason = VERIFIER.classify_xcode_test_stage(stage, log, summary)

        self.assertEqual(status, "BLOCKED")
        self.assertIn("runner", reason.lower())

    def test_xcode_repeated_runner_restarts_without_completed_case_are_blocked(self):
        stage = {"status": "TIMEOUT", "exit_code": None, "timed_out": True}
        restart = "Restarting after unexpected exit, crash, or test timeout."
        log = ("Test Case '-[LatticeLensUITests testOne]' started.\n"
               "Running tests...\n" + restart + "\n"
               "Test Case '-[LatticeLensUITests testTwo]' started.\n"
               "Running tests...\n" + restart + "\n")

        status, reason = VERIFIER.classify_xcode_test_stage(stage, log, None)

        self.assertEqual(status, "BLOCKED")
        self.assertIn("restarted", reason.lower())
        self.assertIn("completed", reason.lower())

    def test_xcode_assertion_failure_is_not_reclassified_as_infrastructure_block(self):
        stage = {"status": "FAIL", "exit_code": 65, "timed_out": False}
        log = ("Test Case '-[LatticeLensTests.CoreContractTests testWrongValue]' started.\n"
               "Test Case '-[LatticeLensTests.CoreContractTests testWrongValue]' failed (0.01 seconds).\n"
               "Executed 1 test, with 1 failure.")
        summary = {
            "result": "Failed",
            "totalTestCount": 1,
            "passedTests": 0,
            "failedTests": 1,
            "skippedTests": 0,
            "testFailures": [{
                "testName": "testWrongValue",
                "failureText": "XCTAssertEqual failed.",
            }],
        }

        status, reason = VERIFIER.classify_xcode_test_stage(stage, log, summary)

        self.assertEqual(status, "FAIL")
        self.assertIn("test", reason.lower())

    def test_xcode_timeout_before_any_case_is_blocked(self):
        stage = {"status": "TIMEOUT", "exit_code": None, "timed_out": True}

        status, reason = VERIFIER.classify_xcode_test_stage(stage, "", None)

        self.assertEqual(status, "BLOCKED")
        self.assertIn("before", reason.lower())

    def test_xcode_zero_test_result_cannot_be_reported_as_pass(self):
        stage = {"status": "PASS", "exit_code": 0, "timed_out": False}
        empty_result = {
            "result": "Passed",
            "totalTestCount": 0,
            "passedTests": 0,
            "failedTests": 0,
            "skippedTests": 0,
            "testFailures": [],
        }

        status, reason = VERIFIER.classify_xcode_test_stage(stage, "", empty_result)

        self.assertEqual(status, "FAIL")
        self.assertIn("non-empty", reason.lower())

    def test_xcode_pass_requires_nonempty_successful_xcresult(self):
        stage = {"status": "PASS", "exit_code": 0, "timed_out": False}
        result = {
            "result": "Passed",
            "totalTestCount": 238,
            "passedTests": 234,
            "failedTests": 0,
            "skippedTests": 4,
            "testFailures": [],
        }

        status, _ = VERIFIER.classify_xcode_test_stage(stage, "", result)

        self.assertEqual(status, "PASS")


class GateEvidenceContractTests(unittest.TestCase):
    REQUIRED_G02_CASES = {
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
    }

    REQUIRED_G07_CASES = {
        "testResearchBundleVerifyDryRunAndRestoreToNewTarget",
        "testResearchBundleTypedRestoreBuildsVerifiedV9StagingStoreWithoutActiveOverwrite",
        "testResearchBundleSchema5ImportsIntoV12TypedStagingStore",
        "testResearchBundleTypedRestoreHonorsPreCancelledImportWithoutCreatingTarget",
        "testResearchBundleTypedRestoreCancelsAfterStagingAndRemovesTargetFamily",
        "testResearchBundlePostStageFailuresRemoveNewStoreFamily",
        "testResearchBundleV10RoundTripsCategoryFormulaInventoryAndJobCheckpoint",
        "testResearchBundleSchema7OmitsEmptyAuditRecordCounts",
        "testV11WorkbenchRowsSurviveRelaunchAndRejectedCompareKeepsPriorMatrix",
    }

    def test_g01_summary_names_required_ui_cases_and_keeps_live_inspire_optional(self):
        summary = VERIFIER.g01_gate_summary(
            {"all_required_passed": True}, {"all_required_passed": False})

        self.assertIn("Category/pagination contract cases: PASS", summary)
        self.assertIn("responsive XCUITest cases: incomplete", summary)
        self.assertIn("Live INSPIRE completeness is optional", summary)
        self.assertNotIn("live global INSPIRE completeness", summary)

        all_passed = VERIFIER.g01_gate_summary(
            {"all_required_passed": True}, {"all_required_passed": True})
        self.assertIn("responsive XCUITest cases: PASS", all_passed)

    def test_g07_summary_reflects_current_bundle_cases_and_keeps_partial_boundary(self):
        log = "\n".join(
            "Test Case '-[LatticeLensTests.V4LocalTests " + name + "]' passed (0.01 seconds)."
            for name in sorted(self.REQUIRED_G07_CASES)
        )

        evidence = VERIFIER.g07_required_case_evidence(log)

        self.assertEqual(set(VERIFIER.G07_REQUIRED_CASES), self.REQUIRED_G07_CASES)
        self.assertTrue(evidence["all_required_passed"])
        self.assertEqual({case["status"] for case in evidence["cases"]}, {"PASS"})
        self.assertIn("analysis-run/attempt round-trip", evidence["summary"])
        self.assertIn("disk-backed V12 Radar/Compare/Notebook/Search", evidence["summary"])
        self.assertIn("Injected post-stage failures", evidence["summary"])
        self.assertIn("semantic-comparison checkpoints", evidence["summary"])
        self.assertIn("schema-5", evidence["summary"])
        self.assertIn("pre-stage and mid-stage cancellation", evidence["summary"])
        self.assertIn("post-stage failures", evidence["summary"])
        self.assertNotIn("independent report/run tables remain unverified", evidence["summary"])

    def test_g07_missing_or_failed_bundle_case_fails_closed(self):
        log = "\n".join(
            "Test Case '-[LatticeLensTests.V4LocalTests " + name + "]' " +
            ("skipped - fixture unavailable (0.01 seconds)." if name.endswith("AfterStagingAndRemovesTargetFamily")
             else "passed (0.01 seconds).")
            for name in sorted(self.REQUIRED_G07_CASES -
                               {"testResearchBundleTypedRestoreCancelsAfterStagingAndRemovesTargetFamily"})
        )

        evidence = VERIFIER.g07_required_case_evidence(log)

        self.assertFalse(evidence["all_required_passed"])
        missing_case = next(case for case in evidence["cases"]
                            if case["test"] == "testResearchBundleTypedRestoreCancelsAfterStagingAndRemovesTargetFamily")
        self.assertEqual(missing_case["status"], "NOT_RUN")
        self.assertIn("missing or non-passing", evidence["summary"])


class CurrentRunGateContractTests(unittest.TestCase):
    REQUIRED_G02_CASES = GateEvidenceContractTests.REQUIRED_G02_CASES
    REQUIRED_G07_CASES = GateEvidenceContractTests.REQUIRED_G07_CASES

    def test_required_case_evidence_distinguishes_missing_failed_skipped_and_duplicates(self):
        names = ("testPass", "testMissing", "testFail", "testSkip", "testDuplicate")
        log = "\n".join((
            "Test Case '-[Suite testPass]' passed (0.01 seconds).",
            "Test Case '-[Suite testFail]' failed (0.01 seconds).",
            "Test Case '-[Suite testSkip]' skipped (0.01 seconds).",
            "Test Case '-[Suite testDuplicate]' passed (0.01 seconds).",
            "Test Case '-[Suite testDuplicate]' passed (0.01 seconds).",
        ))

        evidence = VERIFIER.required_case_evidence(log, names)
        statuses = {case["test"]: case["status"] for case in evidence["cases"]}

        self.assertEqual(statuses, {
            "testPass": "PASS",
            "testMissing": "NOT_RUN",
            "testFail": "FAIL",
            "testSkip": "SKIPPED",
            "testDuplicate": "DUPLICATE_OR_INCONSISTENT",
        })
        self.assertFalse(evidence["all_required_passed"])

    def test_gate_status_uses_current_cases_and_keeps_blocked_distinct(self):
        passing = VERIFIER.required_case_evidence(
            "Test Case '-[Suite testOne]' passed (0.01 seconds).", ("testOne",))
        missing = VERIFIER.required_case_evidence("", ("testOne",))
        failed = VERIFIER.required_case_evidence(
            "Test Case '-[Suite testOne]' failed (0.01 seconds).", ("testOne",))

        self.assertEqual(VERIFIER.required_case_gate_status(passing), "PASS")
        self.assertEqual(VERIFIER.required_case_gate_status(missing), "PARTIAL")
        self.assertEqual(VERIFIER.required_case_gate_status(passing, "BLOCKED"), "BLOCKED")
        self.assertEqual(VERIFIER.required_case_gate_status(failed), "FAIL")

    def test_manual_paths_are_allowlisted_before_regular_file_validation(self):
        with tempfile.TemporaryDirectory(dir=ROOT, prefix=".codex-task-tmp-manual-path-") as directory:
            temporary_root = Path(directory)
            allowed = temporary_root / "allowed"
            allowed.mkdir()
            inside = allowed / "paper.txt"
            inside.write_text("synthetic fixture", encoding="utf-8")
            outside = temporary_root / "outside.txt"
            outside.write_text("must not be accepted", encoding="utf-8")
            link = allowed / "linked.txt"
            link.symlink_to(outside)

            with patch.object(VERIFIER, "ROOT", temporary_root):
                good, good_error = VERIFIER.resolve_scoped_regular_file(
                    "allowed/paper.txt", allowed, "test source")
                traversal, traversal_error = VERIFIER.resolve_scoped_regular_file(
                    "../outside.txt", allowed, "test source")
                absolute, absolute_error = VERIFIER.resolve_scoped_regular_file(
                    str(outside), allowed, "test source")
                linked, linked_error = VERIFIER.resolve_scoped_regular_file(
                    "allowed/linked.txt", allowed, "test source")

            self.assertEqual(good, inside)
            self.assertIsNone(good_error)
            self.assertIsNone(traversal)
            self.assertIn("canonical project-relative", traversal_error)
            self.assertIsNone(absolute)
            self.assertIn("canonical project-relative", absolute_error)
            self.assertIsNone(linked)
            self.assertTrue(linked_error)

    def test_malformed_voiceover_window_and_screenshot_types_return_not_run_not_exception(self):
        with tempfile.TemporaryDirectory(dir=ROOT, prefix=".codex-task-tmp-manual-type-") as directory:
            receipt_path = Path(directory) / "manual.json"
            receipt_path.write_text(json.dumps({
                "schema_version": "latticelens-manual-acceptance-v1",
                "physics_reviews": [],
                "voiceover_review": {
                    "status": "NOT_RUN",
                    "input_manifest_sha256": None,
                    "window_sizes": 17,
                    "screenshots": [{"window_size": [], "path": ["not", "a", "path"]}],
                    "checks": {},
                },
            }), encoding="utf-8")

            with patch.object(VERIFIER, "MANUAL_ACCEPTANCE_PATH", receipt_path):
                results = VERIFIER.validate_manual_acceptance("a" * 64)

            self.assertEqual([item["status"] for item in results], ["NOT_RUN", "NOT_RUN"])
            self.assertIn("VoiceOver screenshots must cover", results[1]["reason"])

    def test_g07_skipped_bundle_case_is_not_counted_as_coverage(self):
        log = "\n".join(
            "Test Case '-[LatticeLensTests.V4LocalTests " + name + "]' " +
            ("skipped - fixture unavailable (0.01 seconds)." if name.endswith("AfterStagingAndRemovesTargetFamily")
             else "passed (0.01 seconds).")
            for name in sorted(self.REQUIRED_G07_CASES)
        )

        evidence = VERIFIER.g07_required_case_evidence(log)

        self.assertFalse(evidence["all_required_passed"])
        cancelled_case = next(case for case in evidence["cases"]
                              if case["test"] == "testResearchBundleTypedRestoreCancelsAfterStagingAndRemovesTargetFamily")
        self.assertEqual(cancelled_case["status"], "SKIPPED")
        self.assertIn("missing or non-passing", evidence["summary"])

    def test_g02_summary_reports_expanded_source_matrix_and_keeps_remaining_gaps_partial(self):
        log = "\n".join(
            "Test Case '-[LatticeLensTests.V4LocalTests " + name + "]' passed (0.01 seconds)."
            for name in sorted(self.REQUIRED_G02_CASES)
        )

        evidence = VERIFIER.g02_migration_case_evidence(log, "PASS")

        self.assertEqual(set(VERIFIER.G02_MIGRATION_TEST_CASES), self.REQUIRED_G02_CASES)
        self.assertTrue(evidence["all_required_passed"])
        self.assertEqual(evidence["v10_drill_status"], "PASS")
        self.assertEqual({case["status"] for case in evidence["cases"]}, {"PASS"})
        self.assertIn("V8-to-V12", evidence["summary"])
        self.assertIn("V9-to-V12", evidence["summary"])
        self.assertIn("host-free synthetic V9-schema refusal check", evidence["summary"])
        self.assertIn("transient SHM bytes changed", evidence["summary"])
        self.assertIn("does not claim whole-family byte preservation or older-app UI behavior",
                      evidence["summary"])
        self.assertIn("manifest-bound V10-to-V12", evidence["summary"])
        self.assertIn("synthetic V8/V9/V10 matrix", evidence["summary"])
        self.assertIn("main/WAL/SHM byte preservation", evidence["summary"])
        self.assertIn("file-write-out-of-space", evidence["summary"])
        self.assertIn("physical disk exhaustion", evidence["summary"])
        self.assertIn("optional source-sidecar handling", evidence["summary"])
        self.assertIn("rejection of missing manifest-listed sidecars", evidence["summary"])
        self.assertIn("duplicate logical formula identity refusal before activation", evidence["summary"])
        self.assertIn("older-app compatible rollback=NOT_RUN", evidence["summary"])
        self.assertIn("G02 remains PARTIAL", evidence["summary"])

    def test_g02_summary_records_source_bound_physical_enospc_without_promoting_old_app_gap(self):
        log = "\n".join(
            "Test Case '-[LatticeLensTests.V4LocalTests " + name + "]' passed (0.01 seconds)."
            for name in sorted(self.REQUIRED_G02_CASES)
        )

        evidence = VERIFIER.g02_migration_case_evidence(log, "PASS", "PASS")

        self.assertEqual(evidence["physical_disk_status"], "PASS")
        self.assertIn("real ENOSPC during staging-copy", evidence["summary"])
        self.assertIn("source family unchanged", evidence["summary"])
        self.assertIn("older-app compatible rollback=NOT_RUN", evidence["summary"])
        self.assertIn("G02 remains PARTIAL", evidence["summary"])

    def test_g02_missing_migration_case_fails_closed(self):
        observed = self.REQUIRED_G02_CASES - {
            "testDefaultFactoryMigratesV8ThroughStagingToV12AndPreservesSourceFamily"
        }
        log = "\n".join(
            "Test Case '-[LatticeLensTests.V4LocalTests " + name + "]' passed (0.01 seconds)."
            for name in sorted(observed)
        )

        evidence = VERIFIER.g02_migration_case_evidence(log, "PASS")

        self.assertFalse(evidence["all_required_passed"])
        v8_case = next(case for case in evidence["cases"]
                       if case["test"] == "testDefaultFactoryMigratesV8ThroughStagingToV12AndPreservesSourceFamily")
        self.assertEqual(v8_case["status"], "NOT_RUN")
        self.assertIn("missing or non-passing", evidence["summary"])

    def test_g02_old_app_restore_receipt_closes_compatibility_boundary_only_with_bound_hashes(self):
        log = "\n".join(
            "Test Case '-[LatticeLensTests.V4LocalTests " + name + "]' passed (0.01 seconds)."
            for name in sorted(self.REQUIRED_G02_CASES)
        )
        evidence = VERIFIER.g02_migration_case_evidence(log, "PASS", "PASS", "PASS")

        self.assertEqual(evidence["status"], "PASS")
        self.assertIn("hash-verified 1.0.11", evidence["summary"])
        self.assertIn("V12 SQLite family", evidence["summary"])
        self.assertNotIn("G02 remains PARTIAL", evidence["summary"])


class G02OldAppRollbackReceiptContractTests(unittest.TestCase):
    def receipt(self, root, input_hash):
        old_release = root / "release-assets" / "Release-1.0.11-local"
        old_release.mkdir(parents=True)
        dmg = old_release / "LatticeLens-1.0.11-local.dmg"
        dmg.write_bytes(b"manifest-bound synthetic DMG")
        manifest_path = old_release / "manifest-v1.0.11.json"
        manifest_path.write_text(json.dumps({
            "product_version": "1.0.11",
            "build_number": 111,
            "bundle_id": "org.latticelens.app",
            "app": {"bundle": "LatticeLens.app", "executable_sha256": "e" * 64},
            "artifacts": {"dmg": {"file": dmg.name,
                                    "sha256": VERIFIER.sha256_file(dmg),
                                    "bytes": dmg.stat().st_size}},
        }), encoding="utf-8")
        source_hashes = {}
        for index, relative in enumerate(VERIFIER.G02_OLD_APP_SOURCE_INPUTS):
            source = root / relative
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text("fixture source " + str(index), encoding="utf-8")
            source_hashes[relative] = VERIFIER.sha256_file(source)
        (root / "evidence").mkdir()
        v12_hashes = {"main": "a" * 64, "wal": "b" * 64}
        backup_hashes = {"Library-v8.store": "c" * 64, "Library-v8.store-wal": "d" * 64}
        task_root = ".codex-task-g02-old-app-test"
        receipt = {
            "schema_version": "latticelens-g02-old-app-rollback-v1",
            "run_id": "20261007T120000Z-12345678",
            "input_manifest_sha256": input_hash,
            "status": "PASS",
            "summary": "old app opened the restored V9 store and displayed the fixture paper",
            "app": {"product_version": "1.0.11", "build_number": "111",
                    "bundle_id": "org.latticelens.app", "executable_sha256": "e" * 64,
                    "process_id": 424242},
            "fixture": {"source_schema_version": 9, "active_schema_version": 12,
                        "paper_id": 18, "paper_title": "G02 Old-App Rollback Fixture Paper 18",
                        "legacy_store_relative": task_root + "/rollback/Library-v8.store",
                        "active_v12_store_relative": task_root + "/rollback/v12-active.store",
                        "backup_verified_before_and_after": True},
            "checks": {
                "fixture_xctest": "PASS", "backup_manifest_and_family": "PASS",
                "old_app_dmg_and_executable_identity": "PASS", "old_app_launch": "PASS",
                "old_app_opened_restored_v9": "PASS", "old_app_did_not_open_v12": "PASS",
                "old_app_read_fixture_paper": "PASS",
                "v8_integrity_check": "ok", "v12_integrity_check": "ok",
                "v12_family_byte_stable": True, "verified_backup_byte_stable": True,
                "network_denied": True, "real_user_library_denied": True,
                "securityd_keychain_access_denied": True,
                "v12_path_denied_by_sandbox": True,
                "system_temporary_paths_denied": True, "task_process_stopped": True,
                "dmg_detached": True, "scratch_removed": True,
            },
            "evidence": {
                "v12_family_sha256_before": v12_hashes,
                "v12_family_sha256_after": dict(v12_hashes),
                "backup_family_sha256_before": backup_hashes,
                "backup_family_sha256_after": dict(backup_hashes),
                "opened_project_files": [task_root + "/rollback/Library-v8.store"],
                "app_log_tail": [], "old_app_log_sha256": "f" * 64,
                "old_app_ui_semantic_read": {
                    "provider": "orca-computer-use", "bundle_id": "org.latticelens.app",
                    "process_id": 424242, "paper_id": 18,
                    "paper_title": "G02 Old-App Rollback Fixture Paper 18",
                    "title_visible": True,
                    "visible_match_lines": ["paperRow-18: G02 Old-App Rollback Fixture Paper 18"],
                    "accessibility_tree_sha256": "9" * 64,
                },
                "dmg_sha256": VERIFIER.sha256_file(dmg),
                "old_app_manifest_sha256": VERIFIER.sha256_file(manifest_path),
            },
            "source_sha256": source_hashes,
        }
        path = root / "tmp-receipt.json"
        path.write_text(json.dumps(receipt), encoding="utf-8")
        return path, receipt

    def test_valid_manifest_bound_restored_v9_receipt_is_preserved(self):
        input_hash = "1" * 64
        with tempfile.TemporaryDirectory(dir=ROOT, prefix=".codex-task-tmp-g02-old-app-receipt-") as directory:
            root = Path(directory)
            receipt_path, _ = self.receipt(root, input_hash)
            result = VERIFIER.validate_old_app_rollback_receipt(
                receipt_path, input_hash, "PASS", root=root)

            self.assertEqual(result["status"], "PASS")
            self.assertEqual(result["receipt_sha256"], VERIFIER.sha256_file(root / result["receipt_path"]))
            self.assertTrue((root / result["receipt_path"]).is_file())

    def test_v12_hash_change_or_missing_opened_v8_path_fails_closed(self):
        input_hash = "2" * 64
        with tempfile.TemporaryDirectory(dir=ROOT, prefix=".codex-task-tmp-g02-old-app-receipt-") as directory:
            root = Path(directory)
            receipt_path, receipt = self.receipt(root, input_hash)
            receipt["evidence"]["v12_family_sha256_after"]["main"] = "9" * 64
            receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
            result = VERIFIER.validate_old_app_rollback_receipt(
                receipt_path, input_hash, "PASS", root=root)

            self.assertEqual(result["status"], "FAIL")
            self.assertIn("V12/backup before-and-after family hashes", result["validation_errors"][0])

    def test_old_app_store_load_errors_override_a_passing_receipt(self):
        for message in (
                "Cannot use staged migration with an unknown model version.",
                "Store failed to load.",
                "CoreData: error: addPersistentStoreWithType:configuration:URL:options:error: returned error"):
            with self.subTest(message=message), tempfile.TemporaryDirectory(
                    dir=ROOT, prefix=".codex-task-tmp-g02-old-app-receipt-") as directory:
                root = Path(directory)
                receipt_path, receipt = self.receipt(root, "5" * 64)
                receipt["evidence"]["app_log_tail"] = [message]
                receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
                result = VERIFIER.validate_old_app_rollback_receipt(
                    receipt_path, "5" * 64, "PASS", root=root)

                self.assertEqual(result["status"], "FAIL")
                self.assertIn("persistent-store load failure", result["validation_errors"][0])

    def test_old_app_receipt_requires_exact_fixture_title_in_accessibility_evidence(self):
        for mutation in ("missing_evidence", "wrong_paper_id", "wrong_title", "hidden_title"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory(
                    dir=ROOT, prefix=".codex-task-tmp-g02-old-app-receipt-") as directory:
                root = Path(directory)
                receipt_path, receipt = self.receipt(root, "6" * 64)
                evidence = receipt["evidence"].get("old_app_ui_semantic_read")
                if mutation == "missing_evidence":
                    receipt["evidence"].pop("old_app_ui_semantic_read")
                elif mutation == "wrong_paper_id":
                    evidence["paper_id"] = 19
                elif mutation == "wrong_title":
                    evidence["paper_title"] = "Different paper"
                else:
                    evidence["title_visible"] = False
                receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
                result = VERIFIER.validate_old_app_rollback_receipt(
                    receipt_path, "6" * 64, "PASS", root=root)

                self.assertEqual(result["status"], "FAIL")
                self.assertIn("accessibility evidence does not prove", result["validation_errors"][0])

    def test_v12_sidecar_open_and_dmg_manifest_mismatch_fail_closed(self):
        for mutation, expected_error in (
                ("v12_sidecar", "process-opened paths"),
                ("dmg_hash", "receipt does not bind"),
                ("missing_tmp_denial", "system_temporary_paths_denied")):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory(
                    dir=ROOT, prefix=".codex-task-tmp-g02-old-app-receipt-") as directory:
                root = Path(directory)
                receipt_path, receipt = self.receipt(root, "3" * 64)
                if mutation == "v12_sidecar":
                    receipt["evidence"]["opened_project_files"].append(
                        receipt["fixture"]["active_v12_store_relative"] + "-shm")
                elif mutation == "dmg_hash":
                    receipt["evidence"]["dmg_sha256"] = "9" * 64
                else:
                    receipt["checks"].pop("system_temporary_paths_denied")
                receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
                result = VERIFIER.validate_old_app_rollback_receipt(
                    receipt_path, "3" * 64, "PASS", root=root)

                self.assertEqual(result["status"], "FAIL")
                self.assertIn(expected_error, result["validation_errors"][0])

    def test_receipt_cannot_omit_a_bound_source_or_escape_with_run_id(self):
        for mutation in ("missing_source", "run_id"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory(
                    dir=ROOT, prefix=".codex-task-tmp-g02-old-app-receipt-") as directory:
                root = Path(directory)
                receipt_path, receipt = self.receipt(root, "4" * 64)
                if mutation == "missing_source":
                    receipt["source_sha256"].pop(VERIFIER.G02_OLD_APP_SOURCE_INPUTS[-1])
                    expected_error = "exact G02 rollback inputs"
                else:
                    receipt["run_id"] = "../../outside"
                    expected_error = "generated UTC compatibility-drill identity"
                receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
                result = VERIFIER.validate_old_app_rollback_receipt(
                    receipt_path, "4" * 64, "PASS", root=root)

                self.assertEqual(result["status"], "FAIL")
                self.assertIn(expected_error, result["validation_errors"][0])


class G10CleanupContractTests(unittest.TestCase):
    def passing_candidate(self):
        return {
            "directory": "release-assets/Release-2.0.0-candidate-test",
            "integrity_sha256": "a" * 64,
            "source_identity_matches_current": True,
            "errors": [],
        }

    def test_g10_pass_requires_removed_scratch_stable_inputs_package_and_no_mount(self):
        candidate = self.passing_candidate()
        status, _, errors = VERIFIER.evaluate_g10_cleanup(
            True, [], 0, [], ["core-assets"], ["core-assets"],
            candidate, candidate, {"status": "PASS", "mounted": False})

        self.assertEqual(status, "PASS")
        self.assertEqual(errors, [])

    def test_g10_stale_candidate_binding_stays_partial(self):
        candidate = self.passing_candidate()
        candidate["source_identity_matches_current"] = False
        status, summary, _ = VERIFIER.evaluate_g10_cleanup(
            True, [], 0, [], ["core-assets"], ["core-assets"],
            candidate, candidate, {"status": "PASS", "mounted": False})

        self.assertEqual(status, "PARTIAL")
        self.assertIn("rebuild it from this run", summary)

    def test_g10_fails_closed_on_leftover_process_changed_release_or_mounted_dmg(self):
        candidate = self.passing_candidate()
        changed = dict(candidate, integrity_sha256="b" * 64)
        cases = (
            VERIFIER.evaluate_g10_cleanup(
                True, [], 1, [], ["core"], ["core"], candidate, candidate,
                {"status": "PASS", "mounted": False}),
            VERIFIER.evaluate_g10_cleanup(
                True, [], 0, [], ["core"], ["core"], candidate, changed,
                {"status": "PASS", "mounted": False}),
            VERIFIER.evaluate_g10_cleanup(
                True, [], 0, [], ["core"], ["core"], candidate, candidate,
                {"status": "FAIL", "mounted": True, "reason": "mounted"}),
            VERIFIER.evaluate_g10_cleanup(
                False, [], 0, [], ["core"], ["core"], candidate, candidate,
                {"status": "PASS", "mounted": False}),
        )

        self.assertTrue(all(status == "FAIL" for status, _, _ in cases))

    def test_cleanup_manifest_contract_requires_exact_removed_target_and_postchecks(self):
        with tempfile.TemporaryDirectory(dir=ROOT, prefix=".codex-task-tmp-g10-receipt-") as directory:
            temporary_root = Path(directory)
            record = {
                "schema_version": "latticelens-cleanup-2.0-final-local-v1",
                "run_id": "run-1",
                "input_manifest_sha256": "c" * 64,
                "status": "applied_postcleanup_verified",
                "targets": [{
                    "path": ".codex-task-audit-2-final.run-1",
                    "canonical_path_verified": True,
                    "directory_symlink": False,
                    "symlink_targets_confined_to_scratch": True,
                    "removed": True,
                    "post_action_check": "path absent",
                    "open_process_count": 0,
                }],
                "post_cleanup_verification": {
                    "frozen_input_manifest": "PASS",
                    "retained_core_assets": "PASS",
                    "release_package_integrity": "PASS",
                    "release_package_unchanged": "PASS",
                    "candidate_source_binding": "PASS",
                    "candidate_dmg_unmounted": "PASS",
                    "owned_processes_stopped": "PASS",
                },
                "unapproved_deletions": [],
            }

            errors = VERIFIER.validate_cleanup_manifest_record(
                record, "run-1", "c" * 64,
                ".codex-task-audit-2-final.run-1", temporary_root)
            self.assertEqual(errors, [])

            record["targets"][0]["path"] = "../outside"
            traversal_errors = VERIFIER.validate_cleanup_manifest_record(
                record, "run-1", "c" * 64,
                ".codex-task-audit-2-final.run-1", temporary_root)
            self.assertTrue(traversal_errors)

    def test_candidate_package_snapshot_checks_checksums_and_verifier_binding(self):
        with tempfile.TemporaryDirectory(dir=ROOT, prefix=".codex-task-tmp-g10-package-") as directory:
            temporary_root = Path(directory)
            candidate = temporary_root / "release-assets" / "Release-2.0.0-candidate-test"
            candidate.mkdir(parents=True)
            compact_validation = candidate / "compact-validation"
            compact_validation.mkdir()
            evidence = temporary_root / "evidence"
            evidence.mkdir()

            for relative, contents in (
                    ("Sources/Fixture.swift", "let fixtureValue = 1\n"),
                    ("Package.swift", "// synthetic package input\n"),
                    ("README.md", "Synthetic local candidate contract.\n"),
                    ("CHANGELOG.md", "Synthetic candidate fixture.\n")):
                path = temporary_root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(contents, encoding="utf-8")

            candidate_source_entries, source_errors = VERIFIER.build_input_source_entries(temporary_root)
            self.assertEqual(source_errors, [])

            def file_entry(path):
                return {
                    "path": path.relative_to(temporary_root).as_posix(),
                    "kind": "file",
                    "bytes": path.stat().st_size,
                    "sha256": VERIFIER.sha256_file(path),
                }

            input_manifest_path = evidence / "inputs-old.json"
            input_manifest_path.write_text(json.dumps({
                "schema_version": "latticelens-input-manifest-v1",
                "run_id": "verifier-old",
                "created_at_utc": "2026-10-03T23:59:00+00:00",
                "files": candidate_source_entries,
            }), encoding="utf-8")
            expected_manifest = VERIFIER.sha256_file(input_manifest_path)

            (candidate / "LatticeLens-2.0.0-local.dmg").write_bytes(b"synthetic dmg")
            (candidate / "LatticeLens-2.0.0.dSYM.zip").write_bytes(b"synthetic dsym")

            performance_path = evidence / "performance.json"
            performance_path.write_text(json.dumps({
                "input_manifest_sha256": expected_manifest,
            }), encoding="utf-8")

            migration_path = evidence / "migration.json"
            migration_path.write_text(json.dumps({
                "inputManifestSHA256": expected_manifest,
            }), encoding="utf-8")
            summary_path = evidence / "validation.md"
            summary_path.write_text("Synthetic validation summary.\n", encoding="utf-8")

            validation_path = evidence / "validation.json"
            validation_path.write_text(json.dumps({
                "schema_version": "latticelens-verify-2.0-final-local",
                "run_id": "verifier-old",
                "report_path": "evidence/validation.json",
                "input_manifest_path": "evidence/inputs-old.json",
                "input_manifest_sha256": expected_manifest,
                "summary_path": "evidence/validation.md",
                "performance_benchmark": {
                    "report_path": "evidence/performance.json",
                    "report_sha256": VERIFIER.sha256_file(performance_path),
                },
                "migration_drill": {
                    "receipt_path": "evidence/migration.json",
                    "receipt_sha256": VERIFIER.sha256_file(migration_path),
                },
            }), encoding="utf-8")

            history_paths = []
            for relative in sorted(VERIFIER.G10_HISTORICAL_CONTEXT_PATHS):
                history_path = temporary_root / relative
                history_path.parent.mkdir(parents=True, exist_ok=True)
                history_path.write_text("Synthetic preserved historical context.\n", encoding="utf-8")
                history_paths.append(history_path)

            for source in (validation_path, summary_path, input_manifest_path,
                           performance_path, migration_path, *history_paths):
                (compact_validation / source.name).write_bytes(source.read_bytes())

            build_input_entries = list(candidate_source_entries) + [
                file_entry(path) for path in (validation_path, summary_path, input_manifest_path,
                                              performance_path, migration_path, *history_paths)
            ]
            build_input_path = candidate / "build-inputs-v2.0.json"
            build_input_path.write_text(json.dumps({
                "schema_version": "latticelens-build-input-manifest-v2.0",
                "run_id": "package-old",
                "files": build_input_entries,
            }), encoding="utf-8")

            manifest = {
                "schema_version": "latticelens-package-manifest-v2.0-local-candidate",
                "run_id": "package-old",
                "generated_at_utc": "2026-10-04T00:00:00+00:00",
                "release_status": "PARTIAL_NOT_FINAL",
                "artifacts": {
                    "dmg": {"file": "LatticeLens-2.0.0-local.dmg",
                            "sha256": VERIFIER.sha256_file(candidate / "LatticeLens-2.0.0-local.dmg")},
                    "dsym": {"file": "LatticeLens-2.0.0.dSYM.zip",
                             "sha256": VERIFIER.sha256_file(candidate / "LatticeLens-2.0.0.dSYM.zip")},
                },
                "build_input_manifest": {
                    "file": "build-inputs-v2.0.json",
                    "sha256": VERIFIER.sha256_file(build_input_path),
                    "input_verifier_manifest_sha256": expected_manifest,
                },
                "validation": {
                    "report": "evidence/validation.json",
                    "report_sha256": VERIFIER.sha256_file(validation_path),
                    "performance": {"path": "evidence/performance.json",
                                    "sha256": VERIFIER.sha256_file(performance_path)},
                    "migration": {"path": "evidence/migration.json",
                                  "sha256": VERIFIER.sha256_file(migration_path)},
                },
                "checks": {name: "PASS" for name in VERIFIER.G10_PACKAGE_CHECKS},
            }
            manifest_path = candidate / "manifest-v2.0-local-candidate.json"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            package_files = sorted(path for path in candidate.rglob("*") if path.is_file())
            sums = "\n".join(
                VERIFIER.sha256_file(path) + "  " + path.relative_to(candidate).as_posix()
                for path in package_files
            ) + "\n"
            (candidate / "SHA256SUMS.txt").write_text(sums, encoding="utf-8")

            current_manifest = {
                "schema_version": "latticelens-input-manifest-v1",
                "run_id": "verifier-new",
                "created_at_utc": "2026-10-04T00:01:00+00:00",
                "files": candidate_source_entries,
            }
            current_manifest_hash = VERIFIER.sha256_bytes(json.dumps(
                current_manifest, sort_keys=True, separators=(",", ":")).encode("utf-8"))
            snapshot, errors = VERIFIER.candidate_package_snapshot(
                current_manifest_hash, current_manifest["files"], temporary_root)
            self.assertEqual(errors, [])
            self.assertEqual(snapshot["checks"]["dmg_verify"], "PASS")
            self.assertFalse(snapshot["input_manifest_matches_current"])
            self.assertTrue(snapshot["input_manifest_entries_match_current"])
            self.assertTrue(snapshot["build_input_sources_match_current"])
            self.assertTrue(snapshot["source_identity_matches_current"])

            manifest["checks"].update({
                "full_user_workflow": "PASS",
                "app_data_rollback": "PASS",
            })
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            package_files = sorted(path for path in candidate.rglob("*")
                                   if path.is_file() and path.name != "SHA256SUMS.txt")
            (candidate / "SHA256SUMS.txt").write_text("\n".join(
                VERIFIER.sha256_file(path) + "  " + path.relative_to(candidate).as_posix()
                for path in package_files
            ) + "\n", encoding="utf-8")
            unreceipted, unreceipted_errors = VERIFIER.candidate_package_snapshot(
                current_manifest_hash, current_manifest["files"], temporary_root)
            self.assertIsNotNone(unreceipted)
            self.assertTrue(any("PASS without a bound acceptance receipt" in error
                                for error in unreceipted_errors))
            self.assertFalse(unreceipted["acceptance_receipts_valid"])
            self.assertEqual(VERIFIER.evaluate_g09_package(unreceipted)[0], "FAIL")

            manifest["checks"].pop("full_user_workflow")
            manifest["checks"].pop("app_data_rollback")
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            package_files = sorted(path for path in candidate.rglob("*")
                                   if path.is_file() and path.name != "SHA256SUMS.txt")
            (candidate / "SHA256SUMS.txt").write_text("\n".join(
                VERIFIER.sha256_file(path) + "  " + path.relative_to(candidate).as_posix()
                for path in package_files
            ) + "\n", encoding="utf-8")

            changed_source = temporary_root / "Sources" / "Fixture.swift"
            changed_source.write_text("let fixtureValue = 2\n", encoding="utf-8")
            changed_entries, changed_errors = VERIFIER.build_input_source_entries(temporary_root)
            self.assertEqual(changed_errors, [])
            stale, stale_errors = VERIFIER.candidate_package_snapshot(
                "e" * 64, changed_entries, temporary_root)
            self.assertEqual(stale_errors, [])
            self.assertFalse(stale["input_manifest_entries_match_current"])
            self.assertFalse(stale["build_input_sources_match_current"])
            self.assertFalse(stale["source_identity_matches_current"])

            (candidate / "LatticeLens-2.0.0-local.dmg").write_bytes(b"tampered dmg")
            tampered, tamper_errors = VERIFIER.candidate_package_snapshot(
                "e" * 64, changed_entries, temporary_root)
            self.assertIsNotNone(tampered)
            self.assertTrue(any("checksum mismatch" in error for error in tamper_errors))

    def test_v2_1_package_uses_only_self_contained_relocated_evidence(self):
        with tempfile.TemporaryDirectory(dir=ROOT, prefix=".codex-task-tmp-g10-v21-self-contained-") as directory:
            temporary_root = Path(directory)
            fixture = make_v2_1_candidate_fixture(
                temporary_root, "Release-2.0.0-candidate-v21",
                "2026-10-16T12:00:00+00:00")
            shutil.rmtree(fixture["evidence"])

            current_entries, source_errors = VERIFIER.build_input_source_entries(temporary_root)
            self.assertEqual(source_errors, [])
            self.assertEqual(current_entries, fixture["source_entries"])
            snapshot, errors = VERIFIER.candidate_package_snapshot(
                fixture["input_manifest_hash"], current_entries, temporary_root)

            self.assertEqual(errors, [])
            self.assertIsNotNone(snapshot)
            self.assertEqual(snapshot["manifest_selection"], "generated_at_utc")
            self.assertEqual(snapshot["directory"], "release-assets/Release-2.0.0-candidate-v21")
            self.assertTrue(snapshot["input_manifest_entries_match_current"])
            self.assertTrue(snapshot["build_input_sources_match_current"])
            self.assertTrue(snapshot["source_identity_matches_current"])
            self.assertFalse(fixture["evidence"].exists())
            for role in ("input_manifest", "summary", "performance", "migration"):
                self.assertTrue(fixture["manifest"]["validation"][role]["path"].startswith(
                    "compact-validation/"))
            self.assertTrue(fixture["manifest"]["validation"]["report"].startswith(
                "compact-validation/"))

    def test_v2_1_package_rejects_missing_tampered_wrong_run_and_wrong_sources(self):
        mutations = ("missing", "tampered", "wrong_run", "wrong_sources", "symlink")
        for mutation in mutations:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory(
                    dir=ROOT, prefix=".codex-task-tmp-g10-v21-invalid-") as directory:
                temporary_root = Path(directory)
                fixture = make_v2_1_candidate_fixture(
                    temporary_root, "Release-2.0.0-candidate-v21",
                    "2026-10-16T12:00:00+00:00")
                candidate = fixture["candidate"]
                manifest = fixture["manifest"]
                compact = candidate / "compact-validation"

                if mutation == "missing":
                    (compact / "performance.json").unlink()
                elif mutation == "tampered":
                    report_path = compact / "validation.json"
                    report_path.write_text(report_path.read_text(encoding="utf-8") + "tampered\n",
                                           encoding="utf-8")
                elif mutation == "wrong_run":
                    index_record = manifest["validation"]["relocation_index"]
                    index_path = candidate / index_record["path"]
                    index = json.loads(index_path.read_text(encoding="utf-8"))
                    index["package_run_id"] = "different-package-run"
                    index_path.write_text(json.dumps(index, sort_keys=True) + "\n", encoding="utf-8")
                    index_record["sha256"] = VERIFIER.sha256_file(index_path)
                    manifest_path = fixture["manifest_path"]
                    manifest_path.write_text(json.dumps(manifest, sort_keys=True) + "\n",
                                             encoding="utf-8")
                    write_candidate_checksums(candidate)
                elif mutation == "wrong_sources":
                    build_path = candidate / manifest["build_input_manifest"]["file"]
                    build_input = json.loads(build_path.read_text(encoding="utf-8"))
                    source_entry = next(item for item in build_input["files"]
                                        if item["path"] == "Sources/Fixture.swift")
                    source_entry["sha256"] = "f" * 64
                    source_entry["bytes"] += 1
                    build_path.write_text(json.dumps(build_input, sort_keys=True) + "\n",
                                          encoding="utf-8")
                    manifest["build_input_manifest"]["sha256"] = VERIFIER.sha256_file(build_path)
                    fixture["manifest_path"].write_text(json.dumps(manifest, sort_keys=True) + "\n",
                                                       encoding="utf-8")
                    write_candidate_checksums(candidate)
                else:
                    moved = candidate / "compact-validation-data"
                    compact.rename(moved)
                    compact.symlink_to(moved.name, target_is_directory=True)

                current_entries, source_errors = VERIFIER.build_input_source_entries(temporary_root)
                self.assertEqual(source_errors, [])
                snapshot, errors = VERIFIER.candidate_package_snapshot(
                    fixture["input_manifest_hash"], current_entries, temporary_root)

                self.assertIsNotNone(snapshot)
                self.assertTrue(errors)
                if mutation == "wrong_run":
                    self.assertTrue(any("different package run" in error for error in errors))
                elif mutation == "wrong_sources":
                    self.assertFalse(snapshot["build_input_sources_match_current"])
                    self.assertFalse(snapshot["source_identity_matches_current"])
                elif mutation == "symlink":
                    self.assertTrue(any("symlink" in error.lower() for error in errors))

    def test_candidate_discovery_uses_manifest_time_and_supports_explicit_final_directory(self):
        with tempfile.TemporaryDirectory(dir=ROOT, prefix=".codex-task-tmp-g10-manifest-selection-") as directory:
            temporary_root = Path(directory)
            older = make_v2_1_candidate_fixture(
                temporary_root, "Release-2.0.0-candidate-older",
                "2026-10-16T12:00:00+00:00")
            newer = make_v2_1_candidate_fixture(
                temporary_root, "Release-2.0.0-final-local",
                "2026-10-17T12:00:00+00:00")
            os.utime(older["manifest_path"], (4102444800, 4102444800))
            current_entries, source_errors = VERIFIER.build_input_source_entries(temporary_root)
            self.assertEqual(source_errors, [])

            discovered, discovery_errors = VERIFIER.candidate_package_snapshot(
                newer["input_manifest_hash"], current_entries, temporary_root)
            self.assertEqual(discovery_errors, [])
            self.assertEqual(discovered["directory"], "release-assets/Release-2.0.0-final-local")
            self.assertEqual(discovered["manifest_selection"], "generated_at_utc")

            explicit, explicit_errors = VERIFIER.candidate_package_snapshot(
                older["input_manifest_hash"], current_entries, temporary_root,
                manifest_path_override=(
                    "release-assets/Release-2.0.0-candidate-older/"
                    "manifest-v2.0-local-candidate.json"))
            self.assertEqual(explicit_errors, [])
            self.assertEqual(explicit["directory"], "release-assets/Release-2.0.0-candidate-older")
            self.assertEqual(explicit["manifest_selection"], "explicit_manifest")

    def test_frozen_input_reverification_detects_mutation(self):
        with tempfile.TemporaryDirectory(dir=ROOT, prefix=".codex-task-tmp-g10-inputs-") as directory:
            temporary_root = Path(directory)
            source = temporary_root / "source.swift"
            source.write_text("let value = 1\n", encoding="utf-8")
            entry = {"path": "source.swift", "kind": "file", "bytes": source.stat().st_size,
                     "sha256": VERIFIER.sha256_file(source)}
            self.assertEqual(VERIFIER.verify_frozen_inputs([entry], temporary_root), [])
            source.write_text("let value = 2\n", encoding="utf-8")
            errors = VERIFIER.verify_frozen_inputs([entry], temporary_root)
            self.assertTrue(any("changed" in error for error in errors))


class G09PackageContractTests(unittest.TestCase):
    def passing_artifact_candidate(self):
        checks = {name: "PASS" for name in VERIFIER.G10_PACKAGE_CHECKS}
        checks.update({"full_user_workflow": "NOT_RUN", "app_data_rollback": "NOT_RUN"})
        return {
            "directory": "release-assets/Release-2.0.0-candidate-test",
            "manifest_path": "release-assets/Release-2.0.0-candidate-test/manifest-v2.0-local-candidate.json",
            "manifest_sha256": "a" * 64,
            "dmg_path": "release-assets/Release-2.0.0-candidate-test/LatticeLens-2.0.0-local.dmg",
            "dmg_sha256": "b" * 64,
            "input_manifest_sha256": "c" * 64,
            "source_identity_matches_current": True,
            "acceptance_receipts_valid": False,
            "checks": checks,
            "errors": [],
        }

    def make_acceptance_receipt_fixture(self, temporary_root, directory_name="candidate"):
        candidate_directory = Path(temporary_root) / directory_name
        evidence_directory = candidate_directory / "compact-validation"
        evidence_directory.mkdir(parents=True)
        candidate_identity = {
            "run_id": "candidate-run-1",
            "input_manifest_sha256": "a" * 64,
            "dmg_sha256": "b" * 64,
            "executable_sha256": "c" * 64,
        }
        manifest = {
            "run_id": candidate_identity["run_id"],
            "artifacts": {"dmg": {"sha256": candidate_identity["dmg_sha256"]}},
            "app": {"executable_sha256": candidate_identity["executable_sha256"]},
            "checks": {"full_user_workflow": "PASS", "app_data_rollback": "PASS"},
            "acceptance_receipts": {},
        }
        listed = {}
        for check_name, required_steps in VERIFIER.G09_ACCEPTANCE_STEPS.items():
            report_relative = "compact-validation/" + check_name + ".md"
            report_path = candidate_directory / report_relative
            report_path.write_text("Synthetic hash-bound acceptance evidence.\n", encoding="utf-8")
            report_digest = VERIFIER.sha256_file(report_path)
            listed[report_relative] = report_digest
            receipt = {
                "schema_version": VERIFIER.G09_ACCEPTANCE_RECEIPT_SCHEMA,
                "check": check_name,
                "status": "PASS",
                "scope": "synthetic contract test only",
                "completed_at_utc": "2026-10-08T00:00:00Z",
                "candidate": candidate_identity,
                "steps": [
                    {"id": step_id, "status": "PASS",
                     "evidence": {"file": report_relative, "sha256": report_digest}}
                    for step_id in sorted(required_steps)
                ],
            }
            receipt_relative = "compact-validation/" + check_name + ".json"
            receipt_path = candidate_directory / receipt_relative
            receipt_path.write_text(json.dumps(receipt, sort_keys=True), encoding="utf-8")
            receipt_digest = VERIFIER.sha256_file(receipt_path)
            listed[receipt_relative] = receipt_digest
            manifest["acceptance_receipts"][check_name] = {
                "file": receipt_relative,
                "sha256": receipt_digest,
            }
        return candidate_directory, manifest, listed

    def test_g09_absent_or_unreadable_candidate_is_not_reported_as_pass(self):
        status, _, issues = VERIFIER.evaluate_g09_package(None)
        self.assertEqual(status, "NOT_RUN")
        self.assertEqual(issues, [])

        status, summary, issues = VERIFIER.evaluate_g09_package(None, ["invalid candidate manifest"])
        self.assertEqual(status, "FAIL")
        self.assertIn("discovery failed", summary)
        self.assertEqual(issues, ["invalid candidate manifest"])

    def test_prepackage_validation_defers_g09_but_does_not_relabel_stale_candidate_as_pass(self):
        candidate = self.passing_artifact_candidate()
        candidate["source_identity_matches_current"] = False

        deferred, summary, issues = VERIFIER.evaluate_g09_package(
            candidate, pre_package_validation=True)
        ordinary, _, ordinary_issues = VERIFIER.evaluate_g09_package(candidate)

        self.assertEqual(deferred, "NOT_RUN")
        self.assertIn("deferred until the current-source package is built", summary)
        self.assertEqual(issues, [])
        self.assertEqual(ordinary, "BLOCKED")
        self.assertTrue(ordinary_issues)

    def test_g09_artifact_only_candidate_remains_partial_and_lists_gaps(self):
        status, summary, issues = VERIFIER.evaluate_g09_package(self.passing_artifact_candidate())

        self.assertEqual(status, "PARTIAL")
        self.assertIn("full_user_workflow=NOT_RUN", summary)
        self.assertIn("app_data_rollback=NOT_RUN", summary)
        self.assertEqual(set(issues), {"full_user_workflow=NOT_RUN", "app_data_rollback=NOT_RUN"})

    def test_g09_requires_the_sandboxed_system_temporary_write_denial_check(self):
        candidate = self.passing_artifact_candidate()
        candidate["checks"].pop("system_temporary_write_denied")

        status, summary, issues = VERIFIER.evaluate_g09_package(candidate)

        self.assertEqual(status, "FAIL")
        self.assertIn("system_temporary_write_denied", summary)
        self.assertEqual(issues, ["system_temporary_write_denied"])

    def test_stale_candidate_missing_a_new_check_is_blocked_until_rebuilt(self):
        candidate = self.passing_artifact_candidate()
        candidate["checks"].pop("system_temporary_write_denied")
        candidate["missing_package_checks"] = ["system_temporary_write_denied"]
        candidate["source_identity_matches_current"] = False

        status, summary, issues = VERIFIER.evaluate_g09_package(candidate)

        self.assertEqual(status, "BLOCKED")
        self.assertIn("rebuild it", summary)
        self.assertIn("system_temporary_write_denied", summary)
        self.assertEqual(len(issues), 1)

    def test_g09_pass_requires_source_binding_and_all_completion_checks(self):
        candidate = self.passing_artifact_candidate()
        candidate["checks"]["full_user_workflow"] = "PASS"
        candidate["checks"]["app_data_rollback"] = "PASS"
        self.assertEqual(
            VERIFIER.evaluate_g09_package(candidate)[0], "FAIL",
            "manifest statuses alone must not pass candidate completion")
        candidate["acceptance_receipts_valid"] = True
        status, _, issues = VERIFIER.evaluate_g09_package(candidate)
        self.assertEqual(status, "PASS")
        self.assertEqual(issues, [])

        candidate["source_identity_matches_current"] = False
        status, summary, _ = VERIFIER.evaluate_g09_package(candidate)
        self.assertEqual(status, "BLOCKED")
        self.assertIn("rebuild it", summary)

    def test_g09_acceptance_receipts_bind_exact_candidate_and_required_steps(self):
        with tempfile.TemporaryDirectory(dir=ROOT, prefix=".codex-task-tmp-g09-acceptance-") as directory:
            candidate_directory, manifest, listed = self.make_acceptance_receipt_fixture(
                directory, "candidate-tamper")

            errors = VERIFIER.validate_g09_acceptance_receipts(
                manifest, candidate_directory, listed, "a" * 64)

            self.assertEqual(errors, [])

    def test_g09_pass_without_receipt_or_checksum_bound_evidence_is_rejected(self):
        with tempfile.TemporaryDirectory(dir=ROOT, prefix=".codex-task-tmp-g09-acceptance-") as directory:
            candidate_directory, manifest, listed = self.make_acceptance_receipt_fixture(
                directory, "candidate-missing-receipt")
            manifest["acceptance_receipts"].pop("full_user_workflow")
            errors = VERIFIER.validate_g09_acceptance_receipts(
                manifest, candidate_directory, listed, "a" * 64)
            self.assertTrue(any("PASS without a bound acceptance receipt" in error for error in errors))

            candidate_directory, manifest, listed = self.make_acceptance_receipt_fixture(
                directory, "candidate-tampered-evidence")
            evidence_path = candidate_directory / "compact-validation/full_user_workflow.md"
            evidence_path.write_text("tampered evidence\n", encoding="utf-8")
            errors = VERIFIER.validate_g09_acceptance_receipts(
                manifest, candidate_directory, listed, "a" * 64)
            self.assertTrue(any("evidence hash is invalid" in error for error in errors))

    def test_g09_receipt_rejects_wrong_candidate_and_missing_workflow_step(self):
        with tempfile.TemporaryDirectory(dir=ROOT, prefix=".codex-task-tmp-g09-acceptance-") as directory:
            candidate_directory, manifest, listed = self.make_acceptance_receipt_fixture(directory)
            workflow = manifest["acceptance_receipts"]["full_user_workflow"]
            receipt_path = candidate_directory / workflow["file"]
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            receipt["candidate"]["dmg_sha256"] = "d" * 64
            receipt["steps"] = [step for step in receipt["steps"]
                                if step["id"] != "offline_browse"]
            receipt_path.write_text(json.dumps(receipt, sort_keys=True), encoding="utf-8")
            digest = VERIFIER.sha256_file(receipt_path)
            workflow["sha256"] = digest
            listed[workflow["file"]] = digest

            errors = VERIFIER.validate_g09_acceptance_receipts(
                manifest, candidate_directory, listed, "a" * 64)

            self.assertTrue(any("not bound to this exact app, DMG" in error for error in errors))
            self.assertTrue(any("omits required steps: offline_browse" in error for error in errors))

    def test_g09_integrity_or_explicit_workflow_failure_fails_closed(self):
        candidate = self.passing_artifact_candidate()
        candidate["errors"] = ["Candidate checksum mismatch: LatticeLens-2.0.0-local.dmg"]
        status, summary, issues = VERIFIER.evaluate_g09_package(candidate)
        self.assertEqual(status, "FAIL")
        self.assertIn("integrity", summary)
        self.assertEqual(issues, candidate["errors"])

        candidate = self.passing_artifact_candidate()
        candidate["checks"]["full_user_workflow"] = "FAIL"
        status, _, issues = VERIFIER.evaluate_g09_package(candidate)
        self.assertEqual(status, "FAIL")
        self.assertEqual(issues, ["full_user_workflow"])

        candidate = self.passing_artifact_candidate()
        candidate["checks"]["app_data_rollback"] = "BLOCKED"
        status, _, issues = VERIFIER.evaluate_g09_package(candidate)
        self.assertEqual(status, "BLOCKED")
        self.assertEqual(issues, ["app_data_rollback"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
