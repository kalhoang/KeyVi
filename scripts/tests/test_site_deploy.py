# SPDX-License-Identifier: LicenseRef-App-Pending
"""Self-tests of the website deployment on the Kalera Docker Swarm (ADR 0602, docs/runbooks/site-deploy.md): the
Dockerfile, the Portainer stack, the prod-only image workflow, the stack variables script and the release-file fetch.
The header equivalence of the container itself is tested by `node deploy/site/test.mjs`.
Run: python3 -I scripts/tests/test_site_deploy.py"""
from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True  # keep scripts/tests free of __pycache__
sys.path.insert(0, str(Path(__file__).resolve().parent))

from support import REPO, run  # noqa: E402

DEPLOY = REPO / "deploy" / "site"
WORKFLOWS = REPO / ".github" / "workflows"
PINNED_ACTION = re.compile(r"uses: [\w.-]+/[\w./-]+@[0-9a-f]{40} # v\d")


def brand() -> dict[str, str]:
    values = {}
    for line in (REPO / "scripts" / "brand.env").read_text(encoding="utf-8").splitlines():
        match = re.match(r'^(APP_[A-Z_]+)="(.*)"$', line)
        if match:
            values[match.group(1)] = match.group(2)
    return values


class DockerfileTests(unittest.TestCase):
    TEXT = (DEPLOY / "Dockerfile").read_text(encoding="utf-8")

    def stages(self) -> list[str]:
        return re.split(r"^FROM ", self.TEXT, flags=re.M)[1:]

    def test_base_images_are_pinned_by_tag_and_digest(self):
        froms = re.findall(r"^FROM (?:--platform=\S+ )?(\S+)", self.TEXT, re.M)
        self.assertEqual(len(froms), 2)
        for image in froms:
            with self.subTest(image=image):
                self.assertRegex(image, r"^[a-z0-9./-]+:[0-9][\w.-]*@sha256:[0-9a-f]{64}$")
        self.assertTrue(froms[0].startswith("node:22."), "the site generator needs Node 22 (ADR 0601)")
        self.assertTrue(froms[1].startswith("nginxinc/nginx-unprivileged:"), "nginx runs as an unprivileged user")

    def test_the_build_stage_runs_the_image_build_script_on_the_build_platform(self):
        build, final = self.stages()
        self.assertTrue(build.startswith("--platform=$BUILDPLATFORM "), "no emulation for a cross-platform build")
        self.assertIn("ARG SITE_STRICT=true", build)
        self.assertIn("ARG SITE_NOINDEX=auto", build)
        self.assertIn('RUN node deploy/site/build.mjs --out /out --strict "$SITE_STRICT" --noindex "$SITE_NOINDEX" '
                      "--downloads deploy/site/downloads", build)
        self.assertNotRegex(final, r"(?m)^RUN ", "the nginx stage only copies, so it needs no emulation")

    def test_the_nginx_stage_serves_the_generated_configuration_and_checks_its_health(self):
        final = self.stages()[1]
        self.assertIn("COPY deploy/site/nginx.conf /etc/nginx/nginx.conf", final)
        self.assertIn("COPY --from=build /out/nginx/ /etc/nginx/site/", final)
        self.assertIn("COPY --from=build /out/html/ /srv/site/", final)
        self.assertIn("EXPOSE 8080", final)
        self.assertRegex(final, r"HEALTHCHECK [^\n]*\\\n\s+CMD wget -q -O /dev/null http://127\.0\.0\.1:8080/healthz")

    def test_the_build_context_holds_only_the_site_inputs(self):
        ignore = (DEPLOY / "Dockerfile.dockerignore").read_text(encoding="utf-8").splitlines()
        rules = [line for line in ignore if line and not line.startswith("#")]
        self.assertEqual(rules[0], "*", "deny everything first")
        for kept in ("!scripts/brand.env", "!compat/matrix.json", "!CHANGELOG.md", "!site/", "!deploy/site/"):
            self.assertIn(kept, rules)
        self.assertIn("site/dist/", rules)
        kept = [rule[1:] for rule in rules if rule.startswith("!")]
        for source in re.findall(r"^COPY (?!--from)(\S+)", self.TEXT, re.M):
            prefix = source.split("*", 1)[0]
            with self.subTest(copy=source):
                self.assertTrue(any(source.startswith(rule) or rule.startswith(prefix) for rule in kept),
                                f"{source} is outside the build context")


class StackTests(unittest.TestCase):
    TEXT = (DEPLOY / "stack.yml").read_text(encoding="utf-8")

    def labels(self) -> list[str]:
        return re.findall(r"^\s+- (traefik\.[^\n]+)$", self.TEXT, re.M)

    def test_two_replicas_on_traefik_public_with_a_healthcheck_and_rolling_updates(self):
        self.assertRegex(self.TEXT, r"\n      replicas: 2\n")
        self.assertRegex(self.TEXT, r"networks:\n  traefik_public:\n    external: true\n    name: traefik_public")
        self.assertIn('test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/healthz"]', self.TEXT)
        self.assertRegex(self.TEXT, r"update_config:\n(?:        .*\n)*        order: start-first")
        self.assertIn("failure_action: rollback", self.TEXT)
        self.assertIn("read_only: true", self.TEXT)

    def test_image_and_names_come_from_variables_never_from_brand_literals(self):
        self.assertIn("image: ghcr.io/${IMAGE_OWNER:?", self.TEXT)
        self.assertIn("/${IMAGE_NAME:?", self.TEXT)
        self.assertIn(":${IMAGE_TAG:-prod}", self.TEXT)
        values = brand()
        for key in ("APP_SITE_HOST", "APP_SLUG", "APP_DISPLAY_NAME"):
            with self.subTest(brand=key):
                self.assertNotRegex(self.TEXT, rf"(?<![A-Za-z0-9_]){re.escape(values[key])}(?![A-Za-z0-9_])")

    def test_traefik_labels_follow_the_kalera_stacks(self):
        labels = self.labels()
        router = "traefik.http.routers.${SITE_SLUG}-site"
        expected = [
            "traefik.enable=true",
            "traefik.swarm.network=traefik_public",
            "traefik.docker.network=traefik_public",
            f"{router}.entrypoints=websecure",
            f"{router}.tls=true",
            f"{router}.tls.certresolver=${{TRAEFIK_CERT_RESOLVER:-cloudflare}}",
            "traefik.http.services.${SITE_SLUG}-site.loadbalancer.server.port=8080",
            "traefik.http.routers.${SITE_SLUG}-site-web.entrypoints=web",
            "traefik.http.middlewares.${SITE_SLUG}-site-https.redirectscheme.scheme=https",
        ]
        for label in expected:
            with self.subTest(label=label):
                self.assertIn(label, labels)
        self.assertIn("traefik.http.routers.${SITE_SLUG:?set SITE_SLUG (deploy/site/stack-env.sh)}-site.rule="
                      "Host(`${SITE_HOST:?set SITE_HOST (deploy/site/stack-env.sh)}`)", labels)
        self.assertIn("VERIFY", self.TEXT.split("services:", 1)[0], "the unconfirmed resolver name is marked")


class SiteImageWorkflowTests(unittest.TestCase):
    TEXT = (WORKFLOWS / "site-image.yml").read_text(encoding="utf-8")

    def steps(self) -> str:
        return self.TEXT.split("    steps:\n", 1)[1]

    def test_it_runs_only_on_the_prod_branch(self):
        """Kalera rule: image builds and deploy webhooks never run on main or on pull requests."""
        triggers = self.TEXT.split("\non:\n", 1)[1].split("\npermissions:", 1)[0]
        self.assertEqual(triggers.strip(), "push:\n    branches: [prod]\n  workflow_dispatch:")
        self.assertIn("    if: github.ref == 'refs/heads/prod'", self.TEXT)
        self.assertNotIn("pull_request", self.TEXT)
        for other in sorted(WORKFLOWS.glob("*.yml")):
            if other.name == "site-image.yml":
                continue
            with self.subTest(workflow=other.name):
                text = other.read_text(encoding="utf-8")
                self.assertNotIn("PORTAINER_WEBHOOK_URL", text)
                self.assertNotRegex(text, r"docker (?:build|push)")

    def test_owner_and_image_name_are_variables(self):
        self.assertIn("IMAGE_OWNER: ${{ vars.IMAGE_OWNER || github.repository_owner }}", self.TEXT)
        self.assertIn("SITE_IMAGE_NAME: ${{ vars.SITE_IMAGE_NAME }}", self.TEXT)
        self.assertIn('deploy/site/stack-env.sh --tag prod | tee -a "$GITHUB_ENV"', self.TEXT)
        self.assertIn("SITE_STRICT: ${{ vars.SITE_STRICT == 'false' && 'false' || 'true' }}", self.TEXT)

    def test_tests_build_live_check_push_then_webhook_in_that_order(self):
        steps = self.steps()
        order = ["node site/test.mjs", "node deploy/site/test.mjs", "deploy/site/fetch-downloads.py",
                 "docker build -f deploy/site/Dockerfile", "node deploy/site/check-live-headers.mjs",
                 'docker push "$IMAGE"', 'curl -fsS -X POST --max-time 60 "$PORTAINER_WEBHOOK_URL"']
        positions = [steps.index(marker) for marker in order]
        self.assertEqual(positions, sorted(positions))
        self.assertIn("PORTAINER_WEBHOOK_URL: ${{ secrets.PORTAINER_WEBHOOK_URL }}", steps)
        self.assertIn("--read-only --tmpfs /tmp", steps, "the check runs the container as the stack does")

    def test_permissions_and_pinned_actions(self):
        self.assertRegex(self.TEXT, r"\npermissions:\n  contents: read\n")
        self.assertIn("    permissions:\n      contents: read\n      packages: write\n", self.TEXT)
        for line in (line.strip() for line in self.TEXT.splitlines() if "uses:" in line):
            with self.subTest(action=line):
                self.assertRegex(line, PINNED_ACTION)

    def test_site_yml_tests_and_builds_but_never_deploys(self):
        site = (WORKFLOWS / "site.yml").read_text(encoding="utf-8")
        self.assertNotIn("\n  deploy:\n", site)
        self.assertNotIn("SITE_DEPLOY_TARGET", site)
        self.assertIn("run: node deploy/site/test.mjs", site)
        self.assertEqual(site.count('- "deploy/site/**"'), 2, "push and pull_request paths")


class StackEnvTests(unittest.TestCase):
    SCRIPT = str(DEPLOY / "stack-env.sh")

    def env_of(self, *args: str, **env: str) -> dict[str, str]:
        result = run("bash", self.SCRIPT, *args, env={"IMAGE_OWNER": "", "SITE_IMAGE_NAME": "", **env})
        self.assertEqual(result.returncode, 0, result.stderr)
        return dict(line.split("=", 1) for line in result.stdout.splitlines())

    def test_values_come_from_the_brand_file(self):
        values = brand()
        out = self.env_of("--owner", "KalHoang")
        self.assertEqual(out["SITE_HOST"], values["APP_SITE_HOST"])
        self.assertEqual(out["SITE_SLUG"], values["APP_SLUG"])
        self.assertEqual(out["IMAGE_OWNER"], "kalhoang", "GHCR namespaces are lowercase")
        self.assertEqual(out["IMAGE_NAME"], f"{values['APP_SLUG']}-site")
        self.assertEqual(out["IMAGE"], f"ghcr.io/kalhoang/{values['APP_SLUG']}-site:prod")

    def test_environment_and_options_override_the_defaults(self):
        out = self.env_of("--tag", "sha-abc", IMAGE_OWNER="someone", SITE_IMAGE_NAME="web")
        self.assertEqual(out["IMAGE"], "ghcr.io/someone/web:sha-abc")

    def test_the_owner_falls_back_to_the_repository_url_and_bad_values_fail(self):
        with tempfile.TemporaryDirectory() as tmp:
            env_file = Path(tmp) / "brand.env"
            text = (REPO / "scripts" / "brand.env").read_text(encoding="utf-8")
            env_file.write_text(re.sub(r'APP_REPOSITORY_URL=".*"', 'APP_REPOSITORY_URL="https://github.com/Owner-1/repo"',
                                       text), encoding="utf-8")
            self.assertEqual(self.env_of(BRAND_ENV=str(env_file))["IMAGE_OWNER"], "owner-1")
        missing = run("bash", self.SCRIPT, env={"IMAGE_OWNER": ""})
        self.assertEqual(missing.returncode, 1)
        self.assertIn("no image owner", missing.stderr)
        for args in (["--owner", "bad owner"], ["--owner", "x", "--image-name", "Bad/Name"], ["--owner", "x", "--tag", "-x"]):
            with self.subTest(args=args):
                self.assertEqual(run("bash", self.SCRIPT, *args).returncode, 1)


class FetchDownloadsTests(unittest.TestCase):
    """Q10: the DMG of every release and every update archive of the appcast are served from the site host, fetched
    from the GitHub Release and checked before they go into the image."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.root = self.tmp / "repo"
        (self.root / "scripts").mkdir(parents=True)
        (self.root / "site" / "data").mkdir(parents=True)
        (self.root / "site" / "static").mkdir(parents=True)
        (self.root / "scripts" / "brand.env").write_text('APP_SLUG="app"\nAPP_SITE_HOST="app.example.test"\n',
                                                         encoding="utf-8")
        self.assets = self.tmp / "assets"
        self.assets.mkdir()
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        fake_gh = self.bin / "gh"
        fake_gh.write_text(
            "#!/usr/bin/env bash\n"
            "# fake gh: release download <tag> --repo R --pattern NAME --dir DIR, copied from $FAKE_ASSETS/<tag>/\n"
            'tag="$3"; name="$7"; dir="$9"\n'
            'echo "$*" >> "$FAKE_ASSETS/calls.log"\n'
            '[[ -f "$FAKE_ASSETS/$tag/$name" ]] || { echo "no asset $name" >&2; exit 1; }\n'
            'cp "$FAKE_ASSETS/$tag/$name" "$dir/$name"\n', encoding="utf-8")
        fake_gh.chmod(fake_gh.stat().st_mode | stat.S_IEXEC)
        self.out = self.tmp / "out"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def asset(self, version: str, name: str, content: bytes) -> tuple[str, int]:
        folder = self.assets / f"v{version}"
        folder.mkdir(exist_ok=True)
        (folder / name).write_bytes(content)
        return hashlib.sha256(content).hexdigest(), len(content)

    def write_inputs(self, releases: list[dict], enclosures: list[tuple[str, int]]) -> None:
        (self.root / "site" / "data" / "releases.json").write_text(json.dumps({"releases": releases}), encoding="utf-8")
        items = "".join(f'<item><enclosure url="{url}" length="{length}" type="application/octet-stream"/></item>'
                        for url, length in enclosures)
        (self.root / "site" / "static" / "appcast.xml").write_text(
            f'<?xml version="1.0"?><rss version="2.0"><channel>{items}</channel></rss>', encoding="utf-8")

    def fetch(self, *extra: str):
        env = {"PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}", "FAKE_ASSETS": str(self.assets)}
        return run(sys.executable, "-I", str(DEPLOY / "fetch-downloads.py"), "--out", str(self.out), "--root",
                   str(self.root), "--repo", "owner/repo", *extra, env=env)

    def test_fetches_and_checks_every_file_on_the_site_host(self):
        dmg_sha, dmg_size = self.asset("1.0.0", "app-1.0.0.dmg", b"disk image")
        _, zip_size = self.asset("1.0.0", "app-1.0.0.zip", b"update archive")
        base = "https://app.example.test/download"
        self.write_inputs(
            [{"version": "1.0.0", "dmgUrl": f"{base}/app-1.0.0.dmg", "sha256": dmg_sha, "size": dmg_size},
             {"version": "0.9.0", "dmgUrl": "https://github.com/o/r/releases/download/v0.9.0/app-0.9.0.dmg",
              "sha256": "0" * 64}],
            [(f"{base}/app-1.0.0.zip", zip_size)])
        result = self.fetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(p.name for p in self.out.iterdir()), ["app-1.0.0.dmg", "app-1.0.0.zip"])
        self.assertIn("2 file(s) on the site host, 0 problem(s)", result.stdout)
        calls = (self.assets / "calls.log").read_text(encoding="utf-8")
        self.assertIn("release download v1.0.0 --repo owner/repo --pattern app-1.0.0.dmg", calls)
        again = self.fetch()
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(again.stdout.count("kept "), 2, "files with the right checksum are not downloaded again")

    def test_a_mismatch_or_a_missing_asset_fails_and_nothing_wrong_is_kept(self):
        self.asset("1.0.0", "app-1.0.0.dmg", b"tampered")
        base = "https://app.example.test/download"
        self.write_inputs([{"version": "1.0.0", "dmgUrl": f"{base}/app-1.0.0.dmg", "sha256": "a" * 64}],
                          [(f"{base}/app-1.1.0.zip", 10)])
        result = self.fetch()
        self.assertEqual(result.returncode, 1)
        self.assertIn("app-1.0.0.dmg: SHA-256 does not match releases.json", result.stderr)
        self.assertIn("app-1.1.0.zip: gh release download v1.1.0 failed", result.stderr)
        self.assertFalse((self.out / "app-1.0.0.dmg").exists())

    def test_no_release_yet_needs_nothing_and_bad_names_are_input_errors(self):
        result = self.fetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("0 file(s)", result.stdout)
        self.write_inputs([{"version": "1", "dmgUrl": "https://app.example.test/download/../x.dmg", "sha256": "a" * 64}],
                          [])
        self.assertEqual(self.fetch().returncode, 2)
        self.write_inputs([{"version": "1", "dmgUrl": "https://app.example.test/download/other.dmg", "sha256": "a" * 64}],
                          [])
        self.assertEqual(self.fetch().returncode, 2)

    def test_a_malformed_releases_json_is_an_input_error_not_a_traceback(self):
        """Fail fast at the boundary: releases.json comes from publish-release but is still external input."""
        path = self.root / "site" / "data" / "releases.json"
        for document, message in [
            ({"releases": ["1.0.0"]}, "releases.json: entry 0 is not an object"),
            ([{"dmgUrl": "https://app.example.test/download/app-1.0.0.dmg", "sha256": "a" * 64}, 42],
             "releases.json: entry 1 is not an object"),
            ({"releases": {"version": "1.0.0"}}, "releases.json: `releases` is not a list"),
            ("1.0.0", "releases.json: expected an object with `releases` or a list"),
        ]:
            with self.subTest(document=document):
                path.write_text(json.dumps(document), encoding="utf-8")
                result = self.fetch()
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(message, result.stderr)
                self.assertNotIn("Traceback", result.stderr)

    def test_releases_json_shapes_match_the_site_reader(self):
        """site/lib/data.mjs renders a top-level list or an object with `releases` or `items`; the same entries are
        fetched, so no download link of the site can point at a file the image lacks."""
        sha, size = self.asset("1.0.0", "app-1.0.0.dmg", b"disk image")
        entry = {"version": "1.0.0", "dmgUrl": "https://app.example.test/download/app-1.0.0.dmg", "sha256": sha,
                 "size": size}
        path = self.root / "site" / "data" / "releases.json"
        for document in ([entry], {"items": [entry]}, {"releases": [entry]}):
            with self.subTest(document=list(document) if isinstance(document, dict) else "list"):
                path.write_text(json.dumps(document), encoding="utf-8")
                result = self.fetch()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("1 file(s) on the site host", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=1)
