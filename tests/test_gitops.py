"""Exercise deployment confirmation without a cluster or registry."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class GitOpsVerificationTests(unittest.TestCase):
    def run_check(self, revision='manifest-sha', healthy=True, image_tag='image-sha', http_fails=False):
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            response = {'status': {'sync': {'status': 'Synced', 'revision': revision},
                                   'health': {'status': 'Healthy' if healthy else 'Degraded'},
                                   'summary': {'images': ['registry/petclinic-web:' + image_tag,
                                                          'registry/petclinic-was:' + image_tag]}}}
            (tmp / 'response.json').write_text(json.dumps(response))
            (tmp / 'curl').write_text('''#!/bin/bash
for arg in "$@"; do
  if [[ "$arg" == *api/v1/applications* ]]; then
    cat "$TEST_RESPONSE"
    exit 0
  fi
done
touch "$HTTP_MARKER"
[[ "$HTTP_FAIL" == 0 ]]
''')
            (tmp / 'sleep').write_text('#!/bin/bash\nexit 0\n')
            for name in ('curl', 'sleep'):
                (tmp / name).chmod(0o700)
            env = dict(os.environ, PATH=str(tmp) + os.pathsep + os.environ['PATH'],
                       ARGOCD_SERVER='https://argo.example', ARGOCD_APP='petclinic-aws',
                       ARGOCD_TOKEN='fake-token', GITOPS_REVISION='manifest-sha',
                       REGISTRY_USER='registry', IMAGE_TAG='image-sha', APP_URL='https://app.example',
                       TEST_RESPONSE=str(tmp / 'response.json'), HTTP_MARKER=str(tmp / 'checked'),
                       HTTP_FAIL='1' if http_fails else '0')
            result = subprocess.run(['bash', str(ROOT / 'scripts/check-gitops-deployment.sh')],
                                    env=env, capture_output=True, text=True)
            self.assertNotIn('fake-token', result.stdout + result.stderr)
            return result.returncode, (tmp / 'checked').exists()

    def test_expected_revision_and_images_pass(self):
        self.assertEqual(self.run_check(), (0, True))

    def test_old_revision_is_not_accepted_as_success(self):
        code, checked = self.run_check(revision='old-manifest')
        self.assertNotEqual(code, 0)
        self.assertFalse(checked)

    def test_old_image_is_not_accepted_as_success(self):
        code, checked = self.run_check(image_tag='old-image')
        self.assertNotEqual(code, 0)
        self.assertFalse(checked)

    def test_degraded_rollout_is_not_accepted(self):
        code, checked = self.run_check(healthy=False)
        self.assertNotEqual(code, 0)
        self.assertFalse(checked)

    def test_http_failure_after_rollout_fails(self):
        code, checked = self.run_check(http_fails=True)
        self.assertNotEqual(code, 0)
        self.assertTrue(checked)
