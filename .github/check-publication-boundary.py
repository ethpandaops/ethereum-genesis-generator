#!/usr/bin/env python3
"""Regression checks for PR validation and Docker publication separation."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
BUILD_WORKFLOW = ROOT / ".github/workflows/build-push.yaml"
VALIDATE_PR_WORKFLOW = ROOT / ".github/workflows/validate-pr.yaml"
PUBLISH_PR_WORKFLOW = ROOT / ".github/workflows/publish-pr.yaml"


def job(workflow: str, name: str) -> str:
    match = re.search(
        rf"(?ms)^  {re.escape(name)}:\n(.*?)(?=^  [a-zA-Z0-9_-]+:\n|\Z)",
        workflow,
    )
    assert match, f"missing {name!r} job"
    return match.group(0)


def assert_pinned_actions(workflow: str) -> None:
    for action in re.findall(r"(?m)^\s*-?\s*uses:\s*([^\s#]+)", workflow):
        assert not action.startswith("./"), f"local action is not allowed: {action}"
        assert re.search(r"@[0-9a-f]{40}$", action), f"action is not SHA-pinned: {action}"


def assert_read_only_github_permissions(workflow: str) -> None:
    assert not re.search(r"(?m)^\s+[a-z-]+:\s*write\s*$", workflow), (
        "workflow must not grant write access to the GitHub token"
    )


def assert_fixed_runners(workflow: str) -> None:
    assert "runners.yaml" not in workflow
    assert "platforms.yaml" not in workflow
    assert "fromJSON(" not in workflow
    for runs_on in re.findall(r"(?m)^\s+runs-on:\s*(.+?)\s*$", workflow):
        assert runs_on in {
            "ubuntu-latest",
            "ubuntu-24.04-arm",
            "${{ matrix.runner }}",
        }, f"unexpected runs-on value: {runs_on}"
    for runner in re.findall(r"(?m)^\s+runner:\s*(\S+)\s*$", workflow):
        assert runner in {"ubuntu-latest", "ubuntu-24.04-arm"}, (
            f"unexpected matrix runner: {runner}"
        )


def check_publish_job(workflow: str, *, cross_run: bool) -> None:
    publish = job(workflow, "publish")
    before_publish = workflow[: workflow.index(publish)]

    assert "secrets." not in before_publish, "secrets may only be referenced by publish"
    assert "actions/checkout" not in publish, "publish must not check out source code"
    assert "./" not in publish, "publish must not invoke repository-local code"
    assert "docker run" not in publish, "publish must not run a built image"
    assert "sha256sum -c" in publish, "publish must verify build artifacts"
    assert "name: image-linux-amd64" in publish
    assert "name: image-linux-arm64" in publish
    assert "pattern:" not in publish, "publish must select exact artifact names"
    assert "merge-multiple:" not in publish, "publish must select exact artifacts"
    if cross_run:
        assert publish.count("run-id: ${{ github.event.workflow_run.id }}") == 2, (
            "PR artifacts must come from the completed validation run"
        )
    assert 'local target="$IMMUTABLE_TAG-$slug"' in publish, (
        "architecture images must use the commit tag"
    )
    assert publish.count('--tag "$IMMUTABLE_TAG"') == 2, (
        "the manifest must retain the commit tag"
    )
    assert publish.count('--tag "$TARGET_TAG"') == 2, (
        "the manifest must retain the requested publication tag"
    )
    assert publish.count("@$amd64_digest") == 2, (
        "amd64 manifest input must use the registry digest"
    )
    assert publish.count("@$arm64_digest") == 2, (
        "manifest promotion must use registry digests"
    )


def main() -> None:
    build = BUILD_WORKFLOW.read_text()
    validate_pr = VALIDATE_PR_WORKFLOW.read_text()
    publish_pr = PUBLISH_PR_WORKFLOW.read_text()
    workflows = build + validate_pr + publish_pr

    assert "pull_request_target:" not in workflows

    assert "  pull_request:" in validate_pr
    assert "workflow_run:" not in validate_pr
    assert "secrets." not in validate_pr
    assert "permissions:\n  contents: read" in validate_pr
    assert "repository: ${{ github.event.pull_request.head.repo.full_name }}" in validate_pr
    assert "ref: ${{ github.event.pull_request.head.sha }}" in validate_pr
    assert "ethereum-genesis-generator:${{ github.event.pull_request.head.sha }}" in validate_pr
    assert validate_pr.count("persist-credentials: false") == 2
    assert "push: false" in validate_pr
    assert "uses: actions/upload-artifact@" in validate_pr
    assert "name: image-${{ matrix.slug }}" in validate_pr

    assert "  pull_request:" not in build
    assert "workflow_run:" not in build
    assert "  workflow_dispatch:" in build
    assert '"$EVENT_NAME" == push || "$EVENT_NAME" == workflow_dispatch' in build
    assert "persist-credentials: false" in build

    assert "  workflow_run:" in publish_pr
    assert "workflows: ['Validate PR image']" in publish_pr
    assert "types: [completed]" in publish_pr
    assert "github.event.workflow_run.event == 'pull_request'" in publish_pr
    assert "github.event.workflow_run.conclusion == 'success'" in publish_pr
    assert "actions/checkout" not in publish_pr
    assert "pull.head.sha === run.head_sha" in publish_pr
    assert "pull.head.repo?.full_name === run.head_repository.full_name" in publish_pr
    assert "review.commit_id !== run.head_sha" in publish_pr
    assert "label.name === 'build-docker-image'" in publish_pr
    assert "['admin', 'maintain', 'write']" in publish_pr
    assert "core.setOutput('source_sha', run.head_sha)" in publish_pr
    publish_pr_job = job(publish_pr, "publish")
    assert "needs: authorize" in publish_pr_job
    assert "if: needs.authorize.outputs.source_sha != ''" in publish_pr_job

    assert_pinned_actions(build)
    assert_pinned_actions(validate_pr)
    assert_pinned_actions(publish_pr)
    assert_read_only_github_permissions(build)
    assert_read_only_github_permissions(validate_pr)
    assert_read_only_github_permissions(publish_pr)
    assert_fixed_runners(build)
    assert_fixed_runners(validate_pr)
    assert_fixed_runners(publish_pr)
    check_publish_job(build, cross_run=False)
    check_publish_job(publish_pr, cross_run=True)

    print("workflow publication checks passed")


if __name__ == "__main__":
    main()
