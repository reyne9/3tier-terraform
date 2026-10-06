"""Regression tests using local fake clients only; no cloud credentials required."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.clients = {name: Mock() for name in ('ec2', 'eks', 'autoscaling', 'sns')}
        fake_boto = types.SimpleNamespace(client=lambda name: self.clients[name])
        with patch.dict(sys.modules, {'boto3': fake_boto}):
            spec = importlib.util.spec_from_file_location('recovery', ROOT / 'codes/aws/3. monitoring/lambda/index.py')
            self.module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(self.module)
        self.module.SNS_TOPIC_ARN = 'test-topic'

    def test_own_report_is_ignored(self):
        event = {'Records': [{'Sns': {'Message': '\nEKS Auto Recovery Report'}}]}
        self.assertEqual(self.module.handler(event, None)['statusCode'], 200)
        self.clients['sns'].publish.assert_not_called()

    def test_alarm_then_own_notification_does_not_loop(self):
        event = {'Records': [{'Sns': {'Message': json.dumps({'AlarmName': 'test-pod-restart', 'NewStateValue': 'ALARM'})}}]}
        self.module.handler(event, None)
        self.clients['sns'].publish.assert_called_once()
        report = self.clients['sns'].publish.call_args.kwargs['Message']
        self.module.handler({'Records': [{'Sns': {'Message': report}}]}, None)
        self.clients['sns'].publish.assert_called_once()

    def test_initializing_node_is_not_terminated(self):
        self.clients['eks'].list_nodegroups.return_value = {'nodegroups': ['web']}
        self.clients['eks'].describe_nodegroup.return_value = {'nodegroup': {'resources': {'autoScalingGroups': [{'name': 'asg'}]}}}
        self.clients['autoscaling'].describe_auto_scaling_groups.return_value = {'AutoScalingGroups': [{'Instances': [{'InstanceId': 'i-test'}]}]}
        for status, expected in [('initializing', False), ('ok', False), ('impaired', True)]:
            self.clients['autoscaling'].terminate_instance_in_auto_scaling_group.reset_mock()
            self.clients['ec2'].describe_instance_status.return_value = {'InstanceStatuses': [{'InstanceStatus': {'Status': status}, 'SystemStatus': {'Status': 'ok'}}]}
            self.module.handle_node_status_check_failed({'AlarmName': 'status-check-failed'})
            self.assertEqual(self.clients['autoscaling'].terminate_instance_in_auto_scaling_group.called, expected)

    def test_subject_stays_within_sns_limit(self):
        self.module.send_notification('a' * 200, {'success': True, 'action_taken': 'none', 'details': ''})
        self.assertLessEqual(len(self.clients['sns'].publish.call_args.kwargs['Subject']), 100)


class BackupTests(unittest.TestCase):
    def run_backup(self, fail=False):
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            template = (ROOT / 'codes/aws/2. service/scripts/backup-init.sh').read_text()
            script = template.split("<<'BACKUP_SCRIPT'\n", 1)[1].split('\nBACKUP_SCRIPT', 1)[0]
            script = script.replace('export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin', 'export PATH="$TEST_BIN:/usr/bin:/bin"')
            for old, new in [('/var/log/mysql-backup-to-azure.log', str(tmp / 'log')), ('/run/lock/mysql-backup.lock', str(tmp / 'lock')), ('/etc/mysql-backup/config.json', str(tmp / 'config.json')), ('/opt/mysql-backup', str(tmp / 'backups'))]:
                script = script.replace(old, new)
            (tmp / 'backups').mkdir()
            (tmp / 'config.json').write_text(json.dumps(dict(region='test', rds_host='db.test', db_name='petclinic', db_username='admin', azure_storage_account='test', azure_container='mysql-backups', secret_arn='test-secret')))
            (tmp / 'backup.sh').write_text(script)
            programs = {
                'flock': '#!/bin/bash\nexit 0\n',
                'aws': '#!/bin/bash\nprintf \'%s\' \'{"rds_password":"sp ace&|$;\\\"password", "azure_storage_key":"a/key+value="}\'\n',
                'mysqldump': '#!/bin/bash\n[[ "$MYSQL_PWD" == \'sp ace&|$;"password\' ]] || exit 42\n[[ "$DUMP_FAIL" == 1 ]] && exit 9\nprintf \'USE `petclinic`;\\nCREATE TABLE test (id INT);\\n\'\n',
                'az': '#!/bin/bash\n[[ "$AZURE_STORAGE_KEY" == "a/key+value=" ]] || exit 43\ntouch "$UPLOAD_MARKER"\n',
            }
            for name, contents in programs.items():
                path = tmp / name
                path.write_text(contents)
                path.chmod(0o700)
            env = dict(os.environ, TEST_BIN=str(tmp), DUMP_FAIL='1' if fail else '0', UPLOAD_MARKER=str(tmp / 'uploaded'))
            result = subprocess.run(['bash', str(tmp / 'backup.sh')], env=env, capture_output=True, text=True)
            return result.returncode, (tmp / 'uploaded').exists(), list((tmp / 'backups').glob('*.partial'))

    def test_special_characters_survive_and_upload_succeeds(self):
        code, uploaded, partials = self.run_backup()
        self.assertEqual(code, 0)
        self.assertTrue(uploaded)
        self.assertFalse(partials)

    def test_failed_dump_is_not_uploaded(self):
        code, uploaded, partials = self.run_backup(fail=True)
        self.assertNotEqual(code, 0)
        self.assertFalse(uploaded)
        self.assertFalse(partials)


class RestoreTests(unittest.TestCase):
    def run_restore(self, database='petclinic', mysql_fails=False):
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            script_dir = tmp / 'scripts'
            script_dir.mkdir()
            source = ROOT / 'codes/azure/2-emergency/scripts/restore-db.sh'
            (script_dir / source.name).write_text(source.read_text())
            client = r'''import gzip, json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
if name == 'terraform':
    outputs = {'mysql_fqdn': 'db.test', 'mysql_database_name': 'petclinic', 'mysql_username': 'mysqladmin', 'storage_account_name': 'test', 'backup_container_name': 'mysql-backups'}
    print(outputs[args[-1]])
elif name == 'az':
    if args[:3] == ['storage', 'blob', 'list']:
        print('backups/latest.sql.gz')
    elif args[:3] == ['storage', 'blob', 'download']:
        with gzip.open(args[args.index('--file') + 1], 'wt') as f:
            f.write('USE `' + os.environ['TEST_DUMP_DB'] + '`;\nCREATE TABLE test (id INT);\n')
elif name == 'mysql':
    if '-e' in args:
        print('1')
    else:
        pathlib.Path(os.environ['RESTORE_MARKER']).write_text(sys.stdin.read())
        if os.environ['MYSQL_FAIL'] == '1':
            sys.exit(3)
'''
            for name in ('terraform', 'az', 'mysql'):
                executable = tmp / name
                executable.write_text('#!' + sys.executable + '\n' + client)
                executable.chmod(0o700)
            env = dict(os.environ, PATH=str(tmp) + os.pathsep + os.environ['PATH'], DB_PASSWORD='fake-password', TEST_DUMP_DB=database, RESTORE_MARKER=str(tmp / 'restored'), MYSQL_FAIL='1' if mysql_fails else '0')
            result = subprocess.run(['bash', str(script_dir / source.name)], env=env, capture_output=True, text=True)
            return result, (tmp / 'restored').exists()

    def test_matching_dump_restores(self):
        result, restored = self.run_restore()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(restored)

    def test_wrong_database_is_rejected_before_mysql(self):
        result, restored = self.run_restore(database='another_database')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(restored)

    def test_mysql_failure_is_not_reported_as_success(self):
        result, restored = self.run_restore(mysql_fails=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('복원 완료:', result.stdout)


class ShellSyntaxTests(unittest.TestCase):
    def test_all_project_shell_scripts_parse(self):
        for folder in ('codes', 'scripts'):
            for path in (ROOT / folder).rglob('*.sh'):
                if '.terraform' not in path.parts:
                    with self.subTest(path=str(path.relative_to(ROOT))):
                        result = subprocess.run(['bash', '-n', str(path)], capture_output=True, text=True)
                        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
