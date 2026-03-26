#!/bin/bash

branch=$(git branch --show-current)
branch_id=$(echo ${branch:0:1} | tr '[:lower:]' '[:upper:]')
version=$(date -u +%Y.%m.%d)-$branch_id$(date -u +%H%M)

case ${branch} in
  main)
    icon="🚀"
    ;;
  stage)
    icon="📸"
    ;;
  *)
    icon="🚩"
    ;;
esac

echo "Bumping $branch version to '$version'"
echo $version > version
git add .
git commit -m "ci: ${icon} ${version}"
git tag -a "${version}" -m "${version}"
