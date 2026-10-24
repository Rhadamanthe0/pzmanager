#!/usr/bin/env bash
# C4 : mêmes critères fail-closed, exécutés via admission réelle et SQLite.
# Les mocks systemd n'admettent que nos fixtures ; jamais d'hôte actif.
set -euo pipefail
ROOT="${PZ_TEST_ROOT:?runner jetable requis}"
exec python3 "$ROOT/tests/test_accounts_safety.py" \
 Accounts.test_purge_read_error_before_backup \
 Accounts.test_purge_read_and_write_lock_fail_closed \
 Accounts.test_purge_trigger_error_rolls_back_all \
 Accounts.test_purge_shared_sid_unknown_age_and_empty_plan \
 Accounts.test_purge_backup_error_prevents_delete \
 Accounts.test_term_precondition_rejects_unreached_backup \
 Accounts.test_term_guard_rejects_worker_before_backup \
 Accounts.test_purge_term_before_delete_preserves_rows \
 Accounts.test_purge_nominal_without_sid_third_authorization_and_counts \
 Accounts.test_purge_days_boundary_and_existing_ledger \
 Accounts.test_purge_invalid_days_and_benign_bad_record_refused \
 Accounts.test_purge_wal_backup_includes_committed_pages \
 Accounts.test_purge_pending_transaction_refused \
 Accounts.test_start_pre_broker_preserves_parent_lock \
 Accounts.test_start_pre_backup_error_keeps_parent_lock_and_data \
 Accounts.test_manual_purge_has_faithful_backup \
 Accounts.test_foreign_states_and_fake_fd_refused \
 Accounts.test_force_active_dry_run_is_read_only \
 Accounts.test_force_active_cannot_mutate
