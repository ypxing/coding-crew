# Shared bats helper: the platform list, read from orchestrator/platforms.json — the file
# install.sh reads — so a suite that loops over platforms covers a new one without an edit.

PLATFORMS_JSON="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/orchestrator/platforms.json"

PLATFORMS=()
while IFS= read -r _p; do
  _p="${_p%$'\r'}"
  [ -n "$_p" ] && PLATFORMS+=("$_p")
done < <(jq -r 'keys_unsorted[]' "$PLATFORMS_JSON")
unset _p

# platform_field <platform> <field> — one platforms.json value (projectSkills, userSkills, …).
platform_field() {
  jq -r --arg p "$1" --arg f "$2" '.[$p][$f]' "$PLATFORMS_JSON" | tr -d '\r'
}
