#!/bin/sh
set -e

function main() {
  echo "" # see https://github.com/actions/toolkit/issues/168

  sanitize "${INPUT_NAME}" "name"
  sanitize "${INPUT_USERNAME}" "username"
  sanitize "${INPUT_PASSWORD}" "password"

  REGISTRY_NO_PROTOCOL=$(echo "${INPUT_REGISTRY}" | sed -e 's/^https:\/\///g')
  if uses "${INPUT_REGISTRY}" && ! isPartOfTheName "${REGISTRY_NO_PROTOCOL}"; then
    INPUT_NAME="${REGISTRY_NO_PROTOCOL}/${INPUT_NAME}"
  fi

  if uses "${INPUT_TAGS}"; then
    TAGS=$(echo "${INPUT_TAGS}" | sed "s/,/ /g")
  else
    translateDockerTag
  fi

  if uses "${INPUT_WORKDIR}"; then
    changeWorkingDirectory
  fi

  echo ${INPUT_PASSWORD} | docker login -u ${INPUT_USERNAME} --password-stdin ${INPUT_REGISTRY}

  FIRST_TAG=$(echo $TAGS | cut -d ' ' -f1)
  DOCKERNAME="${INPUT_NAME}:${FIRST_TAG}"
  BUILDPARAMS=""
  CONTEXT="."

  if uses "${INPUT_DOCKERFILE}"; then
    useCustomDockerfile
  fi
  if uses "${INPUT_BUILDARGS}"; then
    addBuildArgs
  fi
  if uses "${INPUT_CONTEXT}"; then
    CONTEXT="${INPUT_CONTEXT}"
  fi
  if usesBoolean "${INPUT_CACHE}"; then
    useBuildCache
  fi
  if usesBoolean "${INPUT_SNAPSHOT}"; then
    useSnapshot
  fi

  push

  echo "::set-output name=tag::${FIRST_TAG}"
  DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' ${DOCKERNAME})
  echo "::set-output name=digest::${DIGEST}"

  docker logout
}

function sanitize() {
  if [ -z "${1}" ]; then
    >&2 echo "Unable to find the ${2}. Did you set with.${2}?"
    exit 1
  fi
}

function isPartOfTheName() {
  [ $(echo "${INPUT_NAME}" | sed -e "s/${1}//g") != "${INPUT_NAME}" ]
}

function translateDockerTag() {
  local BRANCH=$(echo ${GITHUB_REF} | sed -e "s/refs\/heads\///g" | sed -e "s/\//-/g")
  if hasCustomTag; then
    TAGS=$(echo ${INPUT_NAME} | cut -d':' -f2)
    INPUT_NAME=$(echo ${INPUT_NAME} | cut -d':' -f1)
  elif isOnMaster; then
    TAGS="latest"
  elif isGitTag && usesBoolean "${INPUT_TAG_NAMES}"; then
    TAGS=$(echo ${GITHUB_REF} | sed -e "s/refs\/tags\///g")
  elif isGitTag; then
    TAGS="latest"
  elif isPullRequest; then
    TAGS="${GITHUB_SHA}"
  else
    TAGS="${BRANCH}"
  fi;
}

function hasCustomTag() {
  [ $(echo "${INPUT_NAME}" | sed -e "s/://g") != "${INPUT_NAME}" ]
}

function isOnMaster() {
  [ "${BRANCH}" = "master" ]
}

function isGitTag() {
  [ $(echo "${GITHUB_REF}" | sed -e "s/refs\/tags\///g") != "${GITHUB_REF}" ]
}

function isPullRequest() {
  [ $(echo "${GITHUB_REF}" | sed -e "s/refs\/pull\///g") != "${GITHUB_REF}" ]
}

function changeWorkingDirectory() {
  cd "${INPUT_WORKDIR}"
}

function useCustomDockerfile() {
  BUILDPARAMS="${BUILDPARAMS} -f ${INPUT_DOCKERFILE}"
}

function addBuildArgs() {
  for ARG in $(echo "${INPUT_BUILDARGS}" | tr ',' '\n'); do
    BUILDPARAMS="${BUILDPARAMS} --build-arg ${ARG}"
    echo "::add-mask::${ARG}"
  done
}

function useBuildCache() {
  if docker pull ${DOCKERNAME} 2>/dev/null; then
    BUILDPARAMS="$BUILDPARAMS --cache-from ${DOCKERNAME}"
  fi
}

function uses() {
  [ ! -z "${1}" ]
}

function usesBoolean() {
  [ ! -z "${1}" ] && [ "${1}" = "true" ]
}

function useSnapshot() {
  local BRANCH=$(echo ${GITHUB_REF} | sed -e "s/refs\/heads\///g" | sed -e "s/\//-/g")
  local LAST_TAG=$(git describe --tags $(git rev-list --tags --max-count=1))
  local COMMITS_AHEAD=$(git rev-list ${LAST_TAG}.. --count)
  local SHORT_SHA=$(echo "${GITHUB_SHA}" | cut -c1-6)

  local IMAGE_TAG1="${LAST_TAG}"
  local IMAGE_TAG2="${LAST_TAG}-${BRANCH}.${COMMITS_AHEAD}-${SHORT_SHA}"
  if [[ ${COMMITS_AHEAD} = "0" ]]; then
    TAGS="${TAGS} ${IMAGE_TAG1}"
  else
    TAGS="${TAGS} ${IMAGE_TAG2}"
  fi
  echo ::set-output name=snapshot-tag::"${SNAPSHOT_TAG}"
}

function push() {
  local BUILD_TAGS=""
  for TAG in ${TAGS}
  do
    BUILD_TAGS="${BUILD_TAGS}-t ${INPUT_NAME}:${TAG} "
  done
  docker build ${INPUT_BUILDOPTIONS} ${BUILDPARAMS} ${BUILD_TAGS} ${CONTEXT}

  for TAG in ${TAGS}
  do
    docker push "${INPUT_NAME}:${TAG}"
  done
}

main
