#!/usr/bin/env bash
set -euo pipefail
umask 077

# Published as ci/public-build.sh in Xxdl, outside the private source checkout.
mode=${1:-}
case "$mode" in resolve|checkout|host|build|stage|release|cleanup|self-test) ;; *) exit 2 ;; esac

check_stage() {
    python3 - "$1" <<'PY'
import hashlib, pathlib, re, sys
p = pathlib.Path(sys.argv[1])
files = list(p.iterdir())
apks = [f for f in files if re.fullmatch(r'PronCam-[A-Za-z0-9._-]+-[0-9]+-SCAM\.apk', f.name)]
if len(files) != 2 or len(apks) != 1 or {f.name for f in files} != {apks[0].name, 'SHA256SUMS.txt'}:
    raise SystemExit('Unexpected publication files')
if any(f.is_symlink() or not f.is_file() for f in files):
    raise SystemExit('Unsafe publication file')
expected = hashlib.sha256(apks[0].read_bytes()).hexdigest() + '  ' + apks[0].name + '\n'
if (p / 'SHA256SUMS.txt').read_text() != expected:
    raise SystemExit('APK digest differs')
PY
}

if [[ "$mode" == self-test ]]; then
    fixture=$(mktemp -d)
    trap 'rm -rf -- "$fixture"' EXIT
    stage="$fixture/stage"
    mkdir "$stage" "$fixture/bin"
    printf 'fixture APK' > "$stage/PronCam-0.98-31306-SCAM.apk"
    (cd "$stage" && sha256sum *.apk > SHA256SUMS.txt)
    check_stage "$stage"
    printf 'private source canary' > "$stage/Source.java"
    if check_stage "$stage" >/dev/null 2>&1; then exit 1; fi
    rm "$stage/Source.java"
    printf 'bad digest' > "$stage/SHA256SUMS.txt"
    if check_stage "$stage" >/dev/null 2>&1; then exit 1; fi
    (cd "$stage" && sha256sum *.apk > SHA256SUMS.txt)
    mv "$stage/PronCam-0.98-31306-SCAM.apk" "$fixture/real.apk"
    ln -s ../real.apk "$stage/PronCam-0.98-31306-SCAM.apk"
    if check_stage "$stage" >/dev/null 2>&1; then exit 1; fi
    cat > "$fixture/bin/gh" <<'MOCK'
#!/usr/bin/env bash
[[ "$*" == 'api repos/SOTTRME/Privss' ]] || exit 99
printf '{"id":1461683737,"private":true,"full_name":"SOTTRME/Privss"}\n'
MOCK
    chmod +x "$fixture/bin/gh"
    self=$(realpath "${BASH_SOURCE[0]}")
    export PATH="$fixture/bin:$PATH" RUNNER_TEMP="$fixture" GITHUB_WORKSPACE="$fixture"
    export GITHUB_REPOSITORY=SOTTRME/Xxdl GITHUB_REPOSITORY_ID=1461381914 GITHUB_REF=refs/heads/main
    export GITHUB_TRIGGERING_ACTOR=SOTTRME
    export GITHUB_EVENT_NAME=workflow_dispatch GITHUB_OUTPUT="$fixture/outputs" PRONCAM_SOURCE_TOKEN=fixture
    if GITHUB_ACTOR=untrusted bash "$self" resolve >/dev/null 2>&1; then exit 1; fi
    if GITHUB_ACTOR=SOTTRME GITHUB_TRIGGERING_ACTOR=untrusted bash "$self" resolve >/dev/null 2>&1; then exit 1; fi
    if GITHUB_ACTOR=SOTTRME PRONCAM_SOURCE_REF='main; touch injected' bash "$self" resolve >/dev/null 2>&1; then exit 1; fi
    [[ ! -e "$fixture/outputs" && ! -e "$fixture/injected" ]]
    private="$fixture/proncam-source"
    mkdir -p "$private/tools/ci"
    printf '#!/usr/bin/env bash\necho PRIVATE_SOURCE_CANARY\necho PRIVATE_SOURCE_CANARY >&2\nexit 17\n' > "$private/tools/ci/host-native-a.sh"
    git init --quiet "$private"
    git -C "$private" add .
    git -C "$private" -c user.name=Fixture -c user.email=fixture@local.invalid commit --quiet -m fixture
    sha=$(git -C "$private" rev-parse HEAD)
    if GITHUB_ACTOR=SOTTRME PRONCAM_SOURCE_SHA="$sha" PRONCAM_CHECK_LANE=native-a bash "$self" host > "$fixture/public.log" 2>&1; then exit 1; fi
    if grep -q PRIVATE_SOURCE_CANARY "$fixture/public.log"; then exit 1; fi
    grep -q PRIVATE_SOURCE_CANARY "$fixture/proncam-private-host.log"
    GITHUB_ACTOR=SOTTRME bash "$self" cleanup
    [[ ! -e "$private" && ! -e "$fixture/proncam-private-host.log" ]]
    echo 'PASS: publication/ref/context checks; failing private stdout/stderr stay out of public logs; cleanup'
    exit
fi

[[ ${GITHUB_REPOSITORY:-} == SOTTRME/Xxdl && ${GITHUB_REPOSITORY_ID:-} == 1461381914 &&
   ${GITHUB_ACTOR:-} == SOTTRME && ${GITHUB_TRIGGERING_ACTOR:-} == SOTTRME && ${GITHUB_REF:-} == refs/heads/main &&
   ${GITHUB_EVENT_NAME:-} == workflow_dispatch ]] || { echo 'Build context rejected'; exit 1; }
: "${RUNNER_TEMP:?}" "${GITHUB_WORKSPACE:?}"
source_dir="$RUNNER_TEMP/proncam-source"
key="$RUNNER_TEMP/proncam-release.jks"
askpass="$RUNNER_TEMP/proncam-askpass"
output="$GITHUB_WORKSPACE/public-out"
if [[ "$mode" == cleanup ]]; then
    rm -rf -- "$source_dir"
    rm -f -- "$key" "$askpass" "$RUNNER_TEMP"/proncam-private-*.log "$RUNNER_TEMP/proncam-metadata.json"
    exit
fi

# No private tool stdout, compiler diagnostics, test reports or mapping enter a public log.
exec 9>&1
exec >>"$RUNNER_TEMP/proncam-private-$mode.log" 2>&1
trap 'result=$?; rm -f -- "$askpass"; if (( result )); then printf "::error::PronCam stage failed; private diagnostics were not published.\n" >&9; fi' EXIT
private_repo() {
    : "${PRONCAM_SOURCE_TOKEN:?Missing read-only source token}"
    GH_TOKEN="$PRONCAM_SOURCE_TOKEN" gh api repos/SOTTRME/Privss > "$RUNNER_TEMP/proncam-metadata.json" 9>&-
    python3 - "$RUNNER_TEMP/proncam-metadata.json" 9>&- <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
if r.get('id') != 1461683737 or r.get('private') is not True or r.get('full_name') != 'SOTTRME/Privss':
    raise SystemExit('Private source identity differs')
PY
}

if [[ "$mode" == resolve ]]; then
    private_repo
    ref=${PRONCAM_SOURCE_REF:-}
    [[ -z "$ref" || "$ref" =~ ^[0-9a-f]{40}$ ]] || exit 2
    endpoint="repos/SOTTRME/Privss/git/commits/$ref"
    [[ -n "$ref" ]] || endpoint=repos/SOTTRME/Privss/git/ref/heads/main
    GH_TOKEN="$PRONCAM_SOURCE_TOKEN" gh api "$endpoint" > "$RUNNER_TEMP/proncam-metadata.json" 9>&-
    sha=$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r.get("object",r)["sha"])' "$RUNNER_TEMP/proncam-metadata.json")
    [[ "$sha" =~ ^[0-9a-f]{40}$ && ${GITHUB_RUN_NUMBER:-} =~ ^[1-9][0-9]{0,8}$ ]] || exit 2
    # Freeze this offset when publishing the new workflow: prepared migration build is 31305.
    version=$((31305 + GITHUB_RUN_NUMBER))
    (( version <= 2100000000 )) || exit 2
    printf 'sha=%s\nversion=%s\n' "$sha" "$version" >> "$GITHUB_OUTPUT"
    printf 'Selected source revision; versionCode %s.\n' "$version" >&9
    exit
fi

if [[ "$mode" == checkout ]]; then
    private_repo
    [[ ${PRONCAM_SOURCE_SHA:-} =~ ^[0-9a-f]{40}$ && ! -e "$source_dir" ]] || exit 2
    cat > "$askpass" <<'ASKPASS'
#!/usr/bin/env bash
case "$1" in *Username*) printf '%s\n' x-access-token ;; *Password*) printf '%s\n' "$PRONCAM_SOURCE_TOKEN" ;; *) exit 1 ;; esac
ASKPASS
    chmod 700 "$askpass"
    export GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0
    git init --quiet "$source_dir" 9>&-
    git -C "$source_dir" -c credential.helper= fetch --quiet --no-tags --depth=1 https://github.com/SOTTRME/Privss.git "$PRONCAM_SOURCE_SHA" 9>&-
    git -C "$source_dir" checkout --quiet --detach FETCH_HEAD 9>&-
    [[ $(git -C "$source_dir" rev-parse HEAD) == "$PRONCAM_SOURCE_SHA" ]] || exit 1
    printf 'Pinned private source fetched.\n' >&9
    exit
fi

if [[ "$mode" == stage || "$mode" == release ]]; then
    check_stage "$output"
    if [[ "$mode" == release ]]; then
        [[ ${SCAMERA_VERSION_CODE:-} =~ ^[1-9][0-9]{0,9}$ ]] || exit 2
        gh release create "build-$SCAMERA_VERSION_CODE" --repo SOTTRME/Xxdl --target "$GITHUB_SHA" \
            --title "PronCam $SCAMERA_VERSION_CODE" --notes 'Изменение названия и оптимизация приложения.' "$output"/*
        printf 'Checked APK published in Releases.\n' >&9
    fi
    exit
fi

[[ ${PRONCAM_SOURCE_SHA:-} =~ ^[0-9a-f]{40}$ && $(git -C "$source_dir" rev-parse HEAD) == "$PRONCAM_SOURCE_SHA" ]] || exit 2
cd "$source_dir"
export GITHUB_SHA="$PRONCAM_SOURCE_SHA"
# Private tools do not need public workflow file-command channels.
unset GITHUB_OUTPUT GITHUB_STEP_SUMMARY GITHUB_ENV GITHUB_PATH
if [[ "$mode" == host ]]; then
    case ${PRONCAM_CHECK_LANE:-} in shaders|native-a|native-b|native-c|strip-trailers|codecs) ;; *) exit 2 ;; esac
    bash "tools/ci/host-$PRONCAM_CHECK_LANE.sh" 9>&-
    printf 'Host checks passed.\n' >&9
    exit
fi

: "${SCAMERA_VERSION_CODE:?}" "${SCAMERA_SIGNING_KEYSTORE:?}" "${SCAMERA_KEYSTORE_PASSWORD:?}" "${ANDROID_HOME:?}"
[[ "$SCAMERA_VERSION_CODE" =~ ^[1-9][0-9]{0,9}$ && ! -e "$output" ]] || exit 2
export SCAMERA_VERSION_CODE
chmod +x gradlew
# Execute exactly the private workflow's existing build checks, without copying its log/artifact upload steps.
python3 - 9>&- <<'PY'
from pathlib import Path
import subprocess
lines = Path('.github/workflows/build-test-apk.yml').read_text().splitlines()
names = ['Check fast worker launcher and GCam diagnostic decoder', 'Check ZSL gyro exposure windows',
         'Check settings precision and algorithm availability', 'Check UI language (English defaults, Russian in values-ru, Java text through Lang)',
         'Build debug APK and run unit tests', 'Verify native packaging and settings']
for name in names:
    start = lines.index('      - name: ' + name) + 1
    end = next((i for i in range(start, len(lines)) if lines[i].startswith('      - ') or lines[i].startswith('  host:')), len(lines))
    block = lines[start:end]
    run = next(i for i, line in enumerate(block) if line.startswith('        run:'))
    command = block[run].split('run:', 1)[1].strip()
    if command == '|':
        body = []
        for line in block[run + 1:]:
            if line.strip() and not line.startswith('          '): break
            body.append(line[10:] if line.startswith('          ') else '')
        command = '\n'.join(body)
    if '${{' in command: raise SystemExit('Unexpected workflow expression')
    subprocess.run(['bash', '-euo', 'pipefail', '-c', command], check=True)
PY
aapt="$ANDROID_HOME/build-tools/36.0.0/aapt2"
templates=(app/build/outputs/apk/debug/*.apk)
[[ ${#templates[@]} == 1 && -f ${templates[0]} ]] || exit 1
badging=$("$aapt" dump badging "${templates[0]}" 9>&-)
[[ "$badging" != *application-debuggable* ]] || exit 1
name=$(printf '%s\n' "$badging" | sed -n "s/^package:.*versionName='\([^']*\)'.*/\1/p")
[[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,50}$ ]] || exit 1
printf '%s' "$SCAMERA_SIGNING_KEYSTORE" | base64 -d > "$key"
export SCAMERA_KEYSTORE="$key" SCAMERA_KEY_ALIAS=scamera
mkdir "$output"
python3 tools/package_scam_neural.py --template "${templates[0]}" \
    --apksigner "$ANDROID_HOME/build-tools/36.0.0/lib/apksigner.jar" \
    --output "$output/PronCam-$name-$SCAMERA_VERSION_CODE-SCAM.apk" 9>&-
final_badging=$("$aapt" dump badging "$output"/*.apk 9>&-)
[[ "$final_badging" != *application-debuggable* ]] || exit 1
final_code=$(printf '%s\n' "$final_badging" | sed -n "s/^package:.*versionCode='\([^']*\)'.*/\1/p")
[[ "$final_code" == "$SCAMERA_VERSION_CODE" ]] || exit 1
"$ANDROID_HOME/build-tools/36.0.0/apksigner" verify --print-certs "$output"/*.apk 9>&- | python3 -c '
import re,sys
signers = re.findall(r"^Signer #[0-9]+ certificate SHA-256 digest: (.+)$", sys.stdin.read(), re.M)
if signers != ["7b12875e8172311fecf217e0aa4b4d86d090ae01c50964047d2bae104d91e9d5"]:
    raise SystemExit("APK signer differs")
' 9>&-
(cd "$output" && sha256sum *.apk > SHA256SUMS.txt)
check_stage "$output"
cat "$output/SHA256SUMS.txt" >&9
printf 'PronCam build and signature checks passed.\n' >&9
