# 기술면접 Q&A

## 프로젝트 한 줄 설명

AWS EKS 기반 3-Tier 서비스를 기본 운영 환경으로 두고, 장애 직후에는 HTTPS 점검 페이지를 자동 제공하며, 관리자 승인 후 Azure AKS와 MySQL로 전체 서비스를 복구하는 단계형 멀티클라우드 DR 프로젝트입니다.

## Active-Active인가요?

아닙니다. Pilot Light와 Backup & Restore에 가까운 수동 DR입니다. Azure에는 네트워크, 백업 저장소, 점검 페이지, Front Door를 상시 유지하고 비용이 큰 AKS, Application Gateway, MySQL은 장기 장애가 승인된 뒤 생성합니다.

## 정상 트래픽 경로는 무엇인가요?

`Route 53 → CloudFront → AWS ALB → EKS Web/WAS → RDS MySQL`입니다.

## AWS 장애 시 무엇이 자동으로 전환되나요?

CloudFront Origin Group이 AWS ALB 연결 실패 또는 `500/502/503/504`를 감지하면 `GET/HEAD` 요청을 Azure Front Door로 보냅니다. Front Door는 maintenance mode에서 HTTPS Blob 점검 페이지를 제공합니다.

## 사용자들은 HTTPS 점검 페이지를 자동으로 보나요?

네. CloudFront viewer는 HTTP를 HTTPS로 리다이렉트하고, CloudFront에서 Front Door, Front Door에서 Blob까지도 maintenance mode에서 HTTPS를 사용합니다. 일반 페이지 접속이나 새로고침은 GET이므로 별도 DNS 변경 없이 같은 서비스 도메인에서 점검 페이지를 봅니다.

## 쓰기 요청은 왜 자동 전환되지 않나요?

CloudFront Origin Failover는 GET, HEAD, OPTIONS 요청에만 secondary failover를 수행합니다. 따라서 POST, PUT, PATCH, DELETE를 포함하는 상태 변경 요청은 자동으로 Azure에 재전송되지 않습니다. 이 프로젝트는 그 제한을 숨기지 않고 점검 페이지 단계와 전체 서비스 DR 단계를 분리했습니다.

## 장애 시뮬레이션 사례를 어떻게 설명하나요?

프로젝트 초반에는 Terraform과 클라우드 콘솔의 직관적인 인터페이스, 그리고 AI의 도움으로 인프라를 비교적 수월하게 구축할 수 있었습니다. 그러나 장애 시뮬레이션에서는 GET 화면이 Azure Origin으로 전환되는 것만 확인하고 전체 DR이 성공했다고 판단한 문제가 있었습니다. 쓰기 요청을 별도로 테스트하자 실패했고, CloudFront Origin Failover는 GET, HEAD, OPTIONS 요청에만 Secondary Origin 장애 조치를 수행하며 POST, PUT, PATCH, DELETE 요청은 장애 조치하지 않는다는 점을 확인했습니다. 이에 자동 전환 범위를 입력 기능이 없는 HTTPS 점검 페이지로 제한하고, 전체 서비스 복구는 관리자 승인 후 `2-emergency` 배포, 최신 dump 복원, AKS와 Application Gateway의 읽기·쓰기 검증을 거쳐 CloudFront를 Front Door 직접 Origin으로 수동 전환하도록 재설계했습니다.

## Front Door를 왜 평상시에도 유지하나요?

Blob 기본 endpoint도 HTTPS를 지원하므로 HTTPS만이 유일한 이유는 아닙니다. 장애 전에 검증된 HTTPS 점검 경로를 확보하고, CloudFront의 Azure Origin hostname을 고정하며, Blob과 Application Gateway 사이의 backend 전환점을 통일하기 위해 Front Door 비용을 평상시에도 부담합니다.

## 전체 Azure DR은 언제 전환하나요?

관리자가 장애 범위와 예상 복구 시간을 검토하고 전체 DR을 승인한 뒤 전환합니다. `2-emergency`를 배포하고 최신 dump를 복원한 다음 AKS, Application Gateway, Azure MySQL의 읽기·쓰기와 데이터 정합성을 검증해야 합니다.

## 전체 DR 전환 시 경로는 무엇인가요?

`Route 53 → CloudFront → Azure Front Door → Application Gateway → AKS → Azure MySQL`입니다.

Front Door를 `azure_service`, CloudFront를 `azure_dr` mode로 순서대로 적용합니다. CloudFront는 이때 Origin Group이 아니라 Front Door Origin을 직접 선택하고 7개 HTTP method를 허용합니다.

## 왜 자동으로 AKS를 배포하지 않았나요?

일시 장애에도 비용이 큰 리소스를 자동 생성하면 비용과 운영 위험이 커집니다. DB 복구 없이 트래픽만 먼저 전환하면 데이터 오류가 발생할 수도 있습니다. 그래서 장애 직후 사용자 안내는 자동화하고, 상태가 있는 전체 서비스 복구는 승인과 검증을 거치게 했습니다.

## RTO와 RPO는 어떻게 설명하나요?

점검 페이지 RTO는 CloudFront 장애 판정과 Edge 전파 시간의 영향을 받습니다. 전체 서비스 RTO는 Terraform 배포, dump 복원, workload 배포, App Gateway backend 설정과 검증 시간에 좌우됩니다. RPO는 백업 기반이므로 최신 유효 dump 시점에 의존합니다. 측정하지 않은 고정 시간을 보장값으로 말하지 않습니다.

## Front Door와 CloudFront의 역할 차이는 무엇인가요?

CloudFront는 사용자 도메인의 공통 진입점과 트래픽 상태를 관리합니다. Front Door는 CloudFront가 사용하는 Azure의 고정 Origin으로, maintenance mode에서는 Blob, azure_service mode에서는 Application Gateway를 제공합니다.

## Application Gateway 502는 어떻게 해결했나요?

초기 backend IP가 AKS의 현재 WAS LoadBalancer IP와 달라 health probe가 실패했습니다. Service의 최신 External IP를 다시 조회해 backend pool과 probe를 갱신하고 backend health를 확인했습니다. 이 경험을 통해 동적으로 할당되는 주소를 고정값처럼 다루면 안 된다는 점을 배웠습니다.

## Azure MySQL 인증 오류는 무엇이었나요?

Terraform의 관리자 계정과 Kubernetes Secret의 username/password가 일치하지 않아 WAS가 DB에 접속하지 못했습니다. `mysqladmin` validation을 추가하고 Secret과 JDBC 설정을 같은 값으로 정렬했습니다.

## Terraform destroy 오류는 무엇이었나요?

Kubernetes와 Load Balancer가 만든 ENI와 Security Group 의존성이 남아 삭제 순서가 꼬였습니다. 외부 생성 리소스를 먼저 확인하고 Ingress/Service를 정리한 뒤 Terraform destroy를 수행하도록 절차를 수정했습니다.

## 계층 분리 기반 접근 제어는 어떻게 적용했나요?

Web, WAS, DB를 subnet, node pool, namespace와 Security Group/NSG 규칙으로 분리했습니다. 각 계층은 필요한 다음 계층과 관리 경로만 접근하도록 제한하는 것을 목표로 했습니다. 다만 Azure MySQL의 현재 public access와 비활성 SSL enforcement는 추가 개선 항목으로 명확히 구분합니다.

## ALB Controller의 역할은 무엇인가요?

AWS Load Balancer Controller가 Kubernetes Ingress를 감시해 ALB, listener, target group을 생성합니다. 문서에서는 예전 명칭과 섞지 않고 `AWS Load Balancer Controller`로 통일합니다.

## Failback은 어떻게 하나요?

AWS ALB/EKS/RDS 복구와 데이터 정합성 검증 후 승인을 받고 `scripts/switch-to-aws.sh --approved`를 실행합니다. CloudFront를 normal mode로 먼저 되돌리고 Front Door를 maintenance mode로 복귀시킵니다. Azure `2-emergency` 삭제는 별도 승인으로 수행합니다.

## 1분 답변

이 프로젝트는 AWS EKS 기반 3-Tier 서비스를 Azure로 단계적으로 복구하는 멀티클라우드 DR 프로젝트입니다. 정상 경로는 Route 53, CloudFront, ALB, EKS, RDS이고, AWS 장애 직후 GET/HEAD 요청은 상시 배포된 Front Door를 거쳐 HTTPS Blob 점검 페이지로 자동 전환됩니다. CloudFront Origin Failover가 쓰기 요청을 처리하지 않는다는 제한을 장애 시뮬레이션에서 확인했고, 이를 해결하기 위해 점검 페이지와 전체 서비스 복구를 분리했습니다. 관리자가 전체 DR을 승인하면 Azure `2-emergency`를 배포하고 최신 dump를 복원·검증한 뒤 CloudFront를 Front Door 직접 Origin으로 전환합니다.
