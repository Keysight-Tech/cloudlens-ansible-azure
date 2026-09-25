#!/usr/bin/env bash
# Checks on the Docker tier: the image customers pull from GHCR and the docs
# that tell them how to run it.
#
# Written after an audit found the published image could not deploy what the
# docs promised: VMs tagged as documented were never discovered, Windows could
# not bootstrap (the az CLI was never logged in) or install (installer path),
# a failed Azure login exited 0, the site's wizard wrote a file nothing reads,
# and shard mode deployed to nobody while printing "complete". Every check
# below is one of those, and none needs a cloud account.
#
# Static checks always run:           bash deploy/tests/test_docker_image.sh
# Runtime checks need a built image:  IMAGE=<ref> bash deploy/tests/test_docker_image.sh
# REPO_DIR runs the static checks against another checkout; that is how they
# are proven to go red against the version before the fix.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${REPO_DIR:-$HERE/../..}" || exit 1

PASS=0
FAIL=0
pass() { printf 'PASS %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
skip() { printf 'SKIP %s\n' "$1"; }
# On a failure, show the tail of the last captured output: in CI that is the
# only way to see why a runtime check failed.
check() {
  if eval "$2" >/dev/null 2>&1; then pass "$1"; else
    fail "$1"
    if [[ -n "${out:-}" ]]; then printf '%s\n' "$out" | tail -8 | sed 's/^/    | /'; fi
  fi
}

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# ---------------------------------------------------------------- static ----

# The published image carried the CI job's .git (with a GitHub token) and a
# local build carried customer secrets.
for p in .git customer_input.yaml scripts/load_sp_creds.sh azure_sp_creds.json 'files/*'; do
  check ".dockerignore excludes $p" "grep -qxF '$p' .dockerignore"
done
check "checkout does not persist the job token into .git/config" \
  "grep -q 'persist-credentials: false' .github/workflows/docker-publish.yml"
check "the workflow smoke-tests the image before it pushes" \
  "python3 -c \"import sys; s=open('.github/workflows/docker-publish.yml').read(); i=s.find('test_docker_image.sh'); j=s.find('push: true'); sys.exit(0 if 0 <= i < j else 1)\""
for p in ansible.cfg 'vars/**' 'scripts/**' deploy/shard.sh; do
  check "a change to $p rebuilds the image" "grep -qF -e \"- '$p'\" .github/workflows/docker-publish.yml"
done

check "collections install from requirements.yml" \
  "grep -qE 'ansible-galaxy collection install -r /tmp/requirements.yml' Dockerfile"
check "every collection in requirements.yml has an upper bound" \
  "python3 -c \"import sys,yaml; c=yaml.safe_load(open('requirements.yml'))['collections']; sys.exit(0 if c and all('<' in str(x.get('version','')) for x in c) else 1)\""
check "ansible-core stays below 2.17 (RHEL 7/8 run Python 3.6)" \
  "grep -qE 'ansible-core>=2\.16,<2\.17' Dockerfile"

# The documented tag, in the one-line form deploy-stack.sh rewrites.
check "discovery filter is the documented cloudlens=yes" \
  "grep -qF \"tags['cloudlens'] is not defined or tags['cloudlens'] != 'yes'\" inventory/azure_rm.yaml"
check "deploy-stack.sh can still rewrite the discovery filter" \
  "python3 -c \"import re,sys; s=open('inventory/azure_rm.yaml').read(); sys.exit(0 if re.search(r\\\"  - tags\\\\['\\\\w+'\\\\] is not defined or tags\\\\['\\\\w+'\\\\] != '[^']+'\\\", s) else 1)\""

check "tuned-ansible.cfg has no inline comment after a value" \
  "! grep -nE '^[[:space:]]*[A-Za-z_]+[[:space:]]*=[^#]*[[:space:]]#' deploy/tuned-ansible.cfg"
check "tuned-ansible.cfg does not use the removed yaml callback" \
  "! grep -qE '^stdout_callback[[:space:]]*=[[:space:]]*yaml' deploy/tuned-ansible.cfg"

missing=""
for pb in playbooks/*.yaml; do
  for vf in $(python3 -c "import sys,yaml
for play in yaml.safe_load(open(sys.argv[1])) or []:
    for f in (play.get('vars_files') or []): print(f)" "$pb"); do
    [[ -f "playbooks/$vf" ]] || missing="$missing $pb:$vf"
  done
done
if [[ -z "$missing" ]]; then pass "every vars_files entry exists"; else fail "vars_files missing:$missing"; fi

check "Windows: the installer is checked before the old agent is touched" \
  "python3 -c \"import sys; s=open('playbooks/windows.yaml').read(); i=s.find('Installer is present on the control machine'); j=s.find('Stop CloudLens service if running'); sys.exit(0 if 0 <= i < j else 1)\""

# Every documented docker run must be able to deploy Windows and Linux.
# Written to a file first: bash 3.2 mis-parses a heredoc inside a command substitution.
cat > "$T/doccheck.py" <<'PY'
import re
bad = []
for path in ("docs/index.html", "README.md"):
    text = open(path).read().replace("\\\n", " ")
    for m in re.finditer(r"docker run[^\n<\x60]*cloudlens-ansible-azure:\S+", text):
        cmd = m.group(0)
        for need in ("/work/files", "ANSIBLE_WINRM_PASSWORD", "AZURE_SECRET", "/work/customer_input.yaml"):
            if need not in cmd:
                bad.append("%s: missing %s" % (path, need))
        if "$HOME/.ssh:/root/.ssh" in cmd:
            bad.append("%s: mounts all of ~/.ssh" % path)
print("\n".join(sorted(set(bad))))
PY
bad_cmds="$(python3 "$T/doccheck.py")"
if [[ -z "$bad_cmds" ]]; then pass "every documented docker run mounts files/, the input and a key, and passes the SP and WinRM variables"; else fail "documented docker run is incomplete: $bad_cmds"; fi

check "the wizard no longer offers the unimplemented bastion mode" "! grep -q 'value=\"bastion\"' docs/index.html"
if command -v node >/dev/null 2>&1; then
  node -e "
const fs = require('fs'); const src = fs.readFileSync('docs/script.js', 'utf8');
const body = src.slice(src.indexOf('  function quote('), src.indexOf('  function span('));
const v = x => ({ value: x });
const f = new Function('clmsIp', 'projKey', 'tags', 'rgs', 'mode', body + '; return buildYaml();');
process.stdout.write(f(v('10.1.2.3'), v('k\"ey'), v('Env=Azure, Region=eastus2'), v('rg-a'), v('direct_public')));
" > "$T/wizard.yaml" 2>/dev/null
  check "the wizard writes the schema the playbooks read" \
    "python3 -c \"import sys,yaml; d=yaml.safe_load(open('$T/wizard.yaml')); c=d['cloudlens']; sys.exit(0 if c['manager_ip_or_fqdn']=='10.1.2.3' and c['project_key']=='k\\\"ey' and 'clms' not in d and 'tags' not in d and d['azure']['tag_filters']['cloudlens']=='yes' else 1)\""
else
  skip "wizard output: node is not installed"
fi

# shard.sh, run for real with stub ansible commands.
mkdir -p "$T/shard/deploy" "$T/stubs"
cp deploy/shard.sh "$T/shard/deploy/shard.sh"
: > "$T/shard/customer_input.yaml"
cat > "$T/stubs/ansible-inventory" <<'STUB'
#!/usr/bin/env bash
if [[ "${STUB_EMPTY:-0}" == 1 ]]; then echo '{"_meta":{"hostvars":{}}}'; exit 0; fi
echo '{"_meta":{"hostvars":{"u1":{},"u2":{},"r1":{},"w1":{},"x9":{}}},"ubuntu_prod_vms":{"hosts":["u1","u2"]},"redhat_prod_vms":{"hosts":["r1"]},"windows_prod_vms":{"hosts":["w1"]},"ungrouped":{"hosts":["x9"]}}'
STUB
cat > "$T/stubs/ansible-playbook" <<'STUB'
#!/usr/bin/env bash
limit=""; prev=""
for a in "$@"; do [[ "$prev" == "--limit" ]] && limit="${a#@}"; prev="$a"; done
echo "argv: $*"
[[ "${STUB_NORECAP:-0}" == 1 ]] && exit 0
echo "PLAY RECAP *****"
while read -r h; do [[ -n "$h" ]] && printf '%-20s : ok=3    changed=1    unreachable=0    failed=0\n' "$h"; done < "$limit"
STUB
chmod +x "$T/stubs/"*
out="$(PATH="$T/stubs:$PATH" SHARD_SIZE=2 LOG_DIR="$T/shard/logs" bash "$T/shard/deploy/shard.sh" 4 5 2>&1)"; rc=$?
ran="$(cat "$T"/shard/logs/*.log 2>/dev/null | grep -c ' : ok=')"
if [[ $rc -eq 0 && "$ran" == 4 ]] && grep -q -- '--limit @' "$T"/shard/logs/shard_000.log; then
  pass "shard.sh keeps the groups: 4 target VMs deployed across shards with --limit"
else
  fail "shard.sh did not deploy the 4 target VMs (rc=$rc, ran=$ran): $(printf '%s' "$out" | tail -3)"
fi
rm -rf "$T/shard/logs"
PATH="$T/stubs:$PATH" STUB_EMPTY=1 LOG_DIR="$T/shard/logs" bash "$T/shard/deploy/shard.sh" >/dev/null 2>&1
check "shard.sh fails when no VM is in a target group" "[[ $? -ne 0 ]]"
rm -rf "$T/shard/logs"
PATH="$T/stubs:$PATH" STUB_NORECAP=1 SHARD_SIZE=2 LOG_DIR="$T/shard/logs" bash "$T/shard/deploy/shard.sh" >/dev/null 2>&1
check "shard.sh fails a shard that ran against no hosts" "[[ $? -ne 0 ]]"

# --------------------------------------------------------------- runtime ----
IMAGE="${IMAGE:-}"
if [[ -z "$IMAGE" ]]; then
  skip "runtime checks: set IMAGE=<image ref> to run them"
elif ! docker info >/dev/null 2>&1; then
  skip "runtime checks: docker is not available"
else
  D=(docker run --rm --platform linux/amd64)
  in_image() { "${D[@]}" --entrypoint bash "$IMAGE" -c "$1" 2>&1; }
  FAKE_SP=(-e AZURE_SUBSCRIPTION_ID=00000000-0000-0000-0000-000000000000
           -e AZURE_TENANT=00000000-0000-0000-0000-000000000000
           -e AZURE_CLIENT_ID=00000000-0000-0000-0000-000000000000 -e AZURE_SECRET=x)
  cp customer_input.yaml.example "$T/customer_input.yaml"

  out="$(in_image 'ansible --version')"
  check "image: ansible-core is 2.16" "grep -qE 'core 2\.16\.' <<<\"\$out\""

  out="$(in_image 'ansible-galaxy collection list')"
  for c in azure.azcollection ansible.windows community.windows community.general; do
    check "image: $c is on the collections path" "grep -qE '^$c +[0-9]' <<<\"\$out\""
  done

  for pb in deploy.yaml cleanup.yaml; do
    out="$(in_image "ansible-playbook --syntax-check -i localhost, $pb -e @customer_input.yaml.example")"; rc=$?
    check "image: $pb passes --syntax-check" "[[ $rc -eq 0 ]]"
    check "image: no collection says it does not support this ansible-core ($pb)" "! grep -q 'does not support Ansible version' <<<\"\$out\""
  done
  out="$(in_image "ANSIBLE_CONFIG=/work/deploy/tuned-ansible.cfg ansible-playbook --syntax-check -i localhost, deploy.yaml -e @customer_input.yaml.example")"; rc=$?
  check "image: deploy.yaml loads under deploy/tuned-ansible.cfg" "[[ $rc -eq 0 ]]"

  out="$(in_image 'ls -a /work; find /usr/share/ansible/collections -name "*.pem" -o -name "*.pfx" | wc -l')"
  check "image: no .git, no customer_input.yaml, no test fixture keys" \
    "! grep -qxE '\\.git|customer_input\\.yaml' <<<\"\$out\" && [[ \"\$(tail -1 <<<\"\$out\" | tr -d ' ')\" == 0 ]]"

  out="$("${D[@]}" --user 1000:1000 --entrypoint bash "$IMAGE" -c 'cd /work && ansible-galaxy collection list && ansible-playbook --syntax-check -i localhost, deploy.yaml -e @customer_input.yaml.example' 2>&1)"; rc=$?
  check "image: a non-root user can load the collections and parse the playbooks" "[[ $rc -eq 0 ]] && grep -q azure.azcollection <<<\"\$out\""

  # Relative files/... paths resolve from /work, where files/ is mounted.
  out="$(in_image 'cd /work
printf "[windows_prod_vms]\nw1\n[ubuntu_prod_vms]\nu1\n" > inventory/_probe.ini
cat > playbooks/_probe.yaml <<P
- hosts: u1
  gather_facts: no
  connection: local
  vars_files: [../vars/cloudlens.yaml]
  tasks:
    - debug: {msg: "INSTALLER={{ local_installer_path }} CA={{ local_ca_path }}"}
P
ansible-playbook -i inventory/_probe.ini playbooks/_probe.yaml -e @customer_input.yaml.example')"
  check "image: installer_path from the example resolves under /work/files" \
    "grep -q 'INSTALLER=/work/playbooks/../files/cloudlens-win-sensor' <<<\"\$out\""
  check "image: local_ca_path from the example resolves under /work/files" \
    "grep -q 'CA=/work/playbooks/../files/cloudlenscerts.crt' <<<\"\$out\""

  out="$(in_image 'cd /work && printf "[windows_prod_vms]\nw1 azure_private_ip=10.0.0.5\n" > inventory/_probe.ini && unset ANSIBLE_WINRM_PASSWORD && ansible-playbook -i inventory/_probe.ini playbooks/windows.yaml -e target_group=windows_prod_vms -e @customer_input.yaml.example')"; rc=$?
  check "image: Windows without a password stops in preflight with the fix" \
    "[[ $rc -ne 0 ]] && grep -q 'No WinRM password' <<<\"\$out\""

  out="$("${D[@]}" -v "$T/customer_input.yaml:/work/customer_input.yaml:ro" "${FAKE_SP[@]}" "$IMAGE" deploy 2>&1)"; rc=$?
  check "image: deploy with a bad service principal exits non-zero at the Azure login" \
    "[[ $rc -ne 0 ]] && grep -q 'Azure login with the service principal failed' <<<\"\$out\""
  out="$("${D[@]}" -v "$T/customer_input.yaml:/work/customer_input.yaml:ro" "$IMAGE" deploy 2>&1)"; rc=$?
  check "image: deploy with no credentials says which to set" "[[ $rc -ne 0 ]] && grep -q 'Set Azure credentials' <<<\"\$out\""
  mkdir -p "$T/emptydir/customer_input.yaml"
  out="$("${D[@]}" -v "$T/emptydir/customer_input.yaml:/work/customer_input.yaml" "${FAKE_SP[@]}" "$IMAGE" deploy 2>&1)"; rc=$?
  check "image: a missing customer_input.yaml (Docker made a folder) is named as such" "[[ $rc -ne 0 ]] && grep -q 'is a directory' <<<\"\$out\""
  out="$("${D[@]}" "${FAKE_SP[@]}" "$IMAGE" inventory 2>&1)"; rc=$?
  check "image: inventory with bad credentials exits non-zero" "[[ $rc -ne 0 ]]"

  # Past the login: stub az and the ansible commands to see what deploy runs.
  mkdir -p "$T/img"
  printf '#!/bin/sh\nexit 0\n' > "$T/img/az"
  cat > "$T/img/ansible-inventory" <<'STUB'
#!/bin/sh
if [ "${STUB_EMPTY:-0}" = 1 ]; then echo '{"_meta":{"hostvars":{}}}'; exit 0; fi
echo '{"_meta":{"hostvars":{"u1":{},"r1":{},"w1":{}}},"ubuntu_prod_vms":{"hosts":["u1"]},"redhat_prod_vms":{"hosts":["r1"]},"windows_prod_vms":{"hosts":["w1"]}}'
STUB
  printf '#!/bin/sh\necho "PLAYBOOK ARGV: $*"\n' > "$T/img/ansible-playbook"
  chmod +x "$T/img/"*
  STUBS=(-v "$T/img/az:/usr/bin/az:ro" -v "$T/img/ansible-inventory:/usr/local/bin/ansible-inventory:ro" -v "$T/img/ansible-playbook:/usr/local/bin/ansible-playbook:ro")
  out="$("${D[@]}" "${STUBS[@]}" -e STUB_EMPTY=1 -v "$T/customer_input.yaml:/work/customer_input.yaml:ro" "${FAKE_SP[@]}" "$IMAGE" deploy 2>&1)"; rc=$?
  check "image: zero matching VMs is an error that names the tags" "[[ $rc -ne 0 ]] && grep -q 'No VM matched' <<<\"\$out\""
  out="$("${D[@]}" "${STUBS[@]}" -v "$T/customer_input.yaml:/work/customer_input.yaml:ro" "${FAKE_SP[@]}" "$IMAGE" deploy 2>&1)"; rc=$?
  check "image: deploy runs the playbook on the inventory rendered from tag_filters" \
    "[[ $rc -eq 0 ]] && grep -q 'PLAYBOOK ARGV: -i /tmp/cloudlens-inventory/generated.azure_rm.yaml deploy.yaml' <<<\"\$out\""
  check "image: 3 VMs get the auto-tuned 20 forks" "grep -q -- '--forks 20' <<<\"\$out\""
  out="$("${D[@]}" "${STUBS[@]}" -e ANSIBLE_FORKS=7 -v "$T/customer_input.yaml:/work/customer_input.yaml:ro" "${FAKE_SP[@]}" "$IMAGE" deploy 2>&1)"
  check "image: ANSIBLE_FORKS overrides the auto-tuned forks" "grep -q -- '--forks 7' <<<\"\$out\""

  out="$("${D[@]}" -v "$T/customer_input.yaml:/work/customer_input.yaml:ro" --entrypoint bash "$IMAGE" -c 'cd /work && p=$(python3 scripts/render_azure_inventory.py customer_input.yaml /tmp/inv) && cat "$p"')"
  check "image: tag_filters become the discovery filters" \
    "grep -qF \"tags['cloudlens'] is not defined or tags['cloudlens'] != 'yes'\" <<<\"\$out\" && grep -qF \"tags['env'] is not defined or tags['env'] != 'prod'\" <<<\"\$out\""

  # A mounted ~/.ssh with a macOS-only option must not break SSH.
  mkdir -p "$T/ssh"
  ssh-keygen -q -t ed25519 -N '' -f "$T/ssh/id_rsa" >/dev/null 2>&1
  printf 'Host github.com\n  AddKeysToAgent yes\n  UseKeychain yes\n' > "$T/ssh/config"
  out="$("${D[@]}" -v "$T/ssh:/root/.ssh:ro" "$IMAGE" ansible all -i 127.0.0.1, -m ping -e ansible_ssh_private_key_file=/root/.ssh/id_rsa 2>&1)"
  check "image: a mounted ~/.ssh/config with UseKeychain does not break SSH" \
    "! grep -qi 'Bad configuration option' <<<\"\$out\" && grep -qiE 'refused|timed out|unreachable' <<<\"\$out\""

  out="$("${D[@]}" "$IMAGE" shell -c 'echo shell-ok' 2>&1)"
  check "image: shell mode passes its arguments to bash" "grep -q shell-ok <<<\"\$out\""
fi

printf '\n%d PASS, %d FAIL\n' "$PASS" "$FAIL"
[[ "$FAIL" == "0" ]]
