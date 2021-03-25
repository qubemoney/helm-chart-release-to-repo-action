#!/usr/bin/env bash
# copyright 2020 Stefan Prodan. All rights reserved.
# changed 2021 paschdan
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o pipefail

GITHUB_TOKEN=$1
CHARTS_DIR=$2
CHARTS_URL=$3
OWNER=$4
REPOSITORY=$5
BRANCH=$6
TARGET_DIR=$7
HELM_VERSION=$8
LINTING=$9
COMMIT_USERNAME=${10}
COMMIT_EMAIL=${11}
TAGGING=${12}

CHARTS_TMP_DIR=$(mktemp -d)
REPO_ROOT=$(git rev-parse --show-toplevel)
REPO_URL=""
TAGS=()
GH_HOST=$(cut -d '/' -f 3 <<<"$GITHUB_SERVER_URL")

main() {
  if [[ -z "$HELM_VERSION" ]]; then
    HELM_VERSION="3.5.3"
  fi

  if [[ -z "$CHARTS_DIR" ]]; then
    CHARTS_DIR="charts"
  fi

  if [[ -z "$OWNER" ]]; then
    OWNER=$(cut -d '/' -f 1 <<<"$GITHUB_REPOSITORY")
  fi

  if [[ -z "$REPOSITORY" ]]; then
    REPOSITORY=$(cut -d '/' -f 2 <<<"$GITHUB_REPOSITORY")
  fi

  if [[ -z "$BRANCH" ]]; then
    BRANCH="gh-pages"
  fi

  if [[ -z "$TARGET_DIR" ]]; then
    TARGET_DIR="."
  fi

  if [[ -z "$CHARTS_URL" ]]; then
    CHARTS_URL="https://${OWNER}.github.io/${REPOSITORY}"
  fi

  if [[ "$TARGET_DIR" != "." && "$TARGET_DIR" != "docs" ]]; then
    CHARTS_URL="${CHARTS_URL}/${TARGET_DIR}"
  fi

  if [[ -z "$REPO_URL" ]]; then
    REPO_URL="https://x-access-token:${GITHUB_TOKEN}@${GH_HOST}/${OWNER}/${REPOSITORY}"
  fi

  if [[ -z "$COMMIT_USERNAME" ]]; then
    COMMIT_USERNAME="${GITHUB_ACTOR}"
  fi

  if [[ -z "$COMMIT_EMAIL" ]]; then
    COMMIT_EMAIL="${GITHUB_ACTOR}@users.noreply.${GH_HOST}"
  fi

  download
  package
  upload
}

package() {
  pushd "$REPO_ROOT" >/dev/null

  echo 'Looking up latest tag...'
  local latest_tag
  latest_tag=$(lookup_latest_tag)

  echo "Discovering changed charts since '$latest_tag'..."
  local changed_charts=()
  readarray -t changed_charts <<<"$(lookup_changed_charts "$latest_tag")"

  if [[ -n "${changed_charts[*]}" ]]; then

    for chart in "${changed_charts[@]}"; do
      if [[ -d "$chart" ]]; then
        local chart_name=${chart#"$CHARTS_DIR/"}
        local chart_version=$(helm show chart $chart | grep "^version" | awk '{print $2}')
        TAGS+=("${chart_name}-${chart_version}")
        package_chart "${chart}"
      else
        echo "Chart '$chart' no longer exists in repo. Skipping it..."
      fi
    done
  else
    echo "Nothing to do. No chart changes detected"
    exit 0
  fi
}

package_chart() {
  local chart="$1"

  echo "Updating dependencies..."
  helm dependencies update "${chart}"

  if [[ "$LINTING" != "off" ]]; then
    helm lint "${chart}"
  fi
  echo "Packaging chart '$chart'..."
  helm package "${chart}" --destination "${CHARTS_TMP_DIR}"
}

lookup_latest_tag() {
  git fetch --tags >/dev/null 2>&1

  if ! git describe --tags --abbrev=0 2>/dev/null; then
    git rev-list --max-parents=0 --first-parent HEAD
  fi
}

filter_charts() {
  while read -r chart; do
    [[ ! -d "$chart" ]] && continue
    local file="$chart/Chart.yaml"
    if [[ -f "$file" ]]; then
      echo "$chart"
    else
      echo "WARNING: $file is missing, assuming that '$chart' is not a Helm chart. Skipping." 1>&2
    fi
  done
}

lookup_changed_charts() {
  local COMMIT="$1"

  local CHANGED_CHARTS
  CHANGED_CHARTS=$(git diff --find-renames --name-only "$COMMIT" -- "$CHARTS_DIR")

  local DEPTH=$(($(tr "/" "\n" <<<"$CHARTS_DIR" | wc -l) + 1))
  local FIELDS="1-${DEPTH}"

  cut -d '/' -f "$FIELDS" <<<"$CHANGED_CHARTS" | uniq | filter_charts
}

download() {
  local tmpDir=$(mktemp -d)

  pushd $tmpDir >&/dev/null

  curl -sSL https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz | tar xz
  cp linux-amd64/helm /usr/local/bin/helm

  popd >&/dev/null
  rm -rf $tmpDir
}

upload() {
  tmpDir=$(mktemp -d)
  pushd $tmpDir >&/dev/null

  git clone ${REPO_URL}
  cd ${REPOSITORY}
  git config user.name "${COMMIT_USERNAME}"
  git config user.email "${COMMIT_EMAIL}"
  git remote set-url origin ${REPO_URL}
  git checkout ${BRANCH}

  charts=$(cd "${CHARTS_TMP_DIR}" && ls *.tgz | xargs)

  mkdir -p ${TARGET_DIR}
  mv -f ${CHARTS_TMP_DIR}/*.tgz ${TARGET_DIR}

  if [[ -f "${TARGET_DIR}/index.yaml" ]]; then
    echo "Found index, merging changes"
    helm repo index ${TARGET_DIR} --url ${CHARTS_URL} --merge "${TARGET_DIR}/index.yaml"
  else
    echo "No index found, generating a new one"
    helm repo index ${TARGET_DIR} --url ${CHARTS_URL}
  fi

  git add ${TARGET_DIR}
  git commit -m "Publish $charts"
  git push origin ${BRANCH}

  popd >&/dev/null
  rm -rf $tmpDir

  # add tags
  if [[ "$TAGGING" != "off" ]]; then
    echo "Adding tags ${TAGS[*]}..."
    for tag in "${TAGS[@]}"; do
      git tag ${tag}
    done
    git push origin --tags
  fi
}

main
