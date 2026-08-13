#!/bin/sh
# CODEX_MAIN_ONLY_PUSH_POLICY
set -eu
zero="0000000000000000000000000000000000000000"
while IFS=' ' read -r local_ref local_sha remote_ref remote_sha
do
  [ -z "$remote_ref" ] && continue
  if [ "$remote_ref" != "refs/heads/main" ]; then
    echo "Push blocked: only refs/heads/main is allowed (got $remote_ref)." >&2
    exit 1
  fi
  if [ "$local_sha" = "$zero" ]; then
    echo "Push blocked: deleting main is not allowed." >&2
    exit 1
  fi
done
exit 0

