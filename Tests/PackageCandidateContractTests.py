#!/usr/bin/env python3
"""Contract tests for the project-local 2.0 candidate packager."""

import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "Scripts" / "package_2_0_local_candidate.py"
SPEC = importlib.util.spec_from_file_location("package_candidate", SCRIPT)
PACKAGE_CANDIDATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE_CANDIDATE)


class PackageCandidateContractTests(unittest.TestCase):
    def test_packager_release_identity_matches_the_xcode_project(self):
        self.assertEqual(PACKAGE_CANDIDATE.current_product_identity(ROOT), ("2.0.0", 210))
        self.assertEqual((PACKAGE_CANDIDATE.PRODUCT_VERSION, PACKAGE_CANDIDATE.BUILD_NUMBER),
                         PACKAGE_CANDIDATE.current_product_identity(ROOT))

        with tempfile.TemporaryDirectory(dir=ROOT, prefix=".codex-task-tmp-release-identity-") as temporary:
            project = Path(temporary) / "LatticeLens.xcodeproj"
            project.mkdir()
            (project / "project.pbxproj").write_text(
                "MARKETING_VERSION = 2.0.0; INFOPLIST_KEY_CFBundleShortVersionString = 2.0.0; "
                "CURRENT_PROJECT_VERSION = 204; INFOPLIST_KEY_CFBundleVersion = 205;\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "build numbers disagree"):
                PACKAGE_CANDIDATE.current_product_identity(Path(temporary))

    @staticmethod
    def _candidate_output_snapshot():
        candidate = ROOT / "release-assets" / "Release-2.0.0-local"
        if not candidate.exists() and not candidate.is_symlink():
            return None

        entries = {}
        paths = [candidate, *candidate.rglob("*")]
        for path in sorted(paths, key=lambda item: item.as_posix()):
            relative = path.relative_to(candidate.parent).as_posix()
            metadata = path.lstat()
            common = (metadata.st_mtime_ns, metadata.st_mode & 0o777)
            if path.is_symlink():
                entries[relative] = ("symlink", os.readlink(path), *common)
            elif path.is_dir():
                entries[relative] = ("directory", *common)
            elif path.is_file():
                entries[relative] = (
                    "file", metadata.st_size, PACKAGE_CANDIDATE.sha256(path), *common
                )
            else:
                entries[relative] = ("other", *common)
        return entries

    def test_controlled_environment_drops_all_inherited_product_overrides(self):
        inherited = {
            "PATH": "/usr/bin",
            "LATTICELENS_LIVE_INSPIRE_SMOKE": "1",
            "LATTICELENS_V5_DISPOSABLE_V7_STORE": "/outside/source.store",
            "LATTICELENS_V5_DISPOSABLE_SOURCE_ORIGIN": "user_provided",
            "LATTICELENS_V10_DISPOSABLE_INPUT_MANIFEST_SHA256": "stale",
            "LATTICELENS_ALLOW_PRODUCTION_ISOLATION": "1",
            "LATTICELENS_PRODUCTION_STORE_ROOT": "/outside/library",
            "LATTICELENS_UNRECOGNIZED_FUTURE_OPT_IN": "1",
        }
        with patch.dict(os.environ, inherited, clear=True):
            environment = PACKAGE_CANDIDATE.controlled_environment({
                "HOME": "/project/home",
                "LATTICELENS_USE_FIXTURES": "1",
            })

        self.assertEqual(environment["PATH"], "/usr/bin")
        self.assertEqual(environment["HOME"], "/project/home")
        self.assertEqual(environment["LATTICELENS_USE_FIXTURES"], "1")
        self.assertFalse(any(key.startswith("LATTICELENS_") and
                             key != "LATTICELENS_USE_FIXTURES"
                             for key in environment))

    def test_output_path_rejects_symlinked_parent_outside_project(self):
        with tempfile.TemporaryDirectory(
                dir=ROOT, prefix=".codex-task-tmp-package-contract-") as temporary:
            parent = Path(temporary)
            project = parent / "project"
            outside = parent / "outside"
            project.mkdir()
            outside.mkdir()
            (project / "release-assets").symlink_to(outside, target_is_directory=True)
            target = project / "release-assets" / "Release-2.0.0-local"

            with self.assertRaises(RuntimeError):
                PACKAGE_CANDIDATE.validate_output_target(project, target)

    def test_project_file_rejects_symlinked_parent_components(self):
        with tempfile.TemporaryDirectory(
                dir=ROOT, prefix=".codex-task-tmp-package-input-symlink-") as temporary:
            project = Path(temporary) / "project"
            real_directory = project / "real"
            real_directory.mkdir(parents=True)
            (real_directory / "input.json").write_text("{}\n", encoding="utf-8")
            (project / "linked").symlink_to(real_directory, target_is_directory=True)

            with patch.object(PACKAGE_CANDIDATE, "ROOT", project):
                with self.assertRaisesRegex(RuntimeError, "non-symlink project file"):
                    PACKAGE_CANDIDATE.project_file("linked/input.json")

    def test_package_checksum_map_rejects_symlinked_parent_within_package(self):
        with tempfile.TemporaryDirectory(
                dir=ROOT, prefix=".codex-task-package-checksum-symlink-") as temporary:
            project = Path(temporary) / "project"
            package = project / "release-assets" / "Release-2.0.0-candidate-test"
            payloads = package / "payloads"
            payloads.mkdir(parents=True)
            payload = payloads / "context.md"
            payload.write_text("synthetic history\n", encoding="utf-8")
            (package / "compact-validation").symlink_to(
                payloads.name, target_is_directory=True)
            (package / "SHA256SUMS.txt").write_text(
                PACKAGE_CANDIDATE.sha256(payload) + "  compact-validation/context.md\n",
                encoding="utf-8")

            with patch.object(PACKAGE_CANDIDATE, "ROOT", project):
                with self.assertRaisesRegex(RuntimeError, "symlinked or outside"):
                    PACKAGE_CANDIDATE.package_checksum_map(package)

    def test_unbound_historical_context_rejects_symlinked_evidence_directory(self):
        with tempfile.TemporaryDirectory(
                dir=ROOT, prefix=".codex-task-historical-parent-symlink-") as temporary:
            project = Path(temporary) / "project"
            project.mkdir()
            outside = Path(temporary) / "other-project-evidence"
            outside.mkdir()
            for source_path in PACKAGE_CANDIDATE.HISTORICAL_CONTEXT_PATHS:
                (outside / Path(source_path).name).write_text(
                    "synthetic history\n", encoding="utf-8")
            (project / "evidence").symlink_to(outside, target_is_directory=True)

            with patch.object(PACKAGE_CANDIDATE, "ROOT", project):
                with self.assertRaisesRegex(RuntimeError, "regular historical context source"):
                    PACKAGE_CANDIDATE.historical_context_sources({})

    def test_default_output_is_preserved_and_custom_output_must_be_new_and_project_local(self):
        arguments = PACKAGE_CANDIDATE.parse_arguments([
            "validation.json", "input-manifest.json", "performance.json", "migration.json",
        ])
        self.assertEqual(Path(arguments.output_directory), PACKAGE_CANDIDATE.OUTPUT)
        self.assertFalse(arguments.skip_fixture_ui_quit)
        skip_quit = PACKAGE_CANDIDATE.parse_arguments([
            "validation.json", "input-manifest.json", "performance.json", "migration.json",
            "--skip-fixture-ui-quit",
        ])
        self.assertTrue(skip_quit.skip_fixture_ui_quit)

        custom = PACKAGE_CANDIDATE.package_output_target(
            ROOT, "release-assets/Release-2.0.0-host-free-contract")
        self.assertEqual(custom, ROOT / "release-assets" / "Release-2.0.0-host-free-contract")
        PACKAGE_CANDIDATE.require_new_output_directory(custom)

        with self.assertRaises(RuntimeError):
            PACKAGE_CANDIDATE.package_output_target(ROOT, ROOT.parent / "outside-candidate")

        with tempfile.TemporaryDirectory(
                dir=ROOT, prefix=".codex-task-tmp-existing-candidate-contract-") as existing:
            with self.assertRaisesRegex(RuntimeError, "refusing to overwrite"):
                PACKAGE_CANDIDATE.require_new_output_directory(Path(existing))

    def test_canonical_validation_report_uses_root_summary_and_run_specific_report_uses_sibling(self):
        canonical_report = ROOT / "evidence" / "Validation-2.0-final-local.json"
        canonical_summary = ROOT / "VALIDATION_2.0_FINAL.md"
        run_specific_report = ROOT / "evidence" / "Validation-2.0-final-local-run-id.json"

        self.assertEqual(PACKAGE_CANDIDATE.validation_summary_path(canonical_report), canonical_summary)
        self.assertEqual(PACKAGE_CANDIDATE.validation_summary_path(run_specific_report),
                         run_specific_report.with_suffix(".md"))

    def test_universal_binary_check_verifies_each_architecture_separately(self):
        binary = Path("/project/LatticeLens")

        self.assertEqual(
            PACKAGE_CANDIDATE.lipo_verify_arch_commands(binary),
            [
                ["lipo", str(binary), "-verify_arch", "arm64"],
                ["lipo", str(binary), "-verify_arch", "x86_64"],
            ],
        )

    def test_candidate_gate_summary_reconciles_post_package_g09_without_mutating_receipt(self):
        validation = {"gate_results": [
            {"gate": "G01", "status": "PARTIAL", "summary": "XCUITest matrix remains open."},
            {"gate": "G08", "status": "PASS", "summary": "V11 disk benchmark passed."},
            {"gate": "G09", "status": "NOT_RUN", "summary": "No provenance-bound DMG exists."},
        ]}
        checks = {
            "dmg_verify": "PASS",
            "readonly_mount": "PASS",
            "mounted_signature": "PASS",
            "isolated_install_executable_hash_match": "PASS",
            "fixture_no_network_launch_smoke": "PASS",
            "system_temporary_write_denied": "PASS",
            "fixture_app_ui_quit": "NOT_RUN",
            "ui_runner": "NOT_RUN",
            "full_user_workflow": "NOT_RUN",
            "app_data_rollback": "NOT_RUN",
            "voiceover": "NOT_RUN",
        }
        original = [dict(item) for item in validation["gate_results"]]

        gates = PACKAGE_CANDIDATE.candidate_unpassed_gates(validation, checks)

        self.assertEqual(validation["gate_results"], original,
                         "post-package disposition must not rewrite the frozen verifier receipt")
        self.assertEqual([item["gate"] for item in gates], ["G01", "G09"])
        g09 = next(item for item in gates if item["gate"] == "G09")
        self.assertEqual(g09["status"], "PARTIAL")
        self.assertIn("candidate DMG", g09["summary"])
        self.assertIn("app/data rollback", g09["summary"])

    def test_candidate_gate_summary_does_not_clear_an_explicit_g09_failure(self):
        validation = {"gate_results": [
            {"gate": "G09", "status": "FAIL", "summary": "Candidate integrity check failed."},
        ]}
        checks = {
            "dmg_verify": "PASS",
            "readonly_mount": "PASS",
            "mounted_signature": "PASS",
            "isolated_install_executable_hash_match": "PASS",
            "fixture_no_network_launch_smoke": "PASS",
            "system_temporary_write_denied": "PASS",
        }

        gates = PACKAGE_CANDIDATE.candidate_unpassed_gates(validation, checks)

        self.assertEqual(gates[0]["status"], "FAIL")
        self.assertIn("integrity check failed", gates[0]["summary"])

    def test_candidate_gate_summary_downgrades_prepackage_pass_without_workflow_and_rollback(self):
        validation = {"gate_results": [
            {"gate": "G09", "status": "PASS", "summary": "Previous gate record said pass."},
        ]}
        checks = {
            "dmg_verify": "PASS",
            "readonly_mount": "PASS",
            "mounted_signature": "PASS",
            "isolated_install_executable_hash_match": "PASS",
            "fixture_no_network_launch_smoke": "PASS",
            "system_temporary_write_denied": "PASS",
            "full_user_workflow": "NOT_RUN",
            "app_data_rollback": "NOT_RUN",
        }

        gates = PACKAGE_CANDIDATE.candidate_unpassed_gates(validation, checks)

        self.assertEqual(len(gates), 1)
        self.assertEqual(gates[0]["status"], "PARTIAL")
        self.assertIn("app/data rollback", gates[0]["summary"])

    def test_rebuilt_candidate_resolves_only_the_stale_source_blocker(self):
        validation = {"gate_results": [
            {"gate": "G09", "status": "BLOCKED",
             "summary": "The candidate build-input source entries do not match the current source snapshot; "
                        "rebuild it before accepting G09. The stale candidate lacks a current check."},
        ]}
        checks = {name: "PASS" for name in PACKAGE_CANDIDATE.G09_ARTIFACT_CHECKS}
        checks.update({"full_user_workflow": "NOT_RUN", "app_data_rollback": "NOT_RUN"})

        gates = PACKAGE_CANDIDATE.candidate_unpassed_gates(validation, checks)

        self.assertEqual(len(gates), 1)
        self.assertEqual(gates[0]["status"], "PARTIAL")
        self.assertIn("stale candidate was replaced", gates[0]["summary"])
        self.assertIn("app/data rollback remain NOT_RUN", gates[0]["summary"])

    def test_candidate_gate_summary_requires_all_g09_acceptance_checks_before_passing(self):
        validation = {"gate_results": [
            {"gate": "G09", "status": "PARTIAL", "summary": "Full workflow remains open."},
        ]}
        checks = {
            "dmg_verify": "PASS",
            "readonly_mount": "PASS",
            "mounted_signature": "PASS",
            "isolated_install_executable_hash_match": "PASS",
            "fixture_no_network_launch_smoke": "PASS",
            "system_temporary_write_denied": "PASS",
            "full_user_workflow": "PASS",
            "app_data_rollback": "PASS",
        }

        gates = PACKAGE_CANDIDATE.candidate_unpassed_gates(validation, checks)

        self.assertEqual(gates, [])

    def test_candidate_gate_requires_system_temporary_write_denial(self):
        checks = {name: "PASS" for name in PACKAGE_CANDIDATE.G09_ARTIFACT_CHECKS}
        checks["system_temporary_write_denied"] = "NOT_RUN"
        validation = {"gate_results": [
            {"gate": "G09", "status": "NOT_RUN", "summary": "No candidate yet."},
        ]}

        gates = PACKAGE_CANDIDATE.candidate_unpassed_gates(validation, checks)

        self.assertEqual(gates[0]["status"], "PARTIAL")
        self.assertIn("system_temporary_write_denied", gates[0]["summary"])

    def test_fixture_sandbox_denies_network_user_library_keychain_and_system_temporary_writes(self):
        with tempfile.TemporaryDirectory(
                dir=ROOT, prefix=".codex-task-tmp-sandbox-profile-") as temporary:
            profile = PACKAGE_CANDIDATE.sandbox_profile_text(Path(temporary))

        self.assertIn("(deny network*)", profile)
        self.assertIn("(deny file-read* (subpath", profile)
        self.assertIn("(deny file-write* (subpath", profile)
        self.assertIn('(deny mach-lookup (global-name "com.apple.securityd"))', profile)
        self.assertTrue(PACKAGE_CANDIDATE.system_temporary_writes_denied(profile))
        self.assertFalse(PACKAGE_CANDIDATE.system_temporary_writes_denied(
            profile.replace('(deny file-write* (subpath "/private/var/folders"))\n', "")))

    def test_fixture_sandbox_profile_is_accepted_by_macos_sandbox_exec(self):
        sandbox_exec = shutil.which("sandbox-exec")
        if not sandbox_exec:
            self.skipTest("sandbox-exec is unavailable on this host")
        with tempfile.TemporaryDirectory(
                dir=ROOT, prefix=".codex-task-tmp-sandbox-parse-") as temporary:
            profile_path = Path(temporary) / "fixture.sb"
            profile_path.write_text(
                PACKAGE_CANDIDATE.sandbox_profile_text(Path(temporary)), encoding="utf-8")
            result = subprocess.run(
                [sandbox_exec, "-f", str(profile_path), "/usr/bin/true"],
                cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, check=False,
            )

        self.assertEqual(result.returncode, 0, result.stdout)

    def test_process_group_termination_stops_leader_and_child(self):
        process = subprocess.Popen(["/bin/sh", "-c", "sleep 60 & wait"],
                                   cwd=ROOT, start_new_session=True)
        PACKAGE_CANDIDATE.ACTIVE_PROCESS_GROUPS.add(process.pid)
        try:
            self.assertTrue(PACKAGE_CANDIDATE.process_group_exists(process.pid))
            self.assertTrue(PACKAGE_CANDIDATE.terminate_process(process))
            self.assertFalse(PACKAGE_CANDIDATE.process_group_exists(process.pid))
            self.assertNotIn(process.pid, PACKAGE_CANDIDATE.ACTIVE_PROCESS_GROUPS)
        finally:
            PACKAGE_CANDIDATE.terminate_process(process)

    def test_fixture_quit_retries_once_with_restore_window_only_when_focus_is_rejected(self):
        with tempfile.TemporaryDirectory(
                dir=ROOT, prefix=".codex-task-tmp-package-quit-retry-") as temporary:
            commands = []

            def fake_orca_result(command, *, log, timeout=30):
                if command[1:3] == ["computer", "hotkey"]:
                    commands.append(command)
                    if len(commands) == 1:
                        raise RuntimeError("provider rejected action: window_not_focused")
                    return {}
                if command[1:3] == ["computer", "list-apps"]:
                    return {"apps": []}
                self.fail("unexpected Orca command: " + " ".join(command))

            with patch.object(PACKAGE_CANDIDATE, "fixture_app_window_arguments",
                              return_value=["--window-id", "77"]), \
                    patch.object(PACKAGE_CANDIDATE, "orca_result",
                                 side_effect=fake_orca_result):
                PACKAGE_CANDIDATE.request_fixture_app_quit(
                    "/usr/local/bin/orca", 12345, Path(temporary))

        self.assertEqual(len(commands), 2)
        self.assertNotIn("--restore-window", commands[0])
        self.assertIn("--restore-window", commands[1])

    def test_fixture_quit_does_not_retry_non_focus_errors(self):
        with tempfile.TemporaryDirectory(
                dir=ROOT, prefix=".codex-task-tmp-package-quit-error-") as temporary:
            with patch.object(PACKAGE_CANDIDATE, "fixture_app_window_arguments",
                              return_value=["--window-id", "77"]), \
                    patch.object(PACKAGE_CANDIDATE, "orca_result",
                                 side_effect=RuntimeError("app_not_found")) as orca_result:
                with self.assertRaisesRegex(RuntimeError, "app_not_found"):
                    PACKAGE_CANDIDATE.request_fixture_app_quit(
                        "/usr/local/bin/orca", 12345, Path(temporary))

        self.assertEqual(orca_result.call_count, 1)

    def test_fixture_ui_quit_can_be_skipped_without_gui_input_and_stays_not_run(self):
        with patch.object(PACKAGE_CANDIDATE, "request_fixture_app_quit") as request_quit:
            status, summary = PACKAGE_CANDIDATE.fixture_app_ui_quit_result(
                "/usr/local/bin/orca", 12345, ROOT, skip=True)

        self.assertEqual(status, "NOT_RUN")
        self.assertIn("process group is still stopped", summary)
        request_quit.assert_not_called()

    def test_fixture_ui_quit_focus_failure_is_recorded_as_not_run(self):
        with patch.object(PACKAGE_CANDIDATE, "request_fixture_app_quit",
                          side_effect=RuntimeError("window_not_focused after restore")):
            status, summary = PACKAGE_CANDIDATE.fixture_app_ui_quit_result(
                "/usr/local/bin/orca", 12345, ROOT)

        self.assertEqual(status, "NOT_RUN")
        self.assertIn("including after one --restore-window attempt", summary)

    def test_fixture_ui_quit_propagates_errors_unrelated_to_focus(self):
        with patch.object(PACKAGE_CANDIDATE, "request_fixture_app_quit",
                          side_effect=RuntimeError("fixture PID mismatch")):
            with self.assertRaisesRegex(RuntimeError, "fixture PID mismatch"):
                PACKAGE_CANDIDATE.fixture_app_ui_quit_result(
                    "/usr/local/bin/orca", 12345, ROOT)

    def test_checked_run_reports_the_actual_nonzero_return_code(self):
        with self.assertRaisesRegex(RuntimeError, r"command failed \(7\)"):
            PACKAGE_CANDIDATE.checked_run([
                sys.executable, "-B", "-c", "print('expected failure'); raise SystemExit(7)",
            ])

    def test_checked_run_timeout_stops_the_entire_process_group(self):
        with self.assertRaisesRegex(RuntimeError, "command timed out"):
            PACKAGE_CANDIDATE.checked_run(["/bin/sh", "-c", "sleep 60 & wait"], timeout=0.1)

        self.assertEqual(PACKAGE_CANDIDATE.ACTIVE_PROCESS_GROUPS, set())

    def test_help_is_successful_and_does_not_start_a_package_build(self):
        before = self._candidate_output_snapshot()
        result = subprocess.run(
            [sys.executable, "-B", str(SCRIPT), "--help"],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("partial-validation.json", result.stdout)
        self.assertIn("--output-directory", result.stdout)
        self.assertIn("--skip-fixture-ui-quit", result.stdout)
        self.assertEqual(self._candidate_output_snapshot(), before,
                         "--help must leave an existing candidate package unchanged")


if __name__ == "__main__":
    unittest.main()
