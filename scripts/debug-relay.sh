#!/usr/bin/env bash
# debug-relay.sh is executed by Terraform's terraform_data.debug_on_failure via
# `bash -c "$(file debug-relay.sh)"`. It polls the bootstrap Job and relays its
# logs back to the Terraform apply output whenever the Job failed or never
# reached a terminal state. The caller supplies these environment variables:
#
#   BOOTSTRAP_NAMESPACE  — namespace where the Job runs
#   TIMEOUT_SECONDS      — shared timeout budget (in seconds) used for both
#                          the "wait for Job to appear" and "wait for Job to
#                          reach a terminal condition" polls
#
# This is a plain shell script (no Terraform templating) so ${var} parameter
# expansion, $(...) command substitution, and any other shell syntax work
# without escape rules.

ns="${BOOTSTRAP_NAMESPACE}"
timeout_seconds="${TIMEOUT_SECONDS}"
job=flux-operator-bootstrap

# Poll for the Job to appear (helm post-install hook creates it).
deadline=$(( $(date +%s) + timeout_seconds ))
while [ $(date +%s) -lt $deadline ]; do
  if kubectl -n "$ns" get job "$job" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
if ! kubectl -n "$ns" get job "$job" >/dev/null 2>&1; then
  echo "flux-operator-bootstrap: job not created" >&2
  exit 0
fi

# Poll for the Job to reach a terminal condition (complete or failed).
result=""
deadline=$(( $(date +%s) + timeout_seconds ))
while [ $(date +%s) -lt $deadline ]; do
  status=$(kubectl -n "$ns" get job "$job" \
    -o go-template='{{range .status.conditions}}{{.type}}={{.status}} {{end}}' 2>/dev/null || echo "")
  case "$status" in
    *Complete=True*) result="complete"; break ;;
    *Failed=True*) result="failed"; break ;;
  esac
  sleep 2
done

# Only dump logs when the Job failed or never reached a terminal state.
if [ "$result" != "complete" ]; then
  echo "========== flux-operator-bootstrap job logs =========="
  kubectl -n "$ns" logs "job/$job" 2>&1 || true
  echo "======================================================"
fi
