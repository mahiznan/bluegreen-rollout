# ---- Stage 1: build the jar (Maven + JDK 25) ----
FROM maven:3-eclipse-temurin-25 AS build
WORKDIR /build
COPY pom.xml .
RUN mvn -B -q dependency:go-offline
COPY src ./src
RUN mvn -B -q package -DskipTests

# ---- Stage 2: runtime (JRE 25 only) ----
FROM eclipse-temurin:25-jre
WORKDIR /app
COPY --from=build /build/target/risk-domain.jar /app/risk-domain.jar

# The release id. Passed by scripts/release.sh as --build-arg GIT_COMMIT=<short hash>.
# Declared AFTER the Maven layers so a new commit does not invalidate the dependency cache.
# The app reports this value in every response, so the running pod, not the object
# name, is the source of truth for "which commit is this".
ARG GIT_COMMIT=unknown
ENV GIT_COMMIT=${GIT_COMMIT}

EXPOSE 8080
USER 1001
# Exec form so java is PID 1 and receives SIGTERM (graceful shutdown)
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-jar", "/app/risk-domain.jar"]
