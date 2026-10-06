# PetClinic 소스 통합 기록

이 저장소는 인프라 코드와 배포 대상 애플리케이션을 함께 확인할 수 있도록 `spring-petclinic/`에 Web/WAS 소스를 포함합니다. 별도 저장소였던 `reyne9/spring-petclinic`의 커밋 `a2b359637a02134e35a07e71d2eb9a917341efcb`에서 Maven 빌드에 필요한 소스, 테스트, Dockerfile, Nginx 설정을 가져왔습니다. 이 커밋 ID는 통합 시점의 출처 식별용이며, 이 저장소의 Git 이력에 해당 저장소의 전체 커밋 이력이 합쳐진 것은 아닙니다.

통합 후 PostgreSQL을 사용하는 테스트용 `docker-compose.yml`을 추가하고, 검증되지 않은 운영 상태를 주장하던 애플리케이션 화면 문구를 제거했습니다. 2026년 10월 6일 [GitHub Actions 검증](https://github.com/reyne9/3tier-terraform/actions/runs/37476071052)에서 Maven 테스트와 Web/WAS 이미지 빌드가 통과했습니다. 실제 AWS/Azure 배포와 장애 전환은 이 검증에 포함되지 않습니다.

상위 오픈소스 프로젝트는 [Spring PetClinic](https://github.com/spring-projects/spring-petclinic)입니다. 이 저장소에 포함한 소스의 라이선스는 [`spring-petclinic/LICENSE.txt`](../../spring-petclinic/LICENSE.txt)를 확인하세요.
