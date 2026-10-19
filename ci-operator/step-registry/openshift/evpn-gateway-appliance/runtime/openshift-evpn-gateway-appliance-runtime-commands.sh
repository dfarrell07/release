#!/usr/bin/env bash
set -euo pipefail

# /src is the tested checkout baked into ansible-test-runner, including Prow's merge.
cd "$(git rev-parse --show-toplevel)"
revision=$(git rev-parse HEAD)
[[ $revision =~ ^[0-9a-f]{40}$ ]]
test -f image/tools/test-runtime.sh
authfile=${REGISTRY_AUTH_FILE:-/var/run/secrets/ci-pull-credentials/.dockerconfigjson}
test -s "$authfile"
mkdir -p "$ARTIFACT_DIR"
printf '%s\n' "$revision" >"$ARTIFACT_DIR/source-revision.txt"

local_work=$(mktemp -d)
remote_work=""
ip=$(cat "${SHARED_DIR}/public_address")
user=$(cat "${SHARED_DIR}/ssh_user")
ssh_options=(-i "${CLUSTER_PROFILE_DIR}/ssh-privatekey" -o BatchMode=yes -o IdentitiesOnly=yes
  -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3
  -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$local_work/known_hosts")
remote() {
  # Commands are deliberately assembled for execution by the remote shell.
  # shellcheck disable=SC2029
  ssh "${ssh_options[@]}" "${user}@${ip}" "$@"
}

cleanup() {
  status=$?
  trap - EXIT
  set +e
  if [[ -n $remote_work ]]; then
    # Remove credentials before collecting only the explicitly selected output directory.
    remote "sudo -n rm -f '$remote_work/auth.json'"
    auth_status=$?
    remote "sudo -n tar -C '$remote_work/artifacts' -czf - ." >"$ARTIFACT_DIR/runtime-artifacts.tar.gz"
    collection_status=$?
    remote "sudo -n rm -rf '$remote_work'"
    cleanup_status=$?
    if [[ $status -eq 0 && $auth_status -ne 0 ]]; then status=$auth_status; fi
    if [[ $status -eq 0 && $collection_status -ne 0 ]]; then status=$collection_status; fi
    if [[ $status -eq 0 && $cleanup_status -ne 0 ]]; then status=$cleanup_status; fi
  fi
  rm -rf "$local_work"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

candidate=$(remote 'umask 077; mktemp -d /tmp/ega-runtime.XXXXXXXX')
[[ $candidate =~ ^/tmp/ega-runtime\.[[:alnum:]]{8}$ ]]
remote_work=$candidate
remote "mkdir '$remote_work/source' '$remote_work/artifacts'"
# Archive exactly HEAD; do not fetch a mutable PR head or reuse the release PR number.
git archive --format=tar HEAD >"$local_work/source.tar"
sha256sum <"$local_work/source.tar" >"$ARTIFACT_DIR/source-archive.sha256"
remote "tar -C '$remote_work/source' -xf -" <"$local_work/source.tar"
remote "umask 077; cat > '$remote_work/auth.json'" <"$authfile"

# Bound setup separately; the independent remote timeout also survives an SSH disconnect.
remote 'sudo -n timeout --kill-after=1m 10m dnf install -y podman' 2>&1 | tee "$ARTIFACT_DIR/host-setup.log"
runner_env=("REGISTRY_AUTH_FILE=$remote_work/auth.json" "ARTIFACT_DIR=$remote_work/artifacts"
  "SOURCE_REVISION=$revision")
for name in BOOTC_BASE EGA_PAYLOAD_RHEL10_FRR_REPOSITORY EGA_PAYLOAD_RHEL10_FRR_TAG \
  EGA_PAYLOAD_RHEL10_FRR_DIGEST EGA_PAYLOAD_RHEL10_NODE_EXPORTER_REPOSITORY \
  EGA_PAYLOAD_RHEL10_NODE_EXPORTER_TAG EGA_PAYLOAD_RHEL10_NODE_EXPORTER_DIGEST; do
  if [[ -n ${!name:-} ]]; then runner_env+=("$name=${!name}"); fi
done
printf -v command '%q ' sudo -n env "${runner_env[@]}" timeout --kill-after=1m 45m \
  bash "$remote_work/source/image/tools/test-runtime.sh"
remote "cd '$remote_work/source' && $command" 2>&1 | tee "$ARTIFACT_DIR/runtime.log"
