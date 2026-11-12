#!/usr/bin/env bash
# Require SilverPanda's cosign signature on the toolbox image, as the signing
# module does for the OS image itself. Runs after the signing module.
set -euo pipefail
policy=/etc/containers/policy.json
key=/etc/pki/containers/silverpanda.pub
repo=ghcr.io/wiertless/silverpanda-toolbox
test -f "$key"
jq --arg repo "$repo" --arg key "$key" \
  '.transports.docker[$repo] = [{"type": "sigstoreSigned", "keyPath": $key, "signedIdentity": {"type": "matchRepository"}}]' \
  "$policy" > /tmp/policy.json
mv /tmp/policy.json "$policy"
cat > /etc/containers/registries.d/ghcr.io-wiertless-silverpanda-toolbox.yaml <<YAML
docker:
  $repo:
    use-sigstore-attachments: true
YAML
