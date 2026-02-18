#!/usr/bin/env bats
# Tests for resolve_urls()

setup() {
  load '../test_helper/common_setup'
}

@test "repo-scoped API URL" {
  GH_ORG="myorg"
  GH_REPO="myrepo"

  resolve_urls

  assert_equal "$API_URL" "https://api.github.com/repos/myorg/myrepo/actions/runners/registration-token"
}

@test "org-scoped API URL" {
  GH_ORG="myorg"
  GH_REPO=""

  resolve_urls

  assert_equal "$API_URL" "https://api.github.com/orgs/myorg/actions/runners/registration-token"
}

@test "repo-scoped SCOPE string" {
  GH_ORG="acme"
  GH_REPO="api"

  resolve_urls

  assert_equal "$SCOPE" "repo: acme/api"
}

@test "org-scoped SCOPE string" {
  GH_ORG="acme"
  GH_REPO=""

  resolve_urls

  assert_equal "$SCOPE" "org: acme"
}

@test "CONFIG_URL for repo scope" {
  GH_ORG="myorg"
  GH_REPO="myrepo"

  resolve_urls

  assert_equal "$CONFIG_URL" "https://github.com/myorg/myrepo"
}

@test "CONFIG_URL for org scope" {
  GH_ORG="myorg"
  GH_REPO=""

  resolve_urls

  assert_equal "$CONFIG_URL" "https://github.com/myorg"
}
