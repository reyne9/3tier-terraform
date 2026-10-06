"""
EKS Auto Recovery Lambda Function
알람 발생 시 자동 복구 작업을 수행합니다.
"""

import json
import boto3
import os
import logging

# 로깅 설정
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# AWS 클라이언트
ec2 = boto3.client('ec2')
eks = boto3.client('eks')
autoscaling = boto3.client('autoscaling')
sns = boto3.client('sns')

# 환경 변수
CLUSTER_NAME = os.environ.get('CLUSTER_NAME', '')
SNS_TOPIC_ARN = os.environ.get('SNS_TOPIC_ARN', '')
ENVIRONMENT = os.environ.get('ENVIRONMENT', 'prod')


def handler(event, context):
    """
    메인 Lambda 핸들러
    SNS로부터 CloudWatch 알람 메시지를 수신하여 처리합니다.
    """
    logger.info(f"Received event: {json.dumps(event)}")

    try:
        # SNS 메시지 파싱
        for record in event.get('Records', []):
            try:
                message = json.loads(record['Sns']['Message'])
            except (ValueError, KeyError, TypeError):
                continue
            if not isinstance(message, dict) or 'AlarmName' not in message:
                continue
            alarm_name = message.get('AlarmName', '')
            new_state = message.get('NewStateValue', '')

            logger.info(f"Processing alarm: {alarm_name}, State: {new_state}")

            # ALARM 상태일 때만 복구 작업 수행
            if new_state == 'ALARM':
                recovery_result = perform_recovery(alarm_name, message)
                send_notification(alarm_name, recovery_result)
            else:
                logger.info(f"Alarm {alarm_name} is in {new_state} state. No action needed.")

        return {
            'statusCode': 200,
            'body': json.dumps('Recovery check completed')
        }

    except Exception as e:
        logger.error(f"Error processing event: {str(e)}")
        raise


def perform_recovery(alarm_name: str, alarm_data: dict) -> dict:
    """
    알람 유형에 따른 복구 작업 수행
    """
    result = {
        'alarm_name': alarm_name,
        'action_taken': 'none',
        'success': True,
        'details': ''
    }

    try:
        # 노드 상태 체크 실패 알람
        if 'status-check-failed' in alarm_name.lower():
            result = handle_node_status_check_failed(alarm_data)

        # Pod 재시작 횟수 초과 알람
        elif 'pod-restart' in alarm_name.lower():
            result = handle_pod_restart_high(alarm_data)

        # 노드 수 부족 알람
        elif 'node-count-low' in alarm_name.lower():
            result = handle_node_count_low(alarm_data)

        # CPU/메모리 과부하 알람
        elif 'cpu-high' in alarm_name.lower() or 'memory-high' in alarm_name.lower():
            result = handle_resource_pressure(alarm_data)

        # Unhealthy 호스트 알람
        elif 'unhealthy-host' in alarm_name.lower():
            result = handle_unhealthy_hosts(alarm_data)

        else:
            result['details'] = f"No auto-recovery action defined for alarm: {alarm_name}"
            logger.info(result['details'])

    except Exception as e:
        result['success'] = False
        result['details'] = f"Recovery failed: {str(e)}"
        logger.error(result['details'])

    return result


def handle_node_status_check_failed(alarm_data: dict) -> dict:
    """
    노드 상태 체크 실패 시 복구
    - 비정상 인스턴스를 종료하고 ASG가 새 인스턴스를 시작하도록 함
    """
    result = {
        'alarm_name': alarm_data.get('AlarmName', ''),
        'action_taken': 'terminate_unhealthy_instance',
        'success': True,
        'details': ''
    }

    try:
        # EKS 노드 그룹의 ASG 찾기
        nodegroups = eks.list_nodegroups(clusterName=CLUSTER_NAME)

        for ng_name in nodegroups.get('nodegroups', []):
            ng_info = eks.describe_nodegroup(
                clusterName=CLUSTER_NAME,
                nodegroupName=ng_name
            )

            # ASG 이름 가져오기
            asg_name = ng_info['nodegroup']['resources']['autoScalingGroups'][0]['name']

            # ASG 내 비정상 인스턴스 찾기
            asg_response = autoscaling.describe_auto_scaling_groups(
                AutoScalingGroupNames=[asg_name]
            )

            for asg in asg_response.get('AutoScalingGroups', []):
                for instance in asg.get('Instances', []):
                    instance_id = instance['InstanceId']

                    # EC2 인스턴스 상태 확인
                    ec2_status = ec2.describe_instance_status(
                        InstanceIds=[instance_id]
                    )

                    for status in ec2_status.get('InstanceStatuses', []):
                        instance_status = status.get('InstanceStatus', {}).get('Status', '')
                        system_status = status.get('SystemStatus', {}).get('Status', '')

                        if instance_status == 'impaired' or system_status == 'impaired':
                            logger.info(f"Terminating unhealthy instance: {instance_id}")

                            # 인스턴스 종료 (ASG가 자동으로 새 인스턴스 시작)
                            autoscaling.terminate_instance_in_auto_scaling_group(
                                InstanceId=instance_id,
                                ShouldDecrementDesiredCapacity=False
                            )

                            result['details'] += f"Terminated unhealthy instance: {instance_id}. "

        if not result['details']:
            result['details'] = "No unhealthy instances found to terminate."

    except Exception as e:
        result['success'] = False
        result['details'] = f"Failed to handle status check failure: {str(e)}"

    return result


def handle_pod_restart_high(alarm_data: dict) -> dict:
    """
    Pod 재시작 횟수가 높을 때의 복구
    - 알림만 보내고 수동 조치 권장 (Pod 재시작은 k8s가 자동 처리)
    """
    result = {
        'alarm_name': alarm_data.get('AlarmName', ''),
        'action_taken': 'notification_only',
        'success': True,
        'details': 'High pod restart count detected. Kubernetes will handle pod recovery automatically. '
                   'Manual investigation recommended to identify root cause.'
    }

    logger.info(result['details'])
    return result


def handle_node_count_low(alarm_data: dict) -> dict:
    """
    노드 수가 최소값 미만일 때의 복구
    - ASG desired capacity 증가
    """
    result = {
        'alarm_name': alarm_data.get('AlarmName', ''),
        'action_taken': 'scale_up_nodes',
        'success': True,
        'details': ''
    }

    try:
        nodegroups = eks.list_nodegroups(clusterName=CLUSTER_NAME)

        for ng_name in nodegroups.get('nodegroups', []):
            ng_info = eks.describe_nodegroup(
                clusterName=CLUSTER_NAME,
                nodegroupName=ng_name
            )

            current_size = ng_info['nodegroup']['scalingConfig']['desiredSize']
            min_size = ng_info['nodegroup']['scalingConfig']['minSize']
            max_size = ng_info['nodegroup']['scalingConfig']['maxSize']

            # 현재 크기가 최소값과 같으면 증가
            if current_size <= min_size and current_size < max_size:
                new_size = min(current_size + 1, max_size)

                eks.update_nodegroup_config(
                    clusterName=CLUSTER_NAME,
                    nodegroupName=ng_name,
                    scalingConfig={
                        'minSize': min_size,
                        'maxSize': max_size,
                        'desiredSize': new_size
                    }
                )

                result['details'] += f"Scaled nodegroup {ng_name} from {current_size} to {new_size}. "
                logger.info(result['details'])

        if not result['details']:
            result['details'] = "Node groups are already at or above minimum capacity."

    except Exception as e:
        result['success'] = False
        result['details'] = f"Failed to scale up nodes: {str(e)}"

    return result


def handle_resource_pressure(alarm_data: dict) -> dict:
    """
    리소스 압박(CPU/메모리 과부하) 시의 복구
    - 알림 및 스케일 아웃 권장
    """
    result = {
        'alarm_name': alarm_data.get('AlarmName', ''),
        'action_taken': 'notification_with_recommendation',
        'success': True,
        'details': 'High resource utilization detected. Consider scaling out your application or nodes. '
                   'Check HPA settings if available.'
    }

    logger.info(result['details'])
    return result


def handle_unhealthy_hosts(alarm_data: dict) -> dict:
    """
    비정상 호스트 감지 시의 복구
    - 로드밸런서에서 비정상 타겟 확인 및 알림
    """
    result = {
        'alarm_name': alarm_data.get('AlarmName', ''),
        'action_taken': 'notification_with_investigation',
        'success': True,
        'details': 'Unhealthy targets detected in load balancer. '
                   'Kubernetes readiness probes should handle pod-level issues. '
                   'Check pod logs and node status for investigation.'
    }

    logger.info(result['details'])
    return result


def send_notification(alarm_name: str, recovery_result: dict):
    """
    복구 작업 결과를 SNS로 전송
    """
    if not SNS_TOPIC_ARN:
        logger.warning("SNS_TOPIC_ARN not set. Skipping notification.")
        return

    status = "SUCCESS" if recovery_result['success'] else "FAILED"

    message = f"""
🔧 EKS Auto Recovery Report

Environment: {ENVIRONMENT}
Cluster: {CLUSTER_NAME}
Alarm: {alarm_name}

Action Taken: {recovery_result['action_taken']}
Status: {status}

Details:
{recovery_result['details']}

---
This is an automated message from EKS Auto Recovery Lambda.
"""

    try:
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=f"[{status}] EKS Auto Recovery - {alarm_name}"[:100],
            Message=message
        )
        logger.info(f"Notification sent for alarm: {alarm_name}")
    except Exception as e:
        logger.error(f"Failed to send notification: {str(e)}")
