# Development

## Releasing

1. Run the [prepare-release](https://github.com/controlplaneio-fluxcd/terraform-kubernetes-flux-operator-bootstrap/actions/workflows/prepare-release.yaml) workflow from the GitHub Actions UI with the desired version (e.g. `0.1.0` or `v0.1.0`). This opens a PR that bumps `module_version` in `versions.tf` and the version in `README.md`.

2. Run the [e2e](https://github.com/controlplaneio-fluxcd/terraform-kubernetes-flux-operator-bootstrap/actions/workflows/e2e.yaml) workflow against the PR branch to validate. The e2e workflow will not be triggered automatically in this PR because the PR is created by a workflow, so you need to trigger it manually from the GitHub Actions UI.

3. Merge the PR.

4. Tag the merge commit locally and push:

   ```bash
   git pull origin main
   git tag -s -m v0.1.0 v0.1.0
   git push origin v0.1.0
   ```

5. The [release](https://github.com/controlplaneio-fluxcd/terraform-kubernetes-flux-operator-bootstrap/actions/workflows/release.yaml) workflow triggers on the tag push and builds the container image, signs it, publishes the GitHub Release, and generates SLSA provenance.
