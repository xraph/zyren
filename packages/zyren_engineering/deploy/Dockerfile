FROM dart:stable AS build
WORKDIR /src
COPY packages/zyren/pubspec.yaml zyren/pubspec.yaml
COPY packages/zyren/lib zyren/lib
COPY packages/zyren_engineering/pubspec.yaml engineering/pubspec.yaml
COPY packages/zyren_engineering/lib engineering/lib
COPY packages/zyren_engineering/example/hosted_review_service.dart host/bin/server.dart
RUN sed -i '/^resolution: workspace/d' zyren/pubspec.yaml engineering/pubspec.yaml
WORKDIR /src/host
RUN printf 'name: zyren_review_host\nenvironment:\n  sdk: ">=3.10.0 <4.0.0"\ndependencies:\n  zyren_engineering:\n    path: ../engineering\n' > pubspec.yaml
RUN dart pub get && dart compile exe bin/server.dart -o /review-server
RUN mkdir /review-data && chown 65532:65532 /review-data
FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /review-server /usr/local/bin/review-server
COPY --from=build --chown=65532:65532 /review-data /data
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/review-server", "/run/secrets/review_access", "/data/session.json"]
