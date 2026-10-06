# PetClinic application

이 디렉터리는 이 저장소의 AWS/Azure 인프라 코드가 배포 대상으로 삼는 Web/WAS 애플리케이션 소스입니다. 가져온 소스의 커밋과 통합 범위는 [소스 통합 기록](../docs/overview/source-integration.md)에 남겼습니다. 원본은 [Spring PetClinic](https://github.com/spring-projects/spring-petclinic)이며 라이선스는 [LICENSE.txt](LICENSE.txt)를 참고하세요.

Web은 Nginx(80), WAS는 Spring Boot(8080), 데이터베이스는 MySQL입니다. 로컬에서는 기본 H2 설정으로 애플리케이션 테스트를 실행할 수 있습니다.

방문 기록과 별도로 예약 화면을 제공합니다. 소유자 상세 화면에서 반려동물의 예약을 열고 수의사·날짜를 선택하면 비어 있는 시간을 볼 수 있습니다. 평일 09:00~17:00의 1시간 단위(Asia/Seoul)를 사용하며 같은 수의사의 같은 시간 중복 예약은 DB 고유 제약으로 막습니다. 별도 수의사 근무표나 휴무일은 아직 반영하지 않습니다.

```bash
./mvnw test
./mvnw package -DskipTests
docker build -f Dockerfile.was -t petclinic-was:local .
docker build -f Dockerfile.web -t petclinic-web:local .
```

인프라 매니페스트와 기존 Docker Hub 이미지는 별도로 관리되어 왔습니다. 이 소스를 포함한 새 이미지가 실제 AWS/Azure 환경에 배포되었는지는 아직 검증되지 않았습니다.
