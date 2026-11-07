#!/usr/bin/env bash
# Compare the hfsprogs version pinned in the Dockerfile with what Ubuntu
# publishes (Launchpad API), and check that the pinned source files can still
# be downloaded. grype and Snyk can't see hfsprogs (it's built from source),
# so this is how fixes from Ubuntu get noticed.
#
#   .github/scripts/check-hfsprogs.sh [Dockerfile]
#
# Needs curl, jq and dpkg (for Debian version comparison). Writes a Markdown
# report to $REPORT (default hfsprogs-report.md) and, when $GITHUB_OUTPUT is
# set, the outputs pinned, latest, series and status:
#   current      the pin is the newest version published in its Ubuntu series
#   update       a newer version is published in that series (e.g. a security fix)
#   unavailable  the pinned version is no longer published, or its files can't be fetched
set -euo pipefail

dockerfile=${1:-Dockerfile}
report=${REPORT:-hfsprogs-report.md}

arg() { sed -n "s/^ARG $1=//p" "$dockerfile" | head -1; }
version=$(arg HFSPROGS_VERSION)
revision=$(arg HFSPROGS_REVISION)
mirror=$(arg HFSPROGS_MIRROR)
[ -n "$version" ] && [ -n "$revision" ] && [ -n "$mirror" ] ||
  { echo "could not read the HFSPROGS_* ARGs from $dockerfile" >&2; exit 2; }
pinned="${version}-${revision}"
readme="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-reuc/wolfi-hfsplus}/blob/main/README.md#updating-hfsprogs"

# All currently published hfsprogs sources: "<version>\t<series>\t<pocket>"
url='https://api.launchpad.net/devel/ubuntu/+archive/primary?ws.op=getPublishedSources&source_name=hfsprogs&exact_match=true&status=Published'
rows=""
while [ -n "$url" ]; do
  page=$(curl -fsSL --retry 3 "$url")
  rows+=$(jq -r '.entries[] | [.source_package_version, (.distro_series_link | split("/") | last), .pocket] | @tsv' <<<"$page")$'\n'
  url=$(jq -r '.next_collection_link // empty' <<<"$page")
done
rows=$(sed '/^$/d' <<<"$rows")

max_version() {
  local max="" v
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    if [ -z "$max" ] || dpkg --compare-versions "$v" gt "$max"; then max=$v; fi
  done
  echo "$max"
}

# The series that publish the pinned version, and the newest version in them.
series=$(awk -F'\t' -v p="$pinned" '$1 == p { print $2 }' <<<"$rows" | sort -u | paste -sd, -)
if [ -n "$series" ]; then
  latest=$(awk -F'\t' -v s=",$series," 'index(s, "," $2 ",") { print $1 }' <<<"$rows" | max_version)
else
  latest=""
fi
newest_any=$(cut -f1 <<<"$rows" | max_version)

# Are the pinned source files still on the mirror?
missing=()
for f in "hfsprogs_${version}.orig.tar.gz" "hfsprogs_${pinned}.debian.tar.xz"; do
  curl -fsSIL --retry 3 -o /dev/null "${mirror}/${f}" || missing+=("${mirror}/${f}")
done

if [ -z "$series" ] || [ ${#missing[@]} -gt 0 ]; then
  status=unavailable
elif dpkg --compare-versions "$latest" gt "$pinned"; then
  status=update
else
  status=current
fi

{
  echo "### hfsprogs: ${status}"
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| Pinned in \`${dockerfile}\` | \`${pinned}\` |"
  echo "| Ubuntu series publishing it | ${series:-*none*} |"
  echo "| Newest in those series | \`${latest:-n/a}\` |"
  echo "| Newest in any series | \`${newest_any}\` |"
  if [ ${#missing[@]} -gt 0 ]; then
    echo
    echo "These pinned source files could not be downloaded:"
    printf -- '- %s\n' "${missing[@]}"
  fi
  case $status in
    update)
      echo
      echo "A newer hfsprogs is published in **${series}**. Check the Ubuntu changelog and"
      echo "[security notices](https://ubuntu.com/security/cves?package=hfsprogs), then follow"
      echo "[Updating hfsprogs](${readme}): set \`HFSPROGS_REVISION\`"
      echo "and both SHA-256 hashes from \`${mirror}/hfsprogs_${latest#*:}.dsc\`." ;;
    unavailable)
      echo
      echo "Builds will fail once the files are gone from the archive. Move the pin to a version"
      echo "that is still published (see the table below), following"
      echo "[Updating hfsprogs](${readme})." ;;
  esac
  echo
  echo "<details><summary>All published hfsprogs sources</summary>"
  echo
  echo "| Version | Series | Pocket |"
  echo "|---|---|---|"
  awk -F'\t' '{ printf "| `%s` | %s | %s |\n", $1, $2, $3 }' <<<"$rows"
  echo
  echo "</details>"
} > "$report"

cat "$report"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "pinned=$pinned"
    echo "latest=$latest"
    echo "series=$series"
    echo "status=$status"
  } >> "$GITHUB_OUTPUT"
fi
