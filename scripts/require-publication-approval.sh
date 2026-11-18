#!/usr/bin/env bash
# Source only from production distribution commands; local builds and rehearsals do not use it.
if [[ "${RELAYBAR_PUBLICATION_APPROVED:-}" != "yes" ]]; then
  echo "This command changes distribution state. Obtain explicit user approval, then set RELAYBAR_PUBLICATION_APPROVED=yes for this invocation." >&2
  exit 1
fi
