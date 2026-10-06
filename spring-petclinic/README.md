# PetClinic application

이 디렉터리는 이 저장소의 AWS/Azure 인프라 코드가 배포 대상으로 삼는 Web/WAS 애플리케이션 소스입니다. `reyne9/spring-petclinic`의 `a2b359637a02134e35a07e71d2eb9a917341efcb` 커밋에서 Maven 빌드에 필요한 소스, 테스트, Dockerfile, Nginx 설정을 가져왔습니다. 원본은 [Spring PetClinic](https://github.com/spring-projects/spring-petclinic)이며 라이선스는 [LICENSE.txt](LICENSE.txt)를 참고하세요.

Web은 Nginx(80), WAS는 Spring Boot(8080), 데이터베이스는 MySQL입니다. 로컬에서는 기본 H2 설정으로 애플리케이션 테스트를 실행할 수 있습니다.

```bash
./mvnw test
./mvnw package -DskipTests
docker build -f Dockerfile.was -t petclinic-was:local .
docker build -f Dockerfile.web -t petclinic-web:local .
```

인프라 매니페스트와 기존 Docker Hub 이미지는 별도로 관리되어 왔습니다. 이 소스를 포함한 새 이미지가 실제 AWS/Azure 환경에 배포되었는지는 아직 검증되지 않았습니다.
